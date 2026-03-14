locals {
  cluster_name = "${var.project}-${var.environment}"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ──────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────

module "vpc" {
  source = "../../modules/vpc"

  name            = local.cluster_name
  cidr            = "10.0.0.0/16"
  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet("10.0.0.0/16", 8, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet("10.0.0.0/16", 8, i + 100)]
  cluster_name    = local.cluster_name
  tags            = local.tags
}

# ──────────────────────────────────────────────
# EKS Cluster + System Node Group
# ──────────────────────────────────────────────

module "eks" {
  source = "../../modules/eks"

  cluster_name               = local.cluster_name
  cluster_version            = "1.31"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  system_node_instance_types = ["m5.large"]
  system_node_min            = 2
  system_node_max            = 4
  system_node_desired        = 2
  tags                       = local.tags
}

# ──────────────────────────────────────────────
# Karpenter (node autoscaler for inference)
# ──────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name     = module.eks.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  tags             = local.tags
}

# ──────────────────────────────────────────────
# Cluster Add-ons (ALB, metrics-server, NVIDIA, prometheus-adapter)
# ──────────────────────────────────────────────

module "addons" {
  source = "../../modules/addons"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  vpc_id            = module.vpc.vpc_id
  region            = var.region
  tags              = local.tags
}

# ──────────────────────────────────────────────
# Karpenter NodePool + EC2NodeClass
#
# Configs live in k8s/karpenter/*.yaml as documented YAML files.
# Terraform injects cluster-specific values via templatefile() and
# applies them with kubectl_manifest.
# ──────────────────────────────────────────────

locals {
  karpenter_vars = {
    cluster_name       = local.cluster_name
    node_iam_role_name = module.karpenter.karpenter_node_iam_role_name
  }

  karpenter_manifests_dir = "${path.module}/../../../k8s/karpenter"
}

resource "kubectl_manifest" "karpenter_node_class_gpu" {
  yaml_body  = templatefile("${local.karpenter_manifests_dir}/gpu-node-class.yaml", local.karpenter_vars)
  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_node_class_cpu" {
  yaml_body  = templatefile("${local.karpenter_manifests_dir}/cpu-node-class.yaml", local.karpenter_vars)
  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_nodepool_gpu" {
  yaml_body  = file("${local.karpenter_manifests_dir}/gpu-nodepool.yaml")
  depends_on = [kubectl_manifest.karpenter_node_class_gpu]
}

resource "kubectl_manifest" "karpenter_nodepool_cpu" {
  yaml_body  = file("${local.karpenter_manifests_dir}/cpu-nodepool.yaml")
  depends_on = [kubectl_manifest.karpenter_node_class_cpu]
}
