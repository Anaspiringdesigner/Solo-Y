# rl_agent.py
# Q-Learning RL agent
# State:   normalised HR, HRV, BR → discretised
# Action:  6 visual scenes in TouchDesigner
# Reward:  +ΔHRV - ΔHR (calm and focused)
# Comms:   OSC → TouchDesigner
#
# Requirements:
#   pip install numpy requests python-osc

import time
import json
import numpy as np
import requests
from pathlib import Path
from datetime import datetime
from pythonosc import udp_client

# ============================================================
# Config
# ============================================================
BRAIN_API    = "http://127.0.0.1:8000"
TD_IP        = "127.0.0.1"   # TouchDesigner IP
TD_PORT      = 7000           # TouchDesigner OSC port
POLL_SEC     = 120            # act every 2 minutes (one window)
Q_TABLE_PATH = Path("q_table.json")

# Q-learning hyperparameters
ALPHA        = 0.1    # learning rate
GAMMA        = 0.9    # discount factor
EPSILON      = 0.3    # exploration rate (30% random at start)
EPSILON_MIN  = 0.05   # minimum exploration
EPSILON_DECAY= 0.995  # decay per episode

N_STATES     = 27     # 3 bins × 3 vitals (HR, HRV, BR)
N_ACTIONS    = 6      # one per brain state scene

# Reward weights
ALPHA_HRV    = 0.6    # HRV improvement weight
BETA_HR      = 0.4    # HR reduction weight

# Action → TouchDesigner scene mapping
ACTION_NAMES = {
    0: "Baseline / Calm",
    1: "Panic / Chaos",
    2: "Meaningful Focus",
    3: "Inattention / Drift",
    4: "Rigid Hyperfocus",
    5: "Intervention Alert",
}

# Bin edges for discretising vitals
# Adjust these to your personal HR/HRV/BR ranges
HR_BINS  = [60, 80]    # low < 60, mid 60-80, high > 80
HRV_BINS = [20, 50]    # low < 20, mid 20-50, high > 50
BR_BINS  = [12, 18]    # low < 12, mid 12-18, high > 18


# ============================================================
# Q-table
# ============================================================
def load_q_table() -> np.ndarray:
    if Q_TABLE_PATH.exists():
        with open(Q_TABLE_PATH, "r") as f:
            data = json.load(f)
        print(f"Q-table loaded from {Q_TABLE_PATH}")
        return np.array(data, dtype=np.float32)
    print("No Q-table found. Starting fresh.")
    return np.zeros((N_STATES, N_ACTIONS), dtype=np.float32)


def save_q_table(q: np.ndarray):
    with open(Q_TABLE_PATH, "w") as f:
        json.dump(q.tolist(), f)


# ============================================================
# State discretisation
# ============================================================
def discretise(value: float, bins: list) -> int:
    """Map a continuous value to a bin index (0, 1, 2)."""
    for i, edge in enumerate(bins):
        if value < edge:
            return i
    return len(bins)


def get_state_index(hr: float, hrv: float, br: float) -> int:
    """
    Discretise HR, HRV, BR into a single state index.
    3 bins each → 3×3×3 = 27 states
    """
    hr_bin  = discretise(hr,  HR_BINS)
    hrv_bin = discretise(hrv, HRV_BINS)
    br_bin  = discretise(br,  BR_BINS)
    return hr_bin * 9 + hrv_bin * 3 + br_bin


# ============================================================
# Reward function
# ============================================================
def compute_reward(
    hr_prev:  float,
    hr_curr:  float,
    hrv_prev: float,
    hrv_curr: float,
) -> float:
    """
    r(t) = α * ΔHRV_norm + β * (-ΔHR_norm)

    HRV up   → positive reward
    HR down  → positive reward
    Clipped to [-1, +1]
    """
    delta_hrv = np.clip(
        (hrv_curr - hrv_prev) / (abs(hrv_prev) + 1e-6), -1, 1
    )
    delta_hr  = np.clip(
        (hr_curr  - hr_prev)  / (abs(hr_prev)  + 1e-6), -1, 1
    )
    reward = ALPHA_HRV * delta_hrv + BETA_HR * (-delta_hr)
    return float(np.clip(reward, -1.0, 1.0))


# ============================================================
# Action selection (ε-greedy)
# ============================================================
def select_action(q: np.ndarray, state: int, epsilon: float) -> int:
    if np.random.random() < epsilon:
        return np.random.randint(N_ACTIONS)   # explore
    return int(np.argmax(q[state]))            # exploit


