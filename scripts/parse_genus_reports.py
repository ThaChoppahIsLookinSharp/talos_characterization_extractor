#!/usr/bin/env python3
"""
Parse Cadence Genus reports and summarize approximate PPA.

Usage:
    python3 parse_genus_reports.py reports/genus_simple_mac

Optional:
    python3 parse_genus_reports.py reports/genus_simple_mac --lib /path/to/lib.lib
    python3 parse_genus_reports.py reports/genus_simple_mac --json

Notes:
    - Area is parsed from area.rpt/qor.rpt when possible.
    - Performance is estimated from clock period and WNS/slack.
    - Throughput assumes this design is a sequential MAC accepting 1 MAC/cycle.
    - Temperature is inferred from report text or Liberty nom_temperature if --lib is given.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Optional, Dict, Any, List, Tuple


NUM = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="ignore")
    except FileNotFoundError:
        return ""


def find_first_float(pattern: str, text: str, flags: int = re.IGNORECASE) -> Optional[float]:
    m = re.search(pattern, text, flags)
    if not m:
        return None
    try:
        return float(m.group(1))
    except Exception:
        return None


def all_floats(line: str) -> List[float]:
    vals = []
    for x in re.findall(NUM, line):
        try:
            vals.append(float(x))
        except Exception:
            pass
    return vals


def normalize_slack_to_ns(slack: Optional[float], clock_ns: Optional[float]) -> Optional[float]:
    """
    Genus sometimes reports internal timing in ps-like numbers in logs/tables.
    If clock is 5.0 ns and slack is 206, that is probably 206 ps = 0.206 ns.
    """
    if slack is None:
        return None

    if clock_ns is not None and abs(slack) > clock_ns * 5:
        return slack / 1000.0

    return slack


def parse_clock_period_ns(report_dir: Path) -> Optional[float]:
    # Best source: exported SDC.
    for sdc in report_dir.glob("*.sdc"):
        text = read_text(sdc)
        val = find_first_float(r"create_clock\b.*?-period\s+(" + NUM + r")", text)
        if val is not None:
            return val

    # Fallback: clocks.rpt.
    text = read_text(report_dir / "clocks.rpt")
    val = find_first_float(r"\bperiod\b\s*[:=]?\s*(" + NUM + r")", text)
    if val is not None:
        return val

    # Fallback: any report.
    for rpt in report_dir.glob("*.rpt"):
        text = read_text(rpt)
        val = find_first_float(r"clock.*?period.*?(" + NUM + r")", text)
        if val is not None:
            return val

    return None


def parse_wns_ns(report_dir: Path, clock_ns: Optional[float]) -> Optional[float]:
    """
    Parse WNS from Genus reports.

    Priority:
      1. qor.rpt explicit WNS/setup lines
      2. timing.rpt exact slack lines
      3. unit normalization from ps to ns when needed
    """
    candidates: List[float] = []

    def normalize(value: float) -> float:
        # Genus often reports timing internally in ps-like values.
        # If the value is larger than the clock period, it is probably ps.
        if clock_ns is not None and abs(value) > clock_ns:
            return value / 1000.0
        return value

    # Prefer QoR because it normally summarizes WNS directly.
    qor = read_text(report_dir / "qor.rpt")
    for line in qor.splitlines():
        low = line.lower()

        # Good lines usually contain wns, setup wns, or worst negative slack.
        if "wns" in low or "worst negative slack" in low:
            vals = all_floats(line)
            if vals:
                candidates.append(normalize(vals[-1]))

    if candidates:
        return min(candidates)

    # Fallback: parse timing.rpt, but only exact slack report lines.
    timing = read_text(report_dir / "timing.rpt")
    for line in timing.splitlines():
        low = line.lower().strip()

        # Match lines like:
        #   slack (MET) 98
        #   slack (VIOLATED) -12
        #   slack 0.098
        if re.match(r"^slack\b", low):
            vals = all_floats(line)
            if vals:
                candidates.append(normalize(vals[-1]))

    if candidates:
        return min(candidates)

    return None

def parse_area(report_dir: Path, top: Optional[str] = None) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        "area": None,
        "source": None,
        "unit": "library_area_units",
    }

    texts = [
        ("area.rpt", read_text(report_dir / "area.rpt")),
        ("qor.rpt", read_text(report_dir / "qor.rpt")),
    ]

    labelled_patterns = [
        r"(?:total\s+cell\s+area|cell\s+area|total\s+area|area\s+of\s+design)\s*[:=]\s*(" + NUM + r")",
        r"(?:total\s+area)\s+(" + NUM + r")",
    ]

    for name, text in texts:
        for pat in labelled_patterns:
            val = find_first_float(pat, text)
            if val is not None:
                result["area"] = val
                result["source"] = name
                return result

    # Fallback: search for lines with top/simple_mac or total.
    for name, text in texts:
        for line in text.splitlines():
            low = line.lower()
            if top and top.lower() in low:
                vals = all_floats(line)
                if vals:
                    result["area"] = vals[-1]
                    result["source"] = f"{name}: line containing {top}"
                    return result
            if "total" in low and "area" not in low:
                vals = all_floats(line)
                if vals:
                    result["area"] = vals[-1]
                    result["source"] = f"{name}: total-like line"
                    return result

    return result


def parse_instance_count(report_dir: Path) -> Optional[int]:
    for fname in ["qor.rpt", "gates.rpt", "area.rpt"]:
        text = read_text(report_dir / fname)
        for line in text.splitlines():
            low = line.lower()
            if "inst" in low or "instance" in low or "instances" in low:
                vals = all_floats(line)
                if vals:
                    return int(vals[-1])
    return None


def parse_power(report_dir: Path) -> Dict[str, Any]:
    text = read_text(report_dir / "power.rpt")
    result: Dict[str, Any] = {
        "total_power": None,
        "internal_power": None,
        "switching_power": None,
        "leakage_power": None,
        "source": "power.rpt",
        "unit": "as_reported_by_genus",
    }

    if not text:
        return result

    # Common labelled forms.
    patterns = {
        "total_power": r"(?:total\s+power|total)\s*[:=]?\s*(" + NUM + r")",
        "internal_power": r"(?:internal\s+power|internal)\s*[:=]?\s*(" + NUM + r")",
        "switching_power": r"(?:switching\s+power|switching)\s*[:=]?\s*(" + NUM + r")",
        "leakage_power": r"(?:leakage\s+power|leakage)\s*[:=]?\s*(" + NUM + r")",
    }

    for key, pat in patterns.items():
        val = find_first_float(pat, text)
        if val is not None:
            result[key] = val

    # Fallback: line starting with Total and several numeric columns.
    if result["total_power"] is None:
        for line in text.splitlines():
            if re.match(r"^\s*total\b", line, re.IGNORECASE):
                vals = all_floats(line)
                if vals:
                    result["total_power"] = vals[-1]
                    result["raw_total_line"] = line.strip()
                    break

    return result


def parse_temperature_from_reports(report_dir: Path) -> Tuple[Optional[float], str]:
    combined = ""
    for rpt in report_dir.glob("*.rpt"):
        combined += "\n" + read_text(rpt)

    patterns = [
        r"temperature\s*[:=]?\s*(" + NUM + r")",
        r"PVT values\s*\(\s*" + NUM + r"\s*,\s*" + NUM + r"\s*,\s*(" + NUM + r")\s*\)",
        r"operating condition.*?\(\s*" + NUM + r"\s*,\s*" + NUM + r"\s*,\s*(" + NUM + r")\s*\)",
    ]

    for pat in patterns:
        val = find_first_float(pat, combined)
        if val is not None:
            return val, "parsed_from_reports"

    return None, "not_found_in_reports"


def parse_temperature_from_lib(lib_path: Optional[Path]) -> Tuple[Optional[float], str]:
    if lib_path is None or not lib_path.exists():
        return None, "no_lib_provided"

    # Read only first few MB, enough for nom_temperature usually.
    try:
        with lib_path.open("r", errors="ignore") as f:
            text = f.read(5_000_000)
    except Exception:
        return None, "could_not_read_lib"

    val = find_first_float(r"nom_temperature\s*[:=]\s*(" + NUM + r")", text)
    if val is not None:
        return val, "nom_temperature_from_liberty"

    name = lib_path.name.lower()

    # Rough convention fallback.
    if "wc" in name:
        return 125.0, "inferred_from_wc_corner_name"
    if "tc" in name:
        return 25.0, "inferred_from_tc_corner_name"
    if "bc" in name:
        return -40.0, "inferred_from_bc_corner_name"

    return None, "not_found_in_lib"


def build_summary(report_dir: Path, lib: Optional[Path]) -> Dict[str, Any]:
    top = None
    # Try to infer top from netlist name.
    netlists = list(report_dir.glob("*_netlist.v"))
    if netlists:
        top = netlists[0].name.replace("_netlist.v", "")

    clock_ns = parse_clock_period_ns(report_dir)
    wns_ns = parse_wns_ns(report_dir, clock_ns)

    constrained_freq_mhz = None
    if clock_ns and clock_ns > 0:
        constrained_freq_mhz = 1000.0 / clock_ns

    critical_delay_ns = None
    estimated_fmax_mhz = None

    if clock_ns is not None and wns_ns is not None:
        critical_delay_ns = clock_ns - wns_ns
        if critical_delay_ns > 0:
            estimated_fmax_mhz = 1000.0 / critical_delay_ns
    elif clock_ns is not None:
        # Conservative fallback: assume critical path is roughly the constrained period.
        critical_delay_ns = clock_ns
        estimated_fmax_mhz = constrained_freq_mhz

    # Throughput model for this MAC:
    # 1 MAC/cycle if en=1 every cycle.
    mac_throughput_mmac_s = estimated_fmax_mhz
    ops_throughput_gops_s = None
    if estimated_fmax_mhz is not None:
        # Counting 1 MAC as 2 arithmetic ops: multiply + add.
        ops_throughput_gops_s = 2.0 * estimated_fmax_mhz / 1000.0

    temp_rpt, temp_rpt_src = parse_temperature_from_reports(report_dir)
    temp_lib, temp_lib_src = parse_temperature_from_lib(lib)

    if temp_rpt is not None:
        temp_c = temp_rpt
        temp_src = temp_rpt_src
    else:
        temp_c = temp_lib
        temp_src = temp_lib_src

    summary = {
        "report_dir": str(report_dir),
        "top": top,
        "area": parse_area(report_dir, top),
        "instances": parse_instance_count(report_dir),
        "timing": {
            "clock_period_ns": clock_ns,
            "constraint_frequency_mhz": constrained_freq_mhz,
            "wns_ns": wns_ns,
            "critical_path_delay_ns_approx": critical_delay_ns,
            "estimated_fmax_mhz": estimated_fmax_mhz,
        },
        "throughput": {
            "assumption": "sequential MAC, 1 MAC accepted per cycle when en=1",
            "mac_throughput_mmac_per_s": mac_throughput_mmac_s,
            "ops_throughput_gops_per_s_if_1mac_equals_2ops": ops_throughput_gops_s,
        },
        "power": parse_power(report_dir),
        "temperature": {
            "temperature_c": temp_c,
            "source": temp_src,
            "note": "Temperature is not computed from synthesis. It is parsed/inferred from the operating corner.",
        },
    }

    return summary


def fmt(x: Any, digits: int = 4) -> str:
    if x is None:
        return "N/A"
    if isinstance(x, float):
        return f"{x:.{digits}g}"
    return str(x)


def print_human(summary: Dict[str, Any]) -> None:
    area = summary["area"]
    timing = summary["timing"]
    throughput = summary["throughput"]
    power = summary["power"]
    temp = summary["temperature"]

    print("=" * 72)
    print("GENUS REPORT SUMMARY")
    print("=" * 72)
    print(f"Report dir: {summary['report_dir']}")
    print(f"Top       : {fmt(summary.get('top'))}")
    print()

    print("AREA")
    print("-" * 72)
    print(f"Area      : {fmt(area.get('area'))} {area.get('unit')}")
    print(f"Source    : {fmt(area.get('source'))}")
    print(f"Instances : {fmt(summary.get('instances'))}")
    print()

    print("PERFORMANCE / TIMING")
    print("-" * 72)
    print(f"Clock period constraint : {fmt(timing.get('clock_period_ns'))} ns")
    print(f"Constraint frequency    : {fmt(timing.get('constraint_frequency_mhz'))} MHz")
    print(f"WNS                     : {fmt(timing.get('wns_ns'))} ns")
    print(f"Critical delay approx   : {fmt(timing.get('critical_path_delay_ns_approx'))} ns")
    print(f"Estimated Fmax          : {fmt(timing.get('estimated_fmax_mhz'))} MHz")
    print()

    print("THROUGHPUT")
    print("-" * 72)
    print(f"Assumption              : {throughput.get('assumption')}")
    print(f"MAC throughput          : {fmt(throughput.get('mac_throughput_mmac_per_s'))} MMAC/s")
    print(f"OPS throughput          : {fmt(throughput.get('ops_throughput_gops_per_s_if_1mac_equals_2ops'))} GOPS")
    print()

    print("POWER")
    print("-" * 72)
    print(f"Total power             : {fmt(power.get('total_power'))} {power.get('unit')}")
    print(f"Internal power          : {fmt(power.get('internal_power'))} {power.get('unit')}")
    print(f"Switching power         : {fmt(power.get('switching_power'))} {power.get('unit')}")
    print(f"Leakage power           : {fmt(power.get('leakage_power'))} {power.get('unit')}")
    print()

    print("TEMPERATURE / CORNER")
    print("-" * 72)
    print(f"Temperature             : {fmt(temp.get('temperature_c'))} °C")
    print(f"Source                  : {temp.get('source')}")
    print(f"Note                    : {temp.get('note')}")
    print("=" * 72)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report_dir", help="Directory containing Genus reports")
    parser.add_argument("--lib", default=os.environ.get("LIB"), help="Optional Liberty .lib used for synthesis")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of human summary")
    args = parser.parse_args()

    report_dir = Path(args.report_dir).resolve()
    if not report_dir.exists():
        raise SystemExit(f"ERROR: report directory does not exist: {report_dir}")

    lib = Path(args.lib).resolve() if args.lib else None

    summary = build_summary(report_dir, lib)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print_human(summary)


if __name__ == "__main__":
    main()
