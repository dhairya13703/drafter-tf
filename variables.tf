# SSH
variable "ssh_public_key" {
  description = "SSH Public Key Location"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# Hetzner
variable "hetzner_api_key" {
  description = "Hetzner API Key"
  type        = string
}

variable "hetzner_location" {
  description = "Hetzner Location"
  type        = string
  default     = "nbg1"
}

# AWS
variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-west-2"
}

variable "aws_access_key" {
  description = "AWS Access Key"
  type        = string
}

variable "aws_secret_key" {
  description = "AWS Secret Key"
  type        = string
}

variable "aws_token" {
  description = "AWS Session Token"
  type        = string
}

# Azure
variable "azure_region" {
  description = "Azure Region"
  type        = string
  default     = "West US"
}

variable "azure_subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}
