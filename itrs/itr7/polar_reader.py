# polar_reader.py
# Watches Polar H10 folder on Android via ADB
# Interpolates missing HRV and BR values
# Posts new data to brain.py every 2 minutes
#
# Requirements:
#   pip install pandas numpy requests
#   ADB installed and phone connected via USB
#   USB debugging enabled on phone

import os
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
# Path on Android where Polar Sensor Logger saves files
ANDROID_POLAR_DIR = "/sdcard/PolarSensorLogger"

# brain.py API
BRAIN_API = "http://127.0.0.1:8000"

# How often to check for new data (seconds)
POLL_INTERVAL = 30

# How many seconds of data to send per window
WINDOW_SECONDS = 120

# Local temp folder to store pulled files
LOCAL_TEMP = Path(tempfile.gettempdir()) / "polar_pulled"
LOCAL_TEMP.mkdir(exist_ok=True)

# Track which files we have already processed
processed_hashes = set()


# ============================================================
# ADB helpers
# ============================================================
def adb_is_connected() -> bool:
    try:
        result = subprocess.run(
            ["adb", "devices"],
            capture_output=True, text=True, timeout=5
        )
        lines = [
            l for l in result.stdout.strip().splitlines()
            if l and not l.startswith("List")
        ]
        return any("device" in l for l in lines)
    except Exception as e:
        print(f"  ADB check failed: {e}")
        return False


def adb_list_files(android_dir: str) -> list:
    """List all.txt files in the Android Polar directory."""
    try:
        result = subprocess.run(
            ["adb", "shell", f"ls {android_dir}"],
            capture_output=True, text=True, timeout=10
        )
        files = [
            f.strip() for f in result.stdout.splitlines()
            if f.strip().endswith(".txt") and "Polar_H10" in f
        ]
        return files
    except Exception as e:
        print(f"  ADB list failed: {e}")
        return []


