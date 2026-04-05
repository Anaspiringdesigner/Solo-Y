# brain.py
# Python 3.10+
# pip install numpy pandas scikit-learn torch

import os
import copy
import random
import json
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
    # single merged CSV path
    csv_path: str = "C:/Projects/itrs/itr5/data/all_data.csv"

    # segmentation for fragmented chunks
    max_gap_sec_for_same_segment: int = 10

    # windowing
    window_seconds: int = 120
    stride_seconds: int = 30

    # model
    n_classes: int = 6
    input_dim: int = 3
    hidden_dim: int = 64
    num_layers: int = 1
    dropout: float = 0.2

    # training
    batch_size: int = 64
    lr: float = 1e-3
    weight_decay: float = 1e-5

    pretrain_epochs: int = 1000
    finetune_epochs: int = 1000

    # early stopping
    pretrain_patience: int = 10
    finetune_patience: int = 6
    min_delta: float = 1e-4

    # active learning
    initial_label_fraction: float = 0.10
    active_rounds: int = 8
    query_size_per_round: int = 40
    max_user_labels: int = 500
    uncertainty_threshold: float = 0.55

    # fusion
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
# 2) Diagnostics helpers
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
        pct = 100.0 * c / max(1, total)
        print(f"  {int(v)} ({name}): {c} ({pct:.2f}%)")


def compute_class_weights(y: np.ndarray, n_classes: int) -> torch.Tensor:
    counts = np.bincount(y, minlength=n_classes).astype(np.float32)
    counts = np.maximum(counts, 1.0)
    weights = counts.sum() / counts
    weights = weights / weights.mean()
    return torch.tensor(weights, dtype=torch.float32, device=DEVICE)


# ============================================================
# 3) Load merged CSV
# ============================================================
def load_merged_csv(csv_path: str) -> pd.DataFrame:
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"CSV not found: {os.path.abspath(csv_path)}")

    df = pd.read_csv(csv_path)

    required = {"timestamp", "hr"}
    missing = required - set(df.columns)
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
# 4) Derive missing HRV/BR if needed
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
def compute_deltas(x_hr: np.ndarray, x_hrv: np.ndarray) -> Tuple[float, float]:
    mid       = len(x_hr) // 2
    hr_first  = float(np.mean(x_hr[:mid]))
    hr_second = float(np.mean(x_hr[mid:]))
    hrv_first  = float(np.mean(x_hrv[:mid]))
    hrv_second = float(np.mean(x_hrv[mid:]))
    hr_delta  = (hr_second  - hr_first)  / (abs(hr_first)  + 1e-6)
    hrv_delta = (hrv_second - hrv_first) / (abs(hrv_first) + 1e-6)
    return hr_delta, hrv_delta


