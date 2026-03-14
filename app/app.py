"""
KServe-compatible inference server for DistilBERT sentiment analysis.

Implements the KServe V1 Inference Protocol using FastAPI.

Endpoints:
  GET  /healthz                                  - Liveness probe
  GET  /ready                                    - Readiness probe
  GET  /v1/models/distilbert-sentiment           - Model readiness
  POST /v1/models/distilbert-sentiment:predict   - Inference
  GET  /metrics                                  - Prometheus metrics
"""

import os
import time
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel
from starlette.responses import Response
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_DIR = os.environ.get("MODEL_DIR", "/app/model")
MODEL_NAME = "distilbert-sentiment"

REQUEST_COUNT = Counter(
    "kserve_inference_request_total",
    "Total inference requests",
    ["model_name", "status"],
)
REQUEST_LATENCY = Histogram(
    "kserve_inference_request_duration_seconds",
    "Inference request latency in seconds",
    ["model_name"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

model = None
tokenizer = None
labels = ["NEGATIVE", "POSITIVE"]


@asynccontextmanager
async def lifespan(application: FastAPI):
    global model, tokenizer
    tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR)
    model = AutoModelForSequenceClassification.from_pretrained(MODEL_DIR)
    model.eval()
    print(f"Model loaded from {MODEL_DIR}")
    yield


app = FastAPI(title="KServe-compatible Inference Server", lifespan=lifespan)


class PredictRequest(BaseModel):
    instances: list


@app.get("/healthz")
async def healthz():
    """Lightweight liveness probe — does not touch the model."""
    return {"status": "alive"}


@app.get("/ready")
async def ready():
    """Lightweight readiness probe — checks model is loaded without inference."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"status": "ready"}


@app.get(f"/v1/models/{MODEL_NAME}")
async def model_ready():
    """KServe V1 model readiness endpoint."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"name": MODEL_NAME, "ready": True}


@app.post(f"/v1/models/{MODEL_NAME}:predict")
async def predict(request: PredictRequest):
    """KServe V1 prediction endpoint."""
    start_time = time.time()
    try:
        texts = [
            inst["text"] if isinstance(inst, dict) else inst
            for inst in request.instances
        ]

        inputs = tokenizer(
            texts,
            return_tensors="pt",
            padding=True,
            truncation=True,
            max_length=128,
        )
        inputs.pop("token_type_ids", None)

        with torch.no_grad():
            outputs = model(**inputs)

        probabilities = torch.nn.functional.softmax(outputs.logits, dim=-1)

        predictions = []
        for probs in probabilities:
            pred_idx = torch.argmax(probs).item()
            predictions.append({
                "label": labels[pred_idx],
                "score": probs[pred_idx].item(),
                "probabilities": {
                    labels[i]: probs[i].item() for i in range(len(labels))
                },
            })

        REQUEST_COUNT.labels(model_name=MODEL_NAME, status="success").inc()
        return {"predictions": predictions}

    except Exception as e:
        REQUEST_COUNT.labels(model_name=MODEL_NAME, status="error").inc()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        elapsed = time.time() - start_time
        REQUEST_LATENCY.labels(model_name=MODEL_NAME).observe(elapsed)


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
