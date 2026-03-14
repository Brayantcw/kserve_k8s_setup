REGISTRY ?= brayanmaster
IMAGE    := $(REGISTRY)/kserve-sentiment
TAG      ?= v2
CLUSTER  ?= kserve-inference-dev
REGION   ?= us-west-2
TF_DIR   := infra/environments/dev

.PHONY: build push kubeconfig tf-init tf-plan tf-apply tf-destroy test status

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

# ---- Terraform ----
tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	cd $(TF_DIR) && terraform plan -out=tfplan

tf-apply:
	cd $(TF_DIR) && terraform apply tfplan

tf-destroy:
	cd $(TF_DIR) && terraform destroy

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
	@kubectl get ingress -n inference
	@kubectl get ingress -n monitoring
	@echo "--- Nodes (Karpenter) ---"
	@kubectl get nodes -l karpenter.sh/nodepool
