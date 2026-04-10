import requests
import numpy as np
from datetime import datetime, timedelta

T = 120
now = datetime.utcnow()

hr = (70 + 2*np.sin(np.linspace(0, 6.28, T))).tolist()
hrv = (30 + 3*np.sin(np.linspace(0, 3.14, T))).tolist()
br = (14 + 1*np.sin(np.linspace(0, 9.42, T))).tolist()

payload = {
    "windows": [{
        "start_time": (now - timedelta(seconds=T)).isoformat(),
        "end_time": now.isoformat(),
        "hr": hr,
        "hrv": hrv,
        "br": br,
        "avg_hr": float(np.mean(hr)),
        "avg_hrv": float(np.mean(hrv)),
        "avg_br": float(np.mean(br))
    }]
}

r = requests.post("http://127.0.0.1:8000/ingest", json=payload, timeout=10)
print("INGEST:", r.status_code, r.text)

r2 = requests.get("http://127.0.0.1:8000/latest", timeout=10)
print("LATEST:", r2.status_code)
print(r2.json().keys())
print("z length:", len(r2.json().get("z", [])))