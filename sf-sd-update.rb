#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'logger'
require 'aws-sdk-resources'
require 'securerandom'
require 'yaml'
require 'optparse'

# For development only
require 'pry'

SLEEP_PERIOD = 2
MAX_RETRIES = 30

retries = 0
pending_operations = []

log = Logger.new(STDERR)

options = {}
optparse = OptionParser.new do |opts|
  options[:config] = '/etc/sf-r53-update.yaml'
  opts.on('-c', '--config file') do |c|
    options[:config] = c
  end

  options[:debug] = false
  opts.on('-d', '--debug') do
    options[:debug] = true
  end

  options[:noop] = false
  opts.on('-n', '--noop') do
    options[:noop] = true
  end
end

begin
  optparse.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  warn $ERROR_INFO.to_s
  warn optparse
  exit 2
end

log.level = if options[:debug]
              Logger::DEBUG
            else
              Logger::INFO
            end

# Attempt to load config
log.info("Loading config from #{options[:config]}")
config = YAML.safe_load(File.open(options[:config]))
config_errors = 0
%w[instance_asg_name instance_address_property hosted_zone record_set health_check_tag health_check_config service_name vpc_id service_discovery_timeout prune_service prune_namespace].each do |k|
  unless config.key?(k)
    log.error("No #{k} in config file")
    config_errors += 1
  end
end

unless %w[public_ip_address private_ip_address].include? config['instance_address_property']
  log.error('instance_address_property must be public_ip_address or private_ip_address')
  config_errors += 1
end

exit 1 if config_errors > 0

# Ensure DNS names are given a trailing period
%w[hosted_zone record_set].each do |k|
  config[k] << '.' unless config[k].end_with? '.'
end

log.debug("Config: #{config}")

# If we haven't set a region in the environment, try and find one from
# the link-local endpoint.

unless ENV.key?('AWS_REGION')

  begin
    http = Net::HTTP.new('169.254.169.254', 80)
    http.open_timeout = 1
    http.read_timeout = 1
    instance_identity = JSON.parse(http.request(Net::HTTP::Get.new('/latest/dynamic/instance-identity/document')).body)
    ENV['AWS_REGION'] = instance_identity['region']
    log.debug("Identified region as #{ENV['AWS_REGION']} from link-local endpoint")
  rescue Errno::EHOSTUNREACH, Net::OpenTimeout, Timeout::Error
    log.warn('No link-local endpoint - can\'t calculate region')
  end

end

# Create clients for the API

ec2 = Aws::EC2::Client.new
sd = Aws::ServiceDiscovery::Client.new

# Find EC2 instances matching the given filter, extract their addresses and instance IDs

addresses = []
instance_addresses = {}

instance_filter = [
  {
    'name' => 'tag:aws:autoscaling:groupName',
    'values' => [config['instance_asg_name']]
  },
  {
    'name' => 'instance-state-name',
    'values' => ['running']
  }
]

instance_address_property = config['instance_address_property']

ec2.describe_instances(filters: instance_filter).reservations.each do |r|
  r.instances.each do |i|
    address = i[instance_address_property]
    instance_id = i['instance_id']
    log.debug("Found instance with #{instance_address_property} = #{address}")
    addresses << address
    instance_addresses[instance_id] = address
  end
end

# Check if namespace exists

# Add _sd during testing so as to not conflict with non ServiceDiscovery domains
config['hosted_zone'] = "#{config['hosted_zone']}_sd"

namespace_id = false
namespace_exists = false

sd.list_namespaces.namespaces.each do |namespace|
  next unless namespace.name == config['hosted_zone']
  log.info("Found namespace for zone #{config['hosted_zone']}, id #{namespace.id}")
  namespace_exists = true
  namespace_id = namespace.id
  break
end

unless namespace_exists
  log.info("Creating private DNS namespace: #{config['hosted_zone']}")
  response = sd.create_private_dns_namespace(
    name: config['hosted_zone'],
    vpc: config['vpc_id']
  )
  # Block until namespace is created
  retries = 0
  loop do
    status = sd.get_operation(operation_id: response.operation_id).operation.status
    log.info "Operation #{response.operation_id} status: #{status}"
    break if status == 'SUCCESS'
    sleep(SLEEP_PERIOD)
    if retries == MAX_RETRIES
      error_message = sd.get_operation(operation_id: response.operation_id).operation.error_message
      log.critical("Failed to create namespace for zone #{config['hosted_zone']}, error #{error_message}")
      exit(1)
    end
    retries += 1
  end
  namespace_id = sd.get_operation(operation_id: response.operation_id).operation.targets['NAMESPACE']
