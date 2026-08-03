#!/usr/bin/env python3
"""Score the visibility and identity gates against real Vision output.

Reads two files and nothing else: `vision-cache.json`, which is what Vision
actually saw, and `observations.json`, which is what a human says is true. The
gate is a pure function between them, so trying a threshold costs milliseconds
and touches no device.

This is the *explorer*. `ScanPolicy` in the app stays the shipped
implementation; this exists to find where a threshold belongs by reading the
distribution, rather than by guessing three values and running a field test.
Anything learned here has to be encoded there, and `--check` compares the two.

Overfitting is the standing risk: 490 photos from one library, and a single
burst holds 13% of the target. So the split unit is the occasion, tuning only
ever sees dev, and every number is reported for both halves.

    python3 tools/score_gates.py            # score the current thresholds
    python3 tools/score_gates.py --sweep    # where could each threshold go
    python3 tools/score_gates.py --test     # open the held-out half
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELS = ROOT / "fixtures" / "labels" / "observations.json"
CACHE = ROOT / "fixtures" / "labels" / "vision-cache.json"

# Current thresholds, mirroring the app.
MIN_PERSON_HEIGHT = 0.25
JOINT_CONFIDENCE = 0.30
IDENTITY_COSINE = 0.363
MIN_FACE_PX = 48

# Which occasions are held out. Chosen by hash of the occasion number so the
# split is stable across runs and independent of anything being tuned — picking
# the test half by looking at results is how a held-out set stops being one.
TEST_FRACTION = 0.4


def dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def cosine(a: list[float], b: list[float]) -> float:
    """The embeddings are already L2-normalised, but not by contract."""
    na, nb = math.sqrt(dot(a, a)), math.sqrt(dot(b, b))
    if na == 0 or nb == 0:
        return 0.0
    return dot(a, b) / (na * nb)


def seed_ids() -> set[str]:
    """The photos standing in for 'the user picked themselves', once, at setup."""
    directory = ROOT / "fixtures" / "inbox" / "seed"
    return {path.stem for path in directory.glob("*.jpg")}


def load() -> tuple[list[dict], dict[str, dict], list[list[float]]]:
    labels = json.loads(LABELS.read_text())["photos"]
    cache = {f["id"]: f for f in json.loads(CACHE.read_text())}

    # The seed bucket turned out to be copies of eight *labelled* photos, so
    # they are excluded from scoring rather than merely used as references.
    # Calibrating identity on a face and then scoring identity on the same face
    # measures nothing, and the mistake is invisible in the result — the number
    # just comes out better than it should.
    seeds = [
        face["embedding"]
        for pid in seed_ids()
        for face in cache.get(pid, {}).get("faces", [])
        if face.get("embedding")
    ]
    labels = [p for p in labels if p["id"] not in seed_ids()]
    return labels, cache, seeds


def is_test(photo: dict) -> bool:
    occasion = photo.get("occasion", -1)
    # Undated photos have no occasion and cannot be safely split; keep them in
    # dev so they can never inflate a held-out score.
    if occasion < 0:
        return False
    return (occasion * 2654435761) % 100 < TEST_FRACTION * 100


def tallest_person(facts: dict) -> float:
    return max((box["height"] for box in facts["people"]), default=0.0)


def joints_present(facts: dict, names: set[str], confidence: float) -> bool:
    """Case-insensitive: Vision names joints `leftShoulder`, `neck`, `root`.

    Note these are never *absent* — every pose carries all 19 joints, so this is
    only ever a question about confidence. A gate phrased as "are the hips
    present" was answering a question that has no false case.
    """
    for pose in facts["poses"]:
        if all(
            any(
                key.lower().endswith(name.lower()) and joint["confidence"] >= confidence
                for key, joint in pose["joints"].items()
            )
            for name in names
        ):
            return True
    return False


def best_cosine(facts: dict, seeds: list[list[float]], min_face_px: float) -> float:
    best = -1.0
    for face in facts["faces"]:
        if face["sidePx"] < min_face_px or not face.get("embedding"):
            continue
        for seed in seeds:
            best = max(best, cosine(face["embedding"], seed))
    return best


def predict(facts: dict, seeds: list[list[float]], knobs: dict) -> tuple[bool, str]:
    """Both gates, in pipeline order. Returns (is a photo of the owner we can use, why not)."""
    if facts["isUtility"]:
        return False, "utility"
    if tallest_person(facts) < knobs["min_person_height"]:
        return False, "too small / no person"
    if not joints_present(facts, knobs["joints"], knobs["joint_confidence"]):
        return False, "no readable body"
    if best_cosine(facts, seeds, knobs["min_face_px"]) < knobs["identity_cosine"]:
        return False, "not identified as owner"
    return True, ""


def score(labels, cache, seeds, knobs, subset) -> dict:
    tp = fp = fn = 0
    reasons = collections.Counter()
    covered, target_occasions = set(), set()
    for photo in labels:
        if not subset(photo):
            continue
        facts = cache.get(photo["id"])
        if not facts:
            continue
        truth = photo["visibility"] == "readable" and photo["identity"] == "owner"
        if truth:
            target_occasions.add(photo.get("occasion", -1))
        got, why = predict(facts, seeds, knobs)
        if got and truth:
            tp += 1
            covered.add(photo.get("occasion", -1))
        elif got:
            fp += 1
        elif truth:
            fn += 1
            reasons[why] += 1
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    coverage = len(covered) / len(target_occasions) if target_occasions else 0.0
    return {
        "tp": tp, "fp": fp, "fn": fn,
        "precision": precision, "recall": recall,
        "coverage": coverage,
        "occasions": f"{len(covered)}/{len(target_occasions)}",
        "misses": reasons,
    }


def report(name: str, result: dict) -> None:
    print(
        f"  {name:5}  precision {result['precision']:.1%}  "
        f"photo-recall {result['recall']:.1%}  "
        f"occasion-coverage {result['coverage']:.1%} ({result['occasions']})  "
        f"[tp {result['tp']} fp {result['fp']} fn {result['fn']}]"
    )
    for why, count in result["misses"].most_common():
        print(f"           lost {count:3} to: {why}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sweep", action="store_true", help="show where each threshold could go")
    parser.add_argument("--search", action="store_true", help="grid search, best coverage at precision >= 85 percent")
    parser.add_argument("--test", action="store_true", help="open the held-out occasions")
    args = parser.parse_args()

    if not CACHE.exists():
        print("No vision cache — run `make vision-cache` first.", file=sys.stderr)
        return 1

    labels, cache, seeds = load()
    knobs = {
        "min_person_height": MIN_PERSON_HEIGHT,
        "joints": {"Shoulder", "Hip"},
        "joint_confidence": JOINT_CONFIDENCE,
        "identity_cosine": IDENTITY_COSINE,
        "min_face_px": MIN_FACE_PX,
    }

    target = [p for p in labels if p["visibility"] == "readable" and p["identity"] == "owner"]
    dev_target = [p for p in target if not is_test(p)]
    print(f"corpus {len(labels)} · seeds {len(seeds)} · target {len(target)} "
          f"({len(dev_target)} dev / {len(target) - len(dev_target)} test)\n")

    print("GOAL  occasion-coverage >= 95%, precision >= 85%, on held-out occasions\n")
    report("dev", score(labels, cache, seeds, knobs, lambda p: not is_test(p)))
    if args.test:
        report("test", score(labels, cache, seeds, knobs, is_test))
    else:
        print("  test   (held out — pass --test to open it)")

    if args.search:
        # Grid search on dev only. Ranked by occasion coverage among configs
        # that clear the precision bar, because coverage is the recall proxy
        # that survives pass 3 being deferred: one good photo per occasion is
        # what a garment actually needs.
        #
        # Kept deliberately small. Every knob is a degree of freedom and there
        # are 97 dev targets — searching a thousand configs against a hundred
        # photos finds noise and calls it a threshold.
        results = []
        for joints in [{"Shoulder"}, {"Shoulder", "Hip"}, {"Neck"}, {"Shoulder", "Neck"}]:
            for joint_confidence in [0.02, 0.05, 0.10, 0.20, 0.30]:
                for height in [0.15, 0.25, 0.35]:
                    for cosine_threshold in [0.30, 0.363, 0.45]:
                        trial = dict(knobs) | {
                            "joints": joints,
                            "joint_confidence": joint_confidence,
                            "min_person_height": height,
                            "identity_cosine": cosine_threshold,
                        }
                        r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
                        results.append((r, trial))
        passing = [(r, t) for r, t in results if r["precision"] >= 0.85]
        passing.sort(key=lambda rt: (-rt[0]["coverage"], -rt[0]["precision"]))
        print(f"\ngrid: {len(results)} configs, {len(passing)} clear precision >= 85% (dev)")
        print("  best by occasion coverage:")
        for r, t in passing[:8]:
            print(f"    cov {r['coverage']:5.1%} prec {r['precision']:5.1%} rec {r['recall']:5.1%}  "
                  f"joints={'+'.join(sorted(t['joints'])):13} conf={t['joint_confidence']:<5} "
                  f"h={t['min_person_height']:<5} cos={t['identity_cosine']}")

    if args.sweep:
        print("\nsweep, on dev only:")
        for name, key, values in [
            ("person height", "min_person_height", [0.10, 0.15, 0.20, 0.25, 0.30, 0.40]),
            ("joint conf", "joint_confidence", [0.05, 0.10, 0.20, 0.30, 0.50]),
            ("identity cos", "identity_cosine", [0.20, 0.30, 0.363, 0.45, 0.55]),
            ("min face px", "min_face_px", [12, 24, 36, 48, 64]),
        ]:
            print(f"\n  {name}")
            for value in values:
                trial = dict(knobs) | {key: value}
                r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
                mark = " <- current" if value == knobs[key] else ""
                print(f"    {value:<6} precision {r['precision']:.1%}  "
                      f"coverage {r['coverage']:.1%}  recall {r['recall']:.1%}{mark}")

        print("\n  joint sets")
        for joints in [{"Shoulder", "Hip"}, {"Shoulder"}, {"Shoulder", "Neck"}, {"Hip"}]:
            trial = dict(knobs) | {"joints": joints}
            r = score(labels, cache, seeds, trial, lambda p: not is_test(p))
            print(f"    {'+'.join(sorted(joints)):18} precision {r['precision']:.1%}  "
                  f"coverage {r['coverage']:.1%}  recall {r['recall']:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
