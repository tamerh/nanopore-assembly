"""
Nanopore phage assembly pipeline — top-level workflow.

Configuration: config/config.yaml
Project:       config["project"]  (default in config.yaml; override with --config project=<name>)
Sample sheet:  config/projects/<project>/samples.tsv
Modules:       modules/{qc_reads,assembly,qc_assembly,characterize,report}
"""
from pathlib import Path
from snakemake.utils import min_version
import pandas as pd

min_version("9.0")

configfile: "config/config.yaml"

# ---------------------------------------------------------------------------
# Project resolution and sample sheet loading
# ---------------------------------------------------------------------------

PROJECT = config.get("project")
if not PROJECT:
    raise SystemExit(
        "ERROR: project name required.\n"
        "Set 'project:' in config/config.yaml or pass at CLI:\n"
        "  snakemake --config project=<name> ..."
    )

SHEET_PATH = Path(f"config/projects/{PROJECT}/samples.tsv")
if not SHEET_PATH.is_file():
    raise SystemExit(f"ERROR: sample sheet not found: {SHEET_PATH}")

_sheet = pd.read_csv(SHEET_PATH, sep="\t")
required_cols = {"sample_id", "fastq_filename"}
missing_cols = required_cols - set(_sheet.columns)
if missing_cols:
    raise SystemExit(f"ERROR: sample sheet {SHEET_PATH} missing columns: {missing_cols}")

# Build samples map: sample_id -> dict with full fastq path + sheet metadata.
# Modules read SAMPLES via config["samples"] and don't need to know the
# project layout — the path is resolved here once.
config["samples"] = {
    row["sample_id"]: {
        **row.to_dict(),
        "fastq": f"resources/{PROJECT}/{row['sample_id']}/{row['fastq_filename']}",
    }
    for _, row in _sheet.iterrows()
}
SAMPLES = list(config["samples"])

# Project-scope outputs so multiple projects don't collide.
# Logs are co-located with each rule's outputs (no separate log tree).
config["outdir"] = f"{config['outdir']}/{PROJECT}"

OUTDIR = config["outdir"]

# ---------------------------------------------------------------------------
# Modules — uncomment as each is implemented
# ---------------------------------------------------------------------------

module qc_reads:
    snakefile: "modules/qc_reads/Snakefile"
    config: config
use rule * from qc_reads as qc_reads_*

module assembly:
    snakefile: "modules/assembly/Snakefile"
    config: config
use rule * from assembly as assembly_*

module qc_assembly:
    snakefile: "modules/qc_assembly/Snakefile"
    config: config
use rule * from qc_assembly as qc_assembly_*

module characterize:
    snakefile: "modules/characterize/Snakefile"
    config: config
use rule * from characterize as characterize_*

module report:
    snakefile: "modules/report/Snakefile"
    config: config
use rule * from report as report_*


# ---------------------------------------------------------------------------
# Top-level target — append per-module outputs as they come online
# ---------------------------------------------------------------------------
rule all:
    default_target: True
    input:
        # qc_reads
        expand(f"{OUTDIR}/qc_reads/{{sample}}/nanoplot_raw/NanoStats.txt", sample=SAMPLES),
        expand(f"{OUTDIR}/qc_reads/{{sample}}/filtered.fastq.gz", sample=SAMPLES),
        expand(f"{OUTDIR}/qc_reads/{{sample}}/nanoplot_filtered/NanoStats.txt", sample=SAMPLES),
        expand(f"{OUTDIR}/qc_reads/{{sample}}/adapter_scan.tsv", sample=SAMPLES),
        # assembly
        expand(f"{OUTDIR}/assembly/{{sample}}/flye/assembly_info.txt", sample=SAMPLES),
        expand(f"{OUTDIR}/assembly/{{sample}}/medaka/consensus.fasta", sample=SAMPLES),
        # qc_assembly
        expand(f"{OUTDIR}/qc_assembly/{{sample}}/seqkit_stats.tsv", sample=SAMPLES),
        expand(f"{OUTDIR}/qc_assembly/{{sample}}/quast/report.tsv", sample=SAMPLES),
        expand(f"{OUTDIR}/qc_assembly/{{sample}}/checkv/quality_summary.tsv", sample=SAMPLES),
        # characterize
        expand(f"{OUTDIR}/characterize/{{sample}}/pharokka/pharokka.gff", sample=SAMPLES),
        expand(f"{OUTDIR}/characterize/{{sample}}/pharokka/pharokka_top_hits_mash_inphared.tsv", sample=SAMPLES),
        # report
        f"{OUTDIR}/report/multiqc/multiqc_report.html",
        f"{OUTDIR}/report/report.html",
