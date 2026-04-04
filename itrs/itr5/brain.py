# brain.py
# Python 3.10+
# pip install numpy pandas scikit-learn torch

import os
import random
from dataclasses import dataclass
from typing import Tuple, Optional, Dict

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader

# ============================================================
# 0) Reproducibility + Device
# ============================================================
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# ============================================================
# 1) Config
# ============================================================
@dataclass
class Config:
    # NEW: single merged CSV path
    csv_path: str = "./data/all_data.csv"

    # Segmentation (for fragmented chunks)
    max_gap_sec_for_same_segment: int = 10

    # Windowing
    window_seconds: int = 300   # 5 min
    stride_seconds: int = 60    # 1 min

    # Model
    n_classes: int = 6
    input_dim: int = 3
    hidden_dim: int = 64
    num_layers: int = 1
    dropout: float = 0.2

    # Training
    batch_size: int = 64
    lr: float = 1e-3
    weight_decay: float = 1e-5
    pretrain_epochs: int = 6
    finetune_epochs: int = 3

    # Active learning
    initial_label_fraction: float = 0.10
    active_rounds: int = 8
    query_size_per_round: int = 40
    max_user_labels: int = 500
    uncertainty_threshold: float = 0.55

    # Fusion
    alpha_start: float = 0.35
    alpha_end: float = 0.85


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
# 2) Load merged CSV
# ============================================================
def load_merged_csv(csv_path: str) -> pd.DataFrame:
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"CSV not found: {os.path.abspath(csv_path)}")

    df = pd.read_csv(csv_path)

    required = {"timestamp", "hr"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"CSV missing required columns: {missing}")

    # Optional columns
    if "hrv" not in df.columns:
        df["hrv"] = np.nan
    if "br" not in df.columns:
        df["br"] = np.nan

    # Parse types
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df["hr"] = pd.to_numeric(df["hr"], errors="coerce")
    df["hrv"] = pd.to_numeric(df["hrv"], errors="coerce")
    df["br"] = pd.to_numeric(df["br"], errors="coerce")

    # Basic cleaning
    df = df.dropna(subset=["timestamp", "hr"]).copy()
    df.loc[(df["hr"] < 30) | (df["hr"] > 220), "hr"] = np.nan
    df.loc[(df["hrv"] < 1) | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"] < 4) | (df["br"] > 60), "br"] = np.nan
    df = df.dropna(subset=["hr"]).copy()

    df = df.sort_values("timestamp").reset_index(drop=True)
    return df

# ============================================================
# 3) Derive missing HRV / BR if needed
# ============================================================
def derive_hrv_br_if_missing(df: pd.DataFrame) -> pd.DataFrame:
    d = df.copy().sort_values("timestamp").reset_index(drop=True)

    # Build regular 1-second grid
    d = d.set_index("timestamp").resample("1s").mean(numeric_only=True)

    # HR interpolation for short holes
    d["hr"] = d["hr"].interpolate(limit=10, limit_direction="both")

    # Estimate HRV if mostly missing
    if d["hrv"].isna().mean() > 0.5:
        hr_std_60 = d["hr"].rolling(window=60, min_periods=10).std()
        est_hrv = (hr_std_60 * 12.0).clip(5, 120)
        d["hrv"] = d["hrv"].fillna(est_hrv)

    # Estimate BR if mostly missing
    if d["br"].isna().mean() > 0.5:
        hr_smooth = d["hr"].rolling(window=30, min_periods=5).mean()
        hr_min = hr_smooth.quantile(0.05)
        hr_max = hr_smooth.quantile(0.95)
        denom = max(1e-6, hr_max - hr_min)
        br_est = 10 + (hr_smooth - hr_min) * (10 / denom)  # ~10..20 rpm
        br_est = br_est.clip(8, 24)
        d["br"] = d["br"].fillna(br_est)

    d["hrv"] = d["hrv"].interpolate(limit=20, limit_direction="both")
    d["br"] = d["br"].interpolate(limit=20, limit_direction="both")

    d = d.dropna(subset=["hr", "hrv", "br"]).copy()
    d = d.reset_index()
    return d

# ============================================================
# 4) Segment fragmented chunks by large time gaps
# ============================================================
def add_segment_ids(df: pd.DataFrame, max_gap_sec: int) -> pd.DataFrame:
    d = df.sort_values("timestamp").reset_index(drop=True).copy()
    dt = d["timestamp"].diff().dt.total_seconds().fillna(0)
    d["segment_id"] = (dt > max_gap_sec).cumsum()
    return d

# ============================================================
# 5) Your mathematical rule logic
# ============================================================
def compute_deltas(x_hr: np.ndarray, x_hrv: np.ndarray) -> Tuple[float, float]:
    mid = len(x_hr) // 2
    hr_first = float(np.mean(x_hr[:mid]))
    hr_second = float(np.mean(x_hr[mid:]))
    hrv_first = float(np.mean(x_hrv[:mid]))
    hrv_second = float(np.mean(x_hrv[mid:]))

    hr_delta = (hr_second - hr_first) / (abs(hr_first) + 1e-6)
    hrv_delta = (hrv_second - hrv_first) / (abs(hrv_first) + 1e-6)
    return hr_delta, hrv_delta


def rule_classifier_window(x_hr: np.ndarray, x_hrv: np.ndarray, x_br: np.ndarray) -> Tuple[int, float]:
    hr_delta, hrv_delta = compute_deltas(x_hr, x_hrv)

    if hrv_delta > 0.30:
        ext_state = 6  # Intervention Needed
    elif hr_delta > 0.15 and hrv_delta < -0.20:
        ext_state = 2  # Panic / Procrastination
    elif 0.05 < hr_delta <= 0.15 and hrv_delta <= -0.15:
        ext_state = 5  # Rigid Hyperfocus
    elif 0.02 < hr_delta <= 0.10 and hrv_delta >= -0.10:
        ext_state = 3  # Meaningful Focus
    elif hr_delta <= 0.02 and hrv_delta > 0.05:
        ext_state = 4  # Inattention / Wandering
    else:
        ext_state = 1  # Baseline / Sleep

    pred_idx = ext_state - 1  # convert 1..6 -> 0..5

    conf = 0.60
    conf += min(0.20, abs(hr_delta) * 0.5)
    conf += min(0.20, abs(hrv_delta) * 0.5)
    conf = float(np.clip(conf, 0.50, 0.95))
    return pred_idx, conf

# ============================================================
# 6) Window creation
# ============================================================
def make_windows_from_segments(df: pd.DataFrame, cfg: Config):
    win = cfg.window_seconds
    stride = cfg.stride_seconds

    X_list, y_rule, y_rule_conf, meta = [], [], [], []

    for seg_id, g in df.groupby("segment_id"):
        g = g.sort_values("timestamp").reset_index(drop=True)
        if len(g) < win:
            continue

        hr = g["hr"].values.astype(np.float32)
        hrv = g["hrv"].values.astype(np.float32)
        br = g["br"].values.astype(np.float32)
        ts = g["timestamp"].values

        for s in range(0, len(g) - win + 1, stride):
            e = s + win
            x_hr = hr[s:e]
            x_hrv = hrv[s:e]
            x_br = br[s:e]

            seq = np.stack([x_hr, x_hrv, x_br], axis=-1)
            r, conf = rule_classifier_window(x_hr, x_hrv, x_br)

            X_list.append(seq)
            y_rule.append(r)
            y_rule_conf.append(conf)
            meta.append({
                "segment_id": int(seg_id),
                "start_time": pd.Timestamp(ts[s]),
                "end_time": pd.Timestamp(ts[e - 1]),
            })

    if not X_list:
        raise ValueError("No windows created. Reduce window_seconds or check data continuity.")

    X_raw = np.array(X_list, dtype=np.float32)
    y_rule = np.array(y_rule, dtype=np.int64)
    y_rule_conf = np.array(y_rule_conf, dtype=np.float32)
    return X_raw, y_rule, y_rule_conf, meta

# ============================================================
# 7) Train-only robust scaling (no leakage)
# ============================================================
def fit_robust_scaler(X_train_raw: np.ndarray) -> Dict[str, np.ndarray]:
    C = X_train_raw.shape[2]
    med = np.zeros(C, dtype=np.float32)
    iqr = np.ones(C, dtype=np.float32)
    for ch in range(C):
        vals = X_train_raw[:, :, ch].reshape(-1)
        m = np.median(vals)
        q1 = np.percentile(vals, 25)
        q3 = np.percentile(vals, 75)
        s = q3 - q1
        if s < 1e-6:
            s = 1.0
        med[ch] = float(m)
        iqr[ch] = float(s)
    return {"median": med, "iqr": iqr}


def transform_robust_scaler(X_raw: np.ndarray, scaler: Dict[str, np.ndarray]) -> np.ndarray:
    X = X_raw.copy()
    for ch in range(X.shape[2]):
        X[:, :, ch] = (X[:, :, ch] - scaler["median"][ch]) / scaler["iqr"][ch]
    return X

# ============================================================
# 8) Dataset + model
# ============================================================
class SeqDataset(Dataset):
    def __init__(self, X: np.ndarray, y: np.ndarray, w: Optional[np.ndarray] = None):
        self.X = torch.tensor(X, dtype=torch.float32)
        self.y = torch.tensor(y, dtype=torch.long)
        self.w = None if w is None else torch.tensor(w, dtype=torch.float32)

    def __len__(self):
        return len(self.X)

    def __getitem__(self, i):
        if self.w is None:
            return self.X[i], self.y[i]
        return self.X[i], self.y[i], self.w[i]


class LSTMClassifier(nn.Module):
    def __init__(self, input_dim=3, hidden_dim=64, num_layers=1, n_classes=6, dropout=0.2):
        super().__init__()
        self.lstm = nn.LSTM(
            input_size=input_dim,
            hidden_size=hidden_dim,
            num_layers=num_layers,
            batch_first=True,
            dropout=dropout if num_layers > 1 else 0.0,
        )
        self.drop = nn.Dropout(dropout)
        self.fc = nn.Linear(hidden_dim, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)
        h_last = out[:, -1, :]
        return self.fc(self.drop(h_last))

# ============================================================
# 9) Train/inference helpers
# ============================================================
def train_epoch(model, loader, optimizer, criterion, weighted=False):
    model.train()
    total, n = 0.0, 0
    for batch in loader:
        optimizer.zero_grad()
        if weighted:
            xb, yb, wb = batch
            xb, yb, wb = xb.to(DEVICE), yb.to(DEVICE), wb.to(DEVICE)
            logits = model(xb)
            ce = nn.functional.cross_entropy(logits, yb, reduction="none")
            loss = (ce * wb).mean()
        else:
            xb, yb = batch
            xb, yb = xb.to(DEVICE), yb.to(DEVICE)
            logits = model(xb)
            loss = criterion(logits, yb)

        loss.backward()
        optimizer.step()

        bs = xb.size(0)
        total += float(loss.item()) * bs
        n += bs
    return total / max(1, n)


@torch.no_grad()
def predict_proba(model, X: np.ndarray, batch_size=256) -> np.ndarray:
    model.eval()
    ds = SeqDataset(X, np.zeros(len(X), dtype=np.int64))
    dl = DataLoader(ds, batch_size=batch_size, shuffle=False)
    out = []
    for xb, _ in dl:
        xb = xb.to(DEVICE)
        p = torch.softmax(model(xb), dim=-1).cpu().numpy()
        out.append(p)
    return np.vstack(out)


def entropy_from_probs(p: np.ndarray, eps=1e-9):
    return -np.sum(p * np.log(p + eps), axis=1)


def select_queries_active(probs_unl, y_rule_unl, idx_unl, query_k, uncertainty_threshold):
    yhat = probs_unl.argmax(axis=1)
    maxp = probs_unl.max(axis=1)
    ent = entropy_from_probs(probs_unl)

    uncertain = (maxp < uncertainty_threshold)
    disagree = (yhat != y_rule_unl)

    score = ent + 0.40 * uncertain.astype(np.float32) + 0.35 * disagree.astype(np.float32)
    chosen_local = np.argsort(-score)[:query_k]
    return idx_unl[chosen_local]


def fusion_predict(probs_model, y_rule, conf_rule, alpha):
    n, c = probs_model.shape
    probs_rule = np.zeros((n, c), dtype=np.float32)
    probs_rule[np.arange(n), y_rule] = conf_rule
    rem = 1.0 - conf_rule
    probs_rule += rem[:, None] / c
    probs = alpha * probs_model + (1 - alpha) * probs_rule
    return probs.argmax(axis=1)

# ============================================================
# 10) Main
# ============================================================
def main():
    print("Device:", DEVICE)
    print("Reading CSV:", os.path.abspath(CFG.csv_path))

    # A) Load merged CSV
    df_raw = load_merged_csv(CFG.csv_path)
    print("Rows loaded:", len(df_raw))

    # B) Fill missing channels + resample
    df_filled = derive_hrv_br_if_missing(df_raw)
    print("Rows after fill/resample:", len(df_filled))

    # C) Segment fragmented data
    df_seg = add_segment_ids(df_filled, CFG.max_gap_sec_for_same_segment)
    print("Segments:", df_seg["segment_id"].nunique())

    # D) Windowing + rule labels
    X_raw, y_rule, y_rule_conf, meta = make_windows_from_segments(df_seg, CFG)
    n = len(X_raw)
    print("Windows created:", n)

    # E) Split
    idx_all = np.arange(n)
    idx_train, idx_test = train_test_split(idx_all, test_size=0.2, random_state=SEED)

    # F) Train-only normalization
    scaler = fit_robust_scaler(X_raw[idx_train])
    X = transform_robust_scaler(X_raw, scaler)

    # G) Active-learning pools
    idx_pool = idx_train.copy()
    np.random.shuffle(idx_pool)
    init_k = max(10, int(len(idx_pool) * CFG.initial_label_fraction))
    idx_labeled = idx_pool[:init_k].copy()
    idx_unlabeled = idx_pool[init_k:].copy()

    # Placeholder user labels (replace with real app labels)
    y_user = -1 * np.ones(n, dtype=np.int64)
    y_user[idx_labeled] = y_rule[idx_labeled]  # bootstrap

    # H) Model
    model = LSTMClassifier(
        input_dim=CFG.input_dim,
        hidden_dim=CFG.hidden_dim,
        num_layers=CFG.num_layers,
        n_classes=CFG.n_classes,
        dropout=CFG.dropout,
    ).to(DEVICE)

    optimizer = optim.Adam(model.parameters(), lr=CFG.lr, weight_decay=CFG.weight_decay)
    criterion = nn.CrossEntropyLoss()

    # I) Weak pretraining on rules
    print("\nPretraining on rule labels...")
    w_rule = 0.25 + 0.75 * y_rule_conf[idx_train]
    ds_pre = SeqDataset(X[idx_train], y_rule[idx_train], w_rule)
    dl_pre = DataLoader(ds_pre, batch_size=CFG.batch_size, shuffle=True)

    for ep in range(CFG.pretrain_epochs):
        loss = train_epoch(model, dl_pre, optimizer, criterion, weighted=True)
        print(f"  pretrain {ep+1}/{CFG.pretrain_epochs} loss={loss:.4f}")

    # J) Active learning rounds (placeholder label source)
    print("\nActive learning rounds...")
    for r in range(CFG.active_rounds):
        tr_idx = idx_labeled[y_user[idx_labeled] >= 0]
        if len(tr_idx) == 0:
            break

        ds_gold = SeqDataset(X[tr_idx], y_user[tr_idx])
        dl_gold = DataLoader(ds_gold, batch_size=CFG.batch_size, shuffle=True)

        for _ in range(CFG.finetune_epochs):
            _ = train_epoch(model, dl_gold, optimizer, criterion, weighted=False)

        if len(idx_unlabeled) == 0 or len(idx_labeled) >= CFG.max_user_labels:
            break

        probs_unl = predict_proba(model, X[idx_unlabeled])
        ask_idx = select_queries_active(
            probs_unl, y_rule[idx_unlabeled], idx_unlabeled,
            query_k=min(CFG.query_size_per_round, len(idx_unlabeled)),
            uncertainty_threshold=CFG.uncertainty_threshold
        )

        # TODO: replace with real user labels from UI
        y_user[ask_idx] = y_rule[ask_idx]

        keep = ~np.isin(idx_unlabeled, ask_idx)
        idx_unlabeled = idx_unlabeled[keep]
        idx_labeled = np.concatenate([idx_labeled, ask_idx])

        print(f"Round {r+1}/{CFG.active_rounds} | labeled={len(idx_labeled)}")

    # K) Final inference summary
    probs_test = predict_proba(model, X[idx_test])
    yhat_model = probs_test.argmax(axis=1)

    frac_labeled = len(idx_labeled) / max(1, len(idx_train))
    alpha = CFG.alpha_start + (CFG.alpha_end - CFG.alpha_start) * frac_labeled
    alpha = float(np.clip(alpha, 0.0, 1.0))
    yhat_fused = fusion_predict(probs_test, y_rule[idx_test], y_rule_conf[idx_test], alpha)

    print("\nPrediction distribution (model-only):")
    vals, cnt = np.unique(yhat_model, return_counts=True)
    for v, c in zip(vals, cnt):
        print(f"  {STATE_NAMES[v]}: {c}")

    print("\nPrediction distribution (fused):")
    vals, cnt = np.unique(yhat_fused, return_counts=True)
    for v, c in zip(vals, cnt):
        print(f"  {STATE_NAMES[v]}: {c}")

    print("\nSample prompt windows:")
    for i in range(min(5, len(meta))):
        print(f"  {meta[i]['start_time']} -> {meta[i]['end_time']}")

    print("\nDone.")


if __name__ == "__main__":
    main()