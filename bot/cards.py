"""Reads the board and hole cards from an iPhone Mirroring capture of PokerFace.

Card faces are found as neutral white areas. The rank index and the suit pips on each face
are cut out as ink blobs and matched against the labeled shapes in card_templates/.

  python bot/cards.py capture.png ...   print what each capture shows
  python bot/cards.py --serve           answer one JSON line per image path on stdin
  python bot/cards.py --learn capture.png "4s 4h 7d" "2s Qd"
                                        save new templates from a capture whose board and hole
                                        cards are known ("" for none)
"""
import glob
import json
import os
import signal
import sys

import cv2
import numpy as np

TEMPLATES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "card_templates")

# Measured on a 708x1562 capture and kept as fractions, so another window scale still lines up.
REF_W, REF_H = 708, 1562
BOARD_Y = 707 / REF_H
CARD_H = 92 / REF_H
# Rank index centers of the two fanned hole cards, and how far each card is turned.
HOLE_ANCHORS = [((443 / REF_W, 1356 / REF_H), 15.0), ((520 / REF_W, 1337 / REF_H), -15.0)]
GLYPH_W, GLYPH_H = 40, 32
RANKS = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"]

# A rank is accepted on a close match, or on a fair match that no other rank comes near.
RANK_MIN, RANK_MARGIN = 0.85, 0.06
RANK_FAIR, RANK_FAIR_MARGIN = 0.78, 0.15
SUIT_MIN, SUIT_MARGIN = 0.78, 0.06


def load(path):
    if not os.path.isfile(path):
        return None
    bgr = cv2.imread(path, cv2.IMREAD_COLOR)
    if bgr is None:
        return None
    return np.ascontiguousarray(bgr[..., ::-1]).astype(np.int16)


def neutral(im, lo):
    return (im.min(-1) > lo) & (im.max(-1) - im.min(-1) < 16)


def ink(im, level):
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    red = (r - np.maximum(g, b) > level * 0.25) & (r > level * 0.30)
    black = ((r + g + b) / 3 < level * 0.45) & ~red
    return red, black


def comps(mask, min_area):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    out = []
    for i in range(1, n):
        x, y, w, h, a = (int(v) for v in stats[i])
        if a >= min_area:
            out.append({"x": x, "y": y, "w": w, "h": h, "area": a, "mask": lab[y:y + h, x:x + w] == i})
    return out


def merge(parts):
    x0 = min(p["x"] for p in parts)
    y0 = min(p["y"] for p in parts)
    x1 = max(p["x"] + p["w"] for p in parts)
    y1 = max(p["y"] + p["h"] for p in parts)
    mask = np.zeros((y1 - y0, x1 - x0), bool)
    for p in parts:
        mask[p["y"] - y0:p["y"] - y0 + p["h"], p["x"] - x0:p["x"] - x0 + p["w"]] |= p["mask"]
    reds = sum(p["area"] for p in parts if p["color"] == "red")
    blacks = sum(p["area"] for p in parts if p["color"] == "black")
    return {"x": x0, "y": y0, "w": x1 - x0, "h": y1 - y0, "mask": mask, "area": int(mask.sum()),
            "color": "red" if reds > blacks else "black"}


def hull_mask(face, shape, shrink):
    points = cv2.findNonZero(face["mask"].astype(np.uint8)) + np.array([face["x"], face["y"]])
    inside = cv2.fillConvexPoly(np.zeros(shape, np.uint8), cv2.convexHull(points), 1)
    return cv2.erode(inside, np.ones((shrink, shrink), np.uint8)).astype(bool)


def glyph_parts(patch, level, inside):
    """Ink blobs on the card face. Ink on the felt or a bar next to the card is dropped."""
    red, black = ink(patch, level)
    # The face darkens toward the bottom of the card, to about 60% of its top brightness.
    face = neutral(patch, level * 0.55)
    parts = []
    for color, m in (("red", red), ("black", black)):
        for c in comps(m & inside, 6):
            x, y, w, h = c["x"], c["y"], c["w"], c["h"]
            ring = np.zeros(m.shape, np.uint8)
            ring[max(0, y - 2):y + h + 2, max(0, x - 2):x + w + 2] = 1
            ring[y:y + h, x:x + w][c["mask"]] = 0
            around = face[ring == 1]
            if around.size and around.mean() > 0.25:
                c["color"] = color
                parts.append(c)
    return parts


