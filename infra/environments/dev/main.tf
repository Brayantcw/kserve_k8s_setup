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
# Karpenter NodePool + EC2NodeClass (applied via kubectl)
# ──────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_node_class_gpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu-inference"
    }
    spec = {
      role = module.karpenter.karpenter_node_iam_role_name

      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "100Gi"
            volumeType          = "gp3"
            deleteOnTermination = true
            encrypted           = true
          }
        }
      ]

      # Metadata options for security
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
    }
  })

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_node_class_cpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "cpu-inference"
    }
    spec = {
      role = module.karpenter.karpenter_node_iam_role_name

      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            deleteOnTermination = true
            encrypted           = true
          }
        }
      ]

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
    }
  })

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_nodepool_gpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-inference"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role       = "inference"
            accelerator = "gpu"
          }
        }
        spec = {
          # Only schedule pods that tolerate the GPU taint
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            }
          ]

          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              # On-Demand only for GPU inference — no spot interruptions
              values = ["on-demand"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              # g5 = NVIDIA A10G (cost-effective inference)
              # g6 = NVIDIA L4 (newer, better perf/watt)
              values = ["g5.xlarge", "g5.2xlarge", "g6.xlarge", "g6.2xlarge"]
            }
          ]

          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu-inference"
          }
        }
      }

      limits = {
        # Cap GPU spend: max 4 GPU nodes
        "nvidia.com/gpu" = 4
      }

      disruption = {
        # Prevent Karpenter from voluntarily disrupting inference nodes
        consolidationPolicy = "WhenEmpty"
        # Wait 5 min after node becomes empty before terminating
        consolidateAfter = "5m"
        # Respect PDBs during involuntary disruption
      }

      weight = 10
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class_gpu]
}

resource "kubectl_manifest" "karpenter_nodepool_cpu" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "cpu-inference"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            role = "inference"
          }
        }
        spec = {
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              # Allow spot for CPU inference (cheaper, model can restart quickly)
              values = ["on-demand", "spot"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["m5.xlarge", "m5.2xlarge", "m6i.xlarge", "m6i.2xlarge", "c5.xlarge", "c5.2xlarge"]
            }
          ]

          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "cpu-inference"
          }
        }
      }

      limits = {
        cpu    = "64"
        memory = "256Gi"
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "2m"
      }

      weight = 50
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class_cpu]
}
