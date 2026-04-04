# active_learning_lstm_hr_hrv_br_v2.py
# Python 3.10+
# pip install numpy pandas scikit-learn torch

import random
from dataclasses import dataclass
from typing import Tuple, Optional

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
    # Data simulation
    total_minutes: int = 24 * 60
    sample_period_sec: int = 5  # one sample every 5 seconds
    n_classes: int = 6          # <-- updated to 6 classes

    # Windowing
    window_minutes: int = 5
    stride_minutes: int = 1

    # Model
    input_dim: int = 3  # HR, HRV, BR
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

# Internal class indices: 0..5
# External states in your rule: 1..6
STATE_NAMES = {
    0: "Baseline / Sleep",          # ext 1
    1: "Panic / Procrastination",   # ext 2
    2: "Meaningful Focus",          # ext 3
    3: "Inattention / Wandering",   # ext 4
    4: "Rigid Hyperfocus",          # ext 5
    5: "Intervention Needed",       # ext 6
}


# ----------------------------
# 2) Synthetic data generator (for demo/testing)
#    Replace with real sensor ingestion in production.
# ----------------------------

def simulate_day_dataframe(cfg: Config) -> pd.DataFrame:
    n = int((cfg.total_minutes * 60) / cfg.sample_period_sec)
    times = pd.date_range("2026-01-01", periods=n, freq=f"{cfg.sample_period_sec}s")

    # Hidden synthetic states (internal 0..5)
    # This is only to simulate "ground-truth" for demo.
    states = np.zeros(n, dtype=int)
    current = 0
    i = 0
    probs = np.array([0.28, 0.15, 0.20, 0.15, 0.12, 0.10])  # class priors
    while i < n:
        seg_len = np.random.randint(60, 360)  # 5 to 30 min in 5-sec samples
        if np.random.rand() < 0.40:
            current = int(np.random.choice(cfg.n_classes, p=probs))
        states[i:i + seg_len] = current
        i += seg_len
    states = states[:n]

    # Means per class (synthetic)
    # [Baseline, Panic, Meaningful, Wandering, Hyperfocus, Intervention]
    hr_means  = [62, 95, 78, 70, 86, 100]
    hrv_means = [58, 24, 40, 52, 30, 70]
    br_means  = [12, 20, 15, 13, 17, 11]

    hr = np.zeros(n, dtype=np.float32)
    hrv = np.zeros(n, dtype=np.float32)
    br = np.zeros(n, dtype=np.float32)

    t = np.arange(n) * cfg.sample_period_sec / 3600.0
    circadian = 3.0 * np.sin(2 * np.pi * t / 24.0 - 1.2)

    for k in range(n):
        s = states[k]
        hr[k] = hr_means[s] + circadian[k] + np.random.normal(0, 3.0)
        hrv[k] = hrv_means[s] - 0.5 * circadian[k] + np.random.normal(0, 4.0)
        br[k] = br_means[s] + 0.15 * circadian[k] + np.random.normal(0, 1.5)

    hr = np.clip(hr, 40, 190)
    hrv = np.clip(hrv, 5, 120)
    br = np.clip(br, 6, 40)

    return pd.DataFrame({
        "timestamp": times,
        "hr": hr,
        "hrv": hrv,
        "br": br,
        "true_state": states
    })


# ----------------------------
# 3) Your mathematical logic
# ----------------------------

def compute_deltas(x_hr: np.ndarray, x_hrv: np.ndarray) -> Tuple[float, float]:
    """
    Compute hr_delta and hrv_delta for a window.
    Definition used here:
      delta = (second_half_mean - first_half_mean) / (abs(first_half_mean) + 1e-6)

    If your research defines delta differently (e.g., baseline-referenced),
    replace this function only.
    """
    mid = len(x_hr) // 2

    hr_first = float(np.mean(x_hr[:mid]))
    hr_second = float(np.mean(x_hr[mid:]))

    hrv_first = float(np.mean(x_hrv[:mid]))
    hrv_second = float(np.mean(x_hrv[mid:]))

    hr_delta = (hr_second - hr_first) / (abs(hr_first) + 1e-6)
    hrv_delta = (hrv_second - hrv_first) / (abs(hrv_first) + 1e-6)

    return hr_delta, hrv_delta


