module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Allow public access to the API server (restrict in production)
  cluster_endpoint_public_access = true

  # EKS managed add-ons
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  # System node group — runs monitoring, ingress controllers, karpenter itself
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_min
      max_size       = var.system_node_max
      desired_size   = var.system_node_desired

      labels = {
        role = "system"
      }

      tags = {
        "karpenter.sh/discovery" = var.cluster_name
      }
    }
  }

  # Allow Karpenter to manage nodes
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # Access entries — grant the caller admin access
  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
