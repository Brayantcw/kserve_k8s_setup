variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for EKS"
  type        = list(string)
}

variable "system_node_instance_types" {
  description = "Instance types for the system (non-GPU) managed node group"
  type        = list(string)
  default     = ["m5.large"]
}

variable "system_node_min" {
  type    = number
  default = 2
}

variable "system_node_max" {
  type    = number
  default = 4
}

variable "system_node_desired" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
