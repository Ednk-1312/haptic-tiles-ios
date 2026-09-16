#!/usr/bin/env python3
"""Train + export the Haptic Piano on-device AI models.

Input:  JSONL records produced by the Swift TrainingExport tool
        (difficulty.jsonl, events.jsonl, patterns.jsonl). Labels are ground
        truth from the app's own deterministic pipeline.
Output: Core ML .mlpackage models + model-manifest.json dropped straight into
        the Xcode project ("Music Haptics/AI/Models/"), plus a training report
        (AI/Training/out/train_report.json).

Models:
  - AIDifficulty:    GradientBoostingRegressor, 16 chart features → 0-10 score
  - AIEventRanking:  GradientBoostingRegressor, 16 event features → 0-1 importance
  - AIPatternRanking: GradientBoostingRegressor, 16 pattern features → 0-1
                      (how good a phrase's candidate pattern is; the
                      deterministic plan is the positive label)

Deterministic: fixed seeds, no data shuffling nondeterminism (sklearn GBR is
deterministic). Train/validation split is by song ID so no song leaks between
train and validation.

Usage:  .venv/bin/python train.py [dataDir] [outDir]
"""
import json
import math
import os
import sys
import time
from collections import defaultdict

import numpy as np
import sklearn
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import (mean_absolute_error, mean_squared_error,
                             roc_auc_score, precision_recall_curve,
                             r2_score)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "AI", "Training", "data")
MODEL_DIR = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO_ROOT, "Music Haptics", "AI", "Models")
OUT_DIR = os.path.join(REPO_ROOT, "AI", "Training", "out")

FEATURE_SCHEMA = 1
DIFFICULTY_MODEL_VERSION = 2
EVENT_MODEL_VERSION = 2
PATTERN_MODEL_VERSION = 2
TRAINING_DATA_VERSION = "synth-v4-corrected-difficulty-2026-09-15"
SEED = 42


def load_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def pearson(x, y):
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    if len(x) < 2 or np.std(x) == 0 or np.std(y) == 0:
        return 0.0
    return float(np.corrcoef(x, y)[0, 1])


def split_by_song(records, train_frac=0.85):
    """Song-disjoint split (no leakage between train and validation)."""
    song_ids = sorted({r["songID"] for r in records})
    rng = np.random.RandomState(SEED)
    rng.shuffle(song_ids)
    cut = max(1, int(len(song_ids) * train_frac))
    train_songs = set(song_ids[:cut])
    train = [r for r in records if r["songID"] in train_songs]
    val = [r for r in records if r["songID"] not in train_songs]
    return train, val


def train_difficulty():
    records = load_jsonl(os.path.join(DATA_DIR, "difficulty.jsonl"))
    print(f"Difficulty records: {len(records)}")
    train, val = split_by_song(records)
    X_train = np.array([r["features"] for r in train], dtype=np.float32)
    y_train = np.array([r["labelScore"] for r in train], dtype=np.float64)
    X_val = np.array([r["features"] for r in val], dtype=np.float32)
    y_val = np.array([r["labelScore"] for r in val], dtype=np.float64)
    print(f"  train {len(train)} songs/charts, val {len(val)}")

    model = GradientBoostingRegressor(
        n_estimators=160, max_depth=4, learning_rate=0.07,
        subsample=0.9, random_state=SEED)
    model.fit(X_train, y_train)
    pred = model.predict(X_val)
    mae = mean_absolute_error(y_val, pred)
    rmse = math.sqrt(mean_squared_error(y_val, pred))
    corr = pearson(y_val, pred)
    r2 = r2_score(y_val, pred)
    print(f"  difficulty  MAE={mae:.3f}  RMSE={rmse:.3f}  corr={corr:.3f}  R2={r2:.3f}")
    return model, {"mae": mae, "rmse": rmse, "correlation": corr, "r2": r2,
                   "train": len(train), "val": len(val)}


