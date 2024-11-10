terraform {
  required_providers {
    hcloud = {
      source  = "opentofu/hcloud"
      version = "~> 1.0"
    }
  }
}

provider "hcloud" {
  token = var.hetzner_api_key
  alias = "primary"
}
