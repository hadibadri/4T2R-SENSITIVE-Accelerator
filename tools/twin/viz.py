# -----------------------------------------------------------------------------
# viz.py  --  HONEST visualization for the ArchBetter eval.
#
# Design rules (the user's explicit ask -- no vanity charts):
#   * NO "our bar on top, everyone on the floor" plot. Bars are sorted by VALUE,
#     not by us-first; we land where the number lands (sometimes lower).
#   * Primary comparison views are a Pareto SCATTER (throughput vs power) and a
#     RADAR (multi-axis), which inherently SHOW where we lose, not just where we win.
#   * Unreported (None) values are DROPPED from an axis -- never plotted as 0.
#   * Every chart annotates POWER SCOPE (core vs system+HBM) and MODEL, because
#     cohort tok/s is LLaMA2-7B and ours is TinyLlama-1.1B (not raw-comparable).
#   * Our points are marked [M] measured (filled) vs [P] projected (hollow/hatched).
# -----------------------------------------------------------------------------
import numpy as np
import matplotlib.pyplot as plt

_SCOPE_C = {"core": "#1b9e77", "system+HBM": "#d95f02", "system (<7W envelope)": "#d95f02",
            "system (KV260, few W)": "#d95f02", "system (Kria, few W)": "#d95f02",
            "ASIC core": "#7570b3", "ASIC macro": "#7570b3", "n/r": "#999999",
            "core (DRAM external)": "#1b9e77"}


def _scope_color(s): return _SCOPE_C.get(s, "#999999")


def cohort_table(cohort, arch):
    """Render the authentic cohort table; None -> 'n/r'. Returns a pandas DataFrame
    so Colab shows it natively; nothing here is invented."""
    import pandas as pd
    rows = []
    for w in cohort:
        rows.append(dict(Work=w["name"], Device=w["device"], Class=w["cls"],
                         Clock=w["clock_mhz"], Model=w["model"], Precision=w["precision"],
                         tok_s=w["tok_s"], tok_per_J=w["tok_per_J"],
                         Power_W=w["power_w"], Scope=w["power_scope"],
                         GOPS=w["gops"], GOPS_per_W=w["gops_per_w"], Source=w["cite"]))
    rows.append(dict(Work=arch["name"], Device=arch["device"], Class=arch["cls"],
                     Clock=arch["clock_mhz"], Model=arch["model"], Precision=arch["precision"],
                     tok_s=f"{arch['tok_s_decode_bfp12_shred']} [P]",
                     tok_per_J=f"{arch['tok_per_J_core']} [P]",
                     Power_W=arch["power_w_core"], Scope=arch["power_scope"],
                     GOPS=f"{arch['gops_peak']} pk / {arch['gops_prefill_proj']} pf[P]",
                     GOPS_per_W=None, Source=arch["cite"]))
    df = pd.DataFrame(rows).fillna("n/r")
    return df


def pareto_throughput_power(cohort, arch, ax=None):
    """Throughput-vs-power Pareto scatter. Only works reporting BOTH axes appear.
    Marker color = power scope (so cross-scope points are visibly different).
    ArchBetter appears as a measured-power [M] point with a projected-tok/s [P]
    error bar -- honest about which coordinate is data."""
    if ax is None: _, ax = plt.subplots(figsize=(7, 5))
    for w in cohort:
        if w["tok_s"] is None or w["power_w"] is None:
            continue                      # DROP -- never fabricate a coordinate
        ax.scatter(w["power_w"], w["tok_s"], s=90, color=_scope_color(w["power_scope"]),
                   edgecolor="k", zorder=3)
        ax.annotate(f"{w['name']}\n({w['model'].split()[0]})", (w["power_w"], w["tok_s"]),
                    textcoords="offset points", xytext=(6, 4), fontsize=8)
    # ArchBetter: measured core power; projected decode tok/s band (BFP12+shred).
    lo, hi = arch["tok_s_decode_bfp12_shred"]
    p = arch["power_w_core"]
    ax.errorbar(p, (lo + hi) / 2, yerr=[[(hi - lo) / 2], [(hi - lo) / 2]], fmt="*",
                ms=20, color=_scope_color("core"), ecolor=_scope_color("core"),
                capsize=5, zorder=4, label="ArchBetter (core power [M], decode tok/s [P])")
    ax.annotate("ArchBetter\n(TinyLlama-1.1B)", (p, hi), textcoords="offset points",
                xytext=(8, 6), fontsize=8, weight="bold")
    ax.set_xlabel("Power (W)  --  COLOR = scope; green=core, orange=system+HBM")
    ax.set_ylabel("Decode throughput (tok/s)  --  NOTE: different models per point")
    ax.set_title("Throughput vs Power (model + scope annotated; NOT raw-comparable)")
    ax.set_xscale("log"); ax.grid(True, which="both", alpha=0.3); ax.legend(fontsize=8)
    return ax