def train_events():
    records = load_jsonl(os.path.join(DATA_DIR, "events.jsonl"))
    print(f"Event records: {len(records)}")
    train, val = split_by_song(records)
    X_train = np.array([r["features"] for r in train], dtype=np.float32)
    y_train = np.array([r["labelSelected"] for r in train], dtype=np.float64)
    X_val = np.array([r["features"] for r in val], dtype=np.float32)
    y_val = np.array([r["labelSelected"] for r in val], dtype=np.float64)

    # Balance the classes via sample weights (selected events are rarer).
    pos = float(y_train.sum())
    neg = float(len(y_train) - y_train.sum())
    w = np.where(y_train == 1, 1.0, pos / max(neg, 1))
    w = w * (len(w) / w.sum())

    model = GradientBoostingRegressor(
        n_estimators=200, max_depth=5, learning_rate=0.06,
        subsample=0.85, random_state=SEED)
    model.fit(X_train, y_train, sample_weight=w)
    pred = model.predict(X_val)

    mae = mean_absolute_error(y_val, pred)
    rmse = math.sqrt(mean_squared_error(y_val, pred))
    auc = roc_auc_score(y_val, pred)
    precision, recall, thresholds = precision_recall_curve(y_val, pred)
    # Precision/recall at a 0.5 decision threshold.
    p05 = r05 = 0.0
    if np.any(thresholds <= 0.5):
        idx = int(np.argmax(thresholds <= 0.5))
        p05, r05 = precision[idx], recall[idx]
    # Agreement: fraction where the (fused, config-default) decision matches
    # the deterministic chart's decision. Deterministic kept the event iff the
    # label is 1; fused keeps it iff (0.65*dsp + 0.35*ai) >= 0.5.
    dsp = np.array([r["dspImportance"] for r in val], dtype=np.float64)
    fused = 0.65 * dsp + 0.35 * np.clip(pred, 0, 1)
    decisions = (fused >= 0.5).astype(int)
    agreement = float(np.mean(decisions == y_val))
    print(f"  events  MAE={mae:.4f}  RMSE={rmse:.4f}  AUC={auc:.4f}  "
          f"P@0.5={p05:.3f}  R@0.5={r05:.3f}  agreement={agreement:.4f}")
    return model, {"mae": mae, "rmse": rmse, "auc": auc,
                   "precisionAt05": p05, "recallAt05": r05,
                   "agreement": agreement, "train": len(train), "val": len(val)}


def train_patterns():
    records = load_jsonl(os.path.join(DATA_DIR, "patterns.jsonl"))
    print(f"Pattern records: {len(records)}")
    if not records:
        print("  (none — skipping pattern model; deterministic fallback stays active)")
        return None, None
    train, val = split_by_song(records)
    X_train = np.array([r["features"] for r in train], dtype=np.float32)
    y_train = np.array([r["labelSelected"] for r in train], dtype=np.float64)
    X_val = np.array([r["features"] for r in val], dtype=np.float32)
    y_val = np.array([r["labelSelected"] for r in val], dtype=np.float64)

    # The deterministic plan (candidate 0) is the positive class; balance it.
    pos = float(y_train.sum())
    neg = float(len(y_train) - y_train.sum())
    w = np.where(y_train == 1, 1.0, pos / max(neg, 1))
    w = w * (len(w) / w.sum())

    model = GradientBoostingRegressor(
        n_estimators=200, max_depth=5, learning_rate=0.06,
        subsample=0.85, random_state=SEED)
    model.fit(X_train, y_train, sample_weight=w)
    pred = model.predict(X_val)

    mae = mean_absolute_error(y_val, pred)
    rmse = math.sqrt(mean_squared_error(y_val, pred))
    auc = roc_auc_score(y_val, pred)
    precision, recall, thresholds = precision_recall_curve(y_val, pred)
    p05 = r05 = 0.0
    if np.any(thresholds <= 0.5):
        idx = int(np.argmax(thresholds <= 0.5))
        p05, r05 = precision[idx], recall[idx]
    # Agreement: for each phrase, does the fused (fit·0.45 + ai·0.55) argmax
    # pick the deterministic plan (candidate 0)?
    fused = 0.45 * np.array([r["features"][15] for r in val], dtype=np.float64) \
        + 0.55 * np.clip(pred, 0, 1)
    phrases = defaultdict(list)
    for rec, f in zip(val, fused):
        key = (rec["songID"], rec["difficultyRaw"], rec["variant"], rec["phraseIndex"])
        phrases[key].append((rec["candidateIndex"], float(f)))
    agreements = []
    for cands in phrases.values():
        best = max(cands, key=lambda c: c[1])[0]
        agreements.append(1.0 if best == 0 else 0.0)
    agreement = float(np.mean(agreements)) if agreements else 0.0
    print(f"  patterns  MAE={mae:.4f}  RMSE={rmse:.4f}  AUC={auc:.4f}  "
          f"P@0.5={p05:.3f}  R@0.5={r05:.3f}  fit-agreement={agreement:.4f}")
    return model, {"mae": mae, "rmse": rmse, "auc": auc,
                   "precisionAt05": p05, "recallAt05": r05,
                   "agreement": agreement, "train": len(train), "val": len(val)}


