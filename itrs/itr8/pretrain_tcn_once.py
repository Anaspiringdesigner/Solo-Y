# pretrain_tcn_once.py
# One-time pretraining for TCN encoder on OLD data only (before today),
# using your existing Android folder via ADB (no historical_data folder needed).
#
# Usage:
#   python pretrain_tcn_once.py
#   python pretrain_tcn_once.py --force
#
# Requirements:
#   pip install numpy pandas tensorflow
#   adb installed, phone connected, USB debugging on

import argparse
import subprocess
import tempfile
import hashlib
from pathlib import Path
import numpy as np
import pandas as pd
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers

# ============================================================
# Config
# ============================================================
SEED = 42
np.random.seed(SEED)
tf.random.set_seed(SEED)

ANDROID_POLAR_DIR = "/sdcard/Download/Data_from_H10"
LOCAL_TEMP = Path(tempfile.gettempdir()) / "polar_pretrain_pull"
LOCAL_TEMP.mkdir(exist_ok=True)

MODEL_DIR = Path("models")
MODEL_DIR.mkdir(parents=True, exist_ok=True)

ENCODER_PATH = MODEL_DIR / "tcn_encoder.keras"
SCALER_PATH = MODEL_DIR / "scaler.npz"
FLAG_PATH = MODEL_DIR / "trained_once.flag"

WINDOW_SECONDS = 30
INPUT_DIM = 3
LATENT_DIM = 32
TCN_FILTERS = 32
TCN_KERNEL = 3
DILATIONS = (1, 2, 4, 8)
DROPOUT = 0.1

BATCH_SIZE = 64
EPOCHS = 120
VAL_SPLIT = 0.2

# ============================================================
# ADB helpers
# ============================================================
def adb_is_connected() -> bool:
    try:
        r = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=5)
        lines = [l for l in r.stdout.strip().splitlines() if l and not l.startswith("List")]
        return any("device" in l for l in lines)
    except Exception:
        return False


def adb_list_hr_files(android_dir: str) -> list:
    try:
        r = subprocess.run(["adb", "shell", f"ls {android_dir}"], capture_output=True, text=True, timeout=15)
        files = []
        for f in r.stdout.splitlines():
            f = f.strip()
            if f.endswith(".txt") and "_HR.txt" in f:
                files.append(f)
        return sorted(files)
    except Exception:
        return []


def adb_pull_file(android_path: str, local_path: Path) -> bool:
    try:
        r = subprocess.run(["adb", "pull", android_path, str(local_path)], capture_output=True, text=True, timeout=60)
        return r.returncode == 0
    except Exception:
        return False


