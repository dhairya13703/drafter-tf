module "aws_ssh_key_us_east_2" {
  source = "../../../modules/aws/ssh_key"
  providers = {
    aws.primary = aws.us_east_2
  }

  name       = "uninstance"
  public_key = file(var.ssh_public_key)
}

module "aws_servers_us_east_2" {
  source = "../../../modules/aws/server"
  providers = {
    aws.primary = aws.us_east_2
  }

  for_each = {
    alma_aws_pvm_node_1_us_east_2 = {
      name          = "alma-aws-pvm-node-1-us-east-2"
      ami_owner     = "679593333241"
      ami_name      = "AlmaLinux OS 9*x86_64*"
      instance_type = "c6a.xlarge" # AMD Milan
      user_data     = file("${path.module}/cloud-init-alma-aws.yaml")
    }

    alma_aws_pvm_node_2_us_east_2 = {
      name          = "alma-aws-pvm-node-2-us-east-2"
      ami_owner     = "679593333241"
      ami_name      = "AlmaLinux OS 9*x86_64*"
      instance_type = "c6a.xlarge" # AMD Milan
      user_data     = file("${path.module}/cloud-init-alma-aws.yaml")
    }

    # alma_aws_pvm_node_3_us_east_2 = {
    #   name          = "alma-aws-pvm-node-3-us-east-2"
    #   ami_owner     = "679593333241"
    #   ami_name      = "AlmaLinux OS 9*x86_64*"
    #   instance_type = "c6a.xlarge" # AMD Milan
    #   user_data     = file("${path.module}/cloud-init-alma-aws.yaml")
    # }
  }

  name            = each.value.name
  ami_owner       = each.value.ami_owner
  ami_name        = each.value.ami_name
  instance_type   = each.value.instance_type
  public_key_name = module.aws_ssh_key_us_east_2.name
  user_data       = each.value.user_data
}

locals {
  aws_servers = {
    # us_west_2 = module.aws_servers_us_west_2
    us_east_2 = module.aws_servers_us_east_2
  }
}