def strip_lines(glyph):
    """Cut a thin edge (a label bar, the other card's border) off a large pip."""
    opened = cv2.morphologyEx(glyph["mask"].astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    pieces = comps(opened, 6)
    if not pieces:
        return glyph
    main = max(pieces, key=lambda p: p["area"])
    return {**glyph, "x": glyph["x"] + main["x"], "y": glyph["y"] + main["y"], "w": main["w"], "h": main["h"],
            "mask": main["mask"], "area": main["area"]}


def index_of(parts, card_h, anchor):
    """The rank glyph nearest the anchor (both halves of a 10) and the small pip under it."""
    ax, ay = anchor
    tall = [p for p in parts if 0.18 * card_h < p["h"] < 0.40 * card_h]
    if not tall:
        return None, None
    main = min(tall, key=lambda p: abs(p["x"] + p["w"] / 2 - ax) + abs(p["y"] + p["h"] / 2 - ay))
    group = [main]
    for p in tall:
        if p is main:
            continue
        same_row = abs(p["y"] - main["y"]) < 0.08 * card_h and abs(p["h"] - main["h"]) < 0.10 * card_h
        gap = max(p["x"] - (main["x"] + main["w"]), main["x"] - (p["x"] + p["w"]))
        if same_row and gap < 0.06 * card_h:
            group.append(p)
    rank = merge(group)
    below = [p for p in parts
             if rank["y"] + rank["h"] * 0.8 < p["y"] < rank["y"] + rank["h"] * 1.9
             and p["x"] < rank["x"] + rank["w"] and p["x"] + p["w"] > rank["x"]
             and p["h"] < rank["h"] * 0.9 and p["w"] < rank["h"] * 1.1]
    pip = merge([min(below, key=lambda p: p["y"])]) if below else None
    if pip is not None and pip["h"] >= 20:
        pip = strip_lines(pip)
    return rank, pip


def edge_slant(mask):
    """dx/dy across the card at the index. Perspective leans the outer board cards."""
    h = mask.shape[0]
    rows = [y for y in range(int(h * 0.15), int(h * 0.85)) if mask[y].any()]
    if len(rows) < 6:
        return 0.0
    left = [np.argmax(mask[y]) for y in rows]
    right = [mask.shape[1] - 1 - np.argmax(mask[y][::-1]) for y in rows]
    sl = np.polyfit(rows, left, 1)[0]
    sr = np.polyfit(rows, right, 1)[0]
    return float(sl + 0.3 * (sr - sl))


def unshear(img, s, yc):
    h, w = img.shape[:2]
    pad = int(abs(s) * h) + 2
    m = np.float32([[1, -s, s * yc + pad], [0, 1, 0]])
    flags = cv2.INTER_NEAREST if img.ndim == 2 else cv2.INTER_LINEAR
    return cv2.warpAffine(img, m, (w + 2 * pad, h), flags=flags, borderMode=cv2.BORDER_CONSTANT, borderValue=0), pad


def board_faces(im):
    H = im.shape[0]
    y0, y1 = int(H * (BOARD_Y - CARD_H * 0.6)), int(H * (BOARD_Y + CARD_H * 1.6))
    faces = []
    for c in comps(neutral(im[y0:y1], 185), int(0.18 * (CARD_H * H) ** 2)):
        c["y"] += y0
        h_ok = abs(c["h"] / H - CARD_H) < CARD_H * 0.05
        y_ok = abs(c["y"] / H - BOARD_Y) < CARD_H * 0.4
        w_ok = 0.75 * CARD_H * H < c["w"] < 1.15 * CARD_H * H
        if h_ok and y_ok and w_ok:
            faces.append(c)
    return sorted(faces, key=lambda c: c["x"])


def read_board(im):
    out = []
    for f in board_faces(im):
        x, y, w, h = f["x"], f["y"], f["w"], f["h"]
        patch = im[y:y + h, x:x + w].astype(np.uint8)
        level = float(np.median(patch[f["mask"]].max(-1)))
        # A glyph near the edge can touch it through anti-aliasing, so the face outline would
        # leave it out. The card itself is convex.
        inside = hull_mask({**f, "x": 0, "y": 0}, (h, w), 3).astype(np.uint8)
        s = edge_slant(f["mask"])
        flat, pad = unshear(patch, s, h * 0.17)
        inside, _ = unshear(inside, s, h * 0.17)
        parts = glyph_parts(flat.astype(np.int16), level, inside.astype(bool))
        rank, pip = index_of(parts, h, (pad + w * 0.35, h * 0.17))
        big = None
        if rank is not None:
            low = [p for p in parts if p["h"] > 0.30 * h and p["y"] > rank["y"] + rank["h"]]
            big = merge([max(low, key=lambda p: p["area"])]) if low else None
        out.append({"slot": "board", "rank": rank, "pip": pip, "big": big})
    return out


def read_hole(im):
    H, W = im.shape[:2]
    scale = H / REF_H
    half = int(round(70 * scale))
    out = []
    for i, ((fx, fy), angle) in enumerate(HOLE_ANCHORS):
        cx, cy = int(fx * W), int(fy * H)
        x0, y0 = cx - half, cy - half
        if x0 < 0 or y0 < 0 or x0 + 2 * half > W or y0 + 2 * half > H:
            continue
        patch = im[y0:y0 + 2 * half, x0:x0 + 2 * half].astype(np.uint8)
        m = cv2.getRotationMatrix2D((half, half), -angle, 1.0)
        up = cv2.warpAffine(patch, m, (2 * half, 2 * half), flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_REPLICATE).astype(np.int16)
        face = neutral(up, 90)
        if face.mean() < 0.25:
            continue
        level = float(np.percentile(up[face].max(-1), 90))
        # A black pip on the lower edge touches the dark bar under the cards. Keeping only ink
        # inside the card outline separates the two.
        cards_face = max(comps(neutral(up, level * 0.55), 1), key=lambda p: p["area"])
        inside = hull_mask(cards_face, face.shape, 5)
        rank, pip = index_of(glyph_parts(up, level, inside), 190 * scale, (half, half))
        out.append({"slot": f"hole{i}", "rank": rank, "pip": pip})
    return out


def normalize(mask):
    h, w = mask.shape
    nw = max(1, min(GLYPH_W, int(round(w * GLYPH_H / h))))
    small = cv2.resize(mask.astype(np.float32), (nw, GLYPH_H), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((GLYPH_H, GLYPH_W), np.float32)
    x0 = (GLYPH_W - nw) // 2
    canvas[:, x0:x0 + nw] = small
    return canvas


def holes(vec):
    """Where a glyph encloses background: 'none', 'upper', 'middle', 'lower' or 'two'.

    Stroke weight hardly changes this, and it is what tells 6, 8 and 9 apart.
    """
    m = (vec > 0.5).astype(np.uint8)
    ys = np.nonzero(m)[0]
    if len(ys) == 0:
        return "none"
    top, height = ys.min(), ys.max() - ys.min() + 1
    n, _, stats, centers = cv2.connectedComponentsWithStats(1 - m, connectivity=4)
    H, W = m.shape
    found = [(centers[i][1] - top) / height for i in range(1, n)
             if stats[i][4] >= 3 and stats[i][0] > 0 and stats[i][1] > 0
             and stats[i][0] + stats[i][2] < W and stats[i][1] + stats[i][3] < H]
    if not found:
        return "none"
    if len(found) > 1:
        return "two"
    return "upper" if found[0] < 0.40 else "lower" if found[0] > 0.60 else "middle"


def weight_variants(vec):
    """The glyph drawn a little bolder and a little thinner. Ink comes out heavier on red and
    on dimmed cards than on black ones."""
    big = cv2.resize(vec, None, fx=4, fy=4, interpolation=cv2.INTER_LINEAR) > 0.5
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    out = []
    for op in (cv2.dilate, cv2.erode):
        m = op(big.astype(np.uint8), kernel).astype(bool)
        ys, xs = np.nonzero(m)
        if len(ys):
            out.append(normalize(m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]))
    return out


def load_templates(folder=TEMPLATES):
    out = {"rank": [], "suit": [], "big": []}
    for path in sorted(glob.glob(os.path.join(folder, "*.png"))):
        kind, label, _ = os.path.basename(path)[:-4].split("_")
        vec = cv2.imread(path, cv2.IMREAD_GRAYSCALE).astype(np.float32) / 255
        if kind != "rank":
            out[kind].append((label, vec, None))
            continue
        shape = holes(vec)
        # A variant whose holes closed or opened would land among another rank's look-alikes.
        out[kind] += [(label, v, shape) for v in [vec] + weight_variants(vec) if holes(v) == shape]
    return out


def similarity(a, b):
    union = np.maximum(a, b).sum()
    return float(np.minimum(a, b).sum() / union) if union else 0.0


def classify(glyph, templates, allowed=None, by_holes=False):
    """Best label, its score, and the best score of any other label."""
    vec = normalize(glyph["mask"])
    shape = holes(vec) if by_holes else None
    best = {}
    for label, tpl, tshape in templates:
        if allowed and label not in allowed:
            continue
        if by_holes and tshape != shape:
            continue
        s = similarity(vec, tpl)
        if s > best.get(label, 0.0):
            best[label] = s
    if not best:
        return None, 0.0, 0.0
    ranked = sorted(best.items(), key=lambda kv: -kv[1])
    return ranked[0][0], ranked[0][1], ranked[1][1] if len(ranked) > 1 else 0.0


def identify(card, T):
    """'Ah'-style name for one detected card, or None and the reason."""
    if card["rank"] is None:
        return None, ""
    rank, rs, r2 = classify(card["rank"], T["rank"], by_holes=True)
    close = rs >= RANK_MIN and rs - r2 >= RANK_MARGIN
    fair = rs >= RANK_FAIR and rs - r2 >= RANK_FAIR_MARGIN
    if not (close or fair):
        return None, f"rank unsure ({rank} {rs:.2f}/{rs - r2:.2f})"
    # Board cards carry a large pip, which is much easier to tell apart than the small one.
    for kind, tkind in (("big", "big"), ("pip", "suit")):
        g = card.get(kind)
        if g is None or not T[tkind]:
            continue
        allowed = {"h", "d"} if g["color"] == "red" else {"s", "c"}
        suit, ss, s2 = classify(g, T[tkind], allowed)
        if ss >= SUIT_MIN and ss - s2 >= SUIT_MARGIN:
            return rank + suit, ""
    return None, f"suit unsure for {rank}"


def read_cards(im, T):
    """Board and hole cards, plus the reasons this frame should not be trusted."""
    board = [identify(c, T) for c in read_board(im)]
    hole = [identify(c, T) for c in read_hole(im)]
    names = [n for n, _ in board + hole if n]
    problems = [why for _, why in board + hole if why]
    if len(set(names)) != len(names):
        problems.append("duplicate card")
    if any(n is None for n, _ in board):
        problems.append("board card unreadable")
    if len(board) in (1, 2):
        problems.append("board mid-deal")
    return {"board": [n for n, _ in board if n], "hole": [n for n, _ in hole if n], "problems": problems}


def learn(path, board_names, hole_names, folder=TEMPLATES):
    """Save the glyphs of a capture whose cards are known, where they do not already match well."""
    im = load(path)
    if im is None:
        return [f"cannot read {path}"]
    for name in board_names + hole_names:
        if name[:-1] not in RANKS or name[-1] not in "shdc":
            return [f"{name} is not a card. Write cards like As 10h 7d"]
    found = read_board(im), read_hole(im)
    for where, cards_found, names in (("board", found[0], board_names), ("hole", found[1], hole_names)):
        if len(cards_found) != len(names):
            return [f"{len(cards_found)} {where} cards are visible in the capture but {len(names)} were given"]
    T = load_templates(folder)
    notes = []
    for card, name in zip(found[0] + found[1], board_names + hole_names):
        rank, suit = name[:-1], name[-1]
        glyphs = [("rank", card["rank"], rank, RANK_MIN, RANK_MARGIN)]
        if card.get("big") is not None:
            glyphs.append(("big", card["big"], suit, SUIT_MIN, SUIT_MARGIN))
        else:
            glyphs.append(("suit", card["pip"], suit, SUIT_MIN, SUIT_MARGIN))
        for kind, glyph, label, low, margin in glyphs:
            if glyph is None:
                notes.append(f"{name}: no {kind} glyph found")
                continue
            allowed = None
            if kind != "rank":
                allowed = {"h", "d"} if glyph["color"] == "red" else {"s", "c"}
                if label not in allowed:
                    notes.append(f"{name}: the suit ink reads as {glyph['color']}, so it was not saved")
                    continue
            best, score, second = classify(glyph, T[kind], allowed, by_holes=kind == "rank")
            if best == label and score >= low and score - second >= margin:
                continue
            taken = glob.glob(os.path.join(folder, f"{kind}_{label}_l*.png"))
            out = os.path.join(folder, f"{kind}_{label}_l{len(taken):02d}.png")
            cv2.imwrite(out, (normalize(glyph["mask"]) * 255).clip(0, 255).astype(np.uint8))
            notes.append(f"{name}: saved {os.path.basename(out)} (was {best} {score:.2f})")
    return notes or ["every glyph already matches"]


def serve(T):
    # Ctrl-C in the terminal reaches this helper as well as the bot.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    for line in sys.stdin:
        path = line.strip()
        im = load(path) if path else None
        if im is None:
            result = {"board": [], "hole": [], "problems": [f"cannot read {path}"]}
        else:
            try:
                result = read_cards(im, T)
            except Exception as e:
                result = {"board": [], "hole": [], "problems": [f"card reader error: {e!r}"]}
        try:
            sys.stdout.write(json.dumps(result) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            return


def main():
    if sys.argv[1:2] == ["--learn"] and len(sys.argv) == 5:
        for note in learn(sys.argv[2], sys.argv[3].split(), sys.argv[4].split()):
            print(note)
        return
    T = load_templates()
    if sys.argv[1:] == ["--serve"]:
        serve(T)
        return
    for path in sys.argv[1:]:
        im = load(path)
        if im is None:
            print(f"{path}: cannot read")
            continue
        r = read_cards(im, T)
        note = f"  ({'; '.join(r['problems'])})" if r["problems"] else ""
        print(f"{path}: board [{' '.join(r['board'])}] hole [{' '.join(r['hole'])}]{note}")


if __name__ == "__main__":
    main()
