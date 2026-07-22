FROM registry.access.redhat.com/ubi9/python-312:latest

LABEL name="t9-kserve-runtime" \
      summary="T9 Word Prediction FastAPI for KServe on s390x"

USER 0

WORKDIR /opt/app-root/src

# Install dependencies into the image's virtualenv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY app/ ./app/
COPY dictionary.txt ./dictionary.txt

# OpenShift random UID compatibility
RUN chown -R 1001:0 /opt/app-root/src && \
    chmod -R g=u /opt/app-root/src

ENV PYTHONUNBUFFERED=1 \
    DICTIONARY_PATH=/opt/app-root/src/dictionary.txt \
    PORT=8080

USER 1001

EXPOSE 8080

# Use the venv's python/uvicorn explicitly
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]