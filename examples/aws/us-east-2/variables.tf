# SSH
variable "ssh_public_key" {
  description = "SSH Public Key Location"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}