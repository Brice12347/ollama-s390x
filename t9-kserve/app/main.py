from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import List
import os
from .t9 import T9Predictor

app = FastAPI(
    title="T9 Word Prediction",
    description="KServe-compatible T9 predictive text service",
    version="1.0.0"
)

# Load dictionary at startup (KServe mounts /mnt/models if you want)
DICTIONARY_PATH = os.getenv("DICTIONARY_PATH", "/app/dictionary.txt")

with open(DICTIONARY_PATH) as f:
    words = [line.strip() for line in f if line.strip()]

predictor = T9Predictor(words)

class PredictRequest(BaseModel):
    token: str = Field(..., description="T9 digit sequence, e.g. '843'")
    limit: int = Field(10, ge=1, le=50)

class PredictResponse(BaseModel):
    token: str
    predictions: List[str]

@app.get("/health")
@app.get("/ready")
def health():
    return {"status": "ok"}

@app.post("/v1/predict", response_model=PredictResponse)
@app.post("/predict", response_model=PredictResponse)          # KServe convenience
def predict(req: PredictRequest):
    preds = predictor.predict(req.token, req.limit)
    return PredictResponse(token=req.token, predictions=preds)

# KServe v2 protocol style (optional but nice)
@app.post("/v2/models/t9/infer")
def kserve_v2(req: dict):
    token = req.get("inputs", [{}])[0].get("data", [""])[0]
    limit = req.get("parameters", {}).get("limit", 10)
    preds = predictor.predict(str(token), limit)
    return {
        "model_name": "t9",
        "outputs": [{"name": "predictions", "datatype": "BYTES", "data": preds}]
    }