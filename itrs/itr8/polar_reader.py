# polar_reader.py
# Watches Polar H10 folder on Android via ADB
# Interpolates missing HRV and BR values
# Posts ONLY NEW complete windows to brain_tcn.py /ingest
#
# Requirements:
#   pip install pandas numpy requests
#   ADB installed and phone connected via USB
#   USB debugging enabled on phone

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

POLL_INTERVAL = 30      # seconds between checks
WINDOW_SECONDS = 120    # non-overlapping window size in seconds

LOCAL_TEMP = Path(tempfile.gettempdir()) / "polar_pulled"
LOCAL_TEMP.mkdir(exist_ok=True)

# Track last content hash per file (detect if phone file changed)
file_states = {}

# Track last posted window end_time per file (avoid reposting old windows)
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
        lines = [
            l for l in result.stdout.strip().splitlines()
            if l and not l.startswith("List")
        ]
        return any("device" in l for l in lines)
    except Exception as e:
        print(f"  ADB check failed: {e}")
        return False


def adb_list_files(android_dir: str) -> list:
    """List Polar.txt files in the Android folder."""
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
# Polar file parser
# ============================================================
def parse_polar_file(path: Path) -> pd.DataFrame:
    """
    Parse Polar Sensor Logger file.
    Expected columns in line:
      timestamp;hr;hrv;br
    where hrv/br may be missing in many rows.
    """
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

    # Range checks
    df.loc[(df["hr"] < 30) | (df["hr"] > 220), "hr"] = np.nan
    df.loc[(df["hrv"] < 1) | (df["hrv"] > 250), "hrv"] = np.nan
    df.loc[(df["br"] < 4) | (df["br"] > 60), "br"] = np.nan
    df = df.dropna(subset=["hr"]).copy()

    if df.empty:
        return pd.DataFrame()

    # Resample to 1-second grid
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

    # Final cleanup
    df = df.dropna(subset=["hr", "hrv", "br"]).reset_index()
    return df


# ============================================================
# Window builder
# ============================================================
def build_windows(df: pd.DataFrame, window_sec: int = 120) -> list:
    """Build non-overlapping windows from dataframe."""
    if len(df) < window_sec:
        return []

    windows = []
    for s in range(0, len(df) - window_sec + 1, window_sec):
        e = s + window_sec
        chunk = df.iloc[s:e]

        windows.append({
            "start_time": chunk["timestamp"].iloc[0].isoformat(),
            "end_time": chunk["timestamp"].iloc[-1].isoformat(),
            "hr": chunk["hr"].astype(float).values.tolist(),
            "hrv": chunk["hrv"].astype(float).values.tolist(),
            "br": chunk["br"].astype(float).values.tolist(),
            "avg_hr": round(float(chunk["hr"].mean()), 1),
            "avg_hrv": round(float(chunk["hrv"].mean()), 1),
            "avg_br": round(float(chunk["br"].mean()), 1),
        })

    return windows


# ============================================================
# Post to brain_tcn.py
# ============================================================
def post_windows(windows: list) -> bool:
    if not windows:
        return False
    try:
        res = requests.post(
            f"{BRAIN_API}/ingest",
            json={"windows": windows},
            timeout=30
        )
        if res.status_code == 200:
            data = res.json()
            print(f"  Ingested {data.get('ingested', 0)} windows")
            return True
        print(f"  Ingest failed: {res.status_code} | {res.text}")
        return False
    except Exception as e:
        print(f"  Post error: {e}")
        return False


# ============================================================
# Main loop
# ============================================================
def watch():
    print("=" * 60)
    print("Polar H10 ADB Watcher (NEW WINDOWS ONLY)")
    print(f"Watching Android dir: {ANDROID_POLAR_DIR}")
    print(f"Posting to API:       {BRAIN_API}/ingest")
    print(f"Poll interval:        {POLL_INTERVAL}s")
    print(f"Window seconds:       {WINDOW_SECONDS}s")
    print("=" * 60)

    while True:
        # ADB check
        if not adb_is_connected():
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"ADB phone not connected. Retry in {POLL_INTERVAL}s...")
            time.sleep(POLL_INTERVAL)
            continue

        # List files
        remote_files = adb_list_files(ANDROID_POLAR_DIR)
        if not remote_files:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"No Polar files found. Retry in {POLL_INTERVAL}s...")
            time.sleep(POLL_INTERVAL)
            continue

        for fname in remote_files:
            android_path = f"{ANDROID_POLAR_DIR}/{fname}"
            local_path = LOCAL_TEMP / fname

            # Pull file
            ok = adb_pull_file(android_path, local_path)
            if not ok or not local_path.exists():
                continue

            # Detect if file changed
            h = file_hash(local_path)
            if file_states.get(fname) == h:
                continue  # unchanged since last poll
            file_states[fname] = h

            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Updated file: {fname}")

            # Parse
            df = parse_polar_file(local_path)
            if df.empty:
                print("  Parse result empty.")
                continue

            print(f"  Parsed rows: {len(df)} | "
                  f"HR={df['hr'].mean():.1f} HRV={df['hrv'].mean():.1f} BR={df['br'].mean():.1f}")

            # Build windows (all complete windows found in file)
            windows = build_windows(df, WINDOW_SECONDS)
            if not windows:
                print(f"  Not enough data for one full window ({WINDOW_SECONDS}s).")
                continue

            print(f"  Complete windows in file: {len(windows)}")

            # Filter ONLY unseen windows for this file
            last_end = last_posted_end_by_file.get(fname)
            if last_end is None:
                new_windows = windows
            else:
                new_windows = [w for w in windows if w["end_time"] > last_end]

            if not new_windows:
                print(f"  No NEW windows to post (last_end={last_end}).")
                continue

            print(f"  Posting NEW windows: {len(new_windows)} "
                  f"(from {new_windows[0]['end_time']} to {new_windows[-1]['end_time']})")

            posted = post_windows(new_windows)
            if posted:
                last_posted_end_by_file[fname] = new_windows[-1]["end_time"]
                print(f"  last_posted_end[{fname}] = {last_posted_end_by_file[fname]}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    watch()