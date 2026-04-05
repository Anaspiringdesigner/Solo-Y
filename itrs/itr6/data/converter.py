import os
import glob
import pandas as pd

# -----------------------------
# CONFIG
# -----------------------------
# If script is inside /data, keep DATA_DIR="."
# If script is in /itr5, use DATA_DIR="./data"
DATA_DIR = "."
OUTPUT_CSV = "all_data.csv"

# -----------------------------
# Parser for one raw file
# -----------------------------
def parse_raw_file(path: str) -> pd.DataFrame:
    """
    Supports rows like:
      timestamp;hr
      timestamp;hr;hrv;br
    Also handles whitespace-delimited fallback.
    """
    # Try semicolon first
    try:
        df = pd.read_csv(path, sep=";", header=None, engine="python")
    except Exception:
        df = pd.read_csv(path, sep=r"\s+", header=None, engine="python")

    # Drop empty columns
    df = df.dropna(axis=1, how="all")

    # Need at least timestamp + hr
    if df.shape[1] < 2:
        return pd.DataFrame(columns=["timestamp", "hr", "hrv", "br", "source_file"])

    # Remove header-like first row if present
    first = df.iloc[0].astype(str).str.lower().tolist()
    if any(("time" in x or "heart" in x or "hrv" in x or "breath" in x) for x in first):
        df = df.iloc[1:].reset_index(drop=True)

    out = pd.DataFrame()
    out["timestamp"] = pd.to_datetime(df.iloc[:, 0], errors="coerce")
    out["hr"] = pd.to_numeric(df.iloc[:, 1], errors="coerce")
    out["hrv"] = pd.to_numeric(df.iloc[:, 2], errors="coerce") if df.shape[1] >= 3 else pd.NA
    out["br"] = pd.to_numeric(df.iloc[:, 3], errors="coerce") if df.shape[1] >= 4 else pd.NA
    out["source_file"] = os.path.basename(path)

    # Basic cleaning
    out = out.dropna(subset=["timestamp", "hr"]).copy()
    out.loc[(out["hr"] < 30) | (out["hr"] > 220), "hr"] = pd.NA
    out.loc[(out["hrv"] < 1) | (out["hrv"] > 250), "hrv"] = pd.NA
    out.loc[(out["br"] < 4) | (out["br"] > 60), "br"] = pd.NA
    out = out.dropna(subset=["hr"]).copy()

    return out


def main():
    # Grab all files in DATA_DIR except.py and existing.csv
    all_files = [
        f for f in glob.glob(os.path.join(DATA_DIR, "*"))
        if os.path.isfile(f)
        and not f.lower().endswith(".py")
        and not f.lower().endswith(".csv")
    ]

    if not all_files:
        raise FileNotFoundError(f"No raw files found in {os.path.abspath(DATA_DIR)}")

    frames = []
    failed = 0

    for f in sorted(all_files):
        try:
            dfi = parse_raw_file(f)
            if len(dfi) > 0:
                frames.append(dfi)
            else:
                print(f"[SKIP] No valid rows: {os.path.basename(f)}")
        except Exception as e:
            failed += 1
            print(f"[FAIL] {os.path.basename(f)} -> {e}")

    if not frames:
        raise ValueError("No valid data parsed from any file.")

    merged = pd.concat(frames, ignore_index=True)

    # Sort and drop exact duplicates
    merged = merged.sort_values("timestamp").drop_duplicates().reset_index(drop=True)

    # Save
    out_path = os.path.join(DATA_DIR, OUTPUT_CSV)
    merged.to_csv(out_path, index=False)

    print("\nDone.")
    print(f"Files scanned: {len(all_files)}")
    print(f"Files failed: {failed}")
    print(f"Rows in merged CSV: {len(merged)}")
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()