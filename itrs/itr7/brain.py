# brain.py
# Python 3.13+ | TensorFlow 2.x / Keras + FastAPI
# pip install numpy pandas scikit-learn tensorflow fastapi uvicorn

import os
import random
from collections import deque
from dataclasses import dataclass, field
from typing import Tuple, Dict, List, Optional

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import RobustScaler
from sklearn.decomposition import PCA
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

# ============================================================
# 0) Reproducibility
# ============================================================
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
tf.random.set_seed(SEED)

# ============================================================
# 1) Config
# ============================================================
@dataclass
class Config:
    csv_path: str = "C:/Projects/itrs/itr6/data/all_data.csv"

    max_gap_sec_for_same_segment: int = 10

    # Non-overlapping windows
    window_seconds: int = 120
    stride_seconds: int = 120

    # Grouping
    min_group_minutes:      int   = 15
    max_groups_per_round:   int   = 50
    state_change_threshold: float = 0.30

    n_classes:  int   = 6
    input_dim:  int   = 3
    hidden_dim: int   = 64
    dropout:    float = 0.2

    batch_size:        int   = 64
    lr:                float = 1e-3
    pretrain_epochs:   int   = 1000
    finetune_epochs:   int   = 500
    pretrain_patience: int   = 10
    finetune_patience: int   = 6
    min_delta:         float = 1e-4

    # Uncertainty
    uncertainty_low:   float = 0.25
    uncertainty_high:  float = 0.80
    entropy_threshold: float = 0.50
    top_n_uncertain:   int   = 2000


CFG = Config()

STATE_NAMES = {
    0: "Baseline / Sleep",
    1: "Panic / Procrastination",
    2: "Meaningful Focus",
    3: "Inattention / Wandering",
    4: "Rigid Hyperfocus",
    5: "Intervention Needed",
}

# ============================================================
# 2) Diagnostic helpers
# ============================================================
def print_class_distribution(y: np.ndarray, title: str):
    print(f"\n{title}")
    if len(y) == 0:
        print("  (empty)")
        return
    total = len(y)
    vals, cnt = np.unique(y, return_counts=True)
    for v, c in zip(vals, cnt):
        name = STATE_NAMES.get(int(v), str(v))
        pct  = 100.0 * c / max(1, total)
        print(f"  {int(v)} ({name}): {c} ({pct:.2f}%)")


def compute_class_weights(y: np.ndarray, n_classes: int) -> Dict[int, float]:
    counts  = np.bincount(y, minlength=n_classes).astype(np.float32)
    counts  = np.maximum(counts, 1.0)
    weights = counts.sum() / counts
    weights = weights / weights.mean()
    return {i: float(weights[i]) for i in range(n_classes)}


