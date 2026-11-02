"""Ask fullhouse-bot what to do with the table the screen reader saw.

The model plays six-handed no-limit, with the big blind worth 100 of its chips.
This translates a PokerFace table into that shape, asks the model, and translates
the answer back. Nothing here changes the model.

One JSON object per line on stdin, one JSON object per line on stdout:

    {"big_blind": 200000, "hero": 0, "dealer": 0, "hole": ["Ah", "Kd"],
     "board": [], "pot": 0, "to_call": 200000, "can_check": false,
     "seats": [{"dealt": true, "stack": 20000000, "bet": 0, "invested": 0,
                "folded": false, "all_in": false}, ...],
     "raises": [{"seat": 2, "total": 600000}]}

Seats are clockwise, starting with you. `pot` is the pill above the board, which
does not include the bets on this street. `invested` is every chip that seat has
put into the hand, including this street. `raises` is this street only, in order,
and each total is that seat's bet after the raise.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FULLHOUSE = ROOT / "third_party" / "fullhouse-bot"
sys.path.insert(0, str(FULLHOUSE))

from bot.bot import (  # noqa: E402
    ALL_IN,
    BET_50,
    BET_POT,
    BIG_BLIND,
    CHECK_CALL,
    FOLD,
    _DEEP_CFR,
    _apply_legal_mask,
    _push_fold,
    _to_engine_action,
)
from bot.features import encode_state_dict  # noqa: E402

# Model seats, clockwise from the button. Empty chairs become the early positions,
# which have already folded, so the button and the blinds keep their meaning.
# Heads-up keeps the button and the big blind: the button posts the small blind
# and acts last after the flop, which is what heads-up play does.
SLOTS = {
    2: [0, 2],
    3: [0, 1, 2],
    4: [0, 1, 2, 5],
    5: [0, 1, 2, 4, 5],
    6: [0, 1, 2, 3, 4, 5],
}
STREETS = {0: "preflop", 3: "flop", 4: "turn", 5: "river"}


def chips(amount: float, big_blind: float) -> int:
    """PokerFace chips to the model's chips, where the big blind is 100."""
    return int(round(float(amount) * BIG_BLIND / float(big_blind)))


def money(amount: int, big_blind: float) -> float:
    """Model chips back to PokerFace chips."""
    return float(amount) * float(big_blind) / BIG_BLIND


def _seat(raw: dict) -> dict:
    return {
        "dealt": bool(raw.get("dealt")),
        "stack": raw.get("stack"),
        "bet": float(raw.get("bet") or 0),
        "invested": float(raw.get("invested") or 0),
        "folded": bool(raw.get("folded")),
        "all_in": bool(raw.get("all_in")),
    }


