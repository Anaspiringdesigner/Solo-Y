# rl_agent_dqn_latent.py
# DQN RL agent on latent z(t)
# - Loads latent from brain_tcn.py /latest
# - Sends OSC to TouchDesigner
# - Learns with replay + target network
# - Checkpoint save/load
# - Action smoothing (hold + optional gating)
#
# Requirements:
#   pip install numpy requests python-osc tensorflow

import os
import time
import csv
import random
from pathlib import Path
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

# Polling
POLL_SEC = 2  # fast loop; duplicate-window guard prevents fake steps

# State/action
LATENT_DIM = 32
N_ACTIONS = 6

# DQN
GAMMA = 0.99
LR = 1e-3
BATCH_SIZE = 32
REPLAY_SIZE = 10000
MIN_REPLAY = 128
TARGET_UPDATE_EVERY = 100

# Exploration
EPSILON_START = 1.0
EPSILON_MIN = 0.05
EPSILON_DECAY = 0.995

# Reward
ALPHA_HRV = 0.6
BETA_HR = 0.4

# Action smoothing / hysteresis
ACTION_HOLD_STEPS = 2  # minimum steps to hold selected action
CHANGE_Q_MARGIN = 0.05  # require new action Q to exceed held action Q by this margin to switch (during exploit)

# Logging + checkpoints
RUN_DIR = Path("rl_runs")
RUN_DIR.mkdir(exist_ok=True)

LOG_PATH = RUN_DIR / "rl_log.csv"
CKPT_PATH = RUN_DIR / "dqn_ckpt.weights.h5"
TARGET_CKPT_PATH = RUN_DIR / "dqn_target_ckpt.weights.h5"
META_PATH = RUN_DIR / "rl_meta.npz"

BEST_CKPT_PATH = RUN_DIR / "dqn_best.weights.h5"
BEST_META_PATH = RUN_DIR / "rl_best_meta.npz"

SAVE_EVERY_STEPS = 200
BEST_EMA_ALPHA = 0.02  # EMA smoothing for reward
BEST_MIN_STEPS = 500   # only start "best model" tracking after this many steps

# ============================================================
# TouchDesigner action mapping
# ============================================================
ACTION_PARAMS = {
    0: {"speed": 0.01, "hue": 0.60, "blur": 20, "contrast": 0.5},  # deep calm
    1: {"speed": 0.01, "hue": 0.10, "blur": 20, "contrast": 0.5},  # gentle warm
    2: {"speed": 0.01, "hue": 0.60, "blur": 10, "contrast": 1.0},  # soft focus
    3: {"speed": 0.05, "hue": 0.60, "blur": 20, "contrast": 0.5},  # light engage
    4: {"speed": 0.05, "hue": 0.10, "blur": 20, "contrast": 0.5},  # gentle alert
    5: {"speed": 0.05, "hue": 0.60, "blur": 10, "contrast": 1.0},  # active focus
}
ACTION_NAMES = {
    0: "Deep Calm",
    1: "Gentle Warm",
    2: "Soft Focus",
    3: "Light Engage",
    4: "Gentle Alert",
    5: "Active Focus",
}

# ============================================================
# Helpers
# ============================================================
def compute_reward(hr_prev, hr_curr, hrv_prev, hrv_curr):
    """
    reward = alpha * delta_hrv_norm + beta * (-delta_hr_norm)
    clipped to [-1, +1]
    """
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
        print(f"  Fetch error: {e}")
    return {}


def build_q_net(latent_dim, n_actions, lr):
    inp = keras.Input(shape=(latent_dim,), name="z")
    x = layers.Dense(128, activation="relu")(inp)
    x = layers.Dense(128, activation="relu")(x)
    out = layers.Dense(n_actions, activation=None, name="q_values")(x)
    model = keras.Model(inp, out, name="DQN")
    model.compile(optimizer=keras.optimizers.Adam(learning_rate=lr), loss="mse")
    return model