def rule_classifier_window(x_hr: np.ndarray, x_hrv: np.ndarray, x_br: np.ndarray) -> Tuple[int, float]:
    """
    Implements your exact logic:
        if hrv_delta > 0.30: state=6
        elif hr_delta > 0.15 and hrv_delta < -0.20: state=2
        elif 0.05 < hr_delta <= 0.15 and hrv_delta <= -0.15: state=5
        elif 0.02 < hr_delta <= 0.10 and hrv_delta >= -0.10: state=3
        elif hr_delta <= 0.02 and hrv_delta > 0.05: state=4
        else: state=1

    Returns:
      - internal class index 0..5 (PyTorch compatible)
      - confidence 0..1
    """
    hr_delta, hrv_delta = compute_deltas(x_hr, x_hrv)

    # external 1..6
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

    # convert external -> internal index
    pred_idx = ext_state - 1  # 1..6 -> 0..5

    # Optional confidence heuristic
    conf = 0.60
    conf += min(0.20, abs(hr_delta) * 0.5)
    conf += min(0.20, abs(hrv_delta) * 0.5)
    conf = float(np.clip(conf, 0.50, 0.95))

    return pred_idx, conf


# ----------------------------
# 4) Windowing + normalization
# ----------------------------

def robust_scale_per_channel(x: np.ndarray) -> np.ndarray:
    # x shape [N, T, C]
    x_scaled = x.copy()
    c = x.shape[2]
    for ch in range(c):
        vals = x[:, :, ch].reshape(-1)
        med = np.median(vals)
        q1 = np.percentile(vals, 25)
        q3 = np.percentile(vals, 75)
        iqr = q3 - q1
        if iqr < 1e-6:
            iqr = 1.0
        x_scaled[:, :, ch] = (x[:, :, ch] - med) / iqr
    return x_scaled


def make_windows(df: pd.DataFrame, cfg: Config):
    spm = 60 // cfg.sample_period_sec  # samples per minute
    win = cfg.window_minutes * spm
    stride = cfg.stride_minutes * spm

    X_list, y_true, y_rule, y_rule_conf, meta_idx = [], [], [], [], []

    arr_hr = df["hr"].values
    arr_hrv = df["hrv"].values
    arr_br = df["br"].values
    arr_state = df["true_state"].values

    for start in range(0, len(df) - win + 1, stride):
        end = start + win

        x_hr = arr_hr[start:end]
        x_hrv = arr_hrv[start:end]
        x_br = arr_br[start:end]

        seq = np.stack([x_hr, x_hrv, x_br], axis=-1).astype(np.float32)
        X_list.append(seq)

        # true label for this window = majority true state
        y = np.bincount(arr_state[start:end], minlength=cfg.n_classes).argmax()
        y_true.append(int(y))

        r, conf = rule_classifier_window(x_hr, x_hrv, x_br)
        y_rule.append(int(r))
        y_rule_conf.append(float(conf))

        meta_idx.append((start, end))

    X = np.array(X_list, dtype=np.float32)     # [N,T,3]
    y_true = np.array(y_true, dtype=np.int64)  # [N]
    y_rule = np.array(y_rule, dtype=np.int64)  # [N]
    y_rule_conf = np.array(y_rule_conf, dtype=np.float32)

    X = robust_scale_per_channel(X)
    return X, y_true, y_rule, y_rule_conf, meta_idx


# ----------------------------
# 5) Dataset
# ----------------------------

class SeqDataset(Dataset):
    def __init__(self, X: np.ndarray, y: np.ndarray, weights: Optional[np.ndarray] = None):
        self.X = torch.tensor(X, dtype=torch.float32)
        self.y = torch.tensor(y, dtype=torch.long)
        self.w = None if weights is None else torch.tensor(weights, dtype=torch.float32)

    def __len__(self):
        return len(self.X)

    def __getitem__(self, idx):
        if self.w is None:
            return self.X[idx], self.y[idx]
        return self.X[idx], self.y[idx], self.w[idx]


# ----------------------------
# 6) LSTM model
# ----------------------------

