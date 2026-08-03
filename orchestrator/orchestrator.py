#!/usr/bin/env python3
"""
AjipIDM multi-account rotation orchestrator.

MT5 has no API to switch a running EA's own account, so the rotation
happens at the TERMINAL level instead: this script keeps ONE MT5 terminal
logged into ONE account at a time (the EA trades normally on whichever
account is currently active). When that account's EA hits its daily
target/max-loss, it writes a handoff signal file to the terminal's shared
Common\\Files folder (see AjipIDM_Trade.mqh:WriteHandoffSignal). This script
polls for that file, waits until the account is genuinely flat (defense in
depth — the EA already closes everything itself), then calls mt5.login()
to move to the next account in rotation.

Setup:
    pip install -r requirements.txt
    cp accounts.example.json accounts.json   # fill in real credentials
    python orchestrator.py

accounts.json and state.json are gitignored — they hold live credentials
and runtime state and must never be committed.
"""

import csv
import datetime
import json
import os
import sys
import time

import MetaTrader5 as mt5

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "accounts.json")
STATE_PATH = os.path.join(os.path.dirname(__file__), "state.json")
LIVE_STATUS_PATH = os.path.join(os.path.dirname(__file__), "live_status.json")
HANDOFF_HISTORY_PATH = os.path.join(os.path.dirname(__file__), "handoff_history.csv")

DEFAULT_POLL_INTERVAL_SECONDS = 5
DEFAULT_HANDOFF_FILENAME = "AjipIDM_Handoff.csv"
FLAT_WAIT_WARN_INTERVAL_SECONDS = 30

HANDOFF_HISTORY_HEADER = "handled_at,login,reason,pnl,symbol,magic,event_time,outcome,next_login\n"


def load_config(path):
    with open(path, "r") as f:
        cfg = json.load(f)

    accounts = cfg["accounts"]
    if not accounts:
        raise ValueError("accounts.json: 'accounts' list is empty")

    cfg.setdefault("poll_interval_seconds", DEFAULT_POLL_INTERVAL_SECONDS)
    cfg.setdefault("handoff_filename", DEFAULT_HANDOFF_FILENAME)
    cfg.setdefault("mt5_terminal_path", None)
    return cfg


def load_state():
    if not os.path.exists(STATE_PATH):
        return {"current_index": 0, "maxed_today": {}}
    with open(STATE_PATH, "r") as f:
        return json.load(f)


def save_state(state):
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)


def today_str():
    # Local system date. If this differs from the broker/prop-firm's own
    # daily reset boundary (server timezone), adjust to taste — this is a
    # deliberate V1 simplification, not a broker-time lookup.
    return datetime.date.today().isoformat()


def parse_handoff_file(path):
    data = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()
    return data


def common_files_dir():
    info = mt5.terminal_info()
    if info is None:
        raise RuntimeError(f"terminal_info() failed: {mt5.last_error()}")
    return os.path.join(info.commondata_path, "Files")


def mt5_login(account, terminal_path):
    login = int(account["login"])
    password = account["password"]
    server = account["server"]

    # initialize() connects to (launching if needed) the terminal itself —
    # safe to call again on an already-connected terminal. login() is the
    # separate step that authenticates/switches the account on that
    # connection, and is what actually performs the account rotation.
    if not mt5.initialize(path=terminal_path):
        print(f"[orchestrator] mt5.initialize() failed: {mt5.last_error()}", flush=True)
        return False

    if not mt5.login(login, password=password, server=server):
        print(f"[orchestrator] LOGIN FAILED for {login}@{server}: {mt5.last_error()}", flush=True)
        return False

    info = mt5.account_info()
    print(f"[orchestrator] Logged in: {info.login}@{info.server} "
          f"balance={info.balance:.2f} equity={info.equity:.2f}", flush=True)
    return True


def write_live_status(accounts, state):
    # Best-effort snapshot for the dashboard (a separate process with no MT5
    # connection of its own) to read. Swallows errors so a transient API
    # hiccup here never takes down the rotation loop itself — the dashboard
    # just shows a stale "updated_at" if this keeps failing.
    try:
        info = mt5.account_info()
        if info is None:
            return

        positions = mt5.positions_get() or []
        positions_payload = [
            {
                "symbol": p.symbol,
                "type": "BUY" if p.type == mt5.ORDER_TYPE_BUY else "SELL",
                "volume": p.volume,
                "profit": p.profit,
                "open_time": datetime.datetime.fromtimestamp(p.time).isoformat(),
            }
            for p in positions
        ]

        payload = {
            "updated_at": datetime.datetime.now().isoformat(),
            "files_dir": common_files_dir(),
            "current_login": info.login,
            "current_server": info.server,
            "balance": info.balance,
            "equity": info.equity,
            "floating_pnl": info.profit,
            "positions": positions_payload,
            "rotation_index": state["current_index"],
            "rotation_size": len(accounts),
        }
        tmp_path = LIVE_STATUS_PATH + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp_path, LIVE_STATUS_PATH)  # atomic — dashboard never sees a half-written file
    except Exception as exc:
        print(f"[orchestrator] WARNING: write_live_status failed: {exc}", flush=True)


