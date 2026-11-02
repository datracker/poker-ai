# poker-ai

An advice-only poker assistant for the PokerFace app on macOS. It watches the
game through an iPhone Mirroring window, reads the table, and prints what to
do — it never clicks for you. When it is your turn it prints the action, and
you tap it yourself.

## How it works

```
iPhone Mirroring window
        │
        ▼
perceive.swift ──────────── Vision OCR: seats, stacks, bets,
        │                    dealer button, pot, actions
        ▼
cards.py ────────────────── template matching: board + hole cards
        │                    (runs as a background JSON-lines service)
        ▼
   TableRead
        │
        ├── strategy.swift ─ rules engine: short-stack raise-or-fold
        │                    ranges, equity-based continues, value bets
        │
        └── advisor.py ──── fullhouse-bot deep-CFR model
                             (translates the table into the model's
                             six-handed shape and back)
        ▼
advice.swift ────────────── one line: what to tap + where the
                             advice came from (model or rules fallback)
```

The rules strategy is tailored to this app's games: stacks are usually
25–40 big blinds and opponents call too wide, so it plays a modern
raise-or-fold opening game, continues with real equity, value-bets made
hands, and does not bluff air.

## Requirements

- macOS with the Swift toolchain (`xcode-select --install`)
- [iPhone Mirroring](https://support.apple.com/guide/mac-help/mchl070dc12b/mac)
  running PokerFace
- Python 3.12 (`brew install python@3.12`)
- Screen Recording permission for your terminal (System Settings →
  Privacy & Security → Screen Recording)

## Setup

```sh
# Python environment for the card reader (OpenCV + NumPy)
python3 -m venv .venv
.venv/bin/pip install opencv-python numpy

# Python environment for the model advisor (must be 3.12 for eval7)
/opt/homebrew/bin/python3.12 -m venv .venv-advisor
.venv-advisor/bin/pip install numpy 'eval7==0.1.11'

# The decision model (separate repo, cloned alongside this one)
git clone https://github.com/advitrocks9/fullhouse-bot third_party/fullhouse-bot
# the model file must exist at third_party/fullhouse-bot/data/deep_cfr_model.npz

# Build the bot and the click helper (binaries must stay at the repo root —
# they locate cards.py, card_templates/, and the venvs relative to themselves)
swiftc -O bot/*.swift -o pokerbot
swiftc -O click.swift -o clicker
```

## Usage

```sh
./pokerbot                  # live: watch the mirroring window and advise
./pokerbot --once           # read the table once and print advice
./pokerbot --image cap.png  # advise from a saved capture
./pokerbot --replay frames/ # replay a folder of captures
./pokerbot --self-test      # run the strategy test suite
```

Ctrl-C stops the live loop.

## Repo layout

| Path | What it is |
| --- | --- |
| `bot/main.swift` | capture loop and entrypoint |
| `bot/perceive.swift` | Vision-based screen reading → `TableRead` |
| `bot/cards.py` | card recognition (rank/suit template matching) |
| `bot/card_templates/` | labeled rank/suit shapes matched by `cards.py` |
| `bot/strategy.swift` | rules strategy + self-tests |
| `bot/advisor.py` | bridge to the fullhouse-bot model (JSON-lines) |
| `bot/advisor.swift`, `bot/advice.swift` | model glue and the printed advice line |
| `click.swift` | synthetic-click helper tool |

Not tracked in git: `.venv*/`, `.debug/`, `watch1/`, the built binaries,
and `third_party/fullhouse-bot` (clone it as shown above).

## Notes

- **Advice only, by design.** The bot prints what to do; a human taps it.
- `bot/cards.py` can learn new card templates from a labeled capture:
  `python bot/cards.py --learn capture.png "4s 4h 7d" "2s Qd"`
- The model advisor degrades gracefully: if the model or its venv is
  missing, advice falls back to the rules engine and says so.
