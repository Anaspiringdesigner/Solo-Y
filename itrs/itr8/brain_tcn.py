# brain_tcn.py
# FastAPI service:
# - /ingest receives windows
# - scales + encodes to latent z(t)
# - /latest used by RL
#
# Uses 30s runtime window for responsive control.

import os
import random
from pathlib import Path
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

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
tf.random.set_seed(SEED)

@dataclass
class Config:
    window_seconds: int = 30
    input_dim: int = 3
    latent_dim: int = 32
    tcn_filters: int = 32
    tcn_kernel: int = 3
    dilations: tuple = (1, 2, 4, 8)
    dropout: float = 0.1

    model_dir: str = "models"
    encoder_path: str = "models/tcn_encoder.keras"
    scaler_path: str = "models/scaler.npz"

CFG = Config()


def tcn_res_block(x, filters, kernel_size, dilation, dropout, name):
    shortcut = x
    in_ch = int(x.shape[-1])

    y = layers.Conv1D(filters, kernel_size, dilation_rate=dilation, padding="causal", name=f"{name}_c1")(x)
    y = layers.BatchNormalization(name=f"{name}_bn1")(y)
    y = layers.Activation("relu", name=f"{name}_r1")(y)
    y = layers.Dropout(dropout, name=f"{name}_d1")(y)

    y = layers.Conv1D(filters, kernel_size, dilation_rate=dilation, padding="causal", name=f"{name}_c2")(y)
    y = layers.BatchNormalization(name=f"{name}_bn2")(y)
    y = layers.Activation("relu", name=f"{name}_r2")(y)
    y = layers.Dropout(dropout, name=f"{name}_d2")(y)

    if in_ch != filters:
        shortcut = layers.Conv1D(filters, 1, padding="same", name=f"{name}_proj")(shortcut)

    out = layers.Add(name=f"{name}_add")([shortcut, y])
    out = layers.Activation("relu", name=f"{name}_out")(out)
    return out


def build_tcn_encoder(cfg: Config) -> keras.Model:
    inp = keras.Input(shape=(cfg.window_seconds, cfg.input_dim), name="seq_in")
    x = inp
    for i, d in enumerate(cfg.dilations):
        x = tcn_res_block(x, cfg.tcn_filters, cfg.tcn_kernel, d, cfg.dropout, f"b{i+1}_d{d}")
    x = layers.GlobalAveragePooling1D(name="gap")(x)
    z = layers.Dense(cfg.latent_dim, activation=None, name="latent")(x)
    z = layers.LayerNormalization(name="latent_norm")(z)
    return keras.Model(inp, z, name="TCNEncoder")


def default_scaler():
    return {
        "median": np.array([70.0, 30.0, 14.0], dtype=np.float32),
        "iqr": np.array([15.0, 20.0, 6.0], dtype=np.float32),
    }


def load_scaler(path: str):
    if not os.path.exists(path):
        return None
    d = np.load(path)
    med = d["median"].astype(np.float32)
    iqr = d["iqr"].astype(np.float32)
    iqr = np.where(np.abs(iqr) < 1e-6, 1.0, iqr).astype(np.float32)
    return {"median": med, "iqr": iqr}


def scale_window(seq: np.ndarray, scaler: Dict[str, np.ndarray]) -> np.ndarray:
    out = seq.copy()
    for ch in range(out.shape[1]):
        out[:, ch] = (out[:, ch] - scaler["median"][ch]) / scaler["iqr"][ch]
    return out


def fix_len(arr: np.ndarray, target: int) -> np.ndarray:
    if len(arr) >= target:
        return arr[:target]
    if len(arr) == 0:
        return np.zeros(target, dtype=np.float32)
    return np.pad(arr, (0, target - len(arr)), mode="edge")


class AppState:
    encoder: Optional[keras.Model] = None
    scaler: Optional[Dict[str, np.ndarray]] = None
    latest: Optional[Dict] = None
    buffer: deque = deque(maxlen=1000)
    using_pretrained: bool = False

STATE = AppState()

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

@api.get("/status")
def status():
    return {
        "ok": True,
        "encoder_ready": STATE.encoder is not None,
        "using_pretrained": STATE.using_pretrained,
        "buffer_size": len(STATE.buffer),
        "has_latest": STATE.latest is not None,
        "window_seconds": CFG.window_seconds,
        "latent_dim": CFG.latent_dim,
    }

@api.post("/ingest")
def ingest(payload: IngestPayload):
    if STATE.encoder is None or STATE.scaler is None:
        return {"ok": False, "reason": "Encoder/scaler not initialized"}

    if not payload.windows:
        return {"ok": False, "reason": "No windows"}

    ingested = 0
    for w in payload.windows:
        try:
            hr = fix_len(np.array(w.hr, dtype=np.float32), CFG.window_seconds)
            hrv = fix_len(np.array(w.hrv, dtype=np.float32), CFG.window_seconds)
            br = fix_len(np.array(w.br, dtype=np.float32), CFG.window_seconds)

            seq = np.stack([hr, hrv, br], axis=-1)
            seq_scaled = scale_window(seq, STATE.scaler)

            z = STATE.encoder.predict(seq_scaled[np.newaxis], verbose=0)[0]

            item = {
                "start_time": w.start_time,
                "end_time": w.end_time,
                "avg_hr": float(w.avg_hr),
                "avg_hrv": float(w.avg_hrv),
                "avg_br": float(w.avg_br),
                "z": z.astype(float).tolist(),
            }

            STATE.latest = item
            STATE.buffer.append(item)
            ingested += 1

            print(f"[INGEST] end={item['end_time']} HR={item['avg_hr']:.1f} HRV={item['avg_hrv']:.1f} BR={item['avg_br']:.1f}")
        except Exception as e:
            print(f"[INGEST ERROR] {e}")

    return {"ok": True, "ingested": ingested}

@api.get("/latest")
def latest():
    return STATE.latest if STATE.latest else {}

@api.get("/buffer")
def buffer():
    return {"count": len(STATE.buffer), "windows": list(STATE.buffer)}

def init_runtime():
    Path(CFG.model_dir).mkdir(parents=True, exist_ok=True)

    scaler = load_scaler(CFG.scaler_path)
    if scaler is None:
        print(f"[INIT] scaler not found at {CFG.scaler_path}, using default scaler")
        scaler = default_scaler()

    if os.path.exists(CFG.encoder_path):
        print(f"[INIT] loading pretrained encoder: {CFG.encoder_path}")
        encoder = keras.models.load_model(CFG.encoder_path, compile=False)
        encoder.trainable = False
        STATE.using_pretrained = True
    else:
        print(f"[INIT] pretrained encoder missing, building fallback")
        encoder = build_tcn_encoder(CFG)
        encoder.trainable = False
        STATE.using_pretrained = False

    STATE.encoder = encoder
    STATE.scaler = scaler

if __name__ == "__main__":
    init_runtime()
    uvicorn.run(api, host="0.0.0.0", port=8000)