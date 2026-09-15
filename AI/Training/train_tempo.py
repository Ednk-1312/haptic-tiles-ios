#!/usr/bin/env python3
"""Train and export the compact AITempo Core ML model.

The tempo model is a purpose-built candidate ranker, not a generative model.
It receives the same 12 normalized candidate features produced by
`TempoAnalysisMath.modelFeatures` and returns one score for a half/normal/
double-time candidate. Training examples are deterministic synthetic onset
signals with tempo ambiguity, noise, weak percussion, and modest tempo drift.
The model is validated by song-disjoint splits before it is written to the app.

Usage:
    AI/Training/.venv/bin/python AI/Training/train_tempo.py
    AI/Training/.venv/bin/python AI/Training/train_tempo.py --songs 2400

Outputs:
    Music Haptics/AI/Models/AITempo.mlmodel
    Music Haptics/AI/Models/model-manifest.json (tempoAnalysis entry merged)
    AI/Training/out/tempo_train_report.json

No audio is read or uploaded. The generated signal envelopes are training
fixtures only; the shipped app analyzes each user's audio locally with
AVFoundation/Accelerate and passes only its compact flux features to Core ML.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import time
from collections import defaultdict

import numpy as np
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error

try:
    import coremltools as ct
    from coremltools.models import datatypes
except ImportError as exc:  # pragma: no cover - exercised by the CLI environment
    raise SystemExit("coremltools is required; use AI/Training/.venv/bin/python") from exc


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODEL_DIR = os.path.join(REPO_ROOT, "Music Haptics", "AI", "Models")
OUT_DIR = os.path.join(REPO_ROOT, "AI", "Training", "out")
MODEL_NAME = "AITempo"
MODEL_VERSION = 1
FEATURE_SCHEMA_VERSION = 1
TRAINING_DATA_VERSION = "tempo-synth-v1-2026-09-14"
SEED = 42
HOP_TIME = 512.0 / 44_100.0
FEATURE_COUNT = 12


def clamp(value: float, lower: float, upper: float) -> float:
    return min(upper, max(lower, value if math.isfinite(value) else lower))


def periodicity(bpm: float, flux: np.ndarray, hop_time: float) -> float:
    """Match TempoAnalysisMath.periodicity in the Swift runtime."""
    if bpm <= 0 or hop_time <= 0 or len(flux) <= 8:
        return 0.0
    lag = int(round(60.0 / bpm / hop_time))
    if lag <= 0 or lag >= len(flux) - 1:
        return 0.0
    centered = flux.astype(np.float64) - float(np.mean(flux))
    denominator = float(np.dot(centered, centered))
    if denominator <= 1e-12:
        return 0.0
    numerator = float(np.dot(centered[:-lag], centered[lag:]))
    return clamp(numerator / denominator, 0.0, 1.0)


def candidates(around_bpm: float) -> list[float]:
    raw = [around_bpm / 2.0, around_bpm, around_bpm * 2.0]
    result: list[float] = []
    for value in raw:
        value = clamp(value, 40.0, 220.0)
        if not any(abs(value - existing) < 0.001 for existing in result):
            result.append(value)
    return result


def make_flux(true_bpm: float, seconds: float, rng: np.random.RandomState,
              drift: bool, weak_percussion: bool) -> np.ndarray:
    """Create a compact onset envelope with realistic ambiguity/noise."""
    count = int(seconds / HOP_TIME)
    flux = rng.normal(0.0, 0.035, count).astype(np.float32)
    interval = 60.0 / true_bpm / HOP_TIME
    phase = rng.uniform(0.0, max(interval, 1.0))
    index = phase
    while index < count:
        i = int(round(index))
        if 0 <= i < count:
            amplitude = rng.uniform(0.65, 1.15) * (0.65 if weak_percussion else 1.0)
            flux[i] += amplitude
            if i + 1 < count:
                flux[i + 1] += amplitude * rng.uniform(0.12, 0.30)
        index += interval

    # Many tracks contain an eighth-note or subdivision envelope. It makes
    # octave ambiguity real rather than allowing the model to memorize BPM.
    if rng.random_sample() < 0.78:
        subdivision = max(1.0, interval / 2.0)
        index = phase + subdivision * rng.uniform(0.15, 0.85)
        while index < count:
            i = int(round(index))
            if 0 <= i < count:
                flux[i] += rng.uniform(0.08, 0.42) * (0.7 if weak_percussion else 1.0)
            index += interval

    # An optional drift section exercises the stability/tempo-change feature
    # without making the model part of the real-time game loop.
    if drift:
        midpoint = count // 2
        second_interval = interval * rng.uniform(0.90, 1.10)
        index = midpoint + rng.uniform(0, second_interval)
        while index < count:
            i = int(round(index))
            if 0 <= i < count:
                flux[i] += rng.uniform(0.25, 0.85)
            index += second_interval

    # Sparse unrelated transients model vocals/noisy material and prevent a
    # trivial impulse-count lookup.
    transient_count = max(2, int(seconds * rng.uniform(0.2, 1.2)))
    for i in rng.randint(0, count, transient_count):
        flux[i] += rng.uniform(0.02, 0.22)
    return np.maximum(flux, 0.0)


def runtime_features(candidate_bpm: float, baseline_bpm: float,
                     baseline_confidence: float, stability: float,
                     ambiguity: float, tempo_change: bool,
                     flux: np.ndarray) -> list[float]:
    primary = periodicity(baseline_bpm, flux, HOP_TIME)
    candidate = periodicity(candidate_bpm, flux, HOP_TIME)
    return [
        clamp((candidate_bpm - 40.0) / 180.0, 0.0, 1.0),
        clamp(candidate, 0.0, 1.0),
        clamp(primary, 0.0, 1.0),
        clamp(baseline_confidence, 0.0, 1.0),
        clamp(stability, 0.0, 1.0),
        clamp(ambiguity, 0.0, 1.0),
        1.0 if tempo_change else 0.0,
        1.0 if candidate_bpm < baseline_bpm else 0.0,
        1.0 if candidate_bpm > baseline_bpm else 0.0,
        clamp(abs(candidate_bpm - baseline_bpm) / 120.0, 0.0, 1.0),
        clamp(len(flux) * HOP_TIME / 60.0, 0.0, 1.0),
        clamp(HOP_TIME * 100.0, 0.0, 1.0),
    ]


def make_dataset(song_count: int) -> tuple[np.ndarray, np.ndarray, list[dict]]:
    rng = np.random.RandomState(SEED)
    features: list[list[float]] = []
    labels: list[float] = []
    records: list[dict] = []
    for song_index in range(song_count):
        baseline = float(rng.uniform(78.0, 158.0))
        choices = candidates(baseline)
        truth_index = int(rng.choice(len(choices), p=np.ones(len(choices)) / len(choices)))
        true_bpm = choices[truth_index]
        seconds = float(rng.uniform(12.0, 30.0))
        drift = bool(rng.random_sample() < 0.18)
        weak = bool(rng.random_sample() < 0.24)
        flux = make_flux(true_bpm, seconds, rng, drift, weak)

        primary = periodicity(baseline, flux, HOP_TIME)
        half = periodicity(baseline / 2.0, flux, HOP_TIME)
        double = periodicity(baseline * 2.0, flux, HOP_TIME)
        ambiguity = clamp(max(half, double) - primary, 0.0, 1.0)
        confidence = clamp(0.40 + primary * 0.50 + rng.normal(0.0, 0.06), 0.08, 0.98)
        stability = clamp(0.92 - (0.38 if drift else 0.0) + rng.normal(0.0, 0.08), 0.05, 1.0)
        tempo_change = drift
        song_id = f"tempo-song-{song_index:05d}"
        for candidate_index, candidate in enumerate(choices):
            row = runtime_features(candidate, baseline, confidence, stability,
                                   ambiguity, tempo_change, flux)
            features.append(row)
            # Ground truth is the candidate represented by the synthesized
            # signal. A tiny deterministic label jitter avoids a brittle
            # threshold while preserving the ranking target.
            label = 1.0 if candidate_index == truth_index else 0.0
            label += float(rng.normal(0.0, 0.008))
            labels.append(clamp(label, 0.0, 1.0))
            records.append({"songID": song_id, "candidateIndex": candidate_index,
                            "truthIndex": truth_index})
    return (np.asarray(features, dtype=np.float32),
            np.asarray(labels, dtype=np.float64), records)


def split_by_song(records: list[dict], train_fraction: float = 0.85) -> tuple[set[str], set[str]]:
    songs = sorted({record["songID"] for record in records})
    rng = np.random.RandomState(SEED)
    rng.shuffle(songs)
    cut = max(1, int(len(songs) * train_fraction))
    return set(songs[:cut]), set(songs[cut:])


def evaluate(predictions: np.ndarray, labels: np.ndarray,
             records: list[dict]) -> dict[str, float | int]:
    groups: dict[str, list[int]] = defaultdict(list)
    for index, record in enumerate(records):
        groups[record["songID"]].append(index)
    correct = 0
    baseline_correct = 0
    for indices in groups.values():
        winner = max(indices, key=lambda index: float(predictions[index]))
        truth = records[indices[0]]["truthIndex"]
        winner_candidate = records[winner]["candidateIndex"]
        correct += int(winner_candidate == truth)
        # The DSP baseline is the middle (unmultiplied) candidate.
        baseline_correct += int(records[indices[0]]["candidateIndex"] == truth)
    song_count = len(groups)
    return {
        "songCount": song_count,
        "mae": float(mean_absolute_error(labels, predictions)),
        "rmse": float(math.sqrt(mean_squared_error(labels, predictions))),
        "top1Accuracy": float(correct / max(song_count, 1)),
        "baselineTop1Accuracy": float(baseline_correct / max(song_count, 1)),
    }


def export_model(model: GradientBoostingRegressor, evaluation: dict) -> str:
    mlmodel = ct.converters.sklearn.convert(
        model,
        input_features=[("features", datatypes.Array(FEATURE_COUNT))],
    )
    mlmodel.short_description = (
        "Ranks half-time, normal-time, and double-time tempo candidates from "
        "12 compact onset-envelope features."
    )
    mlmodel.author = "Haptic Piano local tempo analysis"
    mlmodel.version = str(MODEL_VERSION)
    mlmodel.user_defined_metadata.update({
        "model_version": str(MODEL_VERSION),
        "feature_schema_version": str(FEATURE_SCHEMA_VERSION),
        "training_data_version": TRAINING_DATA_VERSION,
        "framework": "scikit-learn GradientBoostingRegressor",
        "evaluation": json.dumps(evaluation, sort_keys=True),
        "privacy": "synthetic fixtures; app inference is on-device",
    })
    os.makedirs(MODEL_DIR, exist_ok=True)
    output = os.path.join(MODEL_DIR, f"{MODEL_NAME}.mlmodel")
    mlmodel.save(output)
    return output


def update_manifest(evaluation: dict, training_records: int) -> str:
    path = os.path.join(MODEL_DIR, "model-manifest.json")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        manifest = {}
    manifest["tempoAnalysis"] = {
        "modelVersion": MODEL_VERSION,
        "featureSchemaVersion": FEATURE_SCHEMA_VERSION,
        "featureCount": FEATURE_COUNT,
        "trainingDataVersion": TRAINING_DATA_VERSION,
        "trainingRecordCount": training_records,
        "evaluation": {
            "mae": round(float(evaluation["mae"]), 5),
            "rmse": round(float(evaluation["rmse"]), 5),
            "top1Accuracy": round(float(evaluation["top1Accuracy"]), 5),
            "baselineTop1Accuracy": round(float(evaluation["baselineTop1Accuracy"]), 5),
            "note": "held-out song-disjoint validation on deterministic synthetic onset envelopes",
        },
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--songs", type=int, default=2400,
                        help="number of deterministic synthetic songs (default: 2400)")
    args = parser.parse_args()
    if args.songs < 120:
        raise SystemExit("--songs must be at least 120 for a meaningful split")

    started = time.perf_counter()
    X, y, records = make_dataset(args.songs)
    train_songs, validation_songs = split_by_song(records)
    train_indices = [i for i, record in enumerate(records) if record["songID"] in train_songs]
    validation_indices = [i for i, record in enumerate(records) if record["songID"] in validation_songs]

    model = GradientBoostingRegressor(
        n_estimators=140,
        max_depth=3,
        learning_rate=0.06,
        subsample=0.90,
        random_state=SEED,
    )
    model.fit(X[train_indices], y[train_indices])
    predictions = np.clip(model.predict(X[validation_indices]), 0.0, 1.0)
    validation_records = [records[i] for i in validation_indices]
    evaluation = evaluate(predictions, y[validation_indices], validation_records)
    model_path = export_model(model, evaluation)
    manifest_path = update_manifest(evaluation, len(train_indices))

    os.makedirs(OUT_DIR, exist_ok=True)
    report = {
        "model": MODEL_NAME,
        "modelVersion": MODEL_VERSION,
        "featureSchemaVersion": FEATURE_SCHEMA_VERSION,
        "trainingDataVersion": TRAINING_DATA_VERSION,
        "seed": SEED,
        "syntheticSongCount": args.songs,
        "trainingRecordCount": len(train_indices),
        "validationRecordCount": len(validation_indices),
        "evaluation": evaluation,
        "elapsedSeconds": round(time.perf_counter() - started, 3),
        "modelPath": os.path.relpath(model_path, REPO_ROOT),
        "manifestPath": os.path.relpath(manifest_path, REPO_ROOT),
    }
    report_path = os.path.join(OUT_DIR, "tempo_train_report.json")
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")

    print(json.dumps(report, indent=2))
    if evaluation["top1Accuracy"] < 0.80:
        raise SystemExit("tempo model validation accuracy is below the 0.80 release gate")


if __name__ == "__main__":
    main()
