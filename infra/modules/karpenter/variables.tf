variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "node_iam_role_arn" {
  description = "IAM role ARN for Karpenter-launched nodes"
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
