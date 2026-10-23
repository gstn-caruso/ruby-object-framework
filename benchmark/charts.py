"""Regenerate the README charts from the checked-in benchmark measurements."""

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator


ROOT = Path(__file__).resolve().parent
COLORS = {"interpreter": "#64748b", "yjit": "#087e8b", "zjit": "#8954a8"}
LABELS = {"interpreter": "Interpreter", "yjit": "YJIT", "zjit": "ZJIT"}


def generate_charts():
    measurements = json.loads((ROOT / "results.json").read_text())
    results = measurements["results"]
    samples = [sample for result in results for sample in result["samples"]]
    iterations = {sample["iterations"] for sample in samples}
    counts = {len(result["samples"]) for result in results}
    if len(iterations) != 1 or len(counts) != 1:
        raise ValueError("Charts require equal iterations and sample counts across modes")

    output = ROOT / "charts"
    output.mkdir(exist_ok=True)
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                         "svg.fonttype": "none", "svg.hashsalt": "object-framework"})
    measured_at = measurements["measured_at"].replace("T", " ").replace("Z", " UTC")
    caption = (f"Ruby {samples[0]['ruby']}  ·  {iterations.pop():,} invocations/sample"
               f"  ·  {counts.pop()} samples/mode  ·  {measured_at}")
    metadata = {"Date": measurements["measured_at"],
                "Creator": "ObjectFramework benchmark/charts.py"}

    def save(figure, name, title):
        svg = output / f"{name}.svg"
        figure.savefig(svg, metadata={**metadata, "Title": title})
        svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
        figure.savefig(output / f"{name}.png", dpi=180, metadata={"Title": title})
        plt.close(figure)

    def chart(title, subtitle, xlabel):
        figure, axis = plt.subplots(figsize=(10.5, 4.8))
        figure.subplots_adjust(left=0.18, right=0.94, top=0.69, bottom=0.26)
        figure.text(0.05, 0.91, title, fontsize=20, weight="bold", color="#17334a")
        figure.text(0.05, 0.83, subtitle, fontsize=11, color="#526779")
        figure.text(0.05, 0.10, caption, fontsize=9, color="#526779")
        figure.text(0.05, 0.055, "Source: benchmark/results.json", fontsize=9, color="#526779")
        axis.set_yticks(range(len(results)), [LABELS[result["mode"]] for result in results])
        axis.set_ylim(len(results) - 0.5, -0.5)
        axis.set_xlabel(xlabel, labelpad=10, color="#526779")
        axis.tick_params(axis="both", length=0, pad=9, colors="#526779")
        axis.set_axisbelow(True)
        axis.grid(axis="x", color="#e2e8f0")
        axis.spines[["top", "right", "left", "bottom"]].set_visible(False)
        axis.xaxis.set_major_locator(MaxNLocator(nbins=5))
        return figure, axis

    medians = [result["median_seconds"] * 1000 for result in results]
    maximum = max(sample["seconds"] * 1000 for sample in samples)
    colors = [COLORS[result["mode"]] for result in results]
    figure, axis = chart("Application execution time",
                         "Bars: median · Dots: individual samples · Lower is better",
                         "Elapsed time (ms)")
    axis.barh(range(len(results)), medians, height=0.5, color=colors)
    axis.set_xlim(0, maximum * 1.22)
    for row, result in enumerate(results):
        times = [sample["seconds"] * 1000 for sample in result["samples"]]
        axis.scatter(times, [row] * len(times), s=36, color="white",
                     edgecolors="#17334a", linewidths=1.2, zorder=3)
        axis.text(max(times + [medians[row]]) + maximum * 0.025, row,
                  f"{medians[row]:.2f} ms", va="center", weight="bold", color="#17334a")
    save(figure, "execution-time", "Application execution time")

    baseline = next(result["median_seconds"] for result in results if result["mode"] == "interpreter")
    speedups = [baseline / result["median_seconds"] for result in results]
    figure, axis = chart("Speedup relative to the interpreter",
                         "Interpreter median / mode median · Higher is better",
                         "Speedup (× interpreter)")
    axis.barh(range(len(results)), speedups, height=0.5, color=colors)
    axis.set_xlim(0, max(speedups) * 1.22)
    axis.axvline(1, color="#17334a", linewidth=1, linestyle="--")
    for row, speedup in enumerate(speedups):
        axis.text(speedup + max(speedups) * 0.025, row, f"{speedup:.2f}×",
                  va="center", weight="bold", color="#17334a")
    save(figure, "speedup", "Speedup relative to the interpreter")


if __name__ == "__main__":
    generate_charts()
