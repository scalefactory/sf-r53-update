# sf-r53-update

## About

This is a script to maintain Route53 resource record sets and health checks according to the addresses of server instances in Autoscaling Groups.

## Usage

```
Usage: sf-r53-update [options]
    -c, --config file   Path to YAML config file (default /etc//etc/sf-r53-update.yaml)
    -d, --debug         Log debug messages
    -n, --noop          Don't make any real changes
```

## Configuration

### AWS Credentials

This script will attempt to use a machine's IAM role to identify itself to the AWS APIs, and this is the recommended method of operation.

Absent an IAM role, it will fall back to looking up the credentials in the environment.  Use `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION` va
riables.

The IAM role will need the following permissions, though you can constrain the Resource match for additional security if required.

```
{
    "Version": "2012-10-17",
    "Statement": [
            {
                "Action": [
                    "ec2:DescribeInstances",
                    "route53:ListHealthChecks",
                    "route53:CreateHealthCheck",
                    "route53:DeleteHealthCheck",
                    "route53:ListHostedZones",
                    "route53:ListResourceRecordSets",
                    "route53:ChangeResourceRecordSets",
                    "tag:*"
                ],
                "Effect": "Allow",
                "Resource": [
                    "*"
                ]
            }
    ]
}
```

### Script Configuration

The configuration should be in YAML format:

```
---
instance_asg_name:         example_asg
instance_address_property: public_ip_address
hosted_zone:               example.com.
record_set:                '*.example.com'
health_check_tag:          example_health_check

health_check_config:
    :port:              80
    :type:              TCP
    :request_interval:  10
    :failure_threshold: 3
```

This configuration will cause the script to work in the following way:

  * Enumerate all hosts in the `example_asg` autoscaling group.
  * Obtain their public IP address
  * Create health checks following the health_check_config settings for each IP (if these don't exist), tagging them with `example_health_check`.
  * Create record sets of `*.example.com` for each address, associated with the appropriate healthcheck.
  * Remove any record sets or healthchecks that don't match the list of instances.

Health checks without a matching tag won't be touched.

The 'health_check_config' hash is used as-is in http://docs.aws.amazon.com/sdkforruby/api/Aws/Route53/Client.html#create_health_check-instance_method and can therefore support HTTP, TCP and HTTPS checks. 

### Known Limitations

If the resource record set for an IP already exists, its healthcheck ID won't be updated.


