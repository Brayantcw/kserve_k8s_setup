"""
Locust load test for KServe inference server.

Usage:
  # In-cluster (deployed via k8s manifests)
  # Access Locust UI via port-forward: kubectl port-forward svc/locust -n inference 8089:8089
  # Then open http://localhost:8089

  # Local
  # pip install locust
  # locust -f locustfile.py --host http://localhost:8080
"""

import random

from locust import HttpUser, between, task

SAMPLE_TEXTS = [
    "This movie was absolutely wonderful and I loved every minute of it!",
    "Terrible experience. Would not recommend to anyone.",
    "The product works as expected, nothing special.",
    "I am so happy with this purchase, best decision ever!",
    "Worst customer service I have ever experienced in my life.",
    "Pretty good overall, a few minor issues but nothing major.",
    "The food was delicious and the atmosphere was perfect.",
    "Complete waste of money. Broke after two days.",
    "An outstanding achievement in modern cinema. Truly breathtaking.",
    "Mediocre at best. I expected much more from this brand.",
    "Absolutely fantastic! Exceeded all my expectations.",
    "I regret buying this. Total disappointment.",
    "Solid performance, reliable, and well-built product.",
    "Not worth the price tag. Overrated and overhyped.",
    "A delightful experience from start to finish.",
    "The worst movie I have ever seen. Painful to watch.",
    "Great value for money. Highly recommend!",
    "Boring and predictable. Nothing new or interesting.",
    "Incredible quality and attention to detail.",
    "Save your money and look elsewhere.",
]


class KServeUser(HttpUser):
    wait_time = between(0.1, 1.0)

    @task
    def predict(self):
        text = random.choice(SAMPLE_TEXTS)
        self.client.post(
            "/v1/models/distilbert-sentiment:predict",
            json={"instances": [{"text": text}]},
            name="predict",
        )

    @task(3)
    def predict_batch(self):
        texts = random.sample(SAMPLE_TEXTS, k=random.randint(2, 5))
        self.client.post(
            "/v1/models/distilbert-sentiment:predict",
            json={"instances": [{"text": t} for t in texts]},
            name="predict_batch",
        )