def build_state(payload: dict) -> tuple[dict, float]:
    """Return the model's state dict and the PokerFace big blind."""
    big_blind = float(payload.get("big_blind") or 0)
    if big_blind <= 0:
        raise ValueError("the big blind is not known")
    hole = list(payload.get("hole") or [])
    board = list(payload.get("board") or [])
    if len(hole) != 2:
        raise ValueError("your two cards are needed")
    if len(board) not in STREETS:
        raise ValueError("the board is only partly known")
    seats = [_seat(raw) for raw in payload.get("seats") or []]
    if len(seats) != 5:
        raise ValueError("expected the five PokerFace seats")
    hero = int(payload.get("hero", 0))
    dealer = payload.get("dealer")
    if dealer is None or not (0 <= int(dealer) < 5):
        raise ValueError("the dealer is not known")
    dealer = int(dealer)
    dealt = [i for i in range(5) if seats[i]["dealt"]]
    if hero not in dealt:
        raise ValueError("you are not in this hand")
    if dealer not in dealt:
        raise ValueError("the dealer is not one of the players in the hand")
    if len(dealt) not in SLOTS:
        raise ValueError(f"{len(dealt)} players is outside what the model can play")
    for index in dealt:
        seat = seats[index]
        if seat["stack"] is None and not seat["all_in"]:
            raise ValueError(f"seat {index} has no stack")

    ordered = []
    for step in range(5):
        index = (dealer + step) % 5
        if seats[index]["dealt"]:
            ordered.append(index)
    slots = SLOTS[len(ordered)]
    model_of = {index: slot for index, slot in zip(ordered, slots)}

    players = []
    for slot in range(6):
        players.append(
            {
                "seat": slot,
                "stack": 0,
                "bet_this_street": 0,
                "is_folded": True,
                "is_all_in": False,
                "state": "folded",
            }
        )
    scale = lambda amount: chips(amount, big_blind)  # noqa: E731
    for index in ordered:
        seat = seats[index]
        slot = model_of[index]
        remaining = 0 if seat["all_in"] else scale(seat["stack"] or 0)
        players[slot] = {
            "seat": slot,
            "stack": remaining,
            "bet_this_street": scale(seat["bet"]),
            "is_folded": seat["folded"],
            "is_all_in": seat["all_in"] or remaining == 0 and seat["bet"] > 0,
            "state": "folded" if seat["folded"] else "active",
        }

    street = STREETS[len(board)]
    preflop = street == "preflop"
    hero_slot = model_of[hero]
    hero_bet = players[hero_slot]["bet_this_street"]
    table_max = max(player["bet_this_street"] for player in players)
    # A CHECK button means nothing is owed, even if a pill was misread.
    if payload.get("can_check"):
        owed = 0
        can_check = True
    else:
        owed = max(0, table_max - hero_bet)
        screen_owed = scale(payload.get("to_call") or 0)
        if screen_owed > 0 and abs(screen_owed - owed) > BIG_BLIND:
            owed = screen_owed
        can_check = False
    current_bet = hero_bet + owed

    small_blind, big = (0, 2) if len(ordered) == 2 else (1, 2)
    invested = {model_of[index]: scale(seats[index]["invested"]) for index in ordered}
    bets = {player["seat"]: player["bet_this_street"] for player in players if not player["is_folded"] or player["bet_this_street"]}

    raises = []
    for raw in payload.get("raises") or []:
        index = int(raw["seat"])
        if index not in model_of:
            continue
        total = scale(raw.get("total") or 0)
        if total <= 0:
            continue
        if raises and total <= raises[-1][1]:
            continue
        raises.append((model_of[index], total))
    # The big blind is posted on its own. A first level that only matches it is not a raise.
    if preflop and raises and raises[0][1] <= BIG_BLIND:
        raises = raises[1:]

    log: list[dict] = [
        {"seat": small_blind, "action": "small_blind", "amount": BIG_BLIND // 2},
        {"seat": big, "action": "big_blind", "amount": BIG_BLIND},
    ]
    blind_of = {small_blind: BIG_BLIND // 2, big: BIG_BLIND}
    for slot, total in invested.items():
        extra = total - bets.get(slot, 0) - blind_of.get(slot, 0)
        if extra > 0:
            log.append({"seat": slot, "action": "call", "amount": extra})
    for _ in range({"preflop": 0, "flop": 1, "turn": 2, "river": 3}[street]):
        log.append({"action": "deal"})

    previous = BIG_BLIND if preflop else 0
    raise_totals = []
    for slot, total in raises:
        if total <= previous:
            continue
        player = players[slot]
        action = "all_in" if player["is_all_in"] else "raise"
        log.append({"seat": slot, "action": action, "amount": total})
        raise_totals.append(total)
        previous = total
    last_raiser = raises[-1][0] if raises else None
    last_total = raises[-1][1] if raises else 0
    covered = dict(blind_of) if preflop else {}
    for slot, total in raises:
        covered[slot] = total
    for slot, bet in bets.items():
        if slot == last_raiser and bet == last_total:
            continue
        extra = bet - covered.get(slot, 0)
        if extra > 0:
            log.append({"seat": slot, "action": "call", "amount": extra})

    if raise_totals:
        previous_total = (BIG_BLIND if preflop else 0) if len(raise_totals) == 1 else raise_totals[-2]
        last_size = max(BIG_BLIND, raise_totals[-1] - previous_total)
    else:
        base = BIG_BLIND if preflop else 0
        last_size = max(BIG_BLIND, current_bet - base)
    min_raise_to = current_bet + last_size

    pot_pill = scale(payload.get("pot") or 0)
    street_bets = sum(player["bet_this_street"] for player in players)
    state = {
        "street": street,
        "seat_to_act": hero_slot,
        "dealer": 0,
        "pot": pot_pill + street_bets,
        "community_cards": board,
        "current_bet": current_bet,
        "min_raise_to": min_raise_to,
        "amount_owed": owed,
        "can_check": can_check,
        "your_cards": hole,
        "your_stack": players[hero_slot]["stack"],
        "your_bet_this_street": hero_bet,
        "players": players,
        "action_log": log,
    }
    return state, big_blind


def advise(payload: dict) -> dict:
    state, big_blind = build_state(payload)
    street = state["street"]
    if street == "preflop":
        pushed = _push_fold(state)
        if pushed is not None:
            return _from_chart(pushed, state, big_blind)

    strategy = _DEEP_CFR.get_strategy(state)
    strategy = _apply_legal_mask(strategy, state)
    best_id = int(strategy.argmax())
    fired = _to_engine_action(best_id, state)
    best, raise_to = _describe(fired, best_id, state, big_blind)
    return {
        "probs": [round(float(p), 4) for p in strategy],
        "best": best,
        "raise_to": raise_to,
        "source": "model",
    }


def _describe(fired: dict, best_id: int, state: dict, big_blind: float) -> tuple[str, float | None]:
    action = fired.get("action")
    if action == "all_in" or best_id == ALL_IN:
        total = state["your_bet_this_street"] + state["your_stack"]
        return "all_in", money(total, big_blind)
    if action == "raise":
        name = "half_pot" if best_id == BET_50 else "pot"
        return name, money(int(fired.get("amount") or 0), big_blind)
    if action == "check":
        return "check", None
    if action == "call":
        return "call", None
    if best_id == BET_50:
        return "half_pot", None
    if best_id == BET_POT:
        return "pot", None
    if best_id == CHECK_CALL:
        return ("check" if state.get("can_check") else "call"), None
    return "fold", None


def _from_chart(action: dict, state: dict, big_blind: float) -> dict:
    name = action.get("action")
    probs = [0.0, 0.0, 0.0, 0.0, 0.0]
    raise_to = None
    if name == "all_in":
        best = "all_in"
        probs[ALL_IN] = 1.0
        raise_to = money(state["your_bet_this_street"] + state["your_stack"], big_blind)
    elif name == "raise":
        best = "pot"
        probs[BET_POT] = 1.0
        raise_to = money(int(action.get("amount") or 0), big_blind)
    elif name == "call":
        best = "call"
        probs[CHECK_CALL] = 1.0
    elif name == "check":
        best = "check"
        probs[CHECK_CALL] = 1.0
    else:
        best = "fold"
        probs[FOLD] = 1.0
    return {"probs": probs, "best": best, "raise_to": raise_to, "source": "pushfold"}


def _answer(payload: dict) -> dict:
    try:
        return advise(payload)
    except Exception as exc:
        return {"error": str(exc)}


def serve() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            payload = {}
            result = {"error": "the request was not readable"}
        else:
            result = _answer(payload)
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()


def _check(failures: list[str], name: str, ok: bool, detail: str = "") -> None:
    if not ok:
        failures.append(f"{name}: {detail}" if detail else name)


def _spot(**overrides) -> dict:
    seats = []
    for _ in range(5):
        seats.append(
            {
                "dealt": False,
                "stack": None,
                "bet": 0,
                "invested": 0,
                "folded": False,
                "all_in": False,
            }
        )
    payload = {
        "big_blind": 200_000,
        "hero": 0,
        "dealer": 0,
        "hole": ["Ah", "Kd"],
        "board": [],
        "pot": 0,
        "to_call": 200_000,
        "can_check": False,
        "seats": seats,
        "raises": [],
    }
    payload.update(overrides)
    return payload


def _deal(payload: dict, index: int, stack: float, bet: float = 0, invested: float | None = None, folded: bool = False) -> None:
    payload["seats"][index] = {
        "dealt": True,
        "stack": stack,
        "bet": bet,
        "invested": bet if invested is None else invested,
        "folded": folded,
        "all_in": stack == 0 and bet > 0,
    }


def run_tests() -> int:
    failures: list[str] = []

    # The model has to load and answer a plain six-handed spot on its own.
    from bot.bot import decide

    smoked = decide(
        {
            "street": "preflop",
            "seat_to_act": 0,
            "dealer": 0,
            "pot": 150,
            "community_cards": [],
            "current_bet": 100,
            "min_raise_to": 200,
            "amount_owed": 100,
            "can_check": False,
            "your_cards": ["Ah", "Kh"],
            "your_stack": 9900,
            "your_bet_this_street": 0,
            "players": [
                {"seat": i, "stack": 10000 if i else 9900, "bet_this_street": 0, "is_folded": False, "is_all_in": False}
                for i in range(6)
            ],
            "action_log": [
                {"seat": 1, "action": "small_blind", "amount": 50},
                {"seat": 2, "action": "big_blind", "amount": 100},
            ],
        }
    )
    _check(failures, "decide", smoked.get("action") in {"fold", "check", "call", "raise", "all_in"}, str(smoked))

    # Unopened pot, you are the button. Only the blinds are out.
    unopened = _spot()
    _deal(unopened, 0, 20_000_000)
    _deal(unopened, 1, 20_000_000, bet=100_000, invested=100_000)
    _deal(unopened, 2, 20_000_000, bet=200_000, invested=200_000)
    state, _ = build_state(unopened)
    features, legal = encode_state_dict(state)
    _check(failures, "unopened position", features[21] == 1.0, f"features[21]={features[21]}")
    _check(failures, "unopened raises", features[36] == 0.0, f"features[36]={features[36]}")
    _check(failures, "unopened invested", features[40] == 0.0, f"features[40]={features[40]}")
    _check(failures, "unopened pot", abs(state["pot"] - 150) < 1, f"pot={state['pot']}")
    _check(failures, "unopened players", len(state["players"]) == 6)
    _check(failures, "unopened folded phantoms", sum(1 for p in state["players"] if p["is_folded"]) == 3)
    answer = advise(unopened)
    _check(failures, "unopened source", answer["source"] == "model", str(answer))
    _check(failures, "unopened mix", abs(sum(answer["probs"]) - 1) < 1e-3, str(answer["probs"]))
    _check(failures, "unopened legal", legal[answer["probs"].index(max(answer["probs"]))], str(answer))

    # A three-bet back to you. Two real raises, and you were the opener.
    three = _spot(to_call=1_200_000)
    _deal(three, 0, 18_200_000, bet=600_000, invested=600_000)
    _deal(three, 1, 20_000_000, bet=100_000, invested=100_000, folded=True)
    _deal(three, 2, 18_200_000, bet=1_800_000, invested=1_800_000)
    three["raises"] = [{"seat": 0, "total": 600_000}, {"seat": 2, "total": 1_800_000}]
    state, _ = build_state(three)
    features, _ = encode_state_dict(state)
    _check(failures, "3-bet count", abs(features[36] - 0.5) < 1e-6, f"features[36]={features[36]}")
    _check(failures, "3-bet last raiser", features[38] == 0.0, f"features[38]={features[38]}")
    _check(failures, "3-bet invested", abs(features[40] - 0.03) < 1e-6, f"features[40]={features[40]}")
    answer = advise(three)
    _check(failures, "3-bet mix", answer["source"] == "model" and abs(sum(answer["probs"]) - 1) < 1e-3, str(answer))

    # The turn, facing a bet, as in the saved hand where you hold queen-eight.
    turn = _spot(
        hole=["Qh", "8h"],
        board=["Th", "Jh", "Js", "2s"],
        pot=800_000,
        to_call=400_000,
        dealer=3,
    )
    _deal(turn, 0, 17_000_000, invested=400_000)
    _deal(turn, 2, 24_400_000, bet=400_000, invested=800_000)
    _deal(turn, 3, 5_742_059, invested=200_000, folded=True)
    _deal(turn, 4, 7_838_078, invested=200_000)
    turn["raises"] = [{"seat": 2, "total": 400_000}]
    state, _ = build_state(turn)
    _check(failures, "turn pot", state["pot"] == 600, f"pot={state['pot']}")
    turn_features, _ = encode_state_dict(state)
    _check(failures, "turn pot feature", abs(float(turn_features[27]) - 0.06) < 1e-6, f"features[27]={turn_features[27]}")
    _check(failures, "turn street", state["street"] == "turn")
    _check(failures, "turn owed", state["amount_owed"] == 200, f"owed={state['amount_owed']}")
    answer = advise(turn)
    _check(
        failures,
        "turn answer",
        answer["source"] == "model" and answer["best"] in {"fold", "call", "half_pot", "pot", "all_in"},
        str(answer),
    )

    # Eight big blinds with aces shoves. Seven-deuce folds. Both come from the chart.
    short = _spot(to_call=200_000, hole=["As", "Ad"])
    _deal(short, 0, 1_600_000)
    _deal(short, 1, 1_600_000, bet=100_000, invested=100_000)
    _deal(short, 2, 1_600_000, bet=200_000, invested=200_000)
    answer = advise(short)
    _check(failures, "short aces", answer["source"] == "pushfold" and answer["best"] == "all_in", str(answer))
    short["hole"] = ["7c", "2d"]
    answer = advise(short)
    _check(failures, "short trash", answer["source"] == "pushfold" and answer["best"] == "fold", str(answer))

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("advisor tests passed")
    return 0


def main() -> int:
    if "--test" in sys.argv:
        return run_tests()
    if "--serve" in sys.argv:
        try:
            serve()
        except BrokenPipeError:
            return 0
        return 0
    print("usage: advisor.py --serve | --test", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
