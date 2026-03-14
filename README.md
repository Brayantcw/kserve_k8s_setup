# KServe on EKS — ML Inference Platform

Deploy a KServe-compatible sentiment analysis model on AWS EKS with Karpenter node autoscaling, ALB ingress, Prometheus/Grafana monitoring, and multi-metric HPA.

## Architecture

```
                         ┌──────────────────────────────────────────────────────────────┐
                         │  AWS                                                         │
                         │                                                              │
  Users ──── ALB ────────┤  EKS Cluster                                                │
         (internet-      │  ┌─────────────────────────┐  ┌───────────────────────────┐  │
          facing)        │  │  inference namespace     │  │  monitoring namespace     │  │
              │          │  │                          │  │                           │  │
              ├─ /v1/* ──┼──│─▶ kserve-sentiment      │  │  Prometheus ──▶ Grafana   │  │
              │          │  │   (2-10 replicas, HPA)   │  │  (PVC-backed)  (/grafana) │  │
              ├─/grafana─┼──│                          │  │                           │  │
              │          │  │   Locust (/locust)       │  │  kube-state-metrics       │  │
              └─/locust──┼──│                          │  │  prometheus-adapter       │  │
                         │  │   PodDisruptionBudget    │  └───────────────────────────┘  │
                         │  └─────────────────────────┘                                 │
                         │                                                              │
                         │  ┌─────────────────────────────────────────────────────────┐  │
                         │  │  Node Management                                        │  │
                         │  │                                                         │  │
                         │  │  System Nodes (EKS Managed)    m5.large × 2-4           │  │
                         │  │  GPU Nodes (Karpenter)         g5/g6.xlarge, on-demand  │  │
                         │  │  CPU Nodes (Karpenter)         m5/m6i/c5, spot+od       │  │
                         │  └─────────────────────────────────────────────────────────┘  │
                         └──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5
- `kubectl`
- Docker (for building images)

## Infrastructure Setup

### 1. Configure Terraform Backend

```bash
cp infra/environments/dev/backend.hcl.example infra/environments/dev/backend.hcl
# Edit backend.hcl with your S3 bucket and DynamoDB table
```

### 2. Deploy Infrastructure

```bash
make tf-init
make tf-plan
make tf-apply
```

This creates:
- VPC with public/private subnets across 2 AZs
- EKS cluster (v1.31) with a system managed node group
- Karpenter with GPU and CPU NodePools
- AWS Load Balancer Controller
- Metrics Server
- NVIDIA Device Plugin
- Prometheus Adapter (for custom metrics HPA)

### 3. Deploy Application Stack

```bash
make deploy-all
```

### 4. Test

```bash
make test
```

## GitHub Actions Workflows

### Terraform (`terraform.yml`)

Runs on changes to `infra/`. Pipeline: format check → validate → plan → apply (main only, requires `production` environment approval).

**Required secrets:**
- `AWS_ROLE_ARN` — IAM role ARN for OIDC federation (GitHub → AWS)

### Build & Deploy (`deploy.yml`)

Runs on changes to `app/` or `k8s/`. Builds Docker image, pushes to ECR, deploys to EKS. Supports manual dispatch with a specific image tag.

**Required secrets:**
- `AWS_ROLE_ARN` — same as above

## Ingress Layer

All services are exposed through a single ALB using the AWS Load Balancer Controller with ingress group merging:

| Path | Service | Namespace |
|------|---------|-----------|
| `/v1/*`, `/healthz`, `/ready`, `/metrics` | kserve-sentiment:8080 | inference |
| `/grafana/*` | grafana:3000 | monitoring |
| `/locust/*` | locust:8089 | inference |

For production, add TLS:
```yaml
annotations:
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
```

## Autoscaling

### Pod Autoscaling (HPA)

The HPA scales the inference deployment from 2 to 10 replicas based on four signals:

| Metric | Target | Source |
|--------|--------|--------|
| CPU utilization | 65% | metrics-server |
| Memory utilization | 75% | metrics-server |
| Inference latency (avg) | 500ms/pod | prometheus-adapter |
| Request throughput | 50 RPS/pod | prometheus-adapter |

Scale-up is aggressive (up to 3 pods/min), scale-down is conservative (1 pod every 2 min, 5 min stabilization).

### Node Autoscaling (Karpenter)

Two NodePools handle different workload types:

**GPU Inference (`gpu-inference`)**
- Instance types: `g5.xlarge`, `g5.2xlarge`, `g6.xlarge`, `g6.2xlarge`
- Capacity: **on-demand only** — no spot interruptions for inference
- Taint: `nvidia.com/gpu=true:NoSchedule` — only GPU workloads schedule here
- Limit: 4 GPUs max
- Disruption: `WhenEmpty` with 5 min consolidation delay
- Pods must have `tolerations` for `nvidia.com/gpu` and `nodeSelector: accelerator: gpu`

**CPU Inference (`cpu-inference`)**
- Instance types: `m5.xlarge/2xlarge`, `m6i.xlarge/2xlarge`, `c5.xlarge/2xlarge`
- Capacity: spot + on-demand (Karpenter picks cheapest)
- Limit: 64 vCPU, 256Gi memory
- Disruption: `WhenEmptyOrUnderutilized` with 2 min delay

### Preventing Inference Interruptions

Key design decisions for zero-interruption inference:

1. **GPU nodes are on-demand only** — spot instances can be reclaimed with 2 min notice, which isn't enough for GPU model loading
2. **PodDisruptionBudget** — `minAvailable: 1` ensures at least one pod stays running during node drains
3. **Karpenter `consolidationPolicy: WhenEmpty`** on GPU pool — nodes are only terminated when fully drained, never consolidated while running pods
4. **`maxUnavailable: 0`** on rolling updates — new pods must be ready before old ones terminate
5. **`preStop` hook with 15s sleep** — allows in-flight requests to complete before the pod receives SIGTERM
6. **Topology spread** — pods spread across AZs and hosts, so a single node failure doesn't take down all replicas

## Project Structure

```
├── .github/workflows/
│   ├── terraform.yml              # Infra CI/CD
│   └── deploy.yml                 # App CI/CD
├── app/
│   ├── Dockerfile
│   └── app.py                     # FastAPI inference server
├── infra/
│   ├── environments/dev/          # Dev environment root module
│   │   ├── main.tf                # Wires VPC + EKS + Karpenter + addons
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── versions.tf            # Provider config + S3 backend
│   │   └── terraform.tfvars
│   └── modules/
│       ├── vpc/                   # VPC with EKS/ALB subnet tags
│       ├── eks/                   # EKS cluster + system node group
│       ├── karpenter/             # Karpenter controller + IAM
│       └── addons/                # ALB controller, metrics-server, NVIDIA plugin, prometheus-adapter
├── k8s/
│   ├── deployment.yaml            # Inference Deployment + Service + PDB
│   ├── hpa.yaml                   # Multi-metric HPA (CPU, memory, latency, RPS)
│   ├── ingress.yaml               # ALB Ingress for all services
│   ├── load-test.yaml             # Locust
│   ├── storage-class.yaml         # gp3 StorageClass
│   └── monitoring/
│       ├── prometheus.yaml        # Prometheus + kube-state-metrics (PVC-backed)
│       ├── grafana.yaml           # Grafana with secrets + PVC
│       └── kserve-dashboard.json  # Pre-built dashboard
├── load-test/
│   └── locustfile.py
└── Makefile
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make build` | Build Docker image |
| `make push` | Build and push to registry |
| `make kubeconfig` | Update kubectl config for EKS |
| `make deploy` | Deploy inference server |
| `make deploy-monitoring` | Deploy Prometheus + Grafana |
| `make deploy-autoscaling` | Deploy HPA |
| `make deploy-loadtest` | Deploy Locust |
| `make deploy-ingress` | Deploy ALB Ingress |
| `make deploy-all` | Deploy everything |
| `make tf-init` | Terraform init |
| `make tf-plan` | Terraform plan |
| `make tf-apply` | Terraform apply |
| `make tf-destroy` | Terraform destroy |
| `make test` | Test prediction via ALB |
| `make status` | Show pods, HPA, ingress, Karpenter nodes |
| `make clean` | Delete all K8s resources |
