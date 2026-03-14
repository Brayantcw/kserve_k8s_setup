# KServe on EKS — ML Inference Platform

Deploy a KServe-compatible sentiment analysis model on AWS EKS with Karpenter node autoscaling, ALB ingress, Prometheus/Grafana monitoring, and multi-metric HPA.

## Architecture

![Architecture](docs/img/arquitecture.png)

Users send inference requests (`POST /v1/models/distilbert-sentiment:predict`) through an ALB that routes traffic into the EKS cluster. The cluster is split into three areas: the **inference namespace** (KServe pods scaled by HPA), **load testing** (Locust workers), and the **monitoring namespace** (Prometheus + Grafana). Karpenter manages the worker node group, provisioning GPU or CPU nodes on demand.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5
- `kubectl`
- Docker (for building images)

## Infrastructure Setup

### 1. Configure Terraform Backend

```bash
cp infra/environments/dev/backend.hcl.example infra/environments/dev/backend.hcl
# Edit backend.hcl with your S3 bucket (state locking uses S3 native lockfile, no DynamoDB needed)
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

Application manifests (deployment, HPA, ingress, monitoring) are applied via the GitHub Actions `deploy.yml` workflow on push to `main`. For manual deployment, use the workflow dispatch trigger.

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

## Monitoring

Grafana ships with a pre-built KServe dashboard that tracks model status, total requests, success rate, pod count, RPS, and latency percentiles (p50/p90/p95/p99):

![Grafana Dashboard](docs/img/Grafana_base_dashboard.png)

Dedicated latency panels show average latency over time and a heatmap of request duration distribution, useful for spotting tail latency under load:

![Latency Panels](docs/img/grafana_latency_panels.png)

## Load Testing

Locust runs in-cluster and generates traffic against the inference service. The dashboard shows RPS, response times (p50/p95), and concurrent user count:

![Locust Traffic](docs/img/locus_trafic_over_time.png)

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
│   ├── karpenter/
│   │   ├── gpu-node-class.yaml    # EC2NodeClass for GPU nodes (templatefile)
│   │   ├── cpu-node-class.yaml    # EC2NodeClass for CPU nodes (templatefile)
│   │   ├── gpu-nodepool.yaml      # NodePool — on-demand, WhenEmpty
│   │   └── cpu-nodepool.yaml      # NodePool — spot+od, WhenEmptyOrUnderutilized
│   └── monitoring/
│       ├── prometheus.yaml        # Prometheus + kube-state-metrics (PVC-backed)
│       ├── grafana.yaml           # Grafana with secrets + PVC
│       └── kserve-dashboard.json  # Pre-built dashboard
├── docs/img/                      # Architecture and dashboard screenshots
├── load-test/
│   └── locustfile.py
└── Makefile
```

## Make Targets

All infrastructure and application deployment is managed by Terraform and GitHub Actions. The Makefile provides shortcuts for common operations.

| Target | Description |
|--------|-------------|
| `make build` | Build Docker image |
| `make push` | Build and push to registry |
| `make kubeconfig` | Update kubectl config for EKS |
| `make tf-init` | Terraform init |
| `make tf-plan` | Terraform plan |
| `make tf-apply` | Terraform apply |
| `make tf-destroy` | Terraform destroy |
| `make test` | Test prediction via ALB |
| `make status` | Show pods, HPA, ingress, Karpenter nodes |
