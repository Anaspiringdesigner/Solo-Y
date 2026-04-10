# polar_reader.py
# Live-only Polar H10 reader via ADB
# - Reads ONLY *_HR.txt files
# - Processes ONLY newest HR file
# - Keeps ONLY recent rows (last RECENT_MINUTES)
# - Posts ONLY new complete windows to brain_tcn.py /ingest
#
# Requirements:
#   pip install pandas numpy requests

import time
import subprocess
import tempfile
import hashlib
import requests
import numpy as np
import pandas as pd
from pathlib import Path
from datetime import datetime

# ============================================================
# Config
# ============================================================
ANDROID_POLAR_DIR = "/sdcard/Download/Data_from_H10"
BRAIN_API = "http://127.0.0.1:8000"

POLL_INTERVAL = 10
WINDOW_SECONDS = 120
RECENT_MINUTES = 15
STALE_WINDOW_MINUTES = 5

LOCAL_TEMP = Path(tempfile.gettempdir()) / "polar_pulled"
LOCAL_TEMP.mkdir(exist_ok=True)

file_states = {}
last_posted_end_by_file = {}

# ============================================================
# ADB helpers
# ============================================================
def adb_is_connected() -> bool:
    try:
        result = subprocess.run(
            ["adb", "devices"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in result.stdout.strip().splitlines()
                 if l and not l.startswith("List")]
        return any("device" in l for l in lines)
    except Exception as e:
        print(f"  ADB check failed: {e}")
        return False


def adb_list_hr_files(android_dir: str) -> list:
    try:
        result = subprocess.run(
            ["adb", "shell", f"ls {android_dir}"],
            capture_output=True, text=True, timeout=10
        )
        files = []
        for f in result.stdout.splitlines():
            f = f.strip()
            if f.endswith(".txt") and "_HR.txt" in f:
                files.append(f)
        return files
    except Exception as e:
        print(f"  ADB list failed: {e}")
        return []


def adb_pull_file(android_path: str, local_path: Path) -> bool:
    try:
        result = subprocess.run(
            ["adb", "pull", android_path, str(local_path)],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0
    except Exception as e:
        print(f"  ADB pull failed: {e}")
        return False


def file_hash(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()

# ============================================================
# Parser
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

    df.loc[(df["hr"] < 30) | (df["hr"] > 220), "hr"] = np.nan
    df.loc[(df["hrv"] < 1) | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"] < 4) | (df["br"] > 60), "br"] = np.nan
    df = df.dropna(subset=["hr"]).copy()

    if df.empty:
        return pd.DataFrame()

    df = df.set_index("timestamp").resample("1s").mean(numeric_only=True)

    df["hr"] = df["hr"].interpolate(method="time", limit=10, limit_direction="both")

    if df["hrv"].isna().mean() > 0.5:
        hr_std = df["hr"].rolling(window=60, min_periods=10).std()
        est_hrv = (hr_std * 12.0).clip(5, 120)
        df["hrv"] = df["hrv"].fillna(est_hrv)
    df["hrv"] = df["hrv"].interpolate(method="time", limit=20, limit_direction="both")

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


# ============================================================
# Windowing
# ============================================================
def build_windows(df: pd.DataFrame, window_sec: int = 120) -> list:
    if len(df) < window_sec:
        return []

    out = []
    for s in range(0, len(df) - window_sec + 1, window_sec):
        e = s + window_sec
        chunk = df.iloc[s:e]
        out.append({
            "start_time": chunk["timestamp"].iloc[0].isoformat(),
            "end_time": chunk["timestamp"].iloc[-1].isoformat(),
            "hr": chunk["hr"].astype(float).values.tolist(),
            "hrv": chunk["hrv"].astype(float).values.tolist(),
            "br": chunk["br"].astype(float).values.tolist(),
            "avg_hr": round(float(chunk["hr"].mean()), 1),
            "avg_hrv": round(float(chunk["hrv"].mean()), 1),
            "avg_br": round(float(chunk["br"].mean()), 1),
        })
    return out


# ============================================================
# Post
# ============================================================
def post_windows(windows: list) -> bool:
    if not windows:
        return False
    try:
        r = requests.post(f"{BRAIN_API}/ingest", json={"windows": windows}, timeout=30)
        if r.status_code == 200:
            data = r.json()
            print(f"  Ingested {data.get('ingested', 0)} windows")
            return True
        print(f"  Ingest failed: {r.status_code} | {r.text}")
        return False
    except Exception as e:
        print(f"  Post error: {e}")
        return False


# ============================================================
# Main
# ============================================================
def watch():
    print("=" * 70)
    print("Polar H10 ADB Watcher (LIVE-ONLY)")
    print(f"Dir: {ANDROID_POLAR_DIR}")
    print(f"API: {BRAIN_API}/ingest")
    print("=" * 70)

    while True:
        if not adb_is_connected():
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ADB not connected")
            time.sleep(POLL_INTERVAL)
            continue

        hr_files = adb_list_hr_files(ANDROID_POLAR_DIR)
        if not hr_files:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] No *_HR.txt files found")
            time.sleep(POLL_INTERVAL)
            continue

        hr_files = sorted(hr_files)
        fname = hr_files[-1]  # newest by name timestamp
        android_path = f"{ANDROID_POLAR_DIR}/{fname}"
        local_path = LOCAL_TEMP / fname

        if not adb_pull_file(android_path, local_path):
            time.sleep(POLL_INTERVAL)
            continue
        if not local_path.exists():
            time.sleep(POLL_INTERVAL)
            continue

        h = file_hash(local_path)
        if file_states.get(fname) == h:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] No file change")
            time.sleep(POLL_INTERVAL)
            continue
        file_states[fname] = h

        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Updated file: {fname}")

        df = parse_polar_hr_file(local_path)
        if df.empty:
            print("  Parse empty")
            time.sleep(POLL_INTERVAL)
            continue

        now = pd.Timestamp.utcnow().tz_localize(None)
        df["timestamp"] = pd.to_datetime(df["timestamp"]).dt.tz_localize(None)

        cutoff_recent = now - pd.Timedelta(minutes=RECENT_MINUTES)
        df = df[df["timestamp"] >= cutoff_recent].copy()
        if df.empty:
            print(f"  No rows in last {RECENT_MINUTES} min")
            time.sleep(POLL_INTERVAL)
            continue

        print(f"  Recent rows={len(df)} HR={df['hr'].mean():.1f} HRV={df['hrv'].mean():.1f} BR={df['br'].mean():.1f}")

        windows = build_windows(df, WINDOW_SECONDS)
        if not windows:
            print(f"  Not enough recent data for {WINDOW_SECONDS}s window")
            time.sleep(POLL_INTERVAL)
            continue

        last_end = last_posted_end_by_file.get(fname)
        if last_end is None:
            new_windows = windows
        else:
            new_windows = [w for w in windows if w["end_time"] > last_end]

        if not new_windows:
            print(f"  No NEW windows to post (last_end={last_end})")
            time.sleep(POLL_INTERVAL)
            continue

        stale_cutoff = now - pd.Timedelta(minutes=STALE_WINDOW_MINUTES)
        fresh_windows = []
        for w in new_windows:
            w_end = pd.Timestamp(w["end_time"]).tz_localize(None)
            if w_end >= stale_cutoff:
                fresh_windows.append(w)

        if not fresh_windows:
            print("  New windows are stale; skip")
            time.sleep(POLL_INTERVAL)
            continue

        print(f"  Posting {len(fresh_windows)} fresh window(s), last_end={fresh_windows[-1]['end_time']}")
        ok = post_windows(fresh_windows)
        if ok:
            last_posted_end_by_file[fname] = fresh_windows[-1]["end_time"]
            print(f"  Updated last_posted_end -> {last_posted_end_by_file[fname]}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    watch()