end

# Check if service exists
service_exists = false
service_id = false

sd.list_services.services.each do |service|
  next unless service.name == config['service_name']
  log.info("Found service for service #{config['service_name']}, id #{service.id}")
  service_id = service.id
  service_exists = true
  break
end

# Create service
unless service_exists
  retries = 0
  begin
    log.info("Creating service: #{config['service_name']}")
    response = sd.create_service(
      name: config['service_name'],
      dns_config: {
        namespace_id: namespace_id,
        dns_records: [
          {
            type: 'A',
            ttl: 1
          }
        ]
      }
    )
    service_id = response.service.id
  rescue e
    log.critical("Failed to create service #{config['service_name']} with error #{e}")
    exit(1)
  end
end

# Collect a list of instances in ServiceDiscovery service
sd_instances = []
sd.list_instances(service_id: service_id).instances.each do |instance|
  sd_instances << instance.id
end

# Register missing instances
instance_addresses.each do |instance_id, instance_ipv4|
  next if sd_instances.include? instance_id
  log.info "Registering instance #{instance_id} with IPv4 #{instance_ipv4}"
  response = sd.register_instance(
    service_id: service_id,
    instance_id: instance_id,
    attributes: {
      'AWS_INSTANCE_PORT' => '80',
      'AWS_INSTANCE_IPV4' => instance_ipv4.to_s
    }
  )
  pending_operations << response.operation_id
end

# Deregister instances
sd_instances.each do |instance_id|
  next if instance_addresses.key? instance_id
  log.info "Deregistering instance #{instance_id}"
  response = sd.deregister_instance(
    service_id: service_id,
    instance_id: instance_id
  )
  pending_operations << response.operation_id
end

# Check status of pending operations
retries = 0
loop do
  log.info "Pending instance operations: #{pending_operations.length}"
  pending_operations.each do |operation_id|
    status = sd.get_operation(operation_id: operation_id).operation.status
    log.info "Operation #{operation_id} status: #{status}"
    pending_operations.delete(operation_id) if status == 'SUCCESS'
  end
  break if pending_operations.empty?
  sleep(SLEEP_PERIOD)
  if retries == MAX_RETRIES
    log.critical "Operations failed after #{retries} retries:"
    pending_operations.each do |operation_id|
      status = sd.get_operation(operation_id: operation_id).operation.status
      log.critical "Operation #{operation_id} failed with status: #{status}"
    end
    exit(1)
  end
  retries += 1
end

# Remove service if no instances are registered
if config['prune_service']
  # Check if service has any remaining instances
  if sd.list_instances(service_id: service_id).instances.empty?
    begin
          response = sd.delete_service(id: service_id)
        rescue e
          log.critical("Failed to delete service #{config['service_name']}, error #{e}")
          exit(1)
        end
    log.info "Deleted service: #{config['service_name']}"
  else
    # Service has remaining instances - prevent namespace pruning
    log.info("Not pruning service #{config['service_name']}")
    config['prune_namespace'] = false
  end
end

# Remove namespace if namespace and service pruning is enabled
if config['prune_namespace'] && config['prune_service']
  response = sd.delete_namespace(id: namespace_id)
  # Block until namespace is deleted
  retries = 0
  loop do
    status = sd.get_operation(operation_id: response.operation_id).operation.status
    log.info "Operation #{response.operation_id} status: #{status}"
    break if status == 'SUCCESS'
    sleep(SLEEP_PERIOD)
    if retries == MAX_RETRIES
      error_message = sd.get_operation(operation_id: response.operation_id).operation.error_message
      log.critical("Failed to delete namespace for zone #{config['hosted_zone']}, error #{error_message}")
      exit(1)
    end
    retries += 1
  end
  log.info "Deleted namespace: #{config['hosted_zone']}"
end

exit 0
