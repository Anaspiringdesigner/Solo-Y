# rl_agent_dqn_latent.py
# DQN on latent z(t) from brain_tcn.py

import time
import random
import csv
from pathlib import Path
from collections import deque
from datetime import datetime

import numpy as np
import requests
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from pythonosc import udp_client

BRAIN_API = "http://127.0.0.1:8000"
TD_IP = "127.0.0.1"
TD_PORT = 7000

POLL_SEC = 2
LATENT_DIM = 32
N_ACTIONS = 6

GAMMA = 0.99
LR = 1e-3
BATCH_SIZE = 32
REPLAY_SIZE = 5000
MIN_REPLAY = 64
TARGET_UPDATE_EVERY = 100

EPSILON_START = 1.0
EPSILON_MIN = 0.05
EPSILON_DECAY = 0.995

ALPHA_HRV = 0.6
BETA_HR = 0.4

ACTION_HOLD_STEPS = 1
LOG_PATH = Path("rl_log.csv")

ACTION_PARAMS = {
    0: {"speed": 0.01, "hue": 0.60, "blur": 20, "contrast": 0.5},
    1: {"speed": 0.01, "hue": 0.10, "blur": 20, "contrast": 0.5},
    2: {"speed": 0.01, "hue": 0.60, "blur": 10, "contrast": 1.0},
    3: {"speed": 0.05, "hue": 0.60, "blur": 20, "contrast": 0.5},
    4: {"speed": 0.05, "hue": 0.10, "blur": 20, "contrast": 0.5},
    5: {"speed": 0.05, "hue": 0.60, "blur": 10, "contrast": 1.0},
}
ACTION_NAMES = {
    0: "Deep Calm", 1: "Gentle Warm", 2: "Soft Focus",
    3: "Light Engage", 4: "Gentle Alert", 5: "Active Focus"
}

def compute_reward(hr_prev, hr_curr, hrv_prev, hrv_curr):
    delta_hrv = np.clip((hrv_curr - hrv_prev) / (abs(hrv_prev) + 1e-6), -1, 1)
    delta_hr = np.clip((hr_curr - hr_prev) / (abs(hr_prev) + 1e-6), -1, 1)
    reward = ALPHA_HRV * delta_hrv + BETA_HR * (-delta_hr)
    return float(np.clip(reward, -1.0, 1.0))

def fetch_latest():
    try:
        r = requests.get(f"{BRAIN_API}/latest", timeout=5)
        if r.status_code == 200:
            return r.json()
    except Exception as e:
        print(f"Fetch error: {e}")
    return {}

def build_q_net(latent_dim, n_actions, lr):
    inp = keras.Input(shape=(latent_dim,))
    x = layers.Dense(128, activation="relu")(inp)
    x = layers.Dense(128, activation="relu")(x)
    out = layers.Dense(n_actions)(x)
    m = keras.Model(inp, out)
    m.compile(optimizer=keras.optimizers.Adam(learning_rate=lr), loss="mse")
    return m

def select_action(q_net, z, epsilon):
    if random.random() < epsilon:
        return random.randint(0, N_ACTIONS - 1), "explore"
    qvals = q_net.predict(z[np.newaxis], verbose=0)[0]
    return int(np.argmax(qvals)), "exploit"

def send_osc(client, action, hr, hrv, br, reward):
    p = ACTION_PARAMS[action]
    client.send_message("/rl/speed", float(p["speed"]))
    client.send_message("/rl/hue", float(p["hue"]))
    client.send_message("/rl/blur", float(p["blur"]))
    client.send_message("/rl/contrast", float(p["contrast"]))
    client.send_message("/rl/hr", float(hr))
    client.send_message("/rl/hrv", float(hrv))
    client.send_message("/rl/br", float(br))
    client.send_message("/rl/reward", float(reward))

