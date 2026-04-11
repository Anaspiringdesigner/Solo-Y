# analyze_rl_log.py
# Analyze RL training log and generate trend plots.
#
# Usage:
#   python analyze_rl_log.py
#   python analyze_rl_log.py --log rl_runs/rl_log.csv --out rl_runs/rl_analysis.png --window 50
#
# Requirements:
#   pip install pandas matplotlib numpy

import argparse
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

def safe_numeric(df, col, default=np.nan):
    if col not in df.columns:
        return pd.Series([default] * len(df))
    return pd.to_numeric(df[col], errors="coerce")

def main(log_path: Path, out_path: Path, window: int):
    if not log_path.exists():
        raise FileNotFoundError(f"Log not found: {log_path}")

    df = pd.read_csv(log_path)

    # Required-ish columns with fallback
    df["step"] = safe_numeric(df, "step", 0)
    df["reward"] = safe_numeric(df, "reward", 0.0)
    df["reward_ema"] = safe_numeric(df, "reward_ema", np.nan)
    df["epsilon"] = safe_numeric(df, "epsilon", np.nan)
    df["avg_hr"] = safe_numeric(df, "avg_hr", np.nan)
    df["avg_hrv"] = safe_numeric(df, "avg_hrv", np.nan)
    df["avg_br"] = safe_numeric(df, "avg_br", np.nan)
    df["action"] = safe_numeric(df, "action", np.nan)

    # Sort by step in case of appended logs
    df = df.sort_values("step").reset_index(drop=True)

    # Rolling stats
    df["reward_roll"] = df["reward"].rolling(window=window, min_periods=1).mean()
    df["hr_roll"] = df["avg_hr"].rolling(window=window, min_periods=1).mean()
    df["hrv_roll"] = df["avg_hrv"].rolling(window=window, min_periods=1).mean()
    df["br_roll"] = df["avg_br"].rolling(window=window, min_periods=1).mean()

    # If reward_ema missing, synthesize quick EMA
    if df["reward_ema"].isna().all():
        alpha = 2 / (window + 1.0)
        ema = []
        v = 0.0
        for r in df["reward"].fillna(0.0).values:
            v = (1 - alpha) * v + alpha * r
            ema.append(v)
        df["reward_ema"] = ema

    # Action distribution
    action_counts = df["action"].dropna().astype(int).value_counts().sort_index()

    # Summary
    n = len(df)
    reward_mean = float(df["reward"].mean()) if n else 0.0
    reward_last_roll = float(df["reward_roll"].iloc[-1]) if n else 0.0
    eps_start = float(df["epsilon"].dropna().iloc[0]) if df["epsilon"].notna().any() else np.nan
    eps_end = float(df["epsilon"].dropna().iloc[-1]) if df["epsilon"].notna().any() else np.nan

    print("=" * 70)
    print("RL LOG SUMMARY")
    print("=" * 70)
    print(f"Rows                : {n}")
    print(f"Reward mean         : {reward_mean:+.4f}")
    print(f"Reward rolling({window}) last: {reward_last_roll:+.4f}")
    print(f"Epsilon start -> end: {eps_start:.4f} -> {eps_end:.4f}")
    print("\nAction counts:")
    if len(action_counts) == 0:
        print("  (none)")
    else:
        for a, c in action_counts.items():
            print(f"  Action {a}: {c}")
    print("=" * 70)

    # Plot
    fig, axes = plt.subplots(4, 1, figsize=(12, 12), sharex=True)

    # 1) Reward
    axes[0].plot(df["step"], df["reward"], alpha=0.25, label="reward (raw)")
    axes[0].plot(df["step"], df["reward_roll"], linewidth=2, label=f"reward rolling({window})")
    axes[0].plot(df["step"], df["reward_ema"], linewidth=2, label="reward ema")
    axes[0].axhline(0, linestyle="--", linewidth=1)
    axes[0].set_ylabel("Reward")
    axes[0].legend(loc="best")
    axes[0].grid(alpha=0.3)

    # 2) Epsilon
    axes[1].plot(df["step"], df["epsilon"], linewidth=2, label="epsilon")
    axes[1].set_ylabel("Epsilon")
    axes[1].legend(loc="best")
    axes[1].grid(alpha=0.3)

    # 3) Vitals rolling
    axes[2].plot(df["step"], df["hr_roll"], label=f"HR rolling({window})")
    axes[2].plot(df["step"], df["hrv_roll"], label=f"HRV rolling({window})")
    axes[2].plot(df["step"], df["br_roll"], label=f"BR rolling({window})")
    axes[2].set_ylabel("Vitals (rolling)")
    axes[2].legend(loc="best")
    axes[2].grid(alpha=0.3)

    # 4) Actions over time
    axes[3].scatter(df["step"], df["action"], s=8, alpha=0.6, label="action")
    axes[3].set_ylabel("Action ID")
    axes[3].set_xlabel("Step")
    axes[3].set_yticks([0, 1, 2, 3, 4, 5])
    axes[3].legend(loc="best")
    axes[3].grid(alpha=0.3)

    plt.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150)
    print(f"Saved plot: {out_path.resolve()}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=str, default="rl_log.csv")
    parser.add_argument("--out", type=str, default="rl_analysis.png")
    parser.add_argument("--window", type=int, default=50)
    args = parser.parse_args()

    main(Path(args.log), Path(args.out), args.window)