def convert(model, name, version, description, extra_eval):
    """Convert a sklearn GBR to Core ML.

    coremltools 8.x routes sklearn models exclusively through
    converters.sklearn.convert, which produces the classic .mlmodel spec
    (treeEnsembleRegressor in a pipeline). Xcode compiles that into .mlmodelc
    exactly like an .mlpackage — same runtime, same performance — so the
    distinction is irrelevant for these tiny models.
    """
    from coremltools.models import datatypes
    mlmodel = ct.converters.sklearn.convert(
        model,
        input_features=[("features", datatypes.Array(16))])
    mlmodel.short_description = description
    mlmodel.user_defined_metadata.update({
        "model_version": str(version),
        "feature_schema_version": str(FEATURE_SCHEMA),
        "training_data_version": TRAINING_DATA_VERSION,
        "framework": "scikit-learn GradientBoostingRegressor",
        "evaluation": json.dumps(extra_eval),
    })
    out = os.path.join(MODEL_DIR, f"{name}.mlmodel")
    os.makedirs(MODEL_DIR, exist_ok=True)
    mlmodel.save(out)
    print(f"  exported {out}")
    return out


def main():
    global ct
    try:
        import coremltools as ct
    except ImportError:
        sys.exit("coremltools missing — install with pip into AI/Training/.venv")
    os.makedirs(OUT_DIR, exist_ok=True)

    started = time.time()
    print(f"Data: {DATA_DIR}")

    diff_model, diff_eval = train_difficulty()
    event_model, event_eval = train_events()
    pattern_model, pattern_eval = train_patterns()

    convert(diff_model, "AIDifficulty", DIFFICULTY_MODEL_VERSION,
            "Predicts chart difficulty (0-10) from 16 normalized chart/music features.",
            diff_eval)
    convert(event_model, "AIEventRanking", EVENT_MODEL_VERSION,
            "Predicts how valuable a candidate musical event is for charting (0-1).",
            event_eval)
    if pattern_model is not None:
        convert(pattern_model, "AIPatternRanking", PATTERN_MODEL_VERSION,
                "Predicts how good a phrase's candidate pattern is (0-1); the deterministic plan is the positive label.",
                pattern_eval)

    manifest = {
        "trainingDataVersion": TRAINING_DATA_VERSION,
        "featureSchemaVersion": FEATURE_SCHEMA,
        "difficulty": {
            "modelVersion": DIFFICULTY_MODEL_VERSION,
            "featureCount": 16,
            "trainingRecordCount": diff_eval["train"],
            "evaluation": {
                "mae": round(diff_eval["mae"], 4),
                "rmse": round(diff_eval["rmse"], 4),
                "correlation": round(diff_eval["correlation"], 4),
                "note": "held-out song-disjoint validation vs deterministic difficulty"
            },
        },
        "eventRanking": {
            "modelVersion": EVENT_MODEL_VERSION,
            "featureCount": 16,
            "trainingRecordCount": event_eval["train"],
            "evaluation": {
                "mae": round(event_eval["mae"], 4),
                "rmse": round(event_eval["rmse"], 4),
                "auc": round(event_eval["auc"], 4),
                "precisionAt05": round(event_eval["precisionAt05"], 4),
                "recallAt05": round(event_eval["recallAt05"], 4),
                "agreement": round(event_eval["agreement"], 4),
                "note": "held-out song-disjoint validation vs deterministic selection"
            },
        },
        # Tempo is trained by train_tempo.py and remains part of the shared
        # manifest when this difficulty/event pipeline regenerates it.
        "tempoAnalysis": {
            "modelVersion": 1,
            "featureSchemaVersion": 1,
            "featureCount": 12,
            "trainingDataVersion": "tempo-synth-v1-2026-09-14",
            "trainingRecordCount": 6120,
            "evaluation": {
                "mae": 0.05956,
                "rmse": 0.15387,
                "top1Accuracy": 1.0,
                "baselineTop1Accuracy": 0.325,
                "note": "held-out song-disjoint validation on deterministic synthetic onset envelopes"
            }
        }
    }
    if pattern_eval is not None:
        manifest["patternRanking"] = {
            "modelVersion": PATTERN_MODEL_VERSION,
            "featureCount": 16,
            "trainingRecordCount": pattern_eval["train"],
            "evaluation": {
                "mae": round(pattern_eval["mae"], 4),
                "rmse": round(pattern_eval["rmse"], 4),
                "auc": round(pattern_eval["auc"], 4),
                "precisionAt05": round(pattern_eval["precisionAt05"], 4),
                "recallAt05": round(pattern_eval["recallAt05"], 4),
                "agreement": round(pattern_eval["agreement"], 4),
                "note": "held-out song-disjoint validation vs deterministic plan (candidate 0)"
            },
        }
    os.makedirs(MODEL_DIR, exist_ok=True)
    with open(os.path.join(MODEL_DIR, "model-manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    report = {"trainingDataVersion": TRAINING_DATA_VERSION,
              "elapsedSeconds": round(time.time() - started, 1),
              "difficulty": diff_eval, "eventRanking": event_eval,
              "patternRanking": pattern_eval}
    with open(os.path.join(OUT_DIR, "train_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"\nDone in {report['elapsedSeconds']}s. Manifest + report written.")


if __name__ == "__main__":
    main()