def train_step(q_net, target_net, replay, batch_size):
    batch = random.sample(replay, batch_size)
    s = np.array([b[0] for b in batch], dtype=np.float32)
    a = np.array([b[1] for b in batch], dtype=np.int64)
    r = np.array([b[2] for b in batch], dtype=np.float32)
    s2 = np.array([b[3] for b in batch], dtype=np.float32)
    d = np.array([b[4] for b in batch], dtype=np.float32)

    q = q_net.predict(s, verbose=0)
    qn = target_net.predict(s2, verbose=0)
    mx = np.max(qn, axis=1)

    tgt = q.copy()
    tgt[np.arange(batch_size), a] = r + (1.0 - d) * GAMMA * mx
    q_net.train_on_batch(s, tgt)

def init_log(path: Path):
    if path.exists():
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "timestamp", "step", "end_time", "mode",
            "action", "action_name", "epsilon", "reward",
            "avg_hr", "avg_hrv", "avg_br", "replay"
        ])

def append_log(path: Path, row):
    with open(path, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(row)

def run():
    print("DQN RL Agent (fast loop, duplicate guard)")
    client = udp_client.SimpleUDPClient(TD_IP, TD_PORT)

    random.seed(42)
    np.random.seed(42)
    tf.random.set_seed(42)

    init_log(LOG_PATH)

    q_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)
    target_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)
    target_net.set_weights(q_net.get_weights())

    replay = deque(maxlen=REPLAY_SIZE)

    epsilon = EPSILON_START
    step = 0
    last_end = None

    prev_z = None
    prev_hr = None
    prev_hrv = None
    prev_action = None

    held_action = None
    hold_counter = 0

    while True:
        latest = fetch_latest()
        if not latest or "z" not in latest:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] no latent yet")
            time.sleep(POLL_SEC)
            continue

        end_time = latest.get("end_time")
        if end_time is None:
            time.sleep(POLL_SEC)
            continue

        if end_time == last_end:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] duplicate window, waiting...")
            time.sleep(POLL_SEC)
            continue
        last_end = end_time

        z = np.array(latest["z"], dtype=np.float32)
        if z.shape[0] != LATENT_DIM:
            print(f"latent mismatch: {z.shape[0]}")
            time.sleep(POLL_SEC)
            continue

        hr = float(latest.get("avg_hr", 70))
        hrv = float(latest.get("avg_hrv", 30))
        br = float(latest.get("avg_br", 14))

        reward = 0.0
        if prev_hr is not None and prev_hrv is not None:
            reward = compute_reward(prev_hr, hr, prev_hrv, hrv)

        if prev_z is not None and prev_action is not None:
            replay.append((prev_z, prev_action, reward, z, 0.0))

        if held_action is None or hold_counter <= 0:
            action, mode = select_action(q_net, z, epsilon)
            held_action = action
            hold_counter = ACTION_HOLD_STEPS
        else:
            action = held_action
            mode = "hold"
        hold_counter -= 1

        send_osc(client, action, hr, hrv, br, reward)

        trained = False
        if len(replay) >= MIN_REPLAY:
            train_step(q_net, target_net, replay, BATCH_SIZE)
            trained = True
            if step % TARGET_UPDATE_EVERY == 0:
                target_net.set_weights(q_net.get_weights())
            epsilon = max(EPSILON_MIN, epsilon * EPSILON_DECAY)

        print(
            f"[{datetime.now().strftime('%H:%M:%S')}] step={step} end={end_time} "
            f"mode={mode} a={action}({ACTION_NAMES[action]}) eps={epsilon:.3f} "
            f"r={reward:+.3f} HR={hr:.1f} HRV={hrv:.1f} BR={br:.1f} "
            f"replay={len(replay)} train={'Y' if trained else 'N'}"
        )

        append_log(LOG_PATH, [
            datetime.now().isoformat(), step, end_time, mode,
            action, ACTION_NAMES[action], round(epsilon, 6), round(reward, 6),
            round(hr, 3), round(hrv, 3), round(br, 3), len(replay)
        ])

        prev_z = z
        prev_hr = hr
        prev_hrv = hrv
        prev_action = action
        step += 1
        time.sleep(POLL_SEC)

if __name__ == "__main__":
    run()