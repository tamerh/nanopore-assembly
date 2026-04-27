"""Generate the standalone HTML report from per-stage outputs.

Snakemake injects a `snakemake` object with .input, .output, .params
populated from the rule definition.
"""
from datetime import datetime
from pathlib import Path
import pandas as pd
import jinja2

# Snakemake-injected object
sm = snakemake  # type: ignore[name-defined]


def _coerce(v):
    """Best-effort numeric conversion. Floats that are integral collapse to int.
    Numeric-looking strings are parsed. Anything else is passed through."""
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v) if v.is_integer() else v
    if isinstance(v, str):
        s = v.strip()
        if s.lstrip("-").isdigit():
            return int(s)
        try:
            f = float(s)
            return int(f) if f.is_integer() else f
        except ValueError:
            return v
    return v


def parse_qc_summary(path):
    """Read the per-sample qc_summary.tsv (one row, ~25 columns).

    Columns are named with `_raw` / `_filtered` suffixes plus a few
    derived metrics (pct_reads_kept, pct_bases_kept). We split them
    back into raw / filt sub-dicts to match the template's existing
    `raw.field` / `filt.field` access pattern.
    """
    df = pd.read_csv(path, sep="\t")
    row = {str(k): _coerce(v) for k, v in df.iloc[0].to_dict().items()}
    raw = {k[:-len("_raw")]: v for k, v in row.items() if k.endswith("_raw")}
    filt = {k[:-len("_filtered")]: v for k, v in row.items() if k.endswith("_filtered")}
    derived = {
        k: v for k, v in row.items()
        if k != "sample" and not k.endswith("_raw") and not k.endswith("_filtered")
    }
    return raw, filt, derived


def parse_kv_tsv(path):
    """Parse a 2-column TSV (metric/value) into a dict with coerced values."""
    df = pd.read_csv(path, sep="\t")
    return {str(k): _coerce(v) for k, v in zip(df.iloc[:, 0], df.iloc[:, 1])}


def parse_flye_info(path):
    df = pd.read_csv(path, sep="\t")
    return df.to_dict("records")


def parse_simple_tsv(path):
    df = pd.read_csv(path, sep="\t")
    return df.to_dict("records")


def fmt_filter(v):
    """Jinja filter: format numbers with thousand separators; pass through others."""
    v = _coerce(v)
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, int):
        return f"{v:,}"
    if isinstance(v, float):
        if abs(v) < 100:
            return f"{v:.2f}"
        return f"{v:,.1f}"
    return v


# ---- gather per-sample data ----
project = sm.params.project
results_root = Path(sm.params.results_root)
samples = list(sm.params.samples)
metadata = dict(sm.params.sample_metadata)

sample_data = {}
for sample in samples:
    raw_stats, filt_stats, qc_derived = parse_qc_summary(
        results_root / "qc_reads" / sample / "qc_summary.tsv"
    )
    sd = {
        "metadata": metadata.get(sample, {}),
        "raw_stats": raw_stats,
        "filt_stats": filt_stats,
        "qc_derived": qc_derived,
        "flye_info": parse_flye_info(results_root / "assembly" / sample / "flye" / "assembly_info.txt"),
        "checkv": parse_simple_tsv(results_root / "qc_assembly" / sample / "checkv" / "quality_summary.tsv"),
        "pharokka_cds": parse_simple_tsv(results_root / "characterize" / sample / "pharokka" / "pharokka_cds_functions.tsv"),
        "pharokka_tax": parse_simple_tsv(results_root / "characterize" / sample / "pharokka" / "pharokka_top_hits_mash_inphared.tsv"),
    }
    sample_data[sample] = sd

# Versions table
versions = parse_simple_tsv(Path(sm.input.versions[0] if isinstance(sm.input.versions, list) else sm.input.versions))

# ---- render ----
template_path = Path(sm.input.template)
env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(str(template_path.parent)),
    autoescape=jinja2.select_autoescape(["html"]),
    trim_blocks=True,
    lstrip_blocks=True,
)
env.filters["fmt"] = fmt_filter
template = env.get_template(template_path.name)

# Path to MultiQC html relative to the report's location
report_path = Path(sm.output.html).resolve()
multiqc_path = Path(sm.input.multiqc).resolve()
try:
    multiqc_link = multiqc_path.relative_to(report_path.parent)
except ValueError:
    multiqc_link = multiqc_path

html = template.render(
    project=project,
    samples=samples,
    sample_data=sample_data,
    versions=versions,
    multiqc_link=str(multiqc_link),
    generated_at=datetime.now().strftime("%Y-%m-%d %H:%M"),
    config=dict(sm.config),
)

Path(sm.output.html).write_text(html, encoding="utf-8")
