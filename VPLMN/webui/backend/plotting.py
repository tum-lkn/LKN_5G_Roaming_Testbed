"""Bar-plot generation for the WebUI Plots tab.

Adapted from plotting_bar_compare.py, but:
  - reads the WebUI results directory (passed in), not a hardcoded path
  - keys the roaming mode off test_info.roaming_mode (falls back to filename)
  - tolerates null vplmn_name / dn_location (common in single-config runs)
  - renders to an in-memory PNG instead of writing a PDF

Public API:
  AVAILABLE_METRICS -> list of {id, label, unit, group}
  generate_plot(metric, results_dir) -> (png_bytes, medians_text)
"""

import io
import os
import re
import json
import glob
from pathlib import Path
from datetime import datetime
from collections import defaultdict

import numpy as np
import matplotlib
matplotlib.use("Agg")          # headless backend — no display needed
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

# ── Styling ──────────────────────────────────────────────────────────────────
COLORS = ['#92c5de', '#ca0020', '#0571b0', '#f4a582', '#8dd3c7']
LABELSIZE = 11
LOWER_PERCENTILE = 2
UPPER_PERCENTILE = 98
plt.rcParams.update({"text.usetex": False, "font.family": "serif"})

TIMING_METRICS = ['registration_to_pdu_init', 'pdu_setup']

# ── Metric catalog (id -> label, unit, group) ────────────────────────────────
AVAILABLE_METRICS = [
    {"id": "registration_to_pdu_init", "label": "UE Registration Time",        "unit": "ms",      "group": "Timing"},
    {"id": "pdu_setup",                "label": "PDU Setup Time",               "unit": "ms",      "group": "Timing"},
    {"id": "ping_avg_ms",              "label": "Average Ping Latency",         "unit": "ms",      "group": "Ping"},
    {"id": "ping_min_ms",              "label": "Minimum Ping Latency",         "unit": "ms",      "group": "Ping"},
    {"id": "ping_max_ms",              "label": "Maximum Ping Latency",         "unit": "ms",      "group": "Ping"},
    {"id": "download_speed",           "label": "Download Speed",               "unit": "MB/s",    "group": "Download"},
    {"id": "download_ttfb",            "label": "Download Time to First Byte",  "unit": "s",       "group": "Download"},
    {"id": "download_total_time",      "label": "Download Total Time",          "unit": "s",       "group": "Download"},
    {"id": "video_mbps",               "label": "Video Streaming Rate",         "unit": "Mbps",    "group": "Video"},
    {"id": "video_ttfb",               "label": "Video Time to First Byte",     "unit": "s",       "group": "Video"},
    {"id": "video_total_time",         "label": "Video Total Time",             "unit": "s",       "group": "Video"},
    {"id": "iperf_bps",                "label": "iPerf Throughput",             "unit": "Mbps",    "group": "iPerf"},
    {"id": "iperf_bytes_transferred",  "label": "iPerf Bytes Transferred",      "unit": "MB",      "group": "iPerf"},
    {"id": "iperf_jitter",             "label": "iPerf Jitter",                 "unit": "ms",      "group": "iPerf"},
    {"id": "iperf_lost_pkt",           "label": "iPerf Lost Packets",           "unit": "count",   "group": "iPerf"},
    {"id": "iperf_lost_percent",       "label": "iPerf Packet Loss",            "unit": "%",       "group": "iPerf"},
    {"id": "webpage_ttfb_ms",          "label": "Webpage Time to First Byte",   "unit": "ms",      "group": "Webpage"},
    {"id": "webpage_fcp_ms",           "label": "Webpage First Contentful Paint",   "unit": "ms",  "group": "Webpage"},
    {"id": "webpage_lcp_ms",           "label": "Webpage Largest Contentful Paint", "unit": "ms",  "group": "Webpage"},
    {"id": "webpage_dcl_ms",           "label": "Webpage DOM Content Loaded",   "unit": "ms",      "group": "Webpage"},
    {"id": "webpage_page_load_ms",     "label": "Webpage Page Load",            "unit": "ms",      "group": "Webpage"},
    {"id": "webpage_total_ms",         "label": "Webpage Total Time",           "unit": "ms",      "group": "Webpage"},
]

# Webpage plot metric id -> key inside each webpage_results entry
WEBPAGE_KEYS = {
    "webpage_ttfb_ms":      "ttfb_ms",
    "webpage_fcp_ms":       "fcp_ms",
    "webpage_lcp_ms":       "lcp_ms",
    "webpage_dcl_ms":       "dcl_ms",
    "webpage_page_load_ms": "page_load_ms",
    "webpage_total_ms":     "total_ms",
}
_LABELS = {m["id"]: (m["label"], m["unit"]) for m in AVAILABLE_METRICS}
VALID_METRIC_IDS = {m["id"] for m in AVAILABLE_METRICS}


