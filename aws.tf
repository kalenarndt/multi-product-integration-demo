provider "aws" {
  region     = var.aws_region
  access_key = data.doormat_aws_credentials.creds.access_key
  secret_key = data.doormat_aws_credentials.creds.secret_key
  token      = data.doormat_aws_credentials.creds.token
}

data "aws_availability_zones" "available" {
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  azs                  = data.aws_availability_zones.available.names
  cidr                 = var.vpc_cidr_block
  enable_dns_hostnames = true
  name                 = "${var.stack_id}-vpc"
  private_subnets      = var.vpc_private_subnets
  public_subnets       = var.vpc_public_subnets
}

resource "aws_security_group" "nomad_server" {
  name   = "nomad-server"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true  # reference to the security group itself
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "nomad_server_asg_template" {
  name_prefix   = "lt-"
  image_id      = data.hcp_packer_image.ubuntu_lunar_hashi_amd.cloud_image_id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups = [ aws_security_group.nomad_server.id ]
  }

  private_dns_name_options {
    hostname_type = "resource-name"
  }

  user_data = base64encode(
    templatefile("${path.module}/scripts/nomad-server.tpl",
      {
        nomad_license      = var.nomad_license,
        consul_ca_file     = hcp_consul_cluster.hashistack.consul_ca_file,
        consul_config_file = hcp_consul_cluster.hashistack.consul_config_file
        consul_acl_token   = data.consul_acl_token_secret_id.read.secret_id
      }
    )
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nomad_server_asg" {
  desired_capacity  = 3
  max_size          = 5
  min_size          = 1
  health_check_type = "EC2"
  health_check_grace_period = "60"

  name_prefix = "nomad-server"

  launch_template {
    id = aws_launch_template.nomad_server_asg_template.id
    version = aws_launch_template.nomad_server_asg_template.latest_version
  }
  
  vpc_zone_identifier = module.vpc.public_subnets

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}