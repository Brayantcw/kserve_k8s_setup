variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
