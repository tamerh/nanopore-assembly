"""Normalize NanoPlot stats into a flat per-sample TSV.

NanoPlot's NanoStats.txt is tab-separated but contains compound cells
(e.g. 'Reads >Q15: 315 (76.1%) 7.1Mb' packs count, percent, and bases
into one string). This script parses both raw and filtered stats files,
splits the compound cells into separate columns, computes derived
retention metrics, and emits a single-row TSV — one column per metric —
matching the shape of QUAST/CheckV/seqkit outputs.

Centralizes the messy NanoPlot parsing in one place so downstream
consumers read a flat structured artifact instead of re-parsing
NanoStats.
"""
import csv
import re
from pathlib import Path

sm = snakemake  # type: ignore[name-defined]


_LONGEST_RE = re.compile(r"(\d+)\s*\(([\d.]+)\)")
_QFILTER_RE = re.compile(r"(\d+)\s*\(([\d.]+)%\)\s*([\d.]+)\s*Mb")
_QKEY_RE = re.compile(r">Q(\d+):")


def _to_int(s):
    try:
        return int(float(str(s).strip()))
    except (ValueError, TypeError):
        return None


def _to_float(s):
    try:
        return float(str(s).strip())
    except (ValueError, TypeError):
        return None


def parse_nanostats(path: Path) -> dict:
    """Parse NanoPlot --tsv_stats output into a flat dict.

    Compound cells split:
      - 'longest_read_(with_Q):1' -> longest_read_length / longest_read_q
      - 'Reads >QN:'              -> reads_qN_count / reads_qN_pct / reads_qN_mb

    Ranks 2..5 of longest_read_(with_Q) and all of highest_Q_read_(with_length)
    are intentionally dropped from the summary — only the rank-1 longest is
    summarized. The full ranks remain available in the source NanoStats file
    for anyone who needs them.
    """
    out: dict = {}
    with path.open() as f:
        reader = csv.reader(f, delimiter="\t")
        next(reader, None)  # skip header row ("Metrics", "dataset")
        for row in reader:
            if len(row) < 2:
                continue
            k, v = row[0].strip(), row[1].strip()
            if k == "number_of_reads":
                out["n_reads"] = _to_int(v)
            elif k == "number_of_bases":
                out["n_bases"] = _to_int(v)
            elif k == "median_read_length":
                out["median_length"] = _to_int(v)
            elif k == "mean_read_length":
                out["mean_length"] = _to_int(v)
            elif k == "read_length_stdev":
                out["length_stdev"] = _to_float(v)
            elif k == "n50":
                out["n50"] = _to_int(v)
            elif k == "mean_qual":
                out["mean_q"] = _to_float(v)
            elif k == "median_qual":
                out["median_q"] = _to_float(v)
            elif k == "longest_read_(with_Q):1":
                m = _LONGEST_RE.match(v)
                if m:
                    out["longest_read_length"] = int(m.group(1))
                    out["longest_read_q"] = float(m.group(2))
            elif k.startswith("Reads >Q"):
                qm = _QKEY_RE.search(k)
                vm = _QFILTER_RE.match(v)
                if qm and vm:
                    q = qm.group(1)
                    out[f"reads_q{q}_count"] = int(vm.group(1))
                    out[f"reads_q{q}_pct"] = float(vm.group(2))
                    out[f"reads_q{q}_mb"] = float(vm.group(3))
    return out


def main():
    sample = sm.wildcards.sample
    raw = parse_nanostats(Path(sm.input.raw_stats))
    filt = parse_nanostats(Path(sm.input.filtered_stats))

    row: dict = {"sample": sample}
    for k, v in raw.items():
        row[f"{k}_raw"] = v
    for k, v in filt.items():
        row[f"{k}_filtered"] = v

    if raw.get("n_reads") and filt.get("n_reads"):
        row["pct_reads_kept"] = round(100 * filt["n_reads"] / raw["n_reads"], 2)
    if raw.get("n_bases") and filt.get("n_bases"):
        row["pct_bases_kept"] = round(100 * filt["n_bases"] / raw["n_bases"], 2)

    out_path = Path(sm.output.summary)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(row.keys())
        writer.writerow(["" if v is None else v for v in row.values()])


main()
