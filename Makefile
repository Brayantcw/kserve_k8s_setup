REGISTRY ?= brayanmaster
IMAGE    := $(REGISTRY)/kserve-sentiment
TAG      ?= v2

.PHONY: build push deploy deploy-monitoring deploy-autoscaling deploy-loadtest \
        port-forward stop-port-forward clean

# ---- Build & Push ----
build:
	@echo "==> Building image $(IMAGE):$(TAG)..."
	docker build -t $(IMAGE):$(TAG) app/
	@echo "==> Build complete."

push: build
	@echo "==> Pushing $(IMAGE):$(TAG)..."
	docker push $(IMAGE):$(TAG)
	@echo "==> Push complete."

# ---- Deploy ----
deploy:
	@echo "==> Deploying KServe inference server..."
	kubectl apply -f k8s/deployment.yaml
	kubectl rollout status deployment/kserve-sentiment -n inference --timeout=180s
	@echo "==> KServe deployed."

deploy-monitoring:
	@echo "==> Installing metrics-server..."
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl patch deployment metrics-server -n kube-system --type='json' \
		-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true
	@echo "==> Deploying Prometheus..."
	kubectl apply -f k8s/monitoring/prometheus.yaml
	@echo "==> Creating Grafana dashboard ConfigMap..."
	kubectl create configmap grafana-dashboards \
		--namespace monitoring \
		--from-file=k8s/monitoring/kserve-dashboard.json \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Deploying Grafana..."
	kubectl apply -f k8s/monitoring/grafana.yaml
	kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
	kubectl rollout status deployment/prometheus -n monitoring --timeout=120s
	kubectl rollout status deployment/grafana -n monitoring --timeout=120s
	@echo "==> Monitoring stack deployed."

deploy-autoscaling:
	@echo "==> Deploying HPA..."
	kubectl apply -f k8s/hpa.yaml
	@echo "==> Autoscaling configured."
	@echo "    Watch: kubectl get hpa -n inference -w"

deploy-loadtest:
	@echo "==> Creating Locust ConfigMap..."
	kubectl create configmap locust-config \
		--namespace inference \
		--from-file=load-test/locustfile.py \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Deploying Locust..."
	kubectl apply -f k8s/load-test.yaml
	kubectl rollout status deployment/locust -n inference --timeout=60s
	@echo "==> Locust deployed."

deploy-all: deploy deploy-monitoring deploy-autoscaling deploy-loadtest
	@echo "==> Everything deployed."

# ---- Port Forwarding ----
port-forward:
	@echo "==> Starting port forwards (KServe:8080, Grafana:3000, Prometheus:9090, Locust:8089)..."
	@lsof -ti:8080,3000,9090,8089 2>/dev/null | xargs kill -9 2>/dev/null || true
	@sleep 1
	@kubectl port-forward svc/kserve-sentiment -n inference 8080:8080 > /dev/null 2>&1 &
	@kubectl port-forward svc/grafana -n monitoring 3000:3000 > /dev/null 2>&1 &
	@kubectl port-forward svc/prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
	@kubectl port-forward svc/locust -n inference 8089:8089 > /dev/null 2>&1 &
	@echo "    KServe:     http://localhost:8080"
	@echo "    Grafana:    http://localhost:3000 (admin/admin)"
	@echo "    Prometheus: http://localhost:9090"
	@echo "    Locust:     http://localhost:8089"

stop-port-forward:
	@echo "==> Stopping port forwards..."
	@lsof -ti:8080,3000,9090,8089 2>/dev/null | xargs kill -9 2>/dev/null || true
	@echo "==> Done."

# ---- Test ----
test:
	@echo "==> Testing KServe prediction endpoint..."
	@curl -s http://localhost:8080/v1/models/distilbert-sentiment:predict \
		-H "Content-Type: application/json" \
		-d '{"instances": [{"text": "I love this product!"}]}' | python3 -m json.tool

# ---- Cleanup ----
clean:
	@echo "==> Cleaning up..."
	kubectl delete namespace inference --ignore-not-found
	kubectl delete namespace monitoring --ignore-not-found
	kubectl delete clusterrole prometheus --ignore-not-found
	kubectl delete clusterrolebinding prometheus --ignore-not-found
	@echo "==> Cleaned up."