class LSTMClassifier(nn.Module):
    def __init__(self, input_dim=3, hidden_dim=64, num_layers=1, n_classes=6, dropout=0.2):
        super().__init__()
        self.lstm = nn.LSTM(
            input_size=input_dim,
            hidden_size=hidden_dim,
            num_layers=num_layers,
            batch_first=True,
            dropout=dropout if num_layers > 1 else 0.0
        )
        self.drop = nn.Dropout(dropout)
        self.fc = nn.Linear(hidden_dim, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)     # [B,T,H]
        h_last = out[:, -1, :]    # [B,H]
        z = self.drop(h_last)
        logits = self.fc(z)       # [B,C]
        return logits


# ----------------------------
# 7) Train/Eval helpers
# ----------------------------

def train_epoch(model, loader, optimizer, criterion, weighted=False):
    model.train()
    total_loss = 0.0
    n = 0

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
        total_loss += float(loss.item()) * bs
        n += bs

    return total_loss / max(1, n)


@torch.no_grad()
def predict_proba(model, X: np.ndarray, batch_size=256):
    model.eval()
    ds = SeqDataset(X, np.zeros(len(X), dtype=np.int64))
    dl = DataLoader(ds, batch_size=batch_size, shuffle=False)
    out = []
    for xb, _ in dl:
        xb = xb.to(DEVICE)
        logits = model(xb)
        p = torch.softmax(logits, dim=-1).cpu().numpy()
        out.append(p)
    return np.vstack(out)


@torch.no_grad()
def evaluate(model, X: np.ndarray, y: np.ndarray, name="Eval"):
    p = predict_proba(model, X)
    yhat = p.argmax(axis=1)
    acc = accuracy_score(y, yhat)
    f1 = f1_score(y, yhat, average="macro")
    print(f"\n[{name}] acc={acc:.4f} macro_f1={f1:.4f}")
    print(classification_report(
        y, yhat,
        target_names=[STATE_NAMES[i] for i in range(CFG.n_classes)],
        digits=3
    ))


def entropy_from_probs(p: np.ndarray, eps=1e-9):
    return -np.sum(p * np.log(p + eps), axis=1)


# ----------------------------
# 8) Active learning query policy
# ----------------------------

def select_queries_active(
    probs_unl: np.ndarray,
    y_rule_unl: np.ndarray,
    idx_unl: np.ndarray,
    query_k: int,
    uncertainty_threshold: float
):
    yhat_unl = probs_unl.argmax(axis=1)
    maxp = probs_unl.max(axis=1)
    ent = entropy_from_probs(probs_unl)

    uncertain = (maxp < uncertainty_threshold)
    disagree = (yhat_unl != y_rule_unl)

    score = ent.copy()
    score += 0.40 * uncertain.astype(np.float32)
    score += 0.35 * disagree.astype(np.float32)

    order = np.argsort(-score)
    chosen_local = order[:query_k]
    return idx_unl[chosen_local]


# ----------------------------
# 9) Fusion of rule + model
# ----------------------------

def fusion_predict(
    probs_model: np.ndarray,
    y_rule: np.ndarray,
    conf_rule: np.ndarray,
    alpha: float
):
    n, c = probs_model.shape

    probs_rule = np.zeros((n, c), dtype=np.float32)
    probs_rule[np.arange(n), y_rule] = conf_rule
    rem = 1.0 - conf_rule
    probs_rule += rem[:, None] / c

    probs = alpha * probs_model + (1.0 - alpha) * probs_rule
    return probs.argmax(axis=1)


# ----------------------------
# 10) Main
# ----------------------------