def get_metric_label(metric_name):
    return _LABELS.get(metric_name, (metric_name, "value"))


# ── Which result files belong in the comparison plots ────────────────────────
# Every result JSON is <config-basename>_<timestamp>.json, written by
# testbed_automation.sh — whether it ran standalone or was driven per-config by a
# batch_runner.sh sweep (batch_runner just calls the automation script once per
# config). So there is no single "batch" filename to key on. We instead recognise
# the batch/sweep configs and explicitly exclude one-off / ad-hoc automation runs.
# Both flows name results identically whether launched locally or from the WebUI.
#
# INCLUDE — batch_runner + standard sweep configs:
#   <mode>[_<vplmn>]_dn_<dn>_pld<n>_<ts>.json   # batch_runner --all / main.conf sweep
#   <mode>_<ts>.json for a known mode           # standard configs run through the
#                                               #   batch runner or singly: hr, lbo,
#                                               #   non_roaming, hr-ipsec, hr-remote-upf,
#                                               #   hr_ipsec_N …
#   (and, as a fallback, anything whose test_info.roaming_mode is a known mode,
#    so an oddly-named batch config is still plotted)
#
# EXCLUDE — one-off / ad-hoc automation runs (local or WebUI):
#   webui_run_*        # WebUI "Automation" tab ad-hoc form (writes webui_run_<ts>.conf)
#   batch_results_*    # legacy interactive automation output
#   roaming_baseline*, roaming_<n>ms*   # hand-written smoke-test configs
#   test_*, adhoc_*, tmp_*              # scratch runs
_BATCH_RUNNER_RE = re.compile(r"_dn_.+_pld\d")
_EXCLUDE_NAME_RE = re.compile(
    r"^(webui_run_|batch_results_|roaming_baseline|roaming_\d+ms|test_|adhoc_|tmp_)",
    re.IGNORECASE,
)
_KNOWN_TEST_INFO_MODES = ("hr", "lbo", "non-roaming", "non_roaming")


def is_batch_runner_result(filename, test_info=None):
    """True if this result belongs in the comparison plots.

    Ad-hoc / one-off automation runs are excluded by name; everything else is
    included if it names a known roaming mode, matches the batch sweep naming, or
    records a known roaming_mode inside its test_info (naming-independent fallback).
    """
    stem = Path(filename).stem
    if _EXCLUDE_NAME_RE.search(stem):
        return False
    if _BATCH_RUNNER_RE.search(stem) or _mode_from_name(stem) is not None:
        return True
    m = str((test_info or {}).get("roaming_mode") or "").strip().lower()
    return m in _KNOWN_TEST_INFO_MODES


def load_batch_results(results_dir, only_batch_runner=True):
    files = sorted(glob.glob(str(Path(results_dir) / "*.json")))
    data = []
    for f in files:
        name = os.path.basename(f)
        try:
            with open(f) as fh:
                obj = json.load(fh)
        except Exception:
            continue
        # Filter after loading so the test_info fallback can see the JSON.
        if only_batch_runner and not is_batch_runner_result(name, obj.get("test_info")):
            continue
        obj["__filename__"] = name
        data.append(obj)
    return data


KNOWN_MODES = ('hr', 'lbo', 'hr-ipsec', 'hr-remote-upf', 'hr-ipsec-remote-upf')


def _mode_from_name(name):
    """Parse a roaming mode out of a config/result filename, or None."""
    if not name:
        return None
    base = Path(name).stem
    if base.startswith("non_roaming"):
        return "non-roaming"
    first = base.split("_")[0].lower()
    return first if first in KNOWN_MODES else None


def extract_mode(test_info, filename):
    """Roaming mode, preferring the name-derived variant.

    test_info.roaming_mode records only the base mode ('hr' for hr, hr-ipsec
    and hr-remote-upf alike), so the variant survives only in the config /
    result filename. Parse that first and fall back to roaming_mode.
    """
    ti = test_info or {}
    mode = _mode_from_name(ti.get("config_file")) or _mode_from_name(filename)
    if mode:
        return mode
    mode = ti.get("roaming_mode")
    if mode and mode not in ("null", "None"):
        return mode
    return Path(filename).stem


