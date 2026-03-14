# ──────────────────────────────────────────────
# AWS Load Balancer Controller (for ALB Ingress)
# ──────────────────────────────────────────────

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.tags
}

resource "helm_release" "alb_controller" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.1.0"
  wait       = true

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }
}

# ──────────────────────────────────────────────
# Metrics Server (EKS doesn't include it by default)
# ──────────────────────────────────────────────

resource "helm_release" "metrics_server" {
  namespace  = "kube-system"
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.2"
  wait       = true
}

# ──────────────────────────────────────────────
# NVIDIA Device Plugin (exposes nvidia.com/gpu resource)
# ──────────────────────────────────────────────

resource "helm_release" "nvidia_device_plugin" {
  namespace        = "kube-system"
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.18.2"
  wait             = true
  create_namespace = false

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

# ──────────────────────────────────────────────
# Prometheus Adapter (for custom metrics HPA)
# ──────────────────────────────────────────────

resource "helm_release" "prometheus_adapter" {
  namespace        = "monitoring"
  name             = "prometheus-adapter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-adapter"
  version          = "5.3.0"
  wait             = true
  create_namespace = true

  set {
    name  = "prometheus.url"
    value = "http://prometheus.monitoring.svc"
  }

  set {
    name  = "prometheus.port"
    value = "9090"
  }

  values = [
    yamlencode({
      rules = {
        custom = [
          {
            seriesQuery = "kserve_inference_request_duration_seconds_count{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^(.*)_total$"
              as      = "kserve_inference_rps"
            }
            metricsQuery = "sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)"
          },
          {
            seriesQuery = "kserve_inference_request_duration_seconds_sum{namespace!=\"\",pod!=\"\"}"
            resources = {
              overrides = {
                namespace = { resource = "namespace" }
                pod       = { resource = "pod" }
              }
            }
            name = {
              matches = "^(.*)_sum$"
              as      = "kserve_inference_avg_latency_seconds"
            }
            metricsQuery = "sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>) / sum(rate(kserve_inference_request_duration_seconds_count{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)"
          }
        ]
      }
    })
  ]
}
