# Required variables
aws_region          = "af-south-1"       # e.g. eu-west-1, af-south-1
private_subnet_id   = "subnet-0ca80cf221d8d832e" # private subnet where EC2 + EFS live
ami_id              = "ami-09783b149d42d341d"    # Amazon Linux 2023 or preferred AMI
private_instance_ip = "172.16.2.123"    # free IP inside the private subnet CIDR

# Optional variables (have defaults)
application_name               = "kite-server"        # used for naming/tagging
instance_type                  = "t3.small"           # override if needed
root_volume_size               = 20                    # GiB for root EBS volume
scripts_bucket_name            = ""                    # leave empty to auto-create bytecat-scripts-<account-id>
key_pair_name                  = ""                    # leave empty to create instance without SSH key

tag_name                       = "bytecat"        # common tag key
tag_value                      = "thebytecat"                # common tag value