def extract_metric_value(iteration, metric, test_info=None):
    def res(key):
        v = iteration.get(key)
        return v if isinstance(v, dict) else None

    if metric == 'registration_to_pdu_init':
        return (iteration.get('timing_ms') or {}).get('registration_to_pdu_init')
    if metric == 'pdu_setup':
        return (iteration.get('timing_ms') or {}).get('pdu_setup')
    if metric in ('ping_avg_ms', 'ping_min_ms', 'ping_max_ms'):
        p = res('ping_results')
        return p.get(metric.replace('ping_', '')) if p else None
    if metric == 'download_speed':
        d = res('download_results')
        if d and d.get('success') and d.get('speed_bytes_per_sec') is not None:
            return d['speed_bytes_per_sec'] / (1024 * 1024)
        return None
    if metric in ('download_ttfb', 'download_total_time'):
        d = res('download_results')
        key = 'time_ttfb_sec' if metric == 'download_ttfb' else 'time_total_sec'
        return d.get(key) if d and d.get('success') else None
    if metric == 'video_mbps':
        v = res('video_results')
        return v.get('streaming_mbps') if v and v.get('success') else None
    if metric in ('video_ttfb', 'video_total_time'):
        v = res('video_results')
        key = 'time_ttfb_sec' if metric == 'video_ttfb' else 'time_total_sec'
        return v.get(key) if v and v.get('success') else None
    if metric == 'iperf_bps':
        i = res('iperf_results')
        if i and i.get('bits_per_second') is not None:
            try:
                return float(i['bits_per_second']) / 1e6
            except (ValueError, TypeError):
                return None
        return None
    if metric == 'iperf_bytes_transferred':
        i = res('iperf_results')
        if i and i.get('bytes_transferred') is not None:
            try:
                return float(i['bytes_transferred']) / (1024 * 1024)
            except (ValueError, TypeError):
                return None
        return None
    if metric == 'iperf_jitter':
        i = res('iperf_results')
        return i.get('jitter_ms') if i else None
    if metric == 'iperf_lost_pkt':
        i = res('iperf_results')
        return i.get('lost_packets') if i else None
    if metric == 'iperf_lost_percent':
        i = res('iperf_results')
        return i.get('lost_percent') if i else None
    if metric in WEBPAGE_KEYS:
        # webpage_results is a list of per-URL dicts; average across the
        # successful pages. Falsy values (0 / None) are skipped — for these
        # browser timings 0 means "not captured" (e.g. LCP on a redirect page).
        wr = iteration.get('webpage_results')
        if isinstance(wr, list) and wr:
            key = WEBPAGE_KEYS[metric]
            vals = [w.get(key) for w in wr if isinstance(w, dict) and w.get('success') and w.get(key)]
            if vals:
                return float(np.mean(vals))
        return None
    return None


def collect_data(batch_results, metric):
    """For timing: {mode: {vplmn: {iter_type: [vals]}}}
       Else:       {mode: {vplmn: {dn: [vals]}}}"""
    is_timing = metric in TIMING_METRICS
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for result in batch_results:
        ti = result.get('test_info', {}) or {}
        mode = extract_mode(ti, result.get('__filename__', ''))
        vplmn = ti.get('vplmn_name') or 'Germany'
        dn = ti.get('dn_location') or 'unknown'
        for it in result.get('iterations', []):
            num = it.get('iteration', 0)
            itype = 'cold_start' if num == 1 else 'warm_start'
            val = extract_metric_value(it, metric, ti)
            if val is not None:
                if is_timing:
                    data[mode][vplmn][itype].append(val)
                else:
                    data[mode][vplmn][dn].append(val)
    return data


def _stats(values):
    if not values:
        return 0, 0, 0
    if len(values) < 2:
        v = float(values[0])
        return v, v, v
    return (float(np.median(values)),
            float(np.percentile(values, LOWER_PERCENTILE)),
            float(np.percentile(values, UPPER_PERCENTILE)))


MODE_ORDER = ["non-roaming", "lbo", "hr-remote-upf", "hr", "hr-ipsec"]
VPLMN_ORDER = ["Germany", "France", "USA", "Australia"]
DN_ORDER = ["Frankfurt", "Paris", "Boston", "Sydney", "unknown"]
DN_HATCH = {'Frankfurt': '', 'Paris': '//', 'Boston': '///', 'Sydney': '////', 'unknown': ''}


def _order(available, preferred):
    ordered = [x for x in preferred if x in available]
    ordered += sorted(x for x in available if x not in preferred)
    return ordered