def greedy_action_and_qs(q_net, z):
    qvals = q_net.predict(z[np.newaxis, :], verbose=0)[0]
    a = int(np.argmax(qvals))
    return a, qvals


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


def train_step(q_net, target_net, replay, batch_size, gamma):
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
    target[np.arange(batch_size), a] = r + (1.0 - done) * gamma * max_next

    q_net.train_on_batch(s, target)


def init_log(path: Path):
    if path.exists():
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "timestamp", "step", "window_end_time",
            "mode", "action", "action_name",
            "epsilon", "reward", "reward_ema",
            "avg_hr", "avg_hrv", "avg_br",
            "replay_size", "trained_now"
        ])


def append_log(path: Path, row: list):
    with open(path, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(row)


# ============================================================
# Checkpoint I/O
# ============================================================
def save_checkpoint(q_net, target_net, step, epsilon, best_ema, ema_reward):
    q_net.save_weights(CKPT_PATH)
    target_net.save_weights(TARGET_CKPT_PATH)
    np.savez(
        META_PATH,
        step=np.int64(step),
        epsilon=np.float32(epsilon),
        best_ema=np.float32(best_ema),
        ema_reward=np.float32(ema_reward),
    )
    print(f"  [CKPT] Saved @ step={step} eps={epsilon:.3f} ema={ema_reward:.4f}")


def try_load_checkpoint(q_net, target_net):
    if CKPT_PATH.exists() and TARGET_CKPT_PATH.exists() and META_PATH.exists():
        q_net.load_weights(CKPT_PATH)
        target_net.load_weights(TARGET_CKPT_PATH)
        meta = np.load(META_PATH)
        step = int(meta["step"])
        epsilon = float(meta["epsilon"])
        best_ema = float(meta["best_ema"])
        ema_reward = float(meta["ema_reward"])
        print(f"[CKPT] Loaded checkpoint step={step} eps={epsilon:.3f} ema={ema_reward:.4f}")
        return step, epsilon, best_ema, ema_reward
    return 0, EPSILON_START, -1e9, 0.0


def maybe_save_best(q_net, step, ema_reward, best_ema):
    if step < BEST_MIN_STEPS:
        return best_ema
    if ema_reward > best_ema:
        q_net.save_weights(BEST_CKPT_PATH)
        np.savez(BEST_META_PATH, step=np.int64(step), ema_reward=np.float32(ema_reward))
        print(f"  [BEST] New best EMA reward={ema_reward:.4f} @ step={step}")
        return ema_reward
    return best_ema


# ============================================================
# Main
# ============================================================
def run():
    print("=" * 80)
    print("DQN RL Agent on latent z(t)  |  Checkpoints + Smoothing")
    print(f"Brain API     : {BRAIN_API}")
    print(f"OSC target    : {TD_IP}:{TD_PORT}")
    print(f"Poll          : {POLL_SEC}s")
    print(f"Checkpoint    : {CKPT_PATH}")
    print(f"CSV log       : {LOG_PATH}")
    print("=" * 80)

    random.seed(42)
    np.random.seed(42)
    tf.random.set_seed(42)

    init_log(LOG_PATH)

    client = udp_client.SimpleUDPClient(TD_IP, TD_PORT)

    q_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)
    target_net = build_q_net(LATENT_DIM, N_ACTIONS, LR)

    # initialize target from q
    target_net.set_weights(q_net.get_weights())

    # load if available
    step, epsilon, best_ema, ema_reward = try_load_checkpoint(q_net, target_net)

    replay = deque(maxlen=REPLAY_SIZE)

    prev_z = None
    prev_hr = None
    prev_hrv = None
    prev_action = None

    last_end_time = None
    held_action = None
    hold_counter = 0

    print("\nWaiting for first latent window from /latest...")

    while True:
        latest = fetch_latest()
        if not latest or "z" not in latest:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] no latent yet")
            time.sleep(POLL_SEC)
            continue

        curr_end_time = latest.get("end_time")
        if curr_end_time is None:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] latest missing end_time")
            time.sleep(POLL_SEC)
            continue

        # Duplicate-window guard
        if curr_end_time == last_end_time:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] duplicate window, waiting...")
            time.sleep(POLL_SEC)
            continue
        last_end_time = curr_end_time

        z = np.array(latest["z"], dtype=np.float32)
        if z.shape[0] != LATENT_DIM:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] latent mismatch got={z.shape[0]} expected={LATENT_DIM}")
            time.sleep(POLL_SEC)
            continue

        hr = float(latest.get("avg_hr", 70.0))
        hrv = float(latest.get("avg_hrv", 30.0))
        br = float(latest.get("avg_br", 15.0))

        reward = 0.0
        if prev_hr is not None and prev_hrv is not None:
            reward = compute_reward(prev_hr, hr, prev_hrv, hrv)

        # EMA reward for monitoring / best model tracking
        ema_reward = (1.0 - BEST_EMA_ALPHA) * ema_reward + BEST_EMA_ALPHA * reward

        # Store transition from previous step
        if prev_z is not None and prev_action is not None:
            replay.append((prev_z, prev_action, reward, z, 0.0))

        # Action selection with smoothing/hysteresis
        if held_action is None or hold_counter <= 0:
            # epsilon-greedy
            if random.random() < epsilon:
                action = random.randint(0, N_ACTIONS - 1)
                mode = "explore"
            else:
                greedy_a, qvals = greedy_action_and_qs(q_net, z)
                action = greedy_a
                mode = "exploit"

                # optional gating: only switch if clearly better than current held action
                if held_action is not None:
                    held_q = float(qvals[held_action])
                    new_q = float(qvals[greedy_a])
                    if (greedy_a != held_action) and (new_q < held_q + CHANGE_Q_MARGIN):
                        action = held_action
                        mode = "exploit_hold_gate"

            held_action = action
            hold_counter = ACTION_HOLD_STEPS
        else:
            action = held_action
            mode = "hold"
        hold_counter -= 1

        # Send to TouchDesigner
        send_osc(client, action, hr, hrv, br, reward)

        # Train
        trained_now = False
        if len(replay) >= MIN_REPLAY:
            train_step(q_net, target_net, replay, BATCH_SIZE, GAMMA)
            trained_now = True

            if step % TARGET_UPDATE_EVERY == 0:
                target_net.set_weights(q_net.get_weights())

            epsilon = max(EPSILON_MIN, epsilon * EPSILON_DECAY)

        # Save best
        best_ema = maybe_save_best(q_net, step, ema_reward, best_ema)

        # Periodic checkpoint
        if step > 0 and step % SAVE_EVERY_STEPS == 0:
            save_checkpoint(q_net, target_net, step, epsilon, best_ema, ema_reward)

        print(
            f"[{datetime.now().strftime('%H:%M:%S')}] "
            f"step={step} end={curr_end_time} mode={mode} "
            f"a={action}({ACTION_NAMES[action]}) eps={epsilon:.3f} "
            f"r={reward:+.3f} ema={ema_reward:+.4f} "
            f"HR={hr:.1f} HRV={hrv:.1f} BR={br:.1f} "
            f"replay={len(replay)} train={'Y' if trained_now else 'N'}"
        )

        append_log(LOG_PATH, [
            datetime.now().isoformat(),
            step,
            curr_end_time,
            mode,
            action,
            ACTION_NAMES[action],
            round(epsilon, 6),
            round(reward, 6),
            round(ema_reward, 6),
            round(hr, 3),
            round(hrv, 3),
            round(br, 3),
            len(replay),
            int(trained_now),
        ])

        # Update prev
        prev_z = z
        prev_hr = hr
        prev_hrv = hrv
        prev_action = action

        step += 1
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    run()