# ============================================================
# 3) Load merged CSV
# ============================================================
def load_merged_csv(csv_path: str) -> pd.DataFrame:
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"CSV not found: {os.path.abspath(csv_path)}")

    df = pd.read_csv(csv_path)

    required = {"timestamp", "hr"}
    missing  = required - set(df.columns)
    if missing:
        raise ValueError(f"CSV missing required columns: {missing}")

    if "hrv" not in df.columns:
        df["hrv"] = np.nan
    if "br" not in df.columns:
        df["br"] = np.nan

    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df["hr"]        = pd.to_numeric(df["hr"],  errors="coerce")
    df["hrv"]       = pd.to_numeric(df["hrv"], errors="coerce")
    df["br"]        = pd.to_numeric(df["br"],  errors="coerce")

    df = df.dropna(subset=["timestamp", "hr"]).copy()

    df.loc[(df["hr"]  < 30)  | (df["hr"]  > 220), "hr"]  = np.nan
    df.loc[(df["hrv"] < 1)   | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"]  < 4)   | (df["br"]  > 60),  "br"]  = np.nan
    df = df.dropna(subset=["hr"]).copy()

    df = df.sort_values("timestamp").reset_index(drop=True)
    return df


# ============================================================
# 4) Derive missing HRV / BR
# ============================================================
def derive_hrv_br_if_missing(df: pd.DataFrame) -> pd.DataFrame:
    d = df.copy().sort_values("timestamp").reset_index(drop=True)
    d = d.set_index("timestamp").resample("1s").mean(numeric_only=True)

    d["hr"] = d["hr"].interpolate(limit=10, limit_direction="both")

    if d["hrv"].isna().mean() > 0.5:
        hr_std_60 = d["hr"].rolling(window=60, min_periods=10).std()
        est_hrv   = (hr_std_60 * 12.0).clip(5, 120)
        d["hrv"]  = d["hrv"].fillna(est_hrv)

    if d["br"].isna().mean() > 0.5:
        hr_smooth = d["hr"].rolling(window=30, min_periods=5).mean()
        hr_min    = hr_smooth.quantile(0.05)
        hr_max    = hr_smooth.quantile(0.95)
        denom     = max(1e-6, hr_max - hr_min)
        br_est    = 10 + (hr_smooth - hr_min) * (10 / denom)
        br_est    = br_est.clip(8, 24)
        d["br"]   = d["br"].fillna(br_est)

    d["hrv"] = d["hrv"].interpolate(limit=20, limit_direction="both")
    d["br"]  = d["br"].interpolate(limit=20, limit_direction="both")

    d = d.dropna(subset=["hr", "hrv", "br"]).copy().reset_index()
    return d


# ============================================================
# 5) Segment by time gaps
# ============================================================
def add_segment_ids(df: pd.DataFrame, max_gap_sec: int) -> pd.DataFrame:
    d  = df.sort_values("timestamp").reset_index(drop=True).copy()
    dt = d["timestamp"].diff().dt.total_seconds().fillna(0)
    d["segment_id"] = (dt > max_gap_sec).cumsum()
    return d


# ============================================================
# 6) Rule logic (warm-start only)
# ============================================================
def compute_deltas(
    x_hr:  np.ndarray,
    x_hrv: np.ndarray,
) -> Tuple[float, float]:
    mid        = len(x_hr) // 2
    hr_first   = float(np.mean(x_hr[:mid]))
    hr_second  = float(np.mean(x_hr[mid:]))
    hrv_first  = float(np.mean(x_hrv[:mid]))
    hrv_second = float(np.mean(x_hrv[mid:]))
    hr_delta   = (hr_second  - hr_first)  / (abs(hr_first)  + 1e-6)
    hrv_delta  = (hrv_second - hrv_first) / (abs(hrv_first) + 1e-6)
    return hr_delta, hrv_delta


def rule_classifier_window(
    x_hr:  np.ndarray,
    x_hrv: np.ndarray,
    x_br:  np.ndarray,
) -> Tuple[int, float]:
    hr_delta, hrv_delta = compute_deltas(x_hr, x_hrv)

    if hrv_delta > 0.30:
        ext_state = 6
    elif hr_delta > 0.15 and hrv_delta < -0.20:
        ext_state = 2
    elif 0.05 < hr_delta <= 0.15 and hrv_delta <= -0.15:
        ext_state = 5
    elif 0.02 < hr_delta <= 0.10 and hrv_delta >= -0.10:
        ext_state = 3
    elif hr_delta <= 0.02 and hrv_delta > 0.05:
        ext_state = 4
    else:
        ext_state = 1

    pred_idx = ext_state - 1
    conf     = 0.60
    conf    += min(0.20, abs(hr_delta)  * 0.5)
    conf    += min(0.20, abs(hrv_delta) * 0.5)
    conf     = float(np.clip(conf, 0.50, 0.95))
    return pred_idx, conf


# ============================================================
# 7) Non-overlapping window creation
# ============================================================
def make_windows_from_segments(df: pd.DataFrame, cfg: Config):
    win    = cfg.window_seconds
    stride = cfg.stride_seconds
    X_list, y_rule, y_rule_conf, meta = [], [], [], []

    for seg_id, g in df.groupby("segment_id"):
        g = g.sort_values("timestamp").reset_index(drop=True)
        if len(g) < win:
            continue

        hr  = g["hr"].values.astype(np.float32)
        hrv = g["hrv"].values.astype(np.float32)
        br  = g["br"].values.astype(np.float32)
        ts  = g["timestamp"].values

        for s in range(0, len(g) - win + 1, stride):
            e     = s + win
            x_hr  = hr[s:e]
            x_hrv = hrv[s:e]
            x_br  = br[s:e]

            seq     = np.stack([x_hr, x_hrv, x_br], axis=-1)
            r, conf = rule_classifier_window(x_hr, x_hrv, x_br)

            X_list.append(seq)
            y_rule.append(r)
            y_rule_conf.append(conf)
            meta.append({
                "segment_id": int(seg_id),
                "start_time": pd.Timestamp(ts[s]).isoformat(),
                "end_time":   pd.Timestamp(ts[e - 1]).isoformat(),
                "avg_hr":     round(float(np.mean(x_hr)),  1),
                "avg_hrv":    round(float(np.mean(x_hrv)), 1),
                "avg_br":     round(float(np.mean(x_br)),  1),
            })

    if not X_list:
        raise ValueError("No windows created.")

    X_raw       = np.array(X_list,      dtype=np.float32)
    y_rule      = np.array(y_rule,      dtype=np.int64)
    y_rule_conf = np.array(y_rule_conf, dtype=np.float32)
    return X_raw, y_rule, y_rule_conf, meta


# ============================================================
# 8) Robust scaler
# ============================================================
def fit_robust_scaler(X_train_raw: np.ndarray) -> Dict[str, np.ndarray]:
    C   = X_train_raw.shape[2]
    med = np.zeros(C, dtype=np.float32)
    iqr = np.ones(C,  dtype=np.float32)
    for ch in range(C):
        vals    = X_train_raw[:, :, ch].reshape(-1)
        m       = np.median(vals)
        q1      = np.percentile(vals, 25)
        q3      = np.percentile(vals, 75)
        s       = q3 - q1
        if s < 1e-6:
            s = 1.0
        med[ch] = float(m)
        iqr[ch] = float(s)
    return {"median": med, "iqr": iqr}


def transform_robust_scaler(
    X_raw:  np.ndarray,
    scaler: Dict[str, np.ndarray],
) -> np.ndarray:
    X = X_raw.copy()
    for ch in range(X.shape[2]):
        X[:, :, ch] = (X[:, :, ch] - scaler["median"][ch]) / scaler["iqr"][ch]
    return X


# ============================================================
# 9) Extract flat features for grouping
# ============================================================
def extract_features(X: np.ndarray) -> np.ndarray:
    n, t, c = X.shape
    feats = []
    for i in range(n):
        row = []
        for ch in range(c):
            sig = X[i, :, ch]
            row += [
                float(np.mean(sig)),
                float(np.std(sig)),
                float(np.min(sig)),
                float(np.max(sig)),
                float(np.polyfit(np.arange(t), sig, 1)[0]),
                float(np.percentile(sig, 25)),
                float(np.percentile(sig, 75)),
            ]
        feats.append(row)
    return np.array(feats, dtype=np.float32)


# ============================================================
# 10) Uncertainty scoring
# ============================================================
def compute_uncertainty_scores(probs: np.ndarray) -> np.ndarray:
    eps       = 1e-9
    n_classes = probs.shape[1]
    entropy   = -np.sum(probs * np.log(probs + eps), axis=1)
    norm_ent  = entropy / np.log(n_classes)
    max_prob  = probs.max(axis=1)
    score     = 0.6 * norm_ent + 0.4 * (1.0 - max_prob)
    return score


def select_uncertain_windows(
    probs:       np.ndarray,
    labeled_set: set,
    cfg:         Config,
) -> np.ndarray:
    eps       = 1e-9
    n_classes = probs.shape[1]
    max_prob  = probs.max(axis=1)
    entropy   = -np.sum(probs * np.log(probs + eps), axis=1)
    norm_ent  = entropy / np.log(n_classes)

    band_mask    = (max_prob >= cfg.uncertainty_low) & \
                   (max_prob <= cfg.uncertainty_high)
    entropy_mask = norm_ent >= cfg.entropy_threshold
    uncertain    = np.where(band_mask | entropy_mask)[0]

    uncertain = np.array(
        [i for i in uncertain if i not in labeled_set],
        dtype=np.int64,
    )

    if len(uncertain) == 0:
        return uncertain

    scores       = compute_uncertainty_scores(probs[uncertain])
    sorted_local = np.argsort(-scores)
    uncertain    = uncertain[sorted_local]
    uncertain    = uncertain[:cfg.top_n_uncertain]

    return uncertain


# ============================================================
# 11) Cosine distance
# ============================================================
def cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    denom = (np.linalg.norm(a) * np.linalg.norm(b)) + 1e-9
    return float(1.0 - np.dot(a, b) / denom)


# ============================================================
# 12) Merge windows into groups
# ============================================================
def merge_into_groups(
    window_indices: np.ndarray,
    features:       np.ndarray,
    meta:           List[Dict],
    probs:          np.ndarray,
    min_minutes:    int,
    change_thresh:  float,
) -> List[Dict]:
    if len(window_indices) == 0:
        return []

    # Sort by time
    start_times    = [pd.Timestamp(meta[i]["start_time"]) for i in window_indices]
    sort_order     = np.argsort(start_times)
    window_indices = window_indices[sort_order]

    raw_groups = []
    current    = [window_indices[0]]

    for k in range(1, len(window_indices)):
        prev_idx = window_indices[k - 1]
        curr_idx = window_indices[k]

        try:
            prev_end   = pd.Timestamp(meta[prev_idx]["end_time"])
            curr_start = pd.Timestamp(meta[curr_idx]["start_time"])
            gap_sec    = (curr_start - prev_end).total_seconds()
        except Exception:
            gap_sec = 9999

        dist = cosine_distance(features[prev_idx], features[curr_idx])

        try:
            g_start     = pd.Timestamp(meta[current[0]]["start_time"])
            g_end       = pd.Timestamp(meta[current[-1]]["end_time"])
            current_dur = (g_end - g_start).total_seconds() / 60
        except Exception:
            current_dur = 0.0

        state_changed = dist > change_thresh
        time_gap      = gap_sec > 60
        long_enough   = current_dur >= min_minutes

        if (state_changed and long_enough) or time_gap:
            raw_groups.append(current)
            current = [curr_idx]
        else:
            current.append(curr_idx)

    raw_groups.append(current)

    result = []
    for grp in raw_groups:
        grp_idx     = np.array(grp)
        group_start = meta[grp_idx[0]]["start_time"]
        group_end   = meta[grp_idx[-1]]["end_time"]

        try:
            t0  = pd.Timestamp(group_start)
            t1  = pd.Timestamp(group_end)
            dur = round((t1 - t0).total_seconds() / 60, 1)
        except Exception:
            dur = 0.0

        if dur < min_minutes:
            continue

        avg_hr  = round(float(np.mean([meta[i]["avg_hr"]  for i in grp_idx])), 1)
        avg_hrv = round(float(np.mean([meta[i]["avg_hrv"] for i in grp_idx])), 1)
        avg_br  = round(float(np.mean([meta[i]["avg_br"]  for i in grp_idx])), 1)

        avg_probs   = probs[grp_idx].mean(axis=0).tolist()
        model_guess = int(np.argmax(avg_probs))

        scores     = compute_uncertainty_scores(probs[grp_idx])
        rep_local  = int(np.argmax(scores))
        rep_global = int(grp_idx[rep_local])

        result.append({
            "id":            rep_global,
            "window_ids":    [int(i) for i in grp_idx],
            "start_time":    group_start,
            "end_time":      group_end,
            "duration_min":  dur,
            "window_count":  len(grp_idx),
            "probabilities": avg_probs,
            "model_guess":   model_guess,
            "avg_hr":        avg_hr,
            "avg_hrv":       avg_hrv,
            "avg_br":        avg_br,
        })

    return result


# ============================================================
# 13) Keras LSTM model
# ============================================================
def build_model(cfg: Config) -> keras.Model:
    inputs = keras.Input(shape=(cfg.window_seconds, cfg.input_dim), name="input")
    x      = layers.LSTM(cfg.hidden_dim, name="lstm")(inputs)
    x      = layers.Dropout(cfg.dropout, name="dropout")(x)
    output = layers.Dense(cfg.n_classes, activation="softmax", name="output")(x)
    model  = keras.Model(inputs, output, name="BrainLSTM")
    return model


# ============================================================
# 14) Predict helpers
# ============================================================
def predict_proba(model: keras.Model, X: np.ndarray, batch_size=256) -> np.ndarray:
    return model.predict(X, batch_size=batch_size, verbose=0)


# ============================================================
# 15) Scale a single raw window
# ============================================================
def scale_window(seq: np.ndarray, scaler: Dict) -> np.ndarray:
    """Scale a single (window, 3) array using stored scaler."""
    out = seq.copy()
    for ch in range(out.shape[1]):
        out[:, ch] = (out[:, ch] - scaler["median"][ch]) / scaler["iqr"][ch]
    return out


# ============================================================
# 16) Global app state
# ============================================================
class AppState:
    model:             Optional[keras.Model] = None
    scaler:            Optional[Dict]        = None
    features:          Optional[np.ndarray]  = None
    X:                 Optional[np.ndarray]  = None
    y_rule:            Optional[np.ndarray]  = None
    y_rule_conf:       Optional[np.ndarray]  = None
    meta:              Optional[List]        = None
    y_user:            Optional[np.ndarray]  = None
    uncertain_windows: List[Dict]            = []
    labels:            Dict[int, int]        = {}
    trained:           bool                  = False
    latest_window:     Optional[Dict]        = None
    window_buffer:     deque                 = deque(maxlen=100)


STATE = AppState()


# ============================================================
# 17) FastAPI app
# ============================================================
api = FastAPI(title="Brain API")

api.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class LabelPayload(BaseModel):
    window_id: int
    label:     int


class IngestPayload(BaseModel):
    windows: List[Dict]


# ── Existing endpoints ──────────────────────────────────────

@api.get("/status")
def status():
    return {
        "trained":         STATE.trained,
        "uncertain_count": len(STATE.uncertain_windows),
        "labeled_count":   len(STATE.labels),
        "buffer_size":     len(STATE.window_buffer),
        "has_latest":      STATE.latest_window is not None,
    }


@api.get("/windows")
def get_windows():
    return {"windows": STATE.uncertain_windows}


@api.post("/label")
def submit_label(payload: LabelPayload):
    group = next(
        (g for g in STATE.uncertain_windows if g["id"] == payload.window_id),
        None,
    )

    if group is None:
        STATE.labels[payload.window_id] = payload.label
        if STATE.y_user is not None:
            STATE.y_user[payload.window_id] = payload.label
        return {
            "ok":              True,
            "labeled_windows": 1,
            "labeled_groups":  len(STATE.labels),
        }

    for wid in group["window_ids"]:
        STATE.labels[wid] = payload.label
        if STATE.y_user is not None:
            STATE.y_user[wid] = payload.label

    return {
        "ok":              True,
        "labeled_windows": len(group["window_ids"]),
        "labeled_groups":  len(STATE.labels),
    }


@api.post("/retrain")
def retrain():
    if STATE.model is None:
        return {"ok": False, "reason": "Model not trained yet"}

    labeled_ids = [
        wid for wid, lbl in STATE.labels.items()
        if STATE.y_user is not None and STATE.y_user[wid] >= 0
    ]

    if len(labeled_ids) < 10:
        return {
            "ok":     False,
            "reason": f"Need at least 10 labels, have {len(labeled_ids)}",
        }

    tr_idx = np.array(labeled_ids)
    if len(tr_idx) < 4:
        return {"ok": False, "reason": "Not enough labeled data to split"}

    tr_ft, va_ft = train_test_split(tr_idx, test_size=0.2, random_state=SEED)
    y_tr         = STATE.y_user[tr_ft]
    y_va         = STATE.y_user[va_ft]
    class_w      = compute_class_weights(y_tr, CFG.n_classes)

    STATE.model.fit(
        STATE.X[tr_ft],
        y_tr,
        validation_data=(STATE.X[va_ft], y_va),
        epochs=CFG.finetune_epochs,
        batch_size=CFG.batch_size,
        class_weight=class_w,
        callbacks=[
            keras.callbacks.EarlyStopping(
                monitor="val_loss",
                patience=CFG.finetune_patience,
                min_delta=CFG.min_delta,
                restore_best_weights=True,
                verbose=0,
            )
        ],
        verbose=0,
    )

    print(f"Retrained on {len(tr_ft)} windows "
          f"({len(STATE.labels)} unique windows labeled)")
    _refresh_uncertain_windows()

    return {
        "ok":              True,
        "labeled_windows": len(STATE.labels),
        "uncertain_left":  len(STATE.uncertain_windows),
    }


# ── New endpoints ───────────────────────────────────────────

@api.post("/ingest")
def ingest(payload: IngestPayload):
    """
    Receive new live windows from polar_reader.py.
    Runs inference on each window.
    Stores latest vitals for RL agent.
    Refreshes uncertain groups.
    """
    if STATE.model is None or STATE.scaler is None:
        return {"ok": False, "reason": "Model not ready yet"}

    new_windows = payload.windows
    if not new_windows:
        return {"ok": False, "reason": "No windows provided"}

    ingested = 0

    for win in new_windows:
        try:
            hr  = np.array(win["hr"],  dtype=np.float32)
            hrv = np.array(win["hrv"], dtype=np.float32)
            br  = np.array(win["br"],  dtype=np.float32)

            # Pad or trim to window_seconds
            target = CFG.window_seconds

            def fix(arr: np.ndarray) -> np.ndarray:
                if len(arr) >= target:
                    return arr[:target]
                return np.pad(arr, (0, target - len(arr)), mode="edge")

            hr  = fix(hr)
            hrv = fix(hrv)
            br  = fix(br)

            # Build sequence (window, 3)
            seq = np.stack([hr, hrv, br], axis=-1)

            # Scale
            seq_scaled = scale_window(seq, STATE.scaler)

            # Inference
            X_new       = seq_scaled[np.newaxis, :, :]   # (1, window, 3)
            probs        = predict_proba(STATE.model, X_new)[0]
            model_guess  = int(np.argmax(probs))
            uncertainty  = float(compute_uncertainty_scores(probs[np.newaxis])[0])

            # Build window meta
            window_meta = {
                "start_time":    win["start_time"],
                "end_time":      win["end_time"],
                "avg_hr":        float(win["avg_hr"]),
                "avg_hrv":       float(win["avg_hrv"]),
                "avg_br":        float(win["avg_br"]),
                "probabilities": probs.tolist(),
                "model_guess":   model_guess,
                "uncertainty":   uncertainty,
                "state_name":    STATE_NAMES.get(model_guess, "Unknown"),
            }

            # Always update latest window for RL agent
            STATE.latest_window = window_meta

            # Add to rolling buffer
            STATE.window_buffer.append(window_meta)

            ingested += 1

            print(f"  Ingested window | "
                  f"state={STATE_NAMES[model_guess]} | "
                  f"HR={win['avg_hr']} | "
                  f"HRV={win['avg_hrv']} | "
                  f"uncertainty={uncertainty:.3f}")

        except Exception as e:
            print(f"  Ingest window error: {e}")
            continue

    # Refresh uncertain groups after ingestion
    if ingested > 0:
        _refresh_uncertain_windows()

    return {
        "ok":              True,
        "ingested":        ingested,
        "uncertain_groups": len(STATE.uncertain_windows),
    }


@api.get("/latest")
def get_latest():
    """
    Return the most recent window vitals + model prediction.
    Used by RL agent every 2 minutes.
    """
    if STATE.latest_window is None:
        return {}
    return STATE.latest_window


@api.get("/buffer")
def get_buffer():
    """
    Return the last N windows from the rolling buffer.
    Useful for debugging and visualisation.
    """
    return {
        "count":   len(STATE.window_buffer),
        "windows": list(STATE.window_buffer),
    }


@api.get("/summary")
def get_summary():
    """
    Return a summary of the rolling buffer.
    State distribution, average vitals, trend.
    """
    if not STATE.window_buffer:
        return {"ok": False, "reason": "No data yet"}

    buf = list(STATE.window_buffer)

    # State distribution
    state_counts = {}
    for w in buf:
        name = w.get("state_name", "Unknown")
        state_counts[name] = state_counts.get(name, 0) + 1

    # Average vitals
    avg_hr  = round(float(np.mean([w["avg_hr"]  for w in buf])), 1)
    avg_hrv = round(float(np.mean([w["avg_hrv"] for w in buf])), 1)
    avg_br  = round(float(np.mean([w["avg_br"]  for w in buf])), 1)

    # Trend — last 5 vs first 5
    def trend(key: str) -> float:
        vals = [w[key] for w in buf]
        if len(vals) < 10:
            return 0.0
        return round(float(np.mean(vals[-5:])) - float(np.mean(vals[:5])), 2)

    return {
        "ok":            True,
        "window_count":  len(buf),
        "state_dist":    state_counts,
        "avg_hr":        avg_hr,
        "avg_hrv":       avg_hrv,
        "avg_br":        avg_br,
        "hr_trend":      trend("avg_hr"),
        "hrv_trend":     trend("avg_hrv"),
        "br_trend":      trend("avg_br"),
    }


# ============================================================
# 18) Refresh uncertain windows
# ============================================================
def _refresh_uncertain_windows():
    if STATE.model is None or STATE.X is None:
        return

    probs       = predict_proba(STATE.model, STATE.X)
    labeled_set = set(STATE.labels.keys())

    uncertain_idx = select_uncertain_windows(probs, labeled_set, CFG)
    print(f"  Uncertain windows (unlabeled): {len(uncertain_idx)}")

    if len(uncertain_idx) == 0:
        STATE.uncertain_windows = []
        return

    all_groups = merge_into_groups(
        window_indices = uncertain_idx,
        features       = STATE.features,
        meta           = STATE.meta,
        probs          = probs,
        min_minutes    = CFG.min_group_minutes,
        change_thresh  = CFG.state_change_threshold,
    )

    print(f"  Valid groups (≥{CFG.min_group_minutes} min): {len(all_groups)}")

    if len(all_groups) > CFG.max_groups_per_round:
        def group_uncertainty(g):
            idx    = np.array(g["window_ids"])
            scores = compute_uncertainty_scores(probs[idx])
            return float(scores.mean())

        all_groups.sort(key=group_uncertainty, reverse=True)
        all_groups = all_groups[:CFG.max_groups_per_round]
        all_groups.sort(key=lambda g: g["start_time"])

    STATE.uncertain_windows = all_groups


# ============================================================
# 19) Training pipeline
# ============================================================
def run_training():
    print("TensorFlow:", tf.__version__)
    print("Reading CSV:", os.path.abspath(CFG.csv_path))

    # A) Load
    df_raw = load_merged_csv(CFG.csv_path)
    print("Rows loaded:", len(df_raw))

    # B) Fill
    df_filled = derive_hrv_br_if_missing(df_raw)
    print("Rows after fill/resample:", len(df_filled))

    # C) Segment
    df_seg = add_segment_ids(df_filled, CFG.max_gap_sec_for_same_segment)
    print("Segments:", df_seg["segment_id"].nunique())

    # D) Windows
    X_raw, y_rule, y_rule_conf, meta = make_windows_from_segments(df_seg, CFG)
    n = len(X_raw)
    print("Windows created:", n)
    print_class_distribution(y_rule, "Rule-label distribution (warm-start only):")

    # E) Scale
    idx_all             = np.arange(n)
    idx_train, idx_test = train_test_split(idx_all, test_size=0.2, random_state=SEED)
    scaler              = fit_robust_scaler(X_raw[idx_train])
    X                   = transform_robust_scaler(X_raw, scaler)

    # F) Features
    print("Extracting features for grouping...")
    features = extract_features(X)
    print(f"  Feature shape: {features.shape}")

    # G) y_user
    y_user = -1 * np.ones(n, dtype=np.int64)

    # H) Build + compile
    model = build_model(CFG)
    model.summary()
    model.compile(
        optimizer=keras.optimizers.Adam(learning_rate=CFG.lr),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    # I) Warm-start pretrain
    print("\nWarm-start pretraining on rule labels...")
    w_rule = 0.25 + 0.75 * y_rule_conf[idx_train]
    tr_idx_pre, val_idx_pre = train_test_split(
        idx_train, test_size=0.2, random_state=SEED
    )

    model.fit(
        X[tr_idx_pre],
        y_rule[tr_idx_pre],
        sample_weight=w_rule[np.isin(idx_train, tr_idx_pre)],
        validation_data=(X[val_idx_pre], y_rule[val_idx_pre]),
        epochs=CFG.pretrain_epochs,
        batch_size=CFG.batch_size,
        callbacks=[
            keras.callbacks.EarlyStopping(
                monitor="val_loss",
                patience=CFG.pretrain_patience,
                min_delta=CFG.min_delta,
                restore_best_weights=True,
                verbose=1,
            )
        ],
        verbose=1,
    )

    # J) Save state
    STATE.model       = model
    STATE.scaler      = scaler
    STATE.features    = features
    STATE.X           = X
    STATE.y_rule      = y_rule
    STATE.y_rule_conf = y_rule_conf
    STATE.meta        = meta
    STATE.y_user      = y_user
    STATE.trained     = True

    # K) Initial uncertain groups
    print("\nFinding initial uncertain window groups...")
    _refresh_uncertain_windows()
    print(f"Groups ready for labeling: {len(STATE.uncertain_windows)}")
    print("\nTraining done. API is running at http://localhost:8000")


# ============================================================
# 20) Entry point
# ============================================================
if __name__ == "__main__":
    run_training()
    uvicorn.run(api, host="0.0.0.0", port=8000)