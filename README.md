# KServe Local — ML Inference on Kubernetes

Deploy a KServe-compatible sentiment analysis model on a local Kubernetes cluster with Prometheus monitoring, Grafana dashboards, autoscaling, and load testing.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                          │
│                                                              │
│  ┌─────────────────────┐    ┌─────────────────────────────┐  │
│  │  inference namespace │    │  monitoring namespace       │  │
│  │                     │    │                             │  │
│  │  ┌───────────────┐  │    │  ┌───────────┐ ┌─────────┐ │  │
│  │  │ kserve-       │──┼────┼─▶│ Prometheus│─▶│ Grafana │ │  │
│  │  │ sentiment     │  │    │  └───────────┘ └─────────┘ │  │
│  │  │ (1-5 replicas)│  │    │  ┌───────────────────────┐ │  │
│  │  └───────────────┘  │    │  │ kube-state-metrics    │ │  │
│  │  ┌───────────────┐  │    │  └───────────────────────┘ │  │
│  │  │ Locust        │  │    └─────────────────────────────┘  │
│  │  │ (load tester) │  │                                     │
│  │  └───────────────┘  │    ┌─────────┐                      │
│  │  ┌───────────────┐  │    │ HPA     │ CPU-based autoscaling│
│  │  │ metrics-server│  │    └─────────┘                      │
│  │  └───────────────┘  │                                     │
│  └─────────────────────┘                                     │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker Desktop with Kubernetes enabled (or kind/minikube)
- `kubectl` configured
- `make`

## Quick Start

```bash
# 1. Build and push the image (or use the pre-built one)
make push

# 2. Deploy everything (inference server, monitoring, autoscaling, load testing)
make deploy-all

# 3. Start port forwards
make port-forward

# 4. Test the model
make test
```

**Endpoints after `make port-forward`:**

| Service    | URL                        | Credentials   |
|------------|----------------------------|---------------|
| KServe     | http://localhost:8080       | —             |
| Grafana    | http://localhost:3000       | admin / admin |
| Prometheus | http://localhost:9090       | —             |
| Locust     | http://localhost:8089       | —             |

## Step-by-Step Deployment

### 1. Build & Push the Image

The model (DistilBERT sentiment analysis, ~260MB) is baked into the Docker image at build time — no PVC or runtime downloads needed.

```bash
make build   # Build only
make push    # Build + push to Docker Hub
```

To use your own registry:

```bash
make push REGISTRY=your-dockerhub-user TAG=latest
```

### 2. Deploy the Inference Server

```bash
make deploy
```

Verify it's running:

```bash
kubectl get pods -n inference
kubectl logs -f deployment/kserve-sentiment -n inference
```

### 3. Deploy Monitoring (Prometheus + Grafana)

```bash
make deploy-monitoring
```

This installs:
- **metrics-server** — Required for CPU-based HPA
- **Prometheus** — Scrapes inference pod metrics via annotations
- **kube-state-metrics** — Tracks HPA replica counts
- **Grafana** — Pre-provisioned KServe dashboard

### 4. Deploy Autoscaling

```bash
make deploy-autoscaling
```

The HPA scales from 1 to 5 replicas based on CPU utilization (target: 70%):

```bash
# Watch autoscaling in real-time
kubectl get hpa -n inference -w
```

### 5. Deploy Load Testing

```bash
make deploy-loadtest
```

Then open the Locust UI:

```bash
make port-forward
# Open http://localhost:8089
```

Set the number of users and watch the HPA scale pods up.

## Testing the Prediction API

```bash
# Single prediction
curl -s http://localhost:8080/v1/models/distilbert-sentiment:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [{"text": "I love this product!"}]}' | python3 -m json.tool

# Batch prediction
curl -s http://localhost:8080/v1/models/distilbert-sentiment:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [{"text": "Great quality!"}, {"text": "Terrible service."}]}' | python3 -m json.tool

# Health check
curl http://localhost:8080/healthz

# Readiness check
curl http://localhost:8080/ready

# Model status (KServe V1)
curl http://localhost:8080/v1/models/distilbert-sentiment

# Prometheus metrics
curl http://localhost:8080/metrics
```

**Example response:**

```json
{
    "predictions": [
        {
            "label": "POSITIVE",
            "score": 0.9998694658279419,
            "probabilities": {
                "NEGATIVE": 0.00013048517575953156,
                "POSITIVE": 0.9998694658279419
            }
        }
    ]
}
```

## Project Structure

```
kserve-local/
├── Makefile                          # Build, deploy, port-forward, clean
├── README.md
├── app/
│   ├── Dockerfile                    # Image with model baked in
│   └── app.py                        # FastAPI inference server
├── k8s/
│   ├── deployment.yaml               # KServe Deployment + Service
│   ├── hpa.yaml                      # HorizontalPodAutoscaler
│   ├── load-test.yaml                # Locust Deployment + Service
│   └── monitoring/
│       ├── prometheus.yaml           # Prometheus + kube-state-metrics
│       ├── grafana.yaml              # Grafana with provisioning
│       └── kserve-dashboard.json     # Pre-built Grafana dashboard
└── load-test/
    └── locustfile.py                 # Locust test scenarios
```

## Grafana Dashboard

The pre-provisioned dashboard includes:

- **Model Status** — UP/DOWN indicator
- **Request Rate** — Success/error RPS
- **Latency Percentiles** — p50, p90, p95, p99
- **Latency Heatmap** — Distribution over time
- **Success Rate** — Gauge for SLO tracking
- **CPU / Memory** — Per-pod resource usage
- **HPA Replica Scaling** — Current vs desired vs max replicas

## Key Prometheus Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `kserve_inference_request_total` | Counter | Total requests (labels: `model_name`, `status`) |
| `kserve_inference_request_duration_seconds` | Histogram | Latency in seconds (labels: `model_name`) |
| `container_cpu_usage_seconds_total` | Counter | CPU usage per container (from cAdvisor) |
| `kube_horizontalpodautoscaler_status_*` | Gauge | HPA replica counts (from kube-state-metrics) |

## Make Targets

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image |
| `make push` | Build and push to Docker Hub |
| `make deploy` | Deploy the inference server |
| `make deploy-monitoring` | Deploy Prometheus + Grafana + metrics-server |
| `make deploy-autoscaling` | Deploy HPA |
| `make deploy-loadtest` | Deploy Locust load tester |
| `make deploy-all` | Deploy everything |
| `make port-forward` | Start all port forwards |
| `make stop-port-forward` | Stop all port forwards |
| `make test` | Send a test prediction request |
| `make clean` | Delete all namespaces and resources |

## Cleanup

```bash
make clean
```