def main():
    print("Device:", DEVICE)

    # A) Data
    df = simulate_day_dataframe(CFG)

    # B) Windowing
    X, y_true, y_rule, y_rule_conf, meta_idx = make_windows(df, CFG)
    n = len(X)
    print(f"Total windows: {n}, window shape: {X.shape[1:]}")

    # C) Train/test split
    idx_all = np.arange(n)
    idx_train, idx_test = train_test_split(
        idx_all, test_size=0.2, random_state=SEED, stratify=y_true
    )

    idx_pool = idx_train.copy()
    np.random.shuffle(idx_pool)

    init_k = max(20, int(len(idx_pool) * CFG.initial_label_fraction))
    idx_labeled = idx_pool[:init_k].copy()
    idx_unlabeled = idx_pool[init_k:].copy()

    # Simulated user labels (replace with app labels)
    y_user = -1 * np.ones(n, dtype=np.int64)
    y_user[idx_labeled] = y_true[idx_labeled]

    # D) Model
    model = LSTMClassifier(
        input_dim=CFG.input_dim,
        hidden_dim=CFG.hidden_dim,
        num_layers=CFG.num_layers,
        n_classes=CFG.n_classes,
        dropout=CFG.dropout
    ).to(DEVICE)

    optimizer = optim.Adam(model.parameters(), lr=CFG.lr, weight_decay=CFG.weight_decay)
    criterion = nn.CrossEntropyLoss()

    # E) Pretrain on weak rule labels
    print("\nPretraining on rule labels...")
    w_rule = 0.25 + 0.75 * y_rule_conf[idx_train]
    ds_pre = SeqDataset(X[idx_train], y_rule[idx_train], weights=w_rule)
    dl_pre = DataLoader(ds_pre, batch_size=CFG.batch_size, shuffle=True)

    for ep in range(CFG.pretrain_epochs):
        loss = train_epoch(model, dl_pre, optimizer, criterion, weighted=True)
        if (ep + 1) % 2 == 0:
            print(f"  pretrain epoch {ep+1}/{CFG.pretrain_epochs}, loss={loss:.4f}")

    evaluate(model, X[idx_test], y_true[idx_test], name="After Pretrain (Model only)")

    # F) Active learning rounds
    print("\nActive learning...")
    for r in range(CFG.active_rounds):
        # train on user-labeled data
        tr_idx = idx_labeled.copy()
        ds_gold = SeqDataset(X[tr_idx], y_user[tr_idx])
        dl_gold = DataLoader(ds_gold, batch_size=CFG.batch_size, shuffle=True)

        for _ in range(CFG.finetune_epochs):
            _ = train_epoch(model, dl_gold, optimizer, criterion, weighted=False)

        # evaluate
        probs_test = predict_proba(model, X[idx_test])
        yhat_model = probs_test.argmax(axis=1)
        f1_model = f1_score(y_true[idx_test], yhat_model, average="macro")

        frac_labeled = len(idx_labeled) / max(1, len(idx_train))
        alpha = CFG.alpha_start + (CFG.alpha_end - CFG.alpha_start) * frac_labeled
        alpha = float(np.clip(alpha, 0.0, 1.0))

        yhat_fused = fusion_predict(probs_test, y_rule[idx_test], y_rule_conf[idx_test], alpha)
        f1_fused = f1_score(y_true[idx_test], yhat_fused, average="macro")

        print(f"Round {r+1}/{CFG.active_rounds} | labeled={len(idx_labeled)} | model_f1={f1_model:.4f} | fused_f1={f1_fused:.4f} | alpha={alpha:.2f}")

        if len(idx_unlabeled) == 0 or len(idx_labeled) >= CFG.max_user_labels:
            break

        # query selection
        probs_unl = predict_proba(model, X[idx_unlabeled])
        ask_idx = select_queries_active(
            probs_unl=probs_unl,
            y_rule_unl=y_rule[idx_unlabeled],
            idx_unl=idx_unlabeled,
            query_k=min(CFG.query_size_per_round, len(idx_unlabeled)),
            uncertainty_threshold=CFG.uncertainty_threshold
        )

        # simulate user labels (replace with UI labels)
        y_user[ask_idx] = y_true[ask_idx]

        # move asked samples from unlabeled to labeled
        keep_mask = ~np.isin(idx_unlabeled, ask_idx)
        idx_unlabeled = idx_unlabeled[keep_mask]
        idx_labeled = np.concatenate([idx_labeled, ask_idx])

    # G) Final reports
    print("\n=== Final Model-only ===")
    evaluate(model, X[idx_test], y_true[idx_test], name="Final Model-only")

    probs_test = predict_proba(model, X[idx_test])
    frac_labeled = len(idx_labeled) / max(1, len(idx_train))
    alpha = CFG.alpha_start + (CFG.alpha_end - CFG.alpha_start) * frac_labeled
    alpha = float(np.clip(alpha, 0.0, 1.0))
    yhat_fused = fusion_predict(probs_test, y_rule[idx_test], y_rule_conf[idx_test], alpha)

    print("\n=== Final Fused ===")
    print(classification_report(
        y_true[idx_test],
        yhat_fused,
        target_names=[STATE_NAMES[i] for i in range(CFG.n_classes)],
        digits=3
    ))

    print("Done.")


if __name__ == "__main__":
    main()