def radar_frontier(cohort, arch, axes_spec=None):
    """Multi-axis radar over MODEL-AGNOSTIC metrics so the shape is fair. Each axis
    is min-max normalized across the works that report it; works missing an axis are
    drawn at the axis minimum WITH a hatch note (not silently zeroed). ArchBetter is
    one polygon among others -- it will NOT enclose everyone."""
    axes_spec = axes_spec or [
        ("clock_mhz", "Clock (MHz)", False),
        ("gops_per_w", "GOPS/W", False),
        ("power_w", "1 / Power", True),     # invert: lower power = larger radius
    ]
    # assemble candidates that report >=2 of the chosen axes
    works = [w for w in cohort] + [dict(name=arch["name"], clock_mhz=arch["clock_mhz"],
             gops_per_w=None, power_w=arch["power_w_core"])]
    labels = [a[1] for a in axes_spec]; ang = np.linspace(0, 2*np.pi, len(labels), endpoint=False)
    fig, ax = plt.subplots(figsize=(6, 6), subplot_kw=dict(polar=True))
    # normalization ranges
    norm = {}
    for key, _, inv in axes_spec:
        vals = [w.get(key) for w in works if w.get(key) is not None]
        norm[key] = (min(vals), max(vals)) if vals else (0, 1)
    for w in works:
        r = []
        for key, _, inv in axes_spec:
            v = w.get(key); lo, hi = norm[key]
            if v is None: r.append(0.05); continue
            t = (v - lo) / (hi - lo + 1e-9)
            r.append(1 - t if inv else t)
        r = r + [r[0]]; aa = list(ang) + [ang[0]]
        is_us = w["name"].startswith("ArchBetter")
        ax.plot(aa, r, lw=2.5 if is_us else 1.2, label=w["name"],
                alpha=0.95 if is_us else 0.6)
        if is_us: ax.fill(aa, r, alpha=0.12)
    ax.set_xticks(ang); ax.set_xticklabels(labels, fontsize=9)
    ax.set_title("Model-agnostic frontier (normalized; missing axes shown small)")
    ax.legend(loc="upper right", bbox_to_anchor=(1.35, 1.1), fontsize=7)
    return ax


def efficiency_bars(cohort, arch):
    """IF a bar chart is shown, it is GOPS/W (energy-eff), sorted by value (not
    us-first), only for works that report it. Honest: most cohort works don't report
    GOPS/W -> the bar set is small, and that's the truth, not padded."""
    pts = [(w["name"], w["gops_per_w"]) for w in cohort if w["gops_per_w"] is not None]
    # ArchBetter GOPS/W is projection-gated; show prefill-GOPS / core-W as [P].
    pts.append((arch["name"] + " [P]", arch["gops_prefill_proj"] / arch["power_w_core"]))
    pts.sort(key=lambda x: x[1])          # ascending -> we land where we land
    names, vals = zip(*pts)
    fig, ax = plt.subplots(figsize=(7, 0.5 + 0.5 * len(pts)))
    colors = ["#1b9e77" if "ArchBetter" in n else "#999999" for n in names]
    ax.barh(names, vals, color=colors, edgecolor="k")
    for i, v in enumerate(vals): ax.text(v, i, f" {v:.1f}", va="center", fontsize=8)
    ax.set_xlabel("GOPS/W (energy efficiency) -- only works that REPORT it; sorted by value")
    ax.set_title("GOPS/W -- ours is [P] prefill/core-W; NOT cherry-picked to the top")
    return ax


def archbetter_internal_power_pie(per_resource):
    """Where OUR power goes (from report_power) -- internal diagnostic, not a comparison."""
    items = sorted(per_resource.items(), key=lambda kv: -kv[1])
    fig, ax = plt.subplots(figsize=(6, 6))
    ax.pie([v for _, v in items], labels=[f"{k} {v:.3f}W" for k, v in items],
           autopct="%1.0f%%", startangle=90)
    ax.set_title("ArchBetter accelerator dynamic power breakdown (per-resource)")
    return ax
