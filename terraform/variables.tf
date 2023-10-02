# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0
variable "ssh_keyname" {
  type    = string
  default = "vaccination-key"
}
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}
