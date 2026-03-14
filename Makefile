REGISTRY ?= brayanmaster
IMAGE    := $(REGISTRY)/kserve-sentiment
TAG      ?= v2
CLUSTER  ?= kserve-inference-dev
REGION   ?= us-west-2

.PHONY: build push deploy deploy-monitoring deploy-autoscaling deploy-loadtest \
        deploy-ingress deploy-all kubeconfig test clean

# ---- Build & Push ----
build:
	@echo "==> Building image $(IMAGE):$(TAG)..."
	docker build -t $(IMAGE):$(TAG) app/

push: build
	@echo "==> Pushing $(IMAGE):$(TAG)..."
	docker push $(IMAGE):$(TAG)

# ---- EKS ----
kubeconfig:
	@echo "==> Updating kubeconfig for $(CLUSTER)..."
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

# ---- Deploy ----
deploy: kubeconfig
	@echo "==> Deploying storage class..."
	kubectl apply -f k8s/storage-class.yaml
	@echo "==> Deploying inference server..."
	kubectl apply -f k8s/deployment.yaml
	kubectl rollout status deployment/kserve-sentiment -n inference --timeout=300s

deploy-monitoring: kubeconfig
	@echo "==> Deploying Prometheus..."
	kubectl apply -f k8s/monitoring/prometheus.yaml
	@echo "==> Creating Grafana dashboard ConfigMap..."
	kubectl create configmap grafana-dashboards \
		--namespace monitoring \
		--from-file=k8s/monitoring/kserve-dashboard.json \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Deploying Grafana..."
	kubectl apply -f k8s/monitoring/grafana.yaml
	kubectl rollout status deployment/prometheus -n monitoring --timeout=120s
	kubectl rollout status deployment/grafana -n monitoring --timeout=120s

deploy-autoscaling: kubeconfig
	@echo "==> Deploying HPA..."
	kubectl apply -f k8s/hpa.yaml

deploy-loadtest: kubeconfig
	@echo "==> Creating Locust ConfigMap..."
	kubectl create configmap locust-config \
		--namespace inference \
		--from-file=load-test/locustfile.py \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Deploying Locust..."
	kubectl apply -f k8s/load-test.yaml
	kubectl rollout status deployment/locust -n inference --timeout=60s

deploy-ingress: kubeconfig
	@echo "==> Deploying ALB Ingress..."
	kubectl apply -f k8s/ingress.yaml

deploy-all: deploy deploy-monitoring deploy-autoscaling deploy-loadtest deploy-ingress
	@echo "==> Everything deployed."

# ---- Terraform ----
tf-init:
	cd infra/environments/dev && terraform init

tf-plan:
	cd infra/environments/dev && terraform plan -out=tfplan

tf-apply:
	cd infra/environments/dev && terraform apply tfplan

tf-destroy:
	cd infra/environments/dev && terraform destroy

# ---- Test ----
test:
	@echo "==> Getting ALB URL..."
	@ALB=$$(kubectl get ingress inference-ingress -n inference -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) && \
	echo "==> Testing prediction at $$ALB..." && \
	curl -s "http://$$ALB/v1/models/distilbert-sentiment:predict" \
		-H "Content-Type: application/json" \
		-d '{"instances": [{"text": "I love this product!"}]}' | python3 -m json.tool

# ---- Status ----
status: kubeconfig
	@echo "--- Pods ---"
	@kubectl get pods -n inference
	@echo "--- HPA ---"
	@kubectl get hpa -n inference
	@echo "--- Ingress ---"
	@kubectl get ingress -n inference -n monitoring
	@echo "--- Nodes (Karpenter) ---"
	@kubectl get nodes -l karpenter.sh/nodepool

# ---- Cleanup ----
clean: kubeconfig
	@echo "==> Cleaning up..."
	kubectl delete namespace inference --ignore-not-found
	kubectl delete namespace monitoring --ignore-not-found
	kubectl delete clusterrole prometheus --ignore-not-found
	kubectl delete clusterrolebinding prometheus --ignore-not-found
