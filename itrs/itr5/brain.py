# active_learning_real_txt_pipeline.py
# Python 3.10+
# pip install numpy pandas scikit-learn torch

import os
import glob
import random
from dataclasses import dataclass
from typing import Tuple, Optional, Dict, List

import numpy as np
import pandas as pd
from sklearn.metrics import classification_report, f1_score, accuracy_score
from sklearn.model_selection import train_test_split
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader

# ----------------------------
# 0) Reproducibility
# ----------------------------
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# ----------------------------
# 1) Config
# ----------------------------

@dataclass
class Config:
    # I/O
    data_folder: str = "./data_txt"      # folder containing txt files
    file_pattern: str = "*.txt"

    # Sampling and segmentation
    expected_sample_sec: int = 1
    max_gap_sec_for_same_segment: int = 10  # if gap > this => new segment

    # Windowing
    window_seconds: int = 300   # 5 min
    stride_seconds: int = 60    # 1 min stride

    # Classes
    n_classes: int = 6

    # Model
    input_dim: int = 3
    hidden_dim: int = 64
    num_layers: int = 1
    dropout: float = 0.2

    # Training
    batch_size: int = 64
    lr: float = 1e-3
    weight_decay: float = 1e-5
    pretrain_epochs: int = 8
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

# ----------------------------
# 2) Parsing real TXT files
# ----------------------------

def normalize_col_name(c: str) -> str:
    c = c.strip().lower()
    c = c.replace("(", "").replace(")", "")
    c = c.replace("[", "").replace("]", "")
    c = c.replace(",", " ").replace(";", " ")
    c = " ".join(c.split())
    return c