def _finish(fig, ax, metric, medians):
    label, unit = get_metric_label(metric)
    ax.set_ylabel(f"{label} [{unit}]")
    ax.set_xlabel("Roaming Mode")
    ax.grid(True, alpha=0.3, axis='y')
    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format='png', dpi=150, bbox_inches='tight')
    plt.close(fig)
    buf.seek(0)
    return buf.getvalue(), "\n".join(medians)


def _plot_timing(metric, data):
    medians = [f"{'mode':15} | {'vPLMN':10} | {'start':10} | median"]
    modes = _order(set(data), MODE_ORDER)
    all_vplmns = {v for m in data.values() for v in m}
    vplmns = _order(all_vplmns, VPLMN_ORDER)
    cmap = {v: COLORS[i % len(COLORS)] for i, v in enumerate(vplmns)}

    fig, ax = plt.subplots(figsize=(8, 5))
    bw, gap = 0.18, 0.06
    group_w = len(vplmns) * (2 * bw + gap)
    xs = np.arange(len(modes)) * (group_w + 0.4)
    for mi, mode in enumerate(modes):
        for vi, v in enumerate(vplmns):
            for ii, itype in enumerate(['warm_start', 'cold_start']):
                vals = data[mode][v][itype]
                med, lo, hi = _stats(vals)
                if not vals:
                    continue
                medians.append(f"{mode:15} | {v:10} | {itype:10} | {med:.2f}")
                voff = (vi - (len(vplmns) - 1) / 2) * (2 * bw + gap)
                ioff = (ii - 0.5) * bw
                x = xs[mi] + voff + ioff
                ax.bar(x, med, bw, color=cmap[v], alpha=1.0 if ii == 0 else 0.4,
                       edgecolor='black', linewidth=0.5, hatch=None if ii == 0 else '..')
                if not (lo == 0 and hi == 0 and med == 0):
                    ax.plot([x, x], [lo, hi], color='black', linewidth=1.3, zorder=3)
    ax.set_xticks(xs)
    ax.set_xticklabels(modes)
    leg = [Line2D([0], [0], color='w', label='PLMN:')]
    leg += [Patch(facecolor=cmap[v], edgecolor='black', label=f'  {v}') for v in vplmns]
    leg += [Patch(facecolor='gray', edgecolor='black', label='  warm start'),
            Patch(facecolor='gray', alpha=0.4, hatch='..', edgecolor='black', label='  cold start')]
    ax.legend(handles=leg, loc='best', fontsize=LABELSIZE * 0.8)
    return _finish(fig, ax, metric, medians)


def _plot_other(metric, data):
    medians = [f"{'mode':15} | {'vPLMN':10} | {'DN':10} | median"]
    modes = _order(set(data), MODE_ORDER)
    all_vplmns = {v for m in data.values() for v in m}
    vplmns = _order(all_vplmns, VPLMN_ORDER)
    all_dns = {d for m in data.values() for vd in m.values() for d in vd}
    dns = _order(all_dns, DN_ORDER)
    cmap = {v: COLORS[i % len(COLORS)] for i, v in enumerate(vplmns)}

    fig, ax = plt.subplots(figsize=(8, 5))
    bw, gap = 0.12, 0.05
    group_w = len(dns) * bw
    mode_w = len(vplmns) * group_w + (len(vplmns) - 1) * gap
    xs = np.arange(len(modes)) * (mode_w + 0.3)
    for mi, mode in enumerate(modes):
        for vi, v in enumerate(vplmns):
            for di, dn in enumerate(dns):
                vals = data[mode][v][dn]
                if not vals:
                    continue
                med, lo, hi = _stats(vals)
                medians.append(f"{mode:15} | {v:10} | {dn:10} | {med:.2f}")
                voff = (vi - (len(vplmns) - 1) / 2) * (group_w + gap)
                doff = (di - (len(dns) - 1) / 2) * bw
                x = xs[mi] + voff + doff
                ax.bar(x, med, bw, color=cmap[v], hatch=DN_HATCH.get(dn, ''),
                       alpha=0.85, edgecolor='black', linewidth=0.5)
                if not (lo == 0 and hi == 0 and med == 0):
                    ax.plot([x, x], [lo, hi], color='black', linewidth=1.3, zorder=3)
    ax.set_xticks(xs)
    ax.set_xticklabels(modes)
    leg = [Line2D([0], [0], color='w', label='PLMN:')]
    leg += [Patch(facecolor=cmap[v], edgecolor='black', label=f'  {v}') for v in vplmns]
    if len(dns) > 1 or (dns and dns[0] != 'unknown'):
        leg.append(Line2D([0], [0], color='w', label='DN:'))
        leg += [Patch(facecolor='white', hatch=DN_HATCH.get(d, ''), edgecolor='black', label=f'  {d}') for d in dns]
    ax.legend(handles=leg, loc='best', ncol=2, fontsize=LABELSIZE * 0.8)
    return _finish(fig, ax, metric, medians)


