FROM python:3.11-slim

WORKDIR /app

# Install PyTorch (CPU) separately — the --index-url only covers torch
RUN pip install --no-cache-dir \
    torch==2.6.0 --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir \
    fastapi==0.115.0 \
    uvicorn==0.32.0 \
    transformers==4.46.3 \
    prometheus-client==0.21.0

# Download model at build time so it's baked into the image
RUN python -c "\
from transformers import AutoTokenizer, AutoModelForSequenceClassification; \
AutoTokenizer.from_pretrained('distilbert-base-uncased-finetuned-sst-2-english').save_pretrained('/app/model'); \
AutoModelForSequenceClassification.from_pretrained('distilbert-base-uncased-finetuned-sst-2-english').save_pretrained('/app/model')"

COPY app.py /app/app.py

ENV MODEL_DIR=/app/model

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
