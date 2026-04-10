# rl_agent_dqn_latent.py
# pip install numpy requests python-osc tensorflow
import time
import random
from collections import deque
from datetime import datetime

import numpy as np
import requests
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from pythonosc import udp_client

# ============================================================
# Config
# ============================================================
BRAIN_API = "http://127.0.0.1:8000"
TD_IP = "127.0.0.1"
TD_PORT = 7000

POLL_SEC = 10
LATENT_DIM = 32
N_ACTIONS = 6

# DQN hyperparams
GAMMA = 0.99
LR = 1e-3
BATCH_SIZE = 64
REPLAY_SIZE = 5000
MIN_REPLAY = 500
TARGET_UPDATE_EVERY = 100

EPSILON = 1.0
EPSILON_MIN = 0.05
EPSILON_DECAY = 0.998

# Reward weights
ALPHA_HRV = 0.6
BETA_HR = 0.4

ACTION_PARAMS = {
    0: {"speed": 0.01, "hue": 0.60, "blur": 20, "contrast": 0.5},
    1: {"speed": 0.01, "hue": 0.10, "blur": 20, "contrast": 0.5},
    2: {"speed": 0.01, "hue": 0.60, "blur": 10, "contrast": 1.0},
    3: {"speed": 0.05, "hue": 0.60, "blur": 20, "contrast": 0.5},
    4: {"speed": 0.05, "hue": 0.10, "blur": 20, "contrast": 0.5},
    5: {"speed": 0.05, "hue": 0.60, "blur": 10, "contrast": 1.0},
}

# ============================================================
# Helpers
# ============================================================
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
        print("fetch error:", e)
    return {}

def build_q_net(latent_dim, n_actions, lr):
    inp = keras.Input(shape=(latent_dim,))
    x = layers.Dense(128, activation="relu")(inp)
    x = layers.Dense(128, activation="relu")(x)
    out = layers.Dense(n_actions, activation=None)(x)
    model = keras.Model(inp, out)
    model.compile(optimizer=keras.optimizers.Adam(lr), loss="mse")
    return model

def select_action(q_net, z, epsilon):
    if random.random() < epsilon:
        return random.randint(0, N_ACTIONS - 1), "explore"
    qvals = q_net.predict(z[np.newaxis, :], verbose=0)[0]
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

# ============================================================
# Train step
# ============================================================
def train_step(q_net, target_net, replay, batch_size):
    batch = random.sample(replay, batch_size)

    s = np.array([b[0] for b in batch], dtype=np.float32)
    a = np.array([b[1] for b in batch], dtype=np.int64)
    r = np.array([b[2] for b in batch], dtype=np.float32)
    s2 = np.array([b[3] for b in batch], dtype=np.float32)
    done = np.array([b[4] for b in batch], dtype=np.float32)

    q = q_net.predict(s, verbose=0)
    q_next = target_net.predict(s2, verbose=0)
    max_next = np.max(q_next, axis=1)

    target = q.copy()
    target[np.arange(batch_size), a] = r + (1.0 - done) * GAMMA * max_next

    q_net.train_on_batch(s, target)

# ============================================================
# Main
# ============================================================
def run():
    print("DQN RL Agent on latent z(t)")
    client = udp_client.SimpleUDPClient(TD_IP, TD_PORT)

    q_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)
    target_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)
    target_net.set_weights(q_net.get_weights())

    replay = deque(maxlen=REPLAY_SIZE)

    epsilon = EPSILON
    step = 0

    prev_z = None
    prev_hr = None
    prev_hrv = None
    prev_action = None

    while True:
        latest = fetch_latest()
        if not latest or "z" not in latest:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] no latent yet")
            time.sleep(POLL_SEC)
            continue

        z = np.array(latest["z"], dtype=np.float32)
        hr = float(latest.get("avg_hr", 70.0))
        hrv = float(latest.get("avg_hrv", 30.0))
        br = float(latest.get("avg_br", 15.0))

        reward = 0.0
        if prev_hr is not None and prev_hrv is not None:
            reward = compute_reward(prev_hr, hr, prev_hrv, hrv)

        # store transition from previous step
        if prev_z is not None and prev_action is not None:
            replay.append((prev_z, prev_action, reward, z, 0.0))

        action, mode = select_action(q_net, z, epsilon)
        send_osc(client, action, hr, hrv, br, reward)

        print(f"[{datetime.now().strftime('%H:%M:%S')}] step={step} "
              f"mode={mode} a={action} eps={epsilon:.3f} r={reward:+.3f} "
              f"HR={hr:.1f} HRV={hrv:.1f} BR={br:.1f}")

        # train
        if len(replay) >= MIN_REPLAY:
            train_step(q_net, target_net, replay, BATCH_SIZE)

            if step % TARGET_UPDATE_EVERY == 0:
                target_net.set_weights(q_net.get_weights())

            epsilon = max(EPSILON_MIN, epsilon * EPSILON_DECAY)

        prev_z = z
        prev_hr = hr
        prev_hrv = hrv
        prev_action = action

        step += 1
        time.sleep(POLL_SEC)

if __name__ == "__main__":
    run()

curr_end_time = latest.get("end_time", None)
if curr_end_time is None:
    time.sleep(POLL_SEC)
    continue

if "last_end_time" not in run.__dict__:
    run.last_end_time = None

if run.last_end_time == curr_end_time:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] same window, waiting...")
    time.sleep(POLL_SEC)
    continue

run.last_end_time = curr_end_time