def file_hash(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()

# ============================================================
# Parsing / preprocessing
# ============================================================
def parse_polar_hr_file(path: Path) -> pd.DataFrame:
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    data_lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("Phone timestamp"):
            continue
        if line.startswith("Polar_H10"):
            continue
        data_lines.append(line)

    for line in data_lines:
        parts = line.split(";")
        if len(parts) < 2:
            continue
        try:
            ts = pd.to_datetime(parts[0].strip(), errors="coerce")
            hr = float(parts[1].strip()) if len(parts) > 1 and parts[1].strip() else np.nan
            hrv = float(parts[2].strip()) if len(parts) > 2 and parts[2].strip() else np.nan
            br = float(parts[3].strip()) if len(parts) > 3 and parts[3].strip() else np.nan
            rows.append({"timestamp": ts, "hr": hr, "hrv": hrv, "br": br})
        except Exception:
            continue

    if not rows:
        return pd.DataFrame()

    df = pd.DataFrame(rows)
    df = df.dropna(subset=["timestamp", "hr"]).copy()
    df = df.sort_values("timestamp").reset_index(drop=True)

    # sanity ranges
    df.loc[(df["hr"] < 30) | (df["hr"] > 220), "hr"] = np.nan
    df.loc[(df["hrv"] < 1) | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"] < 4) | (df["br"] > 60), "br"] = np.nan
    df = df.dropna(subset=["hr"]).copy()
    if df.empty:
        return pd.DataFrame()

    # 1s resample
    df = df.set_index("timestamp").resample("1s").mean(numeric_only=True)

    # HR interpolate
    df["hr"] = df["hr"].interpolate(method="time", limit=10, limit_direction="both")

    # HRV fill/interpolate
    if df["hrv"].isna().mean() > 0.5:
        hr_std = df["hr"].rolling(window=60, min_periods=10).std()
        est_hrv = (hr_std * 12.0).clip(5, 120)
        df["hrv"] = df["hrv"].fillna(est_hrv)
    df["hrv"] = df["hrv"].interpolate(method="time", limit=20, limit_direction="both")

    # BR fill/interpolate
    if df["br"].isna().mean() > 0.5:
        hr_smooth = df["hr"].rolling(window=30, min_periods=5).mean()
        hr_min = hr_smooth.quantile(0.05)
        hr_max = hr_smooth.quantile(0.95)
        denom = max(1e-6, hr_max - hr_min)
        br_est = 10 + (hr_smooth - hr_min) * (10 / denom)
        br_est = br_est.clip(8, 24)
        df["br"] = df["br"].fillna(br_est)
    df["br"] = df["br"].interpolate(method="time", limit=20, limit_direction="both")

    df = df.dropna(subset=["hr", "hrv", "br"]).reset_index()
    return df


def build_windows(df: pd.DataFrame, window_sec: int = 120) -> np.ndarray:
    if len(df) < window_sec:
        return np.empty((0, window_sec, 3), dtype=np.float32)

    hr = df["hr"].values.astype(np.float32)
    hrv = df["hrv"].values.astype(np.float32)
    br = df["br"].values.astype(np.float32)

    seqs = []
    for s in range(0, len(df) - window_sec + 1, window_sec):
        e = s + window_sec
        seqs.append(np.stack([hr[s:e], hrv[s:e], br[s:e]], axis=-1))
    if not seqs:
        return np.empty((0, window_sec, 3), dtype=np.float32)
    return np.array(seqs, dtype=np.float32)

# ============================================================
# Scaler
# ============================================================
def fit_robust_scaler(X: np.ndarray):
    flat = X.reshape(-1, X.shape[-1])
    med = np.median(flat, axis=0).astype(np.float32)
    q1 = np.percentile(flat, 25, axis=0).astype(np.float32)
    q3 = np.percentile(flat, 75, axis=0).astype(np.float32)
    iqr = (q3 - q1).astype(np.float32)
    iqr = np.where(np.abs(iqr) < 1e-6, 1.0, iqr).astype(np.float32)
    return med, iqr


def transform_robust(X: np.ndarray, med: np.ndarray, iqr: np.ndarray):
    Y = X.copy()
    for ch in range(Y.shape[-1]):
        Y[:, :, ch] = (Y[:, :, ch] - med[ch]) / iqr[ch]
    return Y

# ============================================================
# TCN AE
# ============================================================
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


def build_encoder():
    inp = keras.Input(shape=(WINDOW_SECONDS, INPUT_DIM), name="seq_in")
    x = inp
    for i, d in enumerate(DILATIONS):
        x = tcn_res_block(x, TCN_FILTERS, TCN_KERNEL, d, DROPOUT, name=f"enc_b{i+1}_d{d}")
    x = layers.GlobalAveragePooling1D(name="gap")(x)
    z = layers.Dense(LATENT_DIM, activation=None, name="latent")(x)
    z = layers.LayerNormalization(name="latent_norm")(z)
    return keras.Model(inp, z, name="TCNEncoder")


def build_autoencoder(encoder: keras.Model):
    inp = keras.Input(shape=(WINDOW_SECONDS, INPUT_DIM), name="ae_in")
    z = encoder(inp)

    x = layers.Dense(WINDOW_SECONDS * 64, activation="relu", name="dec_dense")(z)
    x = layers.Reshape((WINDOW_SECONDS, 64), name="dec_reshape")(x)
    x = layers.Conv1D(64, 3, padding="same", activation="relu", name="dec_c1")(x)
    x = layers.Conv1D(32, 3, padding="same", activation="relu", name="dec_c2")(x)
    out = layers.Conv1D(INPUT_DIM, 1, padding="same", activation=None, name="recon")(x)

    ae = keras.Model(inp, out, name="TCN_Autoencoder")
    ae.compile(
        optimizer=keras.optimizers.Adam(1e-3),
        loss="mse",
        metrics=["mae"],
    )
    return ae

# ============================================================
# Data loader from existing Android folder
# ============================================================
def load_old_windows_from_android() -> np.ndarray:
    if not adb_is_connected():
        raise RuntimeError("ADB device not connected.")

    files = adb_list_hr_files(ANDROID_POLAR_DIR)
    if not files:
        raise FileNotFoundError(f"No *_HR.txt files in {ANDROID_POLAR_DIR}")

    today0 = pd.Timestamp.now().normalize()  # local today 00:00

    all_windows = []
    seen_hashes = set()

    print(f"[DATA] Found {len(files)} HR files on device")
    for fname in files:
        android_path = f"{ANDROID_POLAR_DIR}/{fname}"
        local_path = LOCAL_TEMP / fname

        ok = adb_pull_file(android_path, local_path)
        if not ok or not local_path.exists():
            print(f"[WARN] pull failed: {fname}")
            continue

        h = file_hash(local_path)
        if h in seen_hashes:
            continue
        seen_hashes.add(h)

        try:
            df = parse_polar_hr_file(local_path)
            if df.empty:
                print(f"[SKIP] {fname}: empty parsed")
                continue

            df["timestamp"] = pd.to_datetime(df["timestamp"]).dt.tz_localize(None)

            # OLD data only: strictly before today
            df_old = df[df["timestamp"] < today0].copy()
            if df_old.empty:
                print(f"[SKIP] {fname}: only today data")
                continue

            Xf = build_windows(df_old, WINDOW_SECONDS)
            print(f"[DATA] {fname}: old_rows={len(df_old)} windows={len(Xf)}")

            if len(Xf) > 0:
                all_windows.append(Xf)

        except Exception as e:
            print(f"[WARN] parse fail {fname}: {e}")
            continue

    if not all_windows:
        raise ValueError("No old windows found (< today).")

    X = np.concatenate(all_windows, axis=0).astype(np.float32)
    return X

# ============================================================
# Main
# ============================================================
def main(force: bool = False):
    if FLAG_PATH.exists() and not force:
        print(f"[SKIP] {FLAG_PATH} exists. Already trained once. Use --force to retrain.")
        return

    print("[STEP] Loading old data from existing Android folder via ADB...")
    X_raw = load_old_windows_from_android()
    print(f"[INFO] Total old windows: {len(X_raw)} | shape={X_raw.shape}")

    print("[STEP] Fit robust scaler")
    med, iqr = fit_robust_scaler(X_raw)
    X = transform_robust(X_raw, med, iqr)
    print(f"[INFO] median={med}, iqr={iqr}")

    print("[STEP] Build model")
    encoder = build_encoder()
    ae = build_autoencoder(encoder)
    ae.summary()

    print("[STEP] Train one-time")
    callbacks = [
        keras.callbacks.EarlyStopping(
            monitor="val_loss",
            patience=8,
            restore_best_weights=True,
            verbose=1
        )
    ]

    ae.fit(
        X, X,
        validation_split=VAL_SPLIT,
        epochs=EPOCHS,
        batch_size=BATCH_SIZE,
        callbacks=callbacks,
        verbose=1
    )

    print("[STEP] Save encoder + scaler + flag")
    encoder.save(ENCODER_PATH)
    np.savez(SCALER_PATH, median=med, iqr=iqr)
    FLAG_PATH.write_text("trained_once=true\n")

    print("[DONE]")
    print(f"  Encoder: {ENCODER_PATH}")
    print(f"  Scaler : {SCALER_PATH}")
    print(f"  Flag   : {FLAG_PATH}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="Retrain even if trained_once.flag exists")
    args = parser.parse_args()
    main(force=args.force)