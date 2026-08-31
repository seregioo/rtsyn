#!/usr/bin/env python3
"""Plot and summarize RTSyn timing telemetry from a CSV file."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import sys
from pathlib import Path


REQUIRED_COLUMNS = (
    "cycle_id",
    "timestamp_ns",
    "period_ns",
    "actual_period_ns",
    "latency_ns",
    "wake_lateness_ns",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create timing graphs and summary statistics from RTSyn telemetry."
    )
    parser.add_argument("csv", type=Path, help="input telemetry CSV")
    parser.add_argument("-o", "--output", type=Path, help="output PNG path")
    parser.add_argument("--show", action="store_true", help="open the plot after saving")
    parser.add_argument("--dpi", type=int, default=160, help="PNG resolution (default: 160)")
    parser.add_argument(
        "--max-points",
        type=int,
        default=100_000,
        help="maximum time-series points to draw (default: 100000)",
    )
    return parser.parse_args()


def load_csv(path: Path) -> dict[str, list[float]]:
    columns = {name: [] for name in REQUIRED_COLUMNS}
    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        missing = [name for name in REQUIRED_COLUMNS if name not in (reader.fieldnames or [])]
        if missing:
            raise ValueError(f"missing required columns: {', '.join(missing)}")

        for line_number, row in enumerate(reader, start=2):
            try:
                values = {name: float(row[name]) for name in REQUIRED_COLUMNS}
            except (TypeError, ValueError) as error:
                raise ValueError(f"line {line_number}: invalid numeric value") from error
            if not all(math.isfinite(value) for value in values.values()):
                raise ValueError(f"line {line_number}: non-finite numeric value")
            for name, value in values.items():
                columns[name].append(value)

    if not columns["cycle_id"]:
        raise ValueError("CSV contains no measurements")
    return columns


def percentile(values: list[float], percentage: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentage / 100.0
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def time_unit(values: list[float]) -> tuple[float, str]:
    reference = percentile([abs(value) for value in values], 99.0)
    if reference >= 1_000_000:
        return 1_000_000.0, "ms"
    if reference >= 1_000:
        return 1_000.0, "µs"
    return 1.0, "ns"


def sampled_indices(length: int, maximum: int) -> range:
    step = max(1, math.ceil(length / max(1, maximum)))
    return range(0, length, step)


def print_summary(columns: dict[str, list[float]]) -> None:
    period = columns["period_ns"]
    actual = columns["actual_period_ns"]
    latency = columns["latency_ns"]
    lateness = columns["wake_lateness_ns"]
    error = [actual_value - period_value for actual_value, period_value in zip(actual, period)]
    skipped = [late // target if target > 0 else 0 for late, target in zip(lateness, period)]

    print(f"samples: {len(actual)}")
    print(f"duration: {(columns['timestamp_ns'][-1] - columns['timestamp_ns'][0]) / 1e9:.6f} s")
    for label, values in (
        ("period error", error),
        ("latency", latency),
        ("wake lateness", lateness),
    ):
        print(
            f"{label}: mean={statistics.fmean(values):.1f} ns "
            f"p50={percentile(values, 50):.1f} ns "
            f"p95={percentile(values, 95):.1f} ns "
            f"p99={percentile(values, 99):.1f} ns "
            f"max={max(values):.1f} ns"
        )
    print(f"cycles with at least one skipped period: {sum(value >= 1 for value in skipped)}")


def create_plot(columns: dict[str, list[float]], output: Path, show: bool, dpi: int,
                max_points: int) -> None:
    try:
        import matplotlib
        if not show:
            matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "matplotlib is required; install it with: python3 -m pip install matplotlib"
        ) from error

    timestamps = columns["timestamp_ns"]
    elapsed_s = [(value - timestamps[0]) / 1e9 for value in timestamps]
    period = columns["period_ns"]
    actual = columns["actual_period_ns"]
    latency = columns["latency_ns"]
    lateness = columns["wake_lateness_ns"]
    error = [actual_value - period_value for actual_value, period_value in zip(actual, period)]
    indices = sampled_indices(len(actual), max_points)

    timing_scale, timing_unit = time_unit(actual + latency + lateness)
    error_scale, error_unit = time_unit(error)

    plt.style.use("dark_background")
    figure, axes = plt.subplots(2, 2, figsize=(15, 9), constrained_layout=True)
    figure.suptitle(f"RTSyn telemetry — {output.stem}", fontsize=15)

    axes[0, 0].plot(
        [elapsed_s[i] for i in indices],
        [actual[i] / timing_scale for i in indices],
        linewidth=0.7,
        label="Actual period",
    )
    axes[0, 0].plot(
        [elapsed_s[i] for i in indices],
        [period[i] / timing_scale for i in indices],
        linewidth=1.0,
        label="Requested period",
    )
    axes[0, 0].set(title="Period over time", xlabel="Elapsed time (s)", ylabel=timing_unit)
    axes[0, 0].legend()

    axes[0, 1].plot(
        [elapsed_s[i] for i in indices],
        [latency[i] / timing_scale for i in indices],
        linewidth=0.7,
        label="Latency",
    )
    axes[0, 1].plot(
        [elapsed_s[i] for i in indices],
        [lateness[i] / timing_scale for i in indices],
        linewidth=0.7,
        label="Wake lateness",
    )
    axes[0, 1].set(title="Latency over time", xlabel="Elapsed time (s)", ylabel=timing_unit)
    axes[0, 1].legend()

    axes[1, 0].hist([value / error_scale for value in error], bins="auto", alpha=0.85)
    axes[1, 0].axvline(0, color="white", linewidth=0.8)
    axes[1, 0].set(title="Period-error distribution", xlabel=f"Actual − requested ({error_unit})",
                   ylabel="Samples")

    ordered_lateness = sorted(lateness)
    cumulative = [(index + 1) / len(ordered_lateness) * 100 for index in range(len(ordered_lateness))]
    axes[1, 1].plot(
        [value / timing_scale for value in ordered_lateness], cumulative, linewidth=1.2
    )
    axes[1, 1].set(title="Wake-lateness CDF", xlabel=timing_unit, ylabel="Samples ≤ value (%)")
    axes[1, 1].grid(alpha=0.25)

    for axis in axes.flat:
        axis.grid(alpha=0.18)

    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output, dpi=dpi)
    print(f"plot: {output}")
    if show:
        plt.show()
    plt.close(figure)


def main() -> int:
    args = parse_args()
    output = args.output or args.csv.with_name(f"{args.csv.stem}_telemetry.png")
    try:
        columns = load_csv(args.csv)
        print_summary(columns)
        create_plot(columns, output, args.show, args.dpi, args.max_points)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
