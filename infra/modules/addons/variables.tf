variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