def append_handoff_history(data, outcome, next_login):
    # Persistent audit trail — the handoff signal file itself is deleted
    # right after being read (see handle_handoff), so without this every
    # target/max-loss event would leave no trace for the dashboard to show.
    is_new = not os.path.exists(HANDOFF_HISTORY_PATH)
    with open(HANDOFF_HISTORY_PATH, "a", newline="") as f:
        writer = csv.writer(f)
        if is_new:
            f.write(HANDOFF_HISTORY_HEADER)
        writer.writerow([
            datetime.datetime.now().isoformat(),
            data.get("login", ""),
            data.get("reason", ""),
            data.get("pnl", ""),
            data.get("symbol", ""),
            data.get("magic", ""),
            data.get("time", ""),
            outcome,
            next_login,
        ])


def positions_count(symbol_filter=None, magic_filter=None):
    positions = mt5.positions_get(symbol=symbol_filter) if symbol_filter else mt5.positions_get()
    if positions is None:
        return 0
    if magic_filter is not None:
        positions = [p for p in positions if p.magic == int(magic_filter)]
    return len(positions)


def wait_until_flat(symbol_filter, magic_filter, poll_interval):
    waited = 0
    while True:
        n = positions_count(symbol_filter, magic_filter)
        if n == 0:
            return
        if waited % FLAT_WAIT_WARN_INTERVAL_SECONDS == 0:
            print(f"[orchestrator] waiting for account to go flat — {n} position(s) still open "
                  f"(EA should be closing them itself)", flush=True)
        time.sleep(poll_interval)
        waited += poll_interval


def pick_next_account(accounts, maxed_logins_today, current_index):
    n = len(accounts)
    for step in range(1, n + 1):
        idx = (current_index + step) % n
        if int(accounts[idx]["login"]) not in maxed_logins_today:
            return idx
    return None  # every account already maxed for today


def handle_handoff(cfg, state, accounts, handoff_path):
    data = parse_handoff_file(handoff_path)
    login = data.get("login")
    reason = data.get("reason", "?")
    pnl = data.get("pnl", "?")
    print(f"[orchestrator] Handoff signal: login={login} reason={reason} pnl={pnl}", flush=True)

    current_account = accounts[state["current_index"]]
    symbol_filter = current_account.get("symbol")
    magic_filter = current_account.get("magic")

    wait_until_flat(symbol_filter, magic_filter, cfg["poll_interval_seconds"])
    print("[orchestrator] Account confirmed flat.", flush=True)

    os.remove(handoff_path)

    day = today_str()
    maxed_today = state["maxed_today"].setdefault(day, [])
    if int(current_account["login"]) not in maxed_today:
        maxed_today.append(int(current_account["login"]))

    next_idx = pick_next_account(accounts, set(maxed_today), state["current_index"])
    if next_idx is None:
        print(f"[orchestrator] All {len(accounts)} accounts have hit their daily limit for {day}. "
              f"Idling until the next day.", flush=True)
        append_handoff_history(data, outcome="ALL_MAXED", next_login="")
        save_state(state)
        return

    next_login = accounts[next_idx]["login"]
    if not mt5_login(accounts[next_idx], cfg["mt5_terminal_path"]):
        print("[orchestrator] Switch failed — will retry on the next loop iteration.", flush=True)
        append_handoff_history(data, outcome="LOGIN_FAILED", next_login=next_login)
        return  # don't advance state.current_index — retry the same target next time

    append_handoff_history(data, outcome="SWITCHED", next_login=next_login)
    state["current_index"] = next_idx
    save_state(state)
    write_live_status(accounts, state)


def main():
    cfg = load_config(CONFIG_PATH)
    state = load_state()
    accounts = cfg["accounts"]

    if state["current_index"] >= len(accounts):
        state["current_index"] = 0

    if not mt5_login(accounts[state["current_index"]], cfg["mt5_terminal_path"]):
        print("[orchestrator] Initial login failed, aborting.", flush=True)
        sys.exit(1)
    save_state(state)
    write_live_status(accounts, state)

    last_seen_day = today_str()
    print(f"[orchestrator] Watching for handoff signal '{cfg['handoff_filename']}' "
          f"every {cfg['poll_interval_seconds']}s.", flush=True)

    try:
        while True:
            day = today_str()
            if day != last_seen_day:
                # New day — everyone gets a fresh daily limit, clear exhaustion tracking.
                print(f"[orchestrator] New day ({day}) — clearing exhausted-accounts list.", flush=True)
                state["maxed_today"].pop(last_seen_day, None)
                last_seen_day = day
                save_state(state)

            handoff_path = os.path.join(common_files_dir(), cfg["handoff_filename"])
            if os.path.exists(handoff_path):
                try:
                    handle_handoff(cfg, state, accounts, handoff_path)
                except Exception as exc:
                    print(f"[orchestrator] ERROR handling handoff: {exc}", flush=True)

            # Live snapshot for the dashboard — every cycle, not just on
            # handoff events, so balance/equity/floating PnL stay current
            # while the account just sits there trading.
            write_live_status(accounts, state)

            time.sleep(cfg["poll_interval_seconds"])
    except KeyboardInterrupt:
        print("[orchestrator] Stopping.", flush=True)
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
