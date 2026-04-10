# brain_tcn.py
# Python 3.10+ | pip install numpy tensorflow fastapi uvicorn
import random
from collections import deque
from dataclasses import dataclass
from typing import Dict, List, Optional

import numpy as np
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# ============================================================
# Reproducibility
# ============================================================
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
tf.random.set_seed(SEED)

# ============================================================
# Config
# ============================================================
@dataclass
class Config:
    window_seconds: int = 120
    input_dim: int = 3              # [hr, hrv, br]
    latent_dim: int = 32
    tcn_filters: int = 32
    tcn_kernel: int = 3
    dilations: tuple = (1, 2, 4, 8)
    dropout: float = 0.1

CFG = Config()

# ============================================================
# TCN blocks
# ============================================================
def tcn_res_block(x, filters, kernel_size, dilation, dropout, name):
    shortcut = x
    in_ch = int(x.shape[-1])

    y = layers.Conv1D(
        filters=filters,
        kernel_size=kernel_size,
        dilation_rate=dilation,
        padding="causal",
        activation=None,
        name=f"{name}_conv1"
    )(x)
    y = layers.BatchNormalization(name=f"{name}_bn1")(y)
    y = layers.Activation("relu", name=f"{name}_relu1")(y)
    y = layers.Dropout(dropout, name=f"{name}_drop1")(y)

    y = layers.Conv1D(
        filters=filters,
        kernel_size=kernel_size,
        dilation_rate=dilation,
        padding="causal",
        activation=None,
        name=f"{name}_conv2"
    )(y)
    y = layers.BatchNormalization(name=f"{name}_bn2")(y)
    y = layers.Activation("relu", name=f"{name}_relu2")(y)
    y = layers.Dropout(dropout, name=f"{name}_drop2")(y)

    if in_ch != filters:
        shortcut = layers.Conv1D(filters, kernel_size=1, padding="same", name=f"{name}_proj")(shortcut)

    out = layers.Add(name=f"{name}_add")([shortcut, y])
    out = layers.Activation("relu", name=f"{name}_out")(out)
    return out

def build_tcn_encoder(cfg: Config):
    inp = keras.Input(shape=(cfg.window_seconds, cfg.input_dim), name="seq_in")
    x = inp
    for i, d in enumerate(cfg.dilations):
        x = tcn_res_block(
            x=x,
            filters=cfg.tcn_filters,
            kernel_size=cfg.tcn_kernel,
            dilation=d,
            dropout=cfg.dropout,
            name=f"tcn_b{i+1}_d{d}"
        )
    x = layers.GlobalAveragePooling1D(name="gap")(x)
    z = layers.Dense(cfg.latent_dim, activation=None, name="latent")(x)
    z = layers.LayerNormalization(name="latent_norm")(z)

    encoder = keras.Model(inp, z, name="TCNEncoder")
    return encoder

# ============================================================
# Runtime app state
# ============================================================
class AppState:
    encoder: Optional[keras.Model] = None
    latest: Optional[Dict] = None
    buffer: deque = deque(maxlen=300)

STATE = AppState()

# ============================================================
# FastAPI
# ============================================================
api = FastAPI(title="Brain TCN API")
api.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

class IngestWindow(BaseModel):
    start_time: str
    end_time: str
    hr: List[float]
    hrv: List[float]
    br: List[float]
    avg_hr: float
    avg_hrv: float
    avg_br: float

class IngestPayload(BaseModel):
    windows: List[IngestWindow]

def fix_len(arr: np.ndarray, target: int) -> np.ndarray:
    if len(arr) >= target:
        return arr[:target]
    if len(arr) == 0:
        return np.zeros(target, dtype=np.float32)
    return np.pad(arr, (0, target - len(arr)), mode="edge")

@api.get("/status")
def status():
    return {
        "ok": True,
        "encoder_ready": STATE.encoder is not None,
        "buffer_size": len(STATE.buffer),
        "has_latest": STATE.latest is not None,
    }

@api.post("/ingest")
def ingest(payload: IngestPayload):
    if STATE.encoder is None:
        return {"ok": False, "reason": "Encoder not initialized"}

    ingested = 0
    for w in payload.windows:
        hr = fix_len(np.array(w.hr, dtype=np.float32), CFG.window_seconds)
        hrv = fix_len(np.array(w.hrv, dtype=np.float32), CFG.window_seconds)
        br = fix_len(np.array(w.br, dtype=np.float32), CFG.window_seconds)

        seq = np.stack([hr, hrv, br], axis=-1)[np.newaxis, :, :]  # (1, T, 3)
        z = STATE.encoder.predict(seq, verbose=0)[0]              # (latent_dim,)

        item = {
            "start_time": w.start_time,
            "end_time": w.end_time,
            "avg_hr": float(w.avg_hr),
            "avg_hrv": float(w.avg_hrv),
            "avg_br": float(w.avg_br),
            "z": z.tolist(),
        }
        STATE.latest = item
        STATE.buffer.append(item)
        ingested += 1

    return {"ok": True, "ingested": ingested}

@api.get("/latest")
def latest():
    return STATE.latest if STATE.latest is not None else {}

@api.get("/buffer")
def buffer():
    return {"count": len(STATE.buffer), "windows": list(STATE.buffer)}

if __name__ == "__main__":
    STATE.encoder = build_tcn_encoder(CFG)
    STATE.encoder.summary()
    uvicorn.run(api, host="0.0.0.0", port=8000)