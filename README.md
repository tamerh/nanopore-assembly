# Nanopore Assembly

Snakemake pipeline for Oxford Nanopore long-read genome assembly. Default
target: **bacteriophage isolates** (tested on R10.4.1 chemistry, HAC basecalling).

## Modules

1. **qc_reads** — NanoPlot (raw + filtered), Filtlong (length/quality filter +
   subsample), normalized per-sample QC summary
2. **assembly** — Flye (`--nano-hq`) + medaka (basecaller-matched model)
3. **qc_assembly** — seqkit + QUAST + CheckV (completeness, contamination, DTRs)
4. **characterize** — Pharokka end-to-end: PHANOTATE ORFs, PHROGS functional
   categories, tRNAscan-SE, MinCED CRISPR, Mash-vs-INPHARED taxonomy, dnaapler
   reorientation to terminase
5. **report** — MultiQC + standalone HTML (Python + Jinja2): methods,
   per-sample results, software versions, limitations

## Setup

Requires conda on PATH (mamba recommended for faster solving).

```bash
./pipeline.sh install     # create per-module conda envs + download
                          # CheckV (~5 GB) and Pharokka (~1.2 GB) databases
./pipeline.sh check       # verify everything is present
```

First install takes ~15–30 min, mostly DB downloads; subsequent invocations
reuse everything (idempotent — safe to re-run after editing any env YAML
under `config/envs/`).

## Running

To run the default `phage_demo` project, drop the test FASTQ
`1_024_O.fastq.gz` into `resources/phage_demo/barcode09/` first.

```bash
./pipeline.sh dryrun      # preview the DAG (matches what `run` will execute)
./pipeline.sh run         # full pipeline run (default cores: 8)
./pipeline.sh run -c 16   # override core count
./pipeline.sh run --config project=other_project        # override project
./pipeline.sh run -R report_build_report                # force re-run a single rule (e.g. after editing report template)
```

`run` includes Snakemake `--rerun-incomplete` (resumes after interruption) and `--rerun-triggers mtime`
(only re-runs when an output is missing or older than its input — not when
rule code or env YAML has been edited).

## Pipeline Layout

Built as five modular stages, each with its own conda environment.
Pipeline is project-scoped so every project has its own sample sheet, input directory,
and output directory multi-project setups stay isolated. Default project is `phage_demo`; override via
`--config project=<name>`.

```
.
├── Snakefile               # top-level workflow, imports the 5 modules
├── pipeline.sh             # orchestrator: install, check, run, dryrun, clean
├── config/
│   ├── config.yaml         # pipeline parameters + default `project:`
│   ├── envs/               # one conda env YAML per module/tool group
│   │   ├── base.yaml
│   │   ├── qc-reads.yaml
│   │   ├── flye.yaml
│   │   ├── medaka.yaml
│   │   ├── qc-asm.yaml
│   │   ├── pharokka.yaml
│   │   └── report.yaml
│   └── projects/           # one folder per project, holding its sample sheet
│       └── <project>/samples.tsv
├── resources/              # inputs + downloads (gitignored)
│   ├── <project>/<sample_id>/*.fastq.gz
│   └── databases/          # downloaded reference DBs (CheckV, Pharokka)
├── results/<project>/      # pipeline outputs + per-rule logs (gitignored)
│   ├── qc_reads/<sample>/
│   ├── assembly/<sample>/{flye,medaka}/
│   ├── qc_assembly/<sample>/{quast,checkv}/
│   ├── characterize/<sample>/pharokka/
│   └── report/{report.html, multiqc/, versions.tsv}
└── modules/                # per-stage subworkflows: Snakefile + scripts/
    ├── qc_reads/
    ├── assembly/
    ├── qc_assembly/
    ├── characterize/
    └── report/
```

## Sample sheet

Sample sheet is TSV file with two columns:

```
sample_id   fastq_filename
sample_01   reads.fastq.gz
sample_02   reads.fastq.gz
```

## Limitations and known gaps

- Single sample on a single project exercised — multi-sample and
  multi-project runs are supported by design but not stress-tested
- Isolate-only — metagenomic input would require a different pipeline shape, not a config flag.
- HTML report only (no PDF rendering wired in; the narrative is
  self-contained HTML)
- No reference-based pairwise validation rule — the closest INPHARED match
  is reported but not pulled and aligned
- Single-pass medaka polish — sufficient for R10.4.1 HAC; SUP often needs
  none, hybrid Illumina+ONT data could benefit from polypolish
- Pipeline was exercised on HAC. Running on
  SUP data requires updating `config.medaka.model` to a SUP-trained model
  matching the basecaller version.
- No explicit adapter trimming. Pipeline assumes basecaller-level adapter
  trimming.
- Logs are co-located with each rule's outputs for convenience; can be
  separated into a top-level `logs/` directory later if needed.
- No automated tests — pipeline correctness is verified by end-to-end runs
  on real data, not unit/integration tests.
