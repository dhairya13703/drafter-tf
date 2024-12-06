output "aws_servers" {
  value = {
    for key, module_instances in local.aws_servers : key => {
      for key, module_instance in module_instances : key => {
        user         = module_instance.user
        ipv4_address = module_instance.ipv4_address
        ipv6_address = module_instance.ipv6_address
      }
    }
  }
}