def map_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Map flexible input columns to: timestamp, hr, hrv, br
    """
    original_cols = list(df.columns)
    norm_cols = [normalize_col_name(c) for c in original_cols]
    col_map = dict(zip(original_cols, norm_cols))
    df = df.rename(columns=col_map)

    # Candidate names
    time_candidates = {"time", "timestamp", "datetime", "date time"}
    hr_candidates = {"heart rate bpm", "heart rate", "hr", "bpm"}
    hrv_candidates = {"hrv ms", "hrv", "rmssd", "sdnn"}
    br_candidates = {"breathing rate rpm", "breathing rate", "br", "respiratory rate", "respiration rate"}

    def find_col(cands):
        for c in df.columns:
            if c in cands:
                return c
        return None

    c_time = find_col(time_candidates)
    c_hr = find_col(hr_candidates)
    c_hrv = find_col(hrv_candidates)
    c_br = find_col(br_candidates)

    # If header missing and we got numeric columns only, try positional fallback
    if c_time is None and len(df.columns) >= 2:
        # assume first col is time-ish
        c_time = df.columns[0]
    if c_hr is None and len(df.columns) >= 2:
        c_hr = df.columns[1]
    if c_hrv is None and len(df.columns) >= 3:
        c_hrv = df.columns[2]
    if c_br is None and len(df.columns) >= 4:
        c_br = df.columns[3]

    out = pd.DataFrame()
    out["timestamp"] = df[c_time] if c_time in df.columns else pd.NaT
    out["hr"] = df[c_hr] if c_hr in df.columns else np.nan
    out["hrv"] = df[c_hrv] if c_hrv in df.columns else np.nan
    out["br"] = df[c_br] if c_br in df.columns else np.nan
    return out


def read_one_txt(path: str) -> pd.DataFrame:
    """
    Robust TXT reader for ; or , separated files, with or without headers.
    """
    # Try with header infer
    for sep in [";", ",", r"\s+"]:
        try:
            df = pd.read_csv(path, sep=sep, engine="python")
            if df.shape[1] >= 2:
                mapped = map_columns(df)
                return mapped
        except Exception:
            pass

    # Try headerless fallback
    for sep in [";", ",", r"\s+"]:
        try:
            df = pd.read_csv(path, sep=sep, header=None, engine="python")
            if df.shape[1] >= 2:
                # assign generic names for mapping fallback
                cols = [f"col{i}" for i in range(df.shape[1])]
                df.columns = cols
                mapped = map_columns(df)
                return mapped
        except Exception:
            pass

    raise ValueError(f"Could not parse file: {path}")


def load_txt_folder(data_folder: str, pattern: str = "*.txt") -> pd.DataFrame:
    files = sorted(glob.glob(os.path.join(data_folder, pattern)))
    if not files:
        raise FileNotFoundError(f"No files found in {data_folder} matching {pattern}")

    chunks = []
    for f in files:
        dfi = read_one_txt(f)
        dfi["source_file"] = os.path.basename(f)
        chunks.append(dfi)

    df = pd.concat(chunks, ignore_index=True)

    # parse timestamps
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce", utc=False)
    # parse numeric
    for c in ["hr", "hrv", "br"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")

    # clean
    df = df.dropna(subset=["timestamp"])
    df = df.sort_values("timestamp").reset_index(drop=True)

    # physiological range filters
    df.loc[(df["hr"] < 30) | (df["hr"] > 220), "hr"] = np.nan
    df.loc[(df["hrv"] < 1) | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"] < 4) | (df["br"] > 60), "br"] = np.nan

    # keep rows where at least HR exists; HRV/BR may be missing
    df = df.dropna(subset=["hr"]).copy()

    return df


# ----------------------------
# 3) Resample to 1s + interpolate missing hrv/br
# ----------------------------

def resample_to_1s(df: pd.DataFrame) -> pd.DataFrame:
    df = df.set_index("timestamp").sort_index()
    # Aggregate duplicates per second
    df = df.resample("1s").mean(numeric_only=True)
    # Interpolate short gaps in channels
    df["hr"] = df["hr"].interpolate(limit=5, limit_direction="both")
    df["hrv"] = df["hrv"].interpolate(limit=10, limit_direction="both")
    df["br"] = df["br"].interpolate(limit=10, limit_direction="both")
    df = df.reset_index()
    return df


# ----------------------------
# 4) Segment by big time gaps
# ----------------------------

def add_segment_ids(df: pd.DataFrame, max_gap_sec: int) -> pd.DataFrame:
    df = df.sort_values("timestamp").reset_index(drop=True)
    dt = df["timestamp"].diff().dt.total_seconds().fillna(0)
    new_seg = (dt > max_gap_sec).astype(int)
    df["segment_id"] = new_seg.cumsum()
    return df


# ----------------------------
# 5) Your rule logic
# ----------------------------

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

    conf = 0.60
    conf += min(0.20, abs(hr_delta) * 0.5)
    conf += min(0.20, abs(hrv_delta) * 0.5)
    conf = float(np.clip(conf, 0.50, 0.95))
    return pred_idx, conf


# ----------------------------
# 6) Build windows from segments
# ----------------------------

def make_windows_from_segments(df: pd.DataFrame, cfg: Config):
    win = cfg.window_seconds
    stride = cfg.stride_seconds

    X_list, y_rule, y_rule_conf, meta = [], [], [], []

    for seg_id, g in df.groupby("segment_id"):
        g = g.sort_values("timestamp").reset_index(drop=True)

        # ensure required channels exist
        # for strict mode, require all channels non-null
        g2 = g.dropna(subset=["hr", "hrv", "br"]).copy()
        if len(g2) < win:
            continue

        hr = g2["hr"].values.astype(np.float32)
        hrv = g2["hrv"].values.astype(np.float32)
        br = g2["br"].values.astype(np.float32)
        ts = g2["timestamp"].values

        for s in range(0, len(g2) - win + 1, stride):
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
                "end_time": pd.Timestamp(ts[e - 1])
            })

    if not X_list:
        raise ValueError("No windows created. Check data quality, channels, and segment lengths.")

    X_raw = np.array(X_list, dtype=np.float32)
    y_rule = np.array(y_rule, dtype=np.int64)
    y_rule_conf = np.array(y_rule_conf, dtype=np.float32)

    return X_raw, y_rule, y_rule_conf, meta


# ----------------------------
# 7) Train-only robust scaler
# ----------------------------

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
    med, iqr = scaler["median"], scaler["iqr"]
    for ch in range(X.shape[2]):
        X[:, :, ch] = (X[:, :, ch] - med[ch]) / iqr[ch]
    return X


# ----------------------------
# 8) Dataset, model, train/eval
# ----------------------------

class SeqDataset(Dataset):
    def __init__(self, X: np.ndarray, y: np.ndarray, w: Optional[np.ndarray] = None):
        self.X = torch.tensor(X, dtype=torch.float32)
        self.y = torch.tensor(y, dtype=torch.long)
        self.w = None if w is None else torch.tensor(w, dtype=torch.float32)

    def __len__(self): return len(self.X)

    def __getitem__(self, i):
        if self.w is None:
            return self.X[i], self.y[i]
        return self.X[i], self.y[i], self.w[i]


class LSTMClassifier(nn.Module):
    def __init__(self, input_dim=3, hidden_dim=64, num_layers=1, n_classes=6, dropout=0.2):
        super().__init__()
        self.lstm = nn.LSTM(input_dim, hidden_dim, num_layers=num_layers, batch_first=True,
                            dropout=dropout if num_layers > 1 else 0.0)
        self.drop = nn.Dropout(dropout)
        self.fc = nn.Linear(hidden_dim, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)
        h = out[:, -1, :]
        return self.fc(self.drop(h))


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
    p = alpha * probs_model + (1 - alpha) * probs_rule
    return p.argmax(axis=1)


# ----------------------------
# 9) Main with pseudo-user labels
# ----------------------------

def main():
    print("Device:", DEVICE)

    # A) Load real txt
    df_raw = load_txt_folder(CFG.data_folder, CFG.file_pattern)
    print("Rows loaded:", len(df_raw))

    # B) Resample and segment
    df_1s = resample_to_1s(df_raw)
    df_seg = add_segment_ids(df_1s, max_gap_sec=CFG.max_gap_sec_for_same_segment)

    # C) Window creation
    X_raw, y_rule, y_rule_conf, meta = make_windows_from_segments(df_seg, CFG)
    n = len(X_raw)
    print("Windows created:", n)

    # NOTE:
    # You do not have true labels yet. In production, y_user comes from app UI.
    # For code continuity, we initialize y_user unknown and active learning will query.
    y_user = -1 * np.ones(n, dtype=np.int64)

    # D) Split
    idx_all = np.arange(n)
    idx_train, idx_test = train_test_split(idx_all, test_size=0.2, random_state=SEED)

    # E) Fit scaler on train only
    scaler = fit_robust_scaler(X_raw[idx_train])
    X = transform_robust_scaler(X_raw, scaler)

    # F) Pools
    idx_pool = idx_train.copy()
    np.random.shuffle(idx_pool)
    init_k = max(10, int(len(idx_pool) * CFG.initial_label_fraction))
    idx_labeled = idx_pool[:init_k].copy()      # would be prompted first in real app
    idx_unlabeled = idx_pool[init_k:].copy()

    # For demo only: bootstrap initial labels from rule (until user labels are collected)
    y_user[idx_labeled] = y_rule[idx_labeled]

    # G) Model
    model = LSTMClassifier(
        input_dim=CFG.input_dim,
        hidden_dim=CFG.hidden_dim,
        num_layers=CFG.num_layers,
        n_classes=CFG.n_classes,
        dropout=CFG.dropout
    ).to(DEVICE)

    optimizer = optim.Adam(model.parameters(), lr=CFG.lr, weight_decay=CFG.weight_decay)
    criterion = nn.CrossEntropyLoss()

    # H) Weak pretrain
    print("\nPretraining on rule labels...")
    w_rule = 0.25 + 0.75 * y_rule_conf[idx_train]
    ds_pre = SeqDataset(X[idx_train], y_rule[idx_train], w_rule)
    dl_pre = DataLoader(ds_pre, batch_size=CFG.batch_size, shuffle=True)
    for ep in range(CFG.pretrain_epochs):
        loss = train_epoch(model, dl_pre, optimizer, criterion, weighted=True)
        if (ep + 1) % 2 == 0:
            print(f"  pretrain {ep+1}/{CFG.pretrain_epochs} loss={loss:.4f}")

    # I) Active loop (with pseudo user labels fallback)
    print("\nActive learning rounds...")
    for r in range(CFG.active_rounds):
        # Train on current labeled
        tr_idx = idx_labeled[y_user[idx_labeled] >= 0]
        if len(tr_idx) == 0:
            break

        ds_gold = SeqDataset(X[tr_idx], y_user[tr_idx])
        dl_gold = DataLoader(ds_gold, batch_size=CFG.batch_size, shuffle=True)

        for _ in range(CFG.finetune_epochs):
            _ = train_epoch(model, dl_gold, optimizer, criterion, weighted=False)

        # Choose queries
        if len(idx_unlabeled) == 0 or len(idx_labeled) >= CFG.max_user_labels:
            break

        probs_unl = predict_proba(model, X[idx_unlabeled])
        ask_idx = select_queries_active(
            probs_unl, y_rule[idx_unlabeled], idx_unlabeled,
            query_k=min(CFG.query_size_per_round, len(idx_unlabeled)),
            uncertainty_threshold=CFG.uncertainty_threshold
        )

        # In real app:
        #   show meta[ask_idx] time ranges and collect user state tap
        # Here fallback to rule as placeholder label:
        y_user[ask_idx] = y_rule[ask_idx]

        keep = ~np.isin(idx_unlabeled, ask_idx)
        idx_unlabeled = idx_unlabeled[keep]
        idx_labeled = np.concatenate([idx_labeled, ask_idx])

        print(f"Round {r+1}: labeled={len(idx_labeled)}")

    # J) Inference summary on test split (no ground-truth metrics available)
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

    print("\nDone. Next step: replace pseudo labels with real user labels from UI.")


if __name__ == "__main__":
    main()