# ============================================================
# Q-table update
# ============================================================
def update_q(
    q:          np.ndarray,
    state:      int,
    action:     int,
    reward:     float,
    next_state: int,
) -> np.ndarray:
    """
    Q(s,a) ← Q(s,a) + α * [r + γ * max Q(s',a') - Q(s,a)]
    """
    best_next  = float(np.max(q[next_state]))
    current_q  = q[state, action]
    q[state, action] = current_q + ALPHA * (
        reward + GAMMA * best_next - current_q
    )
    return q


# ============================================================
# OSC sender → TouchDesigner
# ============================================================
def send_osc_action(client: udp_client.SimpleUDPClient, action: int,
                    hr: float, hrv: float, br: float, reward: float):
    """
    Send action and bio state to TouchDesigner via OSC.

    TouchDesigner listens on:
      /rl/action    int      (0-5 scene index)
      /rl/hr        float    (current HR)
      /rl/hrv       float    (current HRV)
      /rl/br        float    (current BR)
      /rl/reward    float    (last reward)
    """
    client.send_message("/rl/action", action)
    client.send_message("/rl/hr",     float(hr))
    client.send_message("/rl/hrv",    float(hrv))
    client.send_message("/rl/br",     float(br))
    client.send_message("/rl/reward", float(reward))

    print(f"  OSC → TD | action={action} ({ACTION_NAMES[action]}) "
          f"| reward={reward:+.3f}")


# ============================================================
# Fetch latest bio state from brain.py
# ============================================================
def fetch_latest_vitals() -> dict:
    """
    GET /latest from brain.py
    Returns latest averaged window vitals.
    """
    try:
        res = requests.get(f"{BRAIN_API}/latest", timeout=10)
        if res.status_code == 200:
            return res.json()
    except Exception as e:
        print(f"  Fetch error: {e}")
    return {}


# ============================================================
# Main RL loop
# ============================================================
def run():
    print("=" * 50)
    print("RL Agent — Polar H10 → TouchDesigner")
    print(f"OSC target: {TD_IP}:{TD_PORT}")
    print(f"Brain API:  {BRAIN_API}")
    print("=" * 50)

    # Init
    q       = load_q_table()
    epsilon = EPSILON
    client  = udp_client.SimpleUDPClient(TD_IP, TD_PORT)

    prev_hr  = None
    prev_hrv = None
    episode  = 0

    print("\nWaiting for first bio window...")

    while True:
        # ── Fetch current vitals ──
        vitals = fetch_latest_vitals()
        if not vitals:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"No vitals yet. Retrying in {POLL_SEC}s...")
            time.sleep(POLL_SEC)
            continue

        curr_hr  = float(vitals.get("avg_hr",  70))
        curr_hrv = float(vitals.get("avg_hrv", 30))
        curr_br  = float(vitals.get("avg_br",  15))

        print(f"\n[{datetime.now().strftime('%H:%M:%S')}] "
              f"HR={curr_hr:.1f} HRV={curr_hrv:.1f} BR={curr_br:.1f}")

        # ── Get state ──
        state = get_state_index(curr_hr, curr_hrv, curr_br)

        # ── Compute reward (needs previous window) ──
        reward = 0.0
        if prev_hr is not None and prev_hrv is not None:
            reward = compute_reward(prev_hr, curr_hr, prev_hrv, curr_hrv)
            print(f"  Reward: {reward:+.3f} "
                  f"(ΔHRV={curr_hrv-prev_hrv:+.1f} "
                  f"ΔHR={curr_hr-prev_hr:+.1f})")

        # ── Select action ──
        action = select_action(q, state, epsilon)

        # ── Send to TouchDesigner ──
        send_osc_action(client, action, curr_hr, curr_hrv, curr_br, reward)

        # ── Update Q-table (if we have previous state) ──
        if prev_hr is not None:
            prev_state = get_state_index(prev_hr, prev_hrv, curr_br)
            q = update_q(q, prev_state, action, reward, state)
            save_q_table(q)

            episode += 1
            epsilon  = max(EPSILON_MIN, epsilon * EPSILON_DECAY)

            print(f"  Episode {episode} | "
                  f"ε={epsilon:.3f} | "
                  f"Q[{prev_state},{action}]={q[prev_state,action]:.3f}")

        # ── Print Q-table summary ──
        if episode % 10 == 0 and episode > 0:
            print("\n  Q-table best actions per state:")
            for s in range(N_STATES):
                best_a = int(np.argmax(q[s]))
                best_q = float(np.max(q[s]))
                if best_q != 0:
                    print(f"    state {s:2d} → "
                          f"action {best_a} "
                          f"({ACTION_NAMES[best_a]}) "
                          f"Q={best_q:.3f}")

        # ── Store previous ──
        prev_hr  = curr_hr
        prev_hrv = curr_hrv

        time.sleep(POLL_SEC)


if __name__ == "__main__":
    run()