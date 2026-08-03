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

```bash
python orchestrator.py
```

Leave it running (e.g. as a Windows service / scheduled task on the VPS
alongside the terminal). Ctrl+C to stop.

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