def _render_from_batch(metric, batch):
    """Render one metric from already-loaded batch results.
    Returns (png_bytes, medians_text). Raises ValueError on bad input/no data."""
    if metric not in VALID_METRIC_IDS:
        raise ValueError(f"Unknown metric: {metric}")
    data = collect_data(batch, metric)
    # any values at all?
    has_data = any(vals for m in data.values() for vd in m.values() for vals in vd.values())
    if not has_data:
        raise ValueError(f"No data for metric '{metric}' in the available results")
    if metric in TIMING_METRICS:
        return _plot_timing(metric, data)
    return _plot_other(metric, data)


def generate_plot(metric, results_dir):
    """Returns (png_bytes, medians_text). Raises ValueError on bad input/no data."""
    batch = load_batch_results(results_dir)
    if not batch:
        raise ValueError("No batch_runner result files found")
    return _render_from_batch(metric, batch)


def generate_all_plots(results_dir):
    """Render every metric in one pass (loads result files once).

    Returns dict:
      {"plots":  {metric_id: png_bytes},   # only metrics that had data
       "errors": {metric_id: message},     # metrics skipped (no data / render error)
       "files":  [filename, ...]}          # batch_runner files that were used
    Raises ValueError if there are no batch_runner result files at all.
    """
    batch = load_batch_results(results_dir)
    if not batch:
        raise ValueError("No batch_runner result files found")
    plots, errors = {}, {}
    for m in AVAILABLE_METRICS:
        mid = m["id"]
        try:
            png, _medians = _render_from_batch(mid, batch)
            plots[mid] = png
        except ValueError as e:
            errors[mid] = str(e)
        except Exception as e:
            errors[mid] = f"Plot generation failed: {e}"
    files = [b.get("__filename__", "") for b in batch]
    return {"plots": plots, "errors": errors, "files": files}


# ── Disk persistence (Plots tab cache) ───────────────────────────────────────
# Rendering every metric with matplotlib is slow, so we do it only on explicit
# "Regenerate plots" and persist the PNGs to a cache dir. On page load the WebUI
# reads those files back instead of re-rendering.
MANIFEST_NAME = "manifest.json"


def generate_all_plots_to_dir(results_dir, out_dir):
    """Render every metric and persist the PNGs + a manifest to out_dir,
    overwriting any previously cached set. Returns the same dict as
    generate_all_plots() with an added 'generated_at' and 'file_count'.
    Raises ValueError if there are no batch_runner result files at all."""
    result = generate_all_plots(results_dir)
    os.makedirs(out_dir, exist_ok=True)
    # Drop stale PNGs so a metric that lost its data doesn't linger on disk.
    for old in glob.glob(str(Path(out_dir) / "*.png")):
        try:
            os.remove(old)
        except OSError:
            pass
    for mid, png in result["plots"].items():
        with open(Path(out_dir) / f"{mid}.png", "wb") as fh:
            fh.write(png)
    manifest = {
        "metrics": list(result["plots"].keys()),
        "errors": result["errors"],
        "files": result["files"],
        "file_count": len(result["files"]),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
    }
    with open(Path(out_dir) / MANIFEST_NAME, "w") as fh:
        json.dump(manifest, fh)
    result["generated_at"] = manifest["generated_at"]
    result["file_count"] = manifest["file_count"]
    return result


def load_cached_plots(out_dir):
    """Read persisted PNGs + manifest from out_dir. Returns a dict shaped like
    generate_all_plots() plus 'generated_at'/'file_count', or None if nothing
    has been generated yet (no manifest)."""
    mpath = Path(out_dir) / MANIFEST_NAME
    if not mpath.exists():
        return None
    try:
        with open(mpath) as fh:
            manifest = json.load(fh)
    except Exception:
        return None
    plots = {}
    for mid in manifest.get("metrics", []):
        p = Path(out_dir) / f"{mid}.png"
        if p.exists():
            try:
                plots[mid] = p.read_bytes()
            except OSError:
                continue
    return {
        "plots": plots,
        "errors": manifest.get("errors", {}),
        "files": manifest.get("files", []),
        "file_count": manifest.get("file_count", len(manifest.get("files", []))),
        "generated_at": manifest.get("generated_at"),
    }