def rule_classifier_window(
    x_hr: np.ndarray,
    x_hrv: np.ndarray,
    x_br: np.ndarray,
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
    conf  = 0.60
    conf += min(0.20, abs(hr_delta)  * 0.5)
    conf += min(0.20, abs(hrv_delta) * 0.5)
    conf  = float(np.clip(conf, 0.50, 0.95))
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

            seq  = np.stack([x_hr, x_hrv, x_br], axis=-1)
            r, conf = rule_classifier_window(x_hr, x_hrv, x_br)

            X_list.append(seq)
            y_rule.append(r)
            y_rule_conf.append(conf)
            meta.append({
                "segment_id": int(seg_id),
                "start_time": pd.Timestamp(ts[s]),
                "end_time":   pd.Timestamp(ts[e - 1]),
            })

    if not X_list:
        raise ValueError("No windows created. Reduce window_seconds or inspect continuity.")

    X_raw       = np.array(X_list,      dtype=np.float32)
    y_rule      = np.array(y_rule,      dtype=np.int64)
    y_rule_conf = np.array(y_rule_conf, dtype=np.float32)
    return X_raw, y_rule, y_rule_conf, meta


# ============================================================
# 8) Train-only robust scaling
# ============================================================
def fit_robust_scaler(X_train_raw: np.ndarray) -> Dict[str, np.ndarray]:
    C   = X_train_raw.shape[2]
    med = np.zeros(C, dtype=np.float32)
    iqr = np.ones(C,  dtype=np.float32)
    for ch in range(C):
        vals = X_train_raw[:, :, ch].reshape(-1)
        m    = np.median(vals)
        q1   = np.percentile(vals, 25)
        q3   = np.percentile(vals, 75)
        s    = q3 - q1
        if s < 1e-6:
            s = 1.0
        med[ch] = float(m)
        iqr[ch] = float(s)
    return {"median": med, "iqr": iqr}


def transform_robust_scaler(
    X_raw: np.ndarray,
    scaler: Dict[str, np.ndarray],
) -> np.ndarray:
    X = X_raw.copy()
    for ch in range(X.shape[2]):
        X[:, :, ch] = (X[:, :, ch] - scaler["median"][ch]) / scaler["iqr"][ch]
    return X


# ============================================================
# 9) Dataset + model
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
    def __init__(
        self,
        input_dim=3,
        hidden_dim=64,
        num_layers=1,
        n_classes=6,
        dropout=0.2,
    ):
        super().__init__()
        self.lstm = nn.LSTM(
            input_size=input_dim,
            hidden_size=hidden_dim,
            num_layers=num_layers,
            batch_first=True,
            dropout=dropout if num_layers > 1 else 0.0,
        )
        self.drop = nn.Dropout(dropout)
        self.fc   = nn.Linear(hidden_dim, n_classes)

    def forward(self, x):
        out, _  = self.lstm(x)
        h_last  = out[:, -1, :]
        return self.fc(self.drop(h_last))


# ============================================================
# 10) Train / inference helpers
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
            ce     = nn.functional.cross_entropy(logits, yb, reduction="none")
            loss   = (ce * wb).mean()
        else:
            xb, yb = batch
            xb, yb = xb.to(DEVICE), yb.to(DEVICE)
            logits = model(xb)
            loss   = criterion(logits, yb)

        loss.backward()
        optimizer.step()

        bs     = xb.size(0)
        total += float(loss.item()) * bs
        n     += bs
    return total / max(1, n)


@torch.no_grad()
def eval_loss(model, loader, criterion, weighted=False):
    model.eval()
    total, n = 0.0, 0
    for batch in loader:
        if weighted:
            xb, yb, wb = batch
            xb, yb, wb = xb.to(DEVICE), yb.to(DEVICE), wb.to(DEVICE)
            logits = model(xb)
            ce     = nn.functional.cross_entropy(logits, yb, reduction="none")
            loss   = (ce * wb).mean()
        else:
            xb, yb = batch
            xb, yb = xb.to(DEVICE), yb.to(DEVICE)
            logits = model(xb)
            loss   = criterion(logits, yb)

        bs     = xb.size(0)
        total += float(loss.item()) * bs
        n     += bs
    return total / max(1, n)


def fit_with_early_stopping(
    model,
    train_loader,
    val_loader,
    optimizer,
    criterion,
    max_epochs: int,
    patience: int,
    min_delta: float,
    weighted: bool = False,
    tag: str = "train",
):
    best_val   = float("inf")
    best_state = copy.deepcopy(model.state_dict())
    wait       = 0

    for ep in range(1, max_epochs + 1):
        tr = train_epoch(model, train_loader, optimizer, criterion, weighted=weighted)
        vl = eval_loss(model, val_loader, criterion, weighted=weighted)

        print(f"  [{tag}] epoch {ep}/{max_epochs} | train_loss={tr:.4f} | val_loss={vl:.4f}")

        if vl < (best_val - min_delta):
            best_val   = vl
            best_state = copy.deepcopy(model.state_dict())
            wait       = 0
        else:
            wait += 1
            if wait >= patience:
                print(f"  [{tag}] Early stopping at epoch {ep}. Best val_loss={best_val:.4f}")
                break

    model.load_state_dict(best_state)
    return best_val


@torch.no_grad()
def predict_proba(model, X: np.ndarray, batch_size=256) -> np.ndarray:
    model.eval()
    ds = SeqDataset(X, np.zeros(len(X), dtype=np.int64))
    dl = DataLoader(ds, batch_size=batch_size, shuffle=False)
    out = []
    for xb, _ in dl:
        xb = xb.to(DEVICE)
        p  = torch.softmax(model(xb), dim=-1).cpu().numpy()
        out.append(p)
    return np.vstack(out)


def entropy_from_probs(p: np.ndarray, eps=1e-9):
    return -np.sum(p * np.log(p + eps), axis=1)


# ============================================================
# 11) Active query selector
# ============================================================
def select_queries_active(
    probs_unl: np.ndarray,
    y_rule_unl: np.ndarray,
    idx_unl: np.ndarray,
    query_k: int,
    uncertainty_threshold: float,
):
    yhat = probs_unl.argmax(axis=1)
    maxp = probs_unl.max(axis=1)
    ent  = entropy_from_probs(probs_unl)

    uncertain = (maxp < uncertainty_threshold)
    disagree  = (yhat != y_rule_unl)

    pred_counts = np.bincount(yhat, minlength=CFG.n_classes).astype(np.float32)
    pred_counts = np.maximum(pred_counts, 1.0)
    rare_bonus  = 1.0 / pred_counts[yhat]

    score  = ent
    score += 0.40 * uncertain.astype(np.float32)
    score += 0.35 * disagree.astype(np.float32)
    score += 0.25 * rare_bonus.astype(np.float32)

    chosen_local = np.argsort(-score)[:query_k]
    return idx_unl[chosen_local]


def fusion_predict(probs_model, y_rule, conf_rule, alpha):
    n, c       = probs_model.shape
    probs_rule = np.zeros((n, c), dtype=np.float32)
    probs_rule[np.arange(n), y_rule] = conf_rule
    rem        = 1.0 - conf_rule
    probs_rule += rem[:, None] / c
    probs      = alpha * probs_model + (1 - alpha) * probs_rule
    return probs.argmax(axis=1)


# ============================================================
# 12) Export
# ============================================================
def export_model_to_onnx(
    model,
    cfg,
    scaler,
    path_onnx: str   = "brain_model.onnx",
    path_scaler: str = "scaler.json",
):
    model.eval()
    dummy = torch.randn(1, cfg.window_seconds, cfg.input_dim).to(DEVICE)

    torch.onnx.export(
        model,
        dummy,
        path_onnx,
        input_names=["input"],
        output_names=["logits"],
        dynamic_axes={
            "input":  {0: "batch_size"},
            "logits": {0: "batch_size"},
        },
        opset_version=17,
        do_constant_folding=True,
    )
    print(f"ONNX saved → {path_onnx}")

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
    print("Device:", DEVICE)
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

    # E) Train/test split
    idx_all = np.arange(n)
    idx_train, idx_test = train_test_split(idx_all, test_size=0.2, random_state=SEED)

    # F) Train-only scaling
    scaler = fit_robust_scaler(X_raw[idx_train])
    X      = transform_robust_scaler(X_raw, scaler)

    # G) Active pools
    idx_pool = idx_train.copy()
    np.random.shuffle(idx_pool)
    init_k        = max(10, int(len(idx_pool) * CFG.initial_label_fraction))
    idx_labeled   = idx_pool[:init_k].copy()
    idx_unlabeled = idx_pool[init_k:].copy()

    y_user = -1 * np.ones(n, dtype=np.int64)
    y_user[idx_labeled] = y_rule[idx_labeled]

    # H) Model + optimizer
    model = LSTMClassifier(
        input_dim=CFG.input_dim,
        hidden_dim=CFG.hidden_dim,
        num_layers=CFG.num_layers,
        n_classes=CFG.n_classes,
        dropout=CFG.dropout,
    ).to(DEVICE)
    optimizer = optim.Adam(model.parameters(), lr=CFG.lr, weight_decay=CFG.weight_decay)

    # I) Pretraining with early stopping
    print("\nPretraining on rule labels with early stopping...")
    w_rule = 0.25 + 0.75 * y_rule_conf[idx_train]

    tr_idx_pre, val_idx_pre = train_test_split(idx_train, test_size=0.2, random_state=SEED)
    ds_pre_tr = SeqDataset(X[tr_idx_pre], y_rule[tr_idx_pre], w_rule[np.isin(idx_train, tr_idx_pre)])
    ds_pre_va = SeqDataset(X[val_idx_pre], y_rule[val_idx_pre], w_rule[np.isin(idx_train, val_idx_pre)])

    dl_pre_tr = DataLoader(ds_pre_tr, batch_size=CFG.batch_size, shuffle=True)
    dl_pre_va = DataLoader(ds_pre_va, batch_size=CFG.batch_size, shuffle=False)

    criterion_pre = nn.CrossEntropyLoss()
    _ = fit_with_early_stopping(
        model=model,
        train_loader=dl_pre_tr,
        val_loader=dl_pre_va,
        optimizer=optimizer,
        criterion=criterion_pre,
        max_epochs=CFG.pretrain_epochs,
        patience=CFG.pretrain_patience,
        min_delta=CFG.min_delta,
        weighted=True,
        tag="pretrain",
    )

    # J) Active learning rounds
    print("\nActive learning rounds...")
    for r in range(CFG.active_rounds):
        tr_idx = idx_labeled[y_user[idx_labeled] >= 0]
        if len(tr_idx) < 20:
            print("Not enough labeled windows to finetune. Stopping.")
            break

        tr_ft, va_ft = train_test_split(tr_idx, test_size=0.2, random_state=SEED + r)

        y_tr_ft       = y_user[tr_ft]
        class_w       = compute_class_weights(y_tr_ft, CFG.n_classes)
        criterion_gold = nn.CrossEntropyLoss(weight=class_w)

        ds_ft_tr = SeqDataset(X[tr_ft], y_user[tr_ft])
        ds_ft_va = SeqDataset(X[va_ft], y_user[va_ft])

        dl_ft_tr = DataLoader(ds_ft_tr, batch_size=CFG.batch_size, shuffle=True)
        dl_ft_va = DataLoader(ds_ft_va, batch_size=CFG.batch_size, shuffle=False)

        _ = fit_with_early_stopping(
            model=model,
            train_loader=dl_ft_tr,
            val_loader=dl_ft_va,
            optimizer=optimizer,
            criterion=criterion_gold,
            max_epochs=CFG.finetune_epochs,
            patience=CFG.finetune_patience,
            min_delta=CFG.min_delta,
            weighted=False,
            tag=f"finetune-r{r+1}",
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
        print_class_distribution(y_user[idx_labeled], f"Labeled-set distribution after round {r+1}:")

    # K) Final inference summary
    probs_test  = predict_proba(model, X[idx_test])
    yhat_model  = probs_test.argmax(axis=1)

    frac_labeled = len(idx_labeled) / max(1, len(idx_train))
    alpha        = CFG.alpha_start + (CFG.alpha_end - CFG.alpha_start) * frac_labeled
    alpha        = float(np.clip(alpha, 0.0, 1.0))
    yhat_fused   = fusion_predict(probs_test, y_rule[idx_test], y_rule_conf[idx_test], alpha)

    print_class_distribution(yhat_model, "Prediction distribution (model-only):")
    print_class_distribution(yhat_fused, "Prediction distribution (fused):")

    print("\nSample prompt windows:")
    for i in range(min(5, len(meta))):
        print(f"  {meta[i]['start_time']} -> {meta[i]['end_time']}")

    # L) Export
    export_model_to_onnx(model, CFG, scaler)

    print("\nDone.")


# ============================================================
if __name__ == "__main__":
    main()