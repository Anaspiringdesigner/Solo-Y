# rl_agent.py
# Q-Learning RL agent
# State:   discretised HR + HRV + BR
# Action:  6 visual parameter sets → TouchDesigner
# Reward:  HRV up + HR down = calm and focused
#
# pip install numpy requests python-osc

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
TD_IP        = "127.0.0.1"
TD_PORT      = 7000
POLL_SEC     = 120
Q_TABLE_PATH = Path("q_table.json")

# Q-learning hyperparameters
ALPHA         = 0.1
GAMMA         = 0.9
EPSILON       = 0.3
EPSILON_MIN   = 0.05
EPSILON_DECAY = 0.995

N_STATES  = 27   # 3 bins × 3 vitals
N_ACTIONS = 6

# Reward weights
ALPHA_HRV = 0.6
BETA_HR   = 0.4

# ── Bin edges ──
# Adjust to YOUR personal ranges after first session
HR_BINS  = [60, 80]    # low < 60 | mid 60-80 | high > 80
HRV_BINS = [20, 50]    # low < 20 | mid 20-50 | high > 50
BR_BINS  = [12, 18]    # low < 12 | mid 12-18 | high > 18

# ── Action space ──
# Each action is a set of visual parameters sent to TouchDesigner
# (speed, hue, blur, contrast)
#
# speed    → how fast the fluid moves    (low = calm)
# hue      → colour temperature          (0.6 = blue/cool, 0.1 = red/warm)
# blur     → smoothness of the fluid     (high = smooth)
# contrast → harshness of the visual     (low = soft)
#
ACTION_PARAMS = {
    0: {"speed": 0.01, "hue": 0.60, "blur": 20, "contrast": 0.5},  # deep calm
    1: {"speed": 0.01, "hue": 0.10, "blur": 20, "contrast": 0.5},  # gentle warm
    2: {"speed": 0.01, "hue": 0.60, "blur": 10, "contrast": 1.0},  # soft focus
    3: {"speed": 0.05, "hue": 0.60, "blur": 20, "contrast": 0.5},  # light engage
    4: {"speed": 0.05, "hue": 0.10, "blur": 20, "contrast": 0.5},  # gentle alert
    5: {"speed": 0.05, "hue": 0.60, "blur": 10, "contrast": 1.0},  # active focus
}

ACTION_NAMES = {
    0: "Deep Calm      (slow + cool + smooth)",
    1: "Gentle Warm    (slow + warm + smooth)",
    2: "Soft Focus     (slow + cool + complex)",
    3: "Light Engage   (medium + cool + smooth)",
    4: "Gentle Alert   (medium + warm + smooth)",
    5: "Active Focus   (medium + cool + complex)",
}


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
    print(f"  Q-table saved → {Q_TABLE_PATH}")


# ============================================================
# State discretisation
# ============================================================
def discretise(value: float, bins: list) -> int:
    for i, edge in enumerate(bins):
        if value < edge:
            return i
    return len(bins)


def get_state_index(hr: float, hrv: float, br: float) -> int:
    """
    Maps HR, HRV, BR into a single state index 0-26.
    3 bins each → 3×3×3 = 27 states.
    """
    hr_bin  = discretise(hr,  HR_BINS)
    hrv_bin = discretise(hrv, HRV_BINS)
    br_bin  = discretise(br,  BR_BINS)
    return hr_bin * 9 + hrv_bin * 3 + br_bin


def describe_state(hr: float, hrv: float, br: float) -> str:
    """Human readable state description."""
    hr_label  = "low HR"  if hr  < HR_BINS[0]  else "mid HR"  if hr  < HR_BINS[1]  else "high HR"
    hrv_label = "low HRV" if hrv < HRV_BINS[0] else "mid HRV" if hrv < HRV_BINS[1] else "high HRV"
    br_label  = "low BR"  if br  < BR_BINS[0]  else "mid BR"  if br  < BR_BINS[1]  else "high BR"
    return f"{hr_label} | {hrv_label} | {br_label}"


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
    r(t) = α * ΔHRV_norm + β * (−ΔHR_norm)

    HRV going up   → positive reward
    HR going down  → positive reward
    Clipped to [−1, +1]
    """
    delta_hrv = np.clip(
        (hrv_curr - hrv_prev) / (abs(hrv_prev) + 1e-6), -1, 1
    )
    delta_hr = np.clip(
        (hr_curr - hr_prev) / (abs(hr_prev) + 1e-6), -1, 1
    )
    reward = ALPHA_HRV * delta_hrv + BETA_HR * (-delta_hr)
    return float(np.clip(reward, -1.0, 1.0))


# ============================================================
# Action selection
# ============================================================
def select_action(q: np.ndarray, state: int, epsilon: float) -> int:
    """ε-greedy: explore randomly or exploit best known action."""
    if np.random.random() < epsilon:
        action = np.random.randint(N_ACTIONS)
        print(f"  Exploring → random action {action}")
        return action
    action = int(np.argmax(q[state]))
    print(f"  Exploiting → best action {action}")
    return action


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
    Q(s,a) ← Q(s,a) + α[r + γ·maxQ(s',a') − Q(s,a)]
    """
    best_next        = float(np.max(q[next_state]))
    current_q        = q[state, action]
    q[state, action] = current_q + ALPHA * (
        reward + GAMMA * best_next - current_q
    )
    return q


