# AjipIDM multi-account rotation orchestrator

Rotates a single MT5 terminal across multiple prop-firm accounts: when the
account currently logged in hits its daily target/max-loss (`InpDailyMaxProfit`
/ `InpDailyMaxLoss` in the EA), it sits out for the rest of the day and the
orchestrator logs the terminal into the next account in the list.

## Why a single terminal, not one per account

MQL5 has no API for an EA to change its own terminal's login. The only way
to move between prop-firm accounts programmatically is at the terminal
level, via the Python `MetaTrader5` package's `mt5.login()` — which is why
this lives outside the EA, in Python.

## How the handoff works

1. The EA (`InpHandoffEnabled = true`) writes `AjipIDM_Handoff.csv` to the
   terminal's shared `Common\Files` folder the moment its daily target/max-loss
   is hit (see `AjipIDM_Trade.mqh:WriteHandoffSignal`).
2. This script polls for that file. When it appears, it double-checks the
   account is actually flat (`positions_get`) before doing anything — the EA
   already closes everything itself, this is just defense in depth.
3. It deletes the signal file, marks that account "done for today", and
   calls `mt5.login()` on the next account in the rotation that hasn't
   already hit its own limit today.
4. If every account in the list has hit its daily limit, the orchestrator
   idles until its local date rolls over, then resets and resumes.

## Setup

```bash
pip install -r requirements.txt
cp accounts.example.json accounts.json
```

Edit `accounts.json`:
- `accounts`: ordered rotation list — `login`, `password`, `server`, and
  optionally `symbol`/`magic` (narrows the flat-check to only this EA's
  positions; omit to require the WHOLE account flat before switching).
- `mt5_terminal_path`: path to `terminal64.exe` (Windows). Leave as the
  default install path or point it at a specific installation.
- `poll_interval_seconds`, `handoff_filename`: must match the EA's
  `InpHandoffFile` input if you change it from the default.

`accounts.json` and `state.json` (runtime rotation position) are gitignored
— they hold live credentials and must never be committed.

## Run

Both the orchestrator and the dashboard together, one command:

```bash
python run.py
```

`run.py` starts both, prefixes each line of output with `[orchestrator]` /
`[dashboard]`, and stops both on Ctrl+C. If one of them crashes it does
**not** take the other down with it — the dashboard shows a "stale"
warning if orchestrator.py dies (so you can still notice remotely), and
orchestrator.py keeps rotating regardless of whether the dashboard is up.
Pass `--dashboard-port`/`--dashboard-address` to override the defaults
(`8501` / `0.0.0.0`).

Or run them separately (e.g. in two terminals, useful while debugging one
of them in isolation):

```bash
python orchestrator.py
```

```bash
streamlit run dashboard.py --server.address 0.0.0.0 --server.port 8501 --server.headless true
```

Leave whichever you use running (e.g. as a Windows service / scheduled task
on the VPS alongside the terminal).

## Dashboard

`dashboard.py` is a Streamlit page for monitoring every account in the
rotation — not just whichever one happens to be logged in right now. It's a
**separate process** from `orchestrator.py` and never touches the MT5 API
itself (it would contend with orchestrator.py for the one terminal login
slot) — it only reads files orchestrator.py and the EA already write to
disk:

- `live_status.json` — balance/equity/floating PnL/open positions for the
  **currently active** account only (single-terminal rotation — every other
  account's live numbers are simply unavailable until it's their turn).
  Written by orchestrator.py every poll cycle.
- `state.json` — rotation position, which logins are maxed out today.
- `handoff_history.csv` — persistent log of every target/max-loss event
  (the signal file itself is deleted right after being read — this is the
  only record that survives).
- `AjipIDM_Batches_<symbol>_<magic>_<login>.csv` — one file per account
  (written by the EA itself, `AjipIDM_Trade.mqh:WriteBatchCsv`), used for
  today's/all-time realized PnL, win rate, trade count, and the cumulative
  PnL chart per account.

### Setup

```bash
pip install -r requirements.txt
```

Set a dashboard password (stored as a sha256 hash only, never plaintext):

```bash
python -c "import hashlib, getpass, json; json.dump({'password_hash': hashlib.sha256(getpass.getpass('Dashboard password: ').encode()).hexdigest()}, open('dashboard_auth.json', 'w'))"
```

See "Run" above (`python run.py`) to start it alongside `orchestrator.py`.

### Accessing it remotely — security note

The password gate is a basic check, not real access control: no
rate-limiting, no session expiry, and Streamlit serves plain HTTP with no
TLS of its own. If you bind `0.0.0.0` so it's reachable from outside the
VPS, do at least one of:

- Restrict the port at the VPS firewall to your own IP.
- Put a reverse proxy in front for TLS (e.g. Caddy — a single `caddyfile`
  line with automatic HTTPS is enough) and only expose the proxy's port.

Don't rely on the password alone if the port is open to the whole internet.

## Known limitations (V1)

- **Day rollover uses the local system clock**, not the broker's server
  time or the prop firm's actual daily-reset time. If those differ
  meaningfully from local midnight, the "everyone's exhausted, wait for
  tomorrow" reset will fire at the wrong moment. Adjust `today_str()` in
  `orchestrator.py` if you need it tied to broker time instead.
- **`positions_count()` checks only via `positions_get`** — pending orders
  aren't included. This EA doesn't use pending orders, but if you extend it
  to do so, add an `orders_get()` check too.
- Login credentials are stored in plaintext in `accounts.json`. Restrict
  file permissions on the VPS accordingly.
