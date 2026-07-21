# syntax=docker/dockerfile:1.6
ARG BASE_IMAGE=image-registry.openshift-image-registry.svc:5000/openshift/python:3.12-minimal-ubi9
FROM ${BASE_IMAGE}

LABEL name="t9-kserve-runtime" \
      summary="T9 Word Prediction FastAPI for KServe on s390x" \
      description="Custom KServe runtime for T9 predictive text" \
      io.k8s.display-name="T9 KServe Runtime" \
      maintainer="you@example.com"

# OpenShift runs as random UID (root group)
USER 0

WORKDIR /app

# Install runtime deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    microdnf clean all || true

# Application
COPY app/ ./app/
COPY dictionary.txt ./dictionary.txt

# Permissions for random UID + root group (OpenShift best practice)
RUN chown -R 1001:0 /app && \
    chmod -R g=u /app && \
    chmod -R a+rX /app

ENV PYTHONUNBUFFERED=1 \
    DICTIONARY_PATH=/app/dictionary.txt \
    PORT=8080

USER 1001

EXPOSE 8080

# KServe expects the container to listen on 8080 by default
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