# ============================================================
# OSC → TouchDesigner
# ============================================================
def send_osc_action(
    client: udp_client.SimpleUDPClient,
    action: int,
    hr:     float,
    hrv:    float,
    br:     float,
    reward: float,
):
    """
    Send visual parameters to TouchDesigner via OSC.

    TouchDesigner listens for:
      /rl/speed     float   fluid movement speed
      /rl/hue       float   colour temperature
      /rl/blur      float   smoothness
      /rl/contrast  float   harshness
      /rl/hr        float   current HR
      /rl/hrv       float   current HRV
      /rl/br        float   current BR
      /rl/reward    float   last reward
    """
    params = ACTION_PARAMS[action]

    client.send_message("/rl/speed",    float(params["speed"]))
    client.send_message("/rl/hue",      float(params["hue"]))
    client.send_message("/rl/blur",     float(params["blur"]))
    client.send_message("/rl/contrast", float(params["contrast"]))
    client.send_message("/rl/hr",       float(hr))
    client.send_message("/rl/hrv",      float(hrv))
    client.send_message("/rl/br",       float(br))
    client.send_message("/rl/reward",   float(reward))

    print(f"  OSC → TD:")
    print(f"    action   = {action} ({ACTION_NAMES[action]})")
    print(f"    speed    = {params['speed']}")
    print(f"    hue      = {params['hue']}")
    print(f"    blur     = {params['blur']}")
    print(f"    contrast = {params['contrast']}")
    print(f"    reward   = {reward:+.3f}")


# ============================================================
# Fetch latest vitals from brain.py
# ============================================================
def fetch_latest_vitals() -> dict:
    try:
        res = requests.get(f"{BRAIN_API}/latest", timeout=10)
        if res.status_code == 200:
            return res.json()
    except Exception as e:
        print(f"  Fetch error: {e}")
    return {}


# ============================================================
# Print Q-table summary
# ============================================================
def print_q_summary(q: np.ndarray):
    print("\n  ── Q-table summary ──")
    for s in range(N_STATES):
        best_a = int(np.argmax(q[s]))
        best_q = float(np.max(q[s]))
        if best_q != 0:
            print(f"    state {s:2d} → "
                  f"action {best_a} | "
                  f"{ACTION_NAMES[best_a]} | "
                  f"Q={best_q:.3f}")
    print("  ─────────────────────\n")


# ============================================================
# Main RL loop
# ============================================================
def run():
    print("=" * 60)
    print("RL Agent — Polar H10 → TouchDesigner")
    print(f"OSC target : {TD_IP}:{TD_PORT}")
    print(f"Brain API  : {BRAIN_API}")
    print(f"Poll every : {POLL_SEC}s")
    print("=" * 60)

    q       = load_q_table()
    epsilon = EPSILON
    client  = udp_client.SimpleUDPClient(TD_IP, TD_PORT)

    prev_hr    = None
    prev_hrv   = None
    prev_state = None
    prev_action = None
    episode    = 0

    print("\nWaiting for first bio window from polar_reader...")

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
        curr_state_name = vitals.get("state_name", "Unknown")

        print(f"\n{'='*60}")
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Episode {episode + 1}")
        print(f"  Brain state : {curr_state_name}")
        print(f"  HR={curr_hr:.1f}  HRV={curr_hrv:.1f}  BR={curr_br:.1f}")
        print(f"  {describe_state(curr_hr, curr_hrv, curr_br)}")

        # ── Get state index ──
        curr_state = get_state_index(curr_hr, curr_hrv, curr_br)
        print(f"  State index : {curr_state}")

        # ── Compute reward ──
        reward = 0.0
        if prev_hr is not None and prev_hrv is not None:
            reward = compute_reward(prev_hr, curr_hr, prev_hrv, curr_hrv)
            print(f"  Reward      : {reward:+.3f} "
                  f"(ΔHRV={curr_hrv - prev_hrv:+.1f} "
                  f"ΔHR={curr_hr - prev_hr:+.1f})")

        # ── Update Q-table from previous step ──
        if prev_state is not None and prev_action is not None:
            q = update_q(q, prev_state, prev_action, reward, curr_state)
            save_q_table(q)
            epsilon = max(EPSILON_MIN, epsilon * EPSILON_DECAY)
            episode += 1
            print(f"  Epsilon     : {epsilon:.3f}")

        # ── Select action ──
        action = select_action(q, curr_state, epsilon)

        # ── Send to TouchDesigner ──
        send_osc_action(client, action, curr_hr, curr_hrv, curr_br, reward)

        # ── Print Q summary every 10 episodes ──
        if episode > 0 and episode % 10 == 0:
            print_q_summary(q)

        # ── Store for next step ──
        prev_hr     = curr_hr
        prev_hrv    = curr_hrv
        prev_state  = curr_state
        prev_action = action

        print(f"  Waiting {POLL_SEC}s for next window...")
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    run()