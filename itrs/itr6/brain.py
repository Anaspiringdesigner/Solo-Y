# brain.py
# Python 3.13+ | TensorFlow 2.x / Keras
# pip install numpy pandas scikit-learn tensorflow

import os
import json
import random
from dataclasses import dataclass
from typing import Tuple, Optional, Dict, List

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers

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

    window_seconds: int = 120
    stride_seconds: int = 30

    n_classes:  int   = 6
    input_dim:  int   = 3
    hidden_dim: int   = 64
    dropout:    float = 0.2

    batch_size:       int   = 64
    lr:               float = 1e-3
    pretrain_epochs:  int   = 1000
    finetune_epochs:  int   = 1000
    pretrain_patience: int  = 10
    finetune_patience: int  = 6
    min_delta:        float = 1e-4

    initial_label_fraction: float = 0.10
    active_rounds:          int   = 8
    query_size_per_round:   int   = 40
    max_user_labels:        int   = 500
    uncertainty_threshold:  float = 0.55

    alpha_start: float = 0.35
    alpha_end:   float = 0.85


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
# 6) Rule logic
# ============================================================
def compute_deltas(
    x_hr: np.ndarray,
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
# 7) Window creation
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

            seq      = np.stack([x_hr, x_hrv, x_br], axis=-1)
            r, conf  = rule_classifier_window(x_hr, x_hrv, x_br)

            X_list.append(seq)
            y_rule.append(r)
            y_rule_conf.append(conf)
            meta.append({
                "segment_id": int(seg_id),
                "start_time": pd.Timestamp(ts[s]),
                "end_time":   pd.Timestamp(ts[e - 1]),
            })

    if not X_list:
        raise ValueError("No windows created. Reduce window_seconds or check data continuity.")

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
# 9) Keras LSTM model
# ============================================================
def build_model(cfg: Config) -> keras.Model:
    inputs = keras.Input(shape=(cfg.window_seconds, cfg.input_dim), name="input")
    x      = layers.LSTM(cfg.hidden_dim, name="lstm")(inputs)
    x      = layers.Dropout(cfg.dropout, name="dropout")(x)
    output = layers.Dense(cfg.n_classes, activation="softmax", name="output")(x)
    model  = keras.Model(inputs, output, name="BrainLSTM")
    return model


# ============================================================
# 10) Predict helpers
# ============================================================
def predict_proba(model: keras.Model, X: np.ndarray, batch_size=256) -> np.ndarray:
    return model.predict(X, batch_size=batch_size, verbose=0)


def entropy_from_probs(p: np.ndarray, eps=1e-9) -> np.ndarray:
    return -np.sum(p * np.log(p + eps), axis=1)


# ============================================================
# 11) Active query selector
# ============================================================
def select_queries_active(
    probs_unl:             np.ndarray,
    y_rule_unl:            np.ndarray,
    idx_unl:               np.ndarray,
    query_k:               int,
    uncertainty_threshold: float,
) -> np.ndarray:
    yhat = probs_unl.argmax(axis=1)
    maxp = probs_unl.max(axis=1)
    ent  = entropy_from_probs(probs_unl)

    uncertain = (maxp < uncertainty_threshold).astype(np.float32)
    disagree  = (yhat != y_rule_unl).astype(np.float32)

    pred_counts = np.bincount(yhat, minlength=CFG.n_classes).astype(np.float32)
    pred_counts = np.maximum(pred_counts, 1.0)
    rare_bonus  = 1.0 / pred_counts[yhat]

    score  = ent
    score += 0.40 * uncertain
    score += 0.35 * disagree
    score += 0.25 * rare_bonus

    chosen_local = np.argsort(-score)[:query_k]
    return idx_unl[chosen_local]


def fusion_predict(
    probs_model: np.ndarray,
    y_rule:      np.ndarray,
    conf_rule:   np.ndarray,
    alpha:       float,
) -> np.ndarray:
    n, c       = probs_model.shape
    probs_rule = np.zeros((n, c), dtype=np.float32)
    probs_rule[np.arange(n), y_rule] = conf_rule
    rem        = 1.0 - conf_rule
    probs_rule += rem[:, None] / c
    probs      = alpha * probs_model + (1 - alpha) * probs_rule
    return probs.argmax(axis=1)


# ============================================================
# 12) Export to TFLite  ← one step, no ONNX needed
# ============================================================
def export_to_tflite(
    model:       keras.Model,
    scaler:      Dict[str, np.ndarray],
    path_tflite: str = "brain_model.tflite",
    path_scaler: str = "scaler.json",
):
    converter = tf.lite.TFLiteConverter.from_keras_model(model)

    # Required for LSTM ops
    converter.target_spec.supported_ops = [
        tf.lite.OpsSet.TFLITE_BUILTINS,
        tf.lite.OpsSet.SELECT_TF_OPS,
    ]
    converter._experimental_lower_tensor_list_ops = False

    tflite_model = converter.convert()

    with open(path_tflite, "wb") as f:
        f.write(tflite_model)
    print(f"TFLite saved → {path_tflite} ({len(tflite_model) / 1024:.1f} KB)")

    with open(path_scaler, "w") as f:
        json.dump(
            {
                "median": scaler["median"].tolist(),
                "iqr":    scaler["iqr"].tolist(),
            },
            f,
            indent=2,
        )
    print(f"Scaler saved → {path_scaler}")

# ============================================================
# 13) Main
# ============================================================
def main():
    print("TensorFlow version:", tf.__version__)
    print("Reading CSV:", os.path.abspath(CFG.csv_path))

    # A) Load
    df_raw = load_merged_csv(CFG.csv_path)
    print("Rows loaded:", len(df_raw))

    # B) Fill channels + resample
    df_filled = derive_hrv_br_if_missing(df_raw)
    print("Rows after fill/resample:", len(df_filled))

    # C) Segment
    df_seg = add_segment_ids(df_filled, CFG.max_gap_sec_for_same_segment)
    print("Segments:", df_seg["segment_id"].nunique())

    # D) Windowing
    X_raw, y_rule, y_rule_conf, meta = make_windows_from_segments(df_seg, CFG)
    n = len(X_raw)
    print("Windows created:", n)
    print_class_distribution(y_rule, "Rule-label distribution on all windows:")

    # E) Train / test split
    idx_all               = np.arange(n)
    idx_train, idx_test   = train_test_split(idx_all, test_size=0.2, random_state=SEED)

    # F) Scaling
    scaler = fit_robust_scaler(X_raw[idx_train])
    X      = transform_robust_scaler(X_raw, scaler)

    # G) Active pools
    idx_pool      = idx_train.copy()
    np.random.shuffle(idx_pool)
    init_k        = max(10, int(len(idx_pool) * CFG.initial_label_fraction))
    idx_labeled   = idx_pool[:init_k].copy()
    idx_unlabeled = idx_pool[init_k:].copy()

    y_user                  = -1 * np.ones(n, dtype=np.int64)
    y_user[idx_labeled]     = y_rule[idx_labeled]

    # H) Build model
    model = build_model(CFG)
    model.summary()
    model.compile(
        optimizer=keras.optimizers.Adam(learning_rate=CFG.lr),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    # I) Pretrain on rule labels
    print("\nPretraining on rule labels...")
    w_rule        = 0.25 + 0.75 * y_rule_conf[idx_train]
    tr_idx_pre, val_idx_pre = train_test_split(
        idx_train, test_size=0.2, random_state=SEED
    )

    pretrain_callbacks = [
        keras.callbacks.EarlyStopping(
            monitor="val_loss",
            patience=CFG.pretrain_patience,
            min_delta=CFG.min_delta,
            restore_best_weights=True,
            verbose=1,
        )
    ]

    model.fit(
        X[tr_idx_pre],
        y_rule[tr_idx_pre],
        sample_weight=w_rule[np.isin(idx_train, tr_idx_pre)],
        validation_data=(X[val_idx_pre], y_rule[val_idx_pre]),
        epochs=CFG.pretrain_epochs,
        batch_size=CFG.batch_size,
        callbacks=pretrain_callbacks,
        verbose=1,
    )

    # J) Active learning rounds
    print("\nActive learning rounds...")
    for r in range(CFG.active_rounds):
        tr_idx = idx_labeled[y_user[idx_labeled] >= 0]
        if len(tr_idx) < 20:
            print("Not enough labeled windows to finetune. Stopping.")
            break

        tr_ft, va_ft = train_test_split(
            tr_idx, test_size=0.2, random_state=SEED + r
        )

        class_w = compute_class_weights(y_user[tr_ft], CFG.n_classes)

        finetune_callbacks = [
            keras.callbacks.EarlyStopping(
                monitor="val_loss",
                patience=CFG.finetune_patience,
                min_delta=CFG.min_delta,
                restore_best_weights=True,
                verbose=1,
            )
        ]

        model.fit(
            X[tr_ft],
            y_user[tr_ft],
            validation_data=(X[va_ft], y_user[va_ft]),
            epochs=CFG.finetune_epochs,
            batch_size=CFG.batch_size,
            class_weight=class_w,
            callbacks=finetune_callbacks,
            verbose=1,
        )

        if len(idx_unlabeled) == 0 or len(idx_labeled) >= CFG.max_user_labels:
            print("Stopping active loop: label budget or pool exhausted.")
            break

        probs_unl = predict_proba(model, X[idx_unlabeled])
        ask_idx   = select_queries_active(
            probs_unl=probs_unl,
            y_rule_unl=y_rule[idx_unlabeled],
            idx_unl=idx_unlabeled,
            query_k=min(CFG.query_size_per_round, len(idx_unlabeled)),
            uncertainty_threshold=CFG.uncertainty_threshold,
        )

        # TODO: replace with real UI labels
        y_user[ask_idx] = y_rule[ask_idx]

        keep          = ~np.isin(idx_unlabeled, ask_idx)
        idx_unlabeled = idx_unlabeled[keep]
        idx_labeled   = np.concatenate([idx_labeled, ask_idx])

        print(f"Round {r+1}/{CFG.active_rounds} | labeled={len(idx_labeled)}")
        print_class_distribution(
            y_user[idx_labeled],
            f"Labeled-set distribution after round {r+1}:"
        )

    # K) Final inference
    probs_test   = predict_proba(model, X[idx_test])
    yhat_model   = probs_test.argmax(axis=1)

    frac_labeled = len(idx_labeled) / max(1, len(idx_train))
    alpha        = CFG.alpha_start + (CFG.alpha_end - CFG.alpha_start) * frac_labeled
    alpha        = float(np.clip(alpha, 0.0, 1.0))
    yhat_fused   = fusion_predict(
        probs_test, y_rule[idx_test], y_rule_conf[idx_test], alpha
    )

    print_class_distribution(yhat_model, "Prediction distribution (model-only):")
    print_class_distribution(yhat_fused, "Prediction distribution (fused):")

    print("\nSample prompt windows:")
    for i in range(min(5, len(meta))):
        print(f"  {meta[i]['start_time']} -> {meta[i]['end_time']}")

    # L) Export — one clean step
    export_to_tflite(model, scaler)

    print("\nDone.")


# ============================================================
if __name__ == "__main__":
    main()