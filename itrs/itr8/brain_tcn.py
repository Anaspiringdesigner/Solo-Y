# brain_tcn.py
# FastAPI service:
# - Receives bio windows via /ingest
# - Scales with robust scaler
# - Encodes with TCN encoder -> latent z(t)
# - Serves latest latent on /latest
#
# If pretrained files exist:
#   models/tcn_encoder.keras
#   models/scaler.npz
# they are loaded and encoder is frozen.
#
# Requirements:
#   pip install numpy tensorflow fastapi uvicorn pydantic

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
    input_dim: int = 3
    latent_dim: int = 32
    tcn_filters: int = 32
    tcn_kernel: int = 3
    dilations: tuple = (1, 2, 4, 8)
    dropout: float = 0.1

    # Model/scaler paths
    model_dir: str = "models"
    encoder_path: str = "models/tcn_encoder.keras"
    scaler_path: str = "models/scaler.npz"

CFG = Config()

# ============================================================
# TCN encoder
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


def build_tcn_encoder(cfg: Config) -> keras.Model:
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
    return keras.Model(inp, z, name="TCNEncoder")


# ============================================================
# Scaler utilities
# ============================================================
def default_scaler():
    # safe fallback (identity-like)
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


# ============================================================
# Runtime state
# ============================================================
class AppState:
    encoder: Optional[keras.Model] = None
    scaler: Optional[Dict[str, np.ndarray]] = None
    latest: Optional[Dict] = None
    buffer: deque = deque(maxlen=500)
    using_pretrained: bool = False

STATE = AppState()

# ============================================================
# API models
# ============================================================
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


@api.get("/status")
def status():
    return {
        "ok": True,
        "encoder_ready": STATE.encoder is not None,
        "using_pretrained": STATE.using_pretrained,
        "buffer_size": len(STATE.buffer),
        "has_latest": STATE.latest is not None,
        "latent_dim": CFG.latent_dim,
        "window_seconds": CFG.window_seconds,
    }


@api.post("/ingest")
def ingest(payload: IngestPayload):
    if STATE.encoder is None or STATE.scaler is None:
        return {"ok": False, "reason": "Encoder/scaler not initialized"}

    new_windows = payload.windows
    if not new_windows:
        return {"ok": False, "reason": "No windows provided"}

    ingested = 0
    for w in new_windows:
        try:
            hr = fix_len(np.array(w.hr, dtype=np.float32), CFG.window_seconds)
            hrv = fix_len(np.array(w.hrv, dtype=np.float32), CFG.window_seconds)
            br = fix_len(np.array(w.br, dtype=np.float32), CFG.window_seconds)

            seq = np.stack([hr, hrv, br], axis=-1)             # (T,3)
            seq_scaled = scale_window(seq, STATE.scaler)       # (T,3)
            z = STATE.encoder.predict(seq_scaled[np.newaxis], verbose=0)[0]  # (latent_dim,)

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
            print(f"  Ingest error: {e}")
            continue

    return {"ok": True, "ingested": ingested}


@api.get("/latest")
def latest():
    return STATE.latest if STATE.latest is not None else {}


@api.get("/buffer")
def buffer():
    return {"count": len(STATE.buffer), "windows": list(STATE.buffer)}


def init_runtime():
    Path(CFG.model_dir).mkdir(parents=True, exist_ok=True)

    scaler = load_scaler(CFG.scaler_path)
    if scaler is None:
        print(f"[INIT] No scaler found at {CFG.scaler_path}. Using default scaler.")
        scaler = default_scaler()

    if os.path.exists(CFG.encoder_path):
        print(f"[INIT] Loading pretrained encoder: {CFG.encoder_path}")
        encoder = keras.models.load_model(CFG.encoder_path, compile=False)
        encoder.trainable = False
        STATE.using_pretrained = True
    else:
        print(f"[INIT] No pretrained encoder found at {CFG.encoder_path}. Building fallback encoder.")
        encoder = build_tcn_encoder(CFG)
        encoder.trainable = False
        STATE.using_pretrained = False

    STATE.encoder = encoder
    STATE.scaler = scaler
    print("[INIT] Encoder/scaler ready.")


if __name__ == "__main__":
    init_runtime()
    uvicorn.run(api, host="0.0.0.0", port=8000)