def adb_pull_file(android_path: str, local_path: Path) -> bool:
    """Pull a single file from Android to local."""
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
    """MD5 hash of file content to detect changes."""
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ============================================================
# Polar file parser
# ============================================================
def parse_polar_file(path: Path) -> pd.DataFrame:
    """
    Parse Polar Sensor Logger HR text file.
    Interpolates missing HRV and BR values.

    Format:
      Phone timestamp;HR [bpm];HRV [ms];Breathing interval [rpm]
      2026-03-31T19:43:21.715;64
      2026-03-31T19:43:22.697;64
      2026-03-31T19:43:25.717;65;5.4
    """
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Skip filename line and header line
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
            ts  = pd.to_datetime(parts[0].strip(), errors="coerce")
            hr  = float(parts[1].strip()) if len(parts) > 1 and parts[1].strip() else np.nan
            hrv = float(parts[2].strip()) if len(parts) > 2 and parts[2].strip() else np.nan
            br  = float(parts[3].strip()) if len(parts) > 3 and parts[3].strip() else np.nan
            rows.append({"timestamp": ts, "hr": hr, "hrv": hrv, "br": br})
        except Exception:
            continue

    if not rows:
        return pd.DataFrame()

    df = pd.DataFrame(rows)
    df = df.dropna(subset=["timestamp", "hr"])
    df = df.sort_values("timestamp").reset_index(drop=True)

    # ── Validate ranges ──
    df.loc[(df["hr"]  < 30)  | (df["hr"]  > 220), "hr"]  = np.nan
    df.loc[(df["hrv"] < 1)   | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"]  < 4)   | (df["br"]  > 60),  "br"]  = np.nan
    df = df.dropna(subset=["hr"])

    # ── Resample to 1s grid ──
    df = df.set_index("timestamp").resample("1s").mean(numeric_only=True)

    # ── Interpolate HR ──
    df["hr"] = df["hr"].interpolate(
        method="time", limit=10, limit_direction="both"
    )

    # ── Interpolate HRV ──
    # If mostly missing → estimate from HR variability
    if df["hrv"].isna().mean() > 0.5:
        hr_std = df["hr"].rolling(window=60, min_periods=10).std()
        est_hrv = (hr_std * 12.0).clip(5, 120)
        df["hrv"] = df["hrv"].fillna(est_hrv)
    df["hrv"] = df["hrv"].interpolate(
        method="time", limit=20, limit_direction="both"
    )

    # ── Interpolate BR ──
    # If mostly missing → estimate from HR
    if df["br"].isna().mean() > 0.5:
        hr_smooth = df["hr"].rolling(window=30, min_periods=5).mean()
        hr_min    = hr_smooth.quantile(0.05)
        hr_max    = hr_smooth.quantile(0.95)
        denom     = max(1e-6, hr_max - hr_min)
        br_est    = 10 + (hr_smooth - hr_min) * (10 / denom)
        br_est    = br_est.clip(8, 24)
        df["br"]  = df["br"].fillna(br_est)
    df["br"] = df["br"].interpolate(
        method="time", limit=20, limit_direction="both"
    )

    # ── Drop remaining NaN ──
    df = df.dropna(subset=["hr", "hrv", "br"]).reset_index()
    df = df.rename(columns={"index": "timestamp"})

    return df


# ============================================================
# Window builder
# ============================================================
def build_windows(df: pd.DataFrame, window_sec: int = 120) -> list:
    """
    Build non-overlapping windows from a dataframe.
    Returns list of window dicts with averaged vitals.
    """
    if len(df) < window_sec:
        return []

    windows = []
    for s in range(0, len(df) - window_sec + 1, window_sec):
        e    = s + window_sec
        chunk = df.iloc[s:e]

        windows.append({
            "start_time": chunk["timestamp"].iloc[0].isoformat(),
            "end_time":   chunk["timestamp"].iloc[-1].isoformat(),
            "hr":         chunk["hr"].values.tolist(),
            "hrv":        chunk["hrv"].values.tolist(),
            "br":         chunk["br"].values.tolist(),
            "avg_hr":     round(float(chunk["hr"].mean()),  1),
            "avg_hrv":    round(float(chunk["hrv"].mean()), 1),
            "avg_br":     round(float(chunk["br"].mean()),  1),
        })

    return windows


# ============================================================
# Post to brain.py
# ============================================================
def post_windows(windows: list) -> bool:
    """Send new windows to brain.py /ingest endpoint."""
    if not windows:
        return False
    try:
        res = requests.post(
            f"{BRAIN_API}/ingest",
            json={"windows": windows},
            timeout=30,
        )
        if res.status_code == 200:
            data = res.json()
            print(f"  Ingested {data.get('ingested', 0)} windows "
                  f"| uncertain groups: {data.get('uncertain_groups', 0)}")
            return True
        else:
            print(f"  Ingest failed: {res.status_code}")
            return False
    except Exception as e:
        print(f"  Post error: {e}")
        return False


# ============================================================
# Main watch loop
# ============================================================
def watch():
    print("=" * 50)
    print("Polar H10 ADB Watcher")
    print(f"Watching: {ANDROID_POLAR_DIR}")
    print(f"Posting to: {BRAIN_API}")
    print("=" * 50)

    # Track last seen content hash per file
    file_states: dict = {}

    while True:
        # ── Check ADB connection ──
        if not adb_is_connected():
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"Phone not connected via ADB. Retrying in {POLL_INTERVAL}s...")
            time.sleep(POLL_INTERVAL)
            continue

        # ── List files on phone ──
        remote_files = adb_list_files(ANDROID_POLAR_DIR)
        if not remote_files:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"No Polar files found. Retrying in {POLL_INTERVAL}s...")
            time.sleep(POLL_INTERVAL)
            continue

        # ── Process each file ──
        for fname in remote_files:
            android_path = f"{ANDROID_POLAR_DIR}/{fname}"
            local_path   = LOCAL_TEMP / fname

            # Pull from phone
            ok = adb_pull_file(android_path, local_path)
            if not ok or not local_path.exists():
                continue

            # Check if file has changed since last pull
            h = file_hash(local_path)
            if file_states.get(fname) == h:
                continue  # no change

            file_states[fname] = h
            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] "
                  f"New/updated file: {fname}")

            # Parse
            df = parse_polar_file(local_path)
            if df.empty:
                print("  Could not parse file.")
                continue

            print(f"  Parsed {len(df)} rows | "
                  f"HR: {df['hr'].mean():.1f} | "
                  f"HRV: {df['hrv'].mean():.1f} | "
                  f"BR: {df['br'].mean():.1f}")

            # Build windows
            windows = build_windows(df, WINDOW_SECONDS)
            if not windows:
                print(f"  Not enough data for windows yet "
                      f"(need {WINDOW_SECONDS}s, have {len(df)}s)")
                continue

            print(f"  Built {len(windows)} windows")

            # Post to brain.py
            post_windows(windows)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    watch()