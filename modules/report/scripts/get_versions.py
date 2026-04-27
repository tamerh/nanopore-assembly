"""Collect installed tool versions across all conda envs into a single TSV.

Runs in Snakemake's host env (no `conda:` directive on the rule) so it can
shell out to `conda list` for each tool's env.
"""
import json
import subprocess
from pathlib import Path

# (env_name, [package_names_to_query])
ENV_TOOLS = [
    ("nanopore-assembly", ["snakemake"]),
    ("nanopore-assembly-qc-reads", ["nanoplot", "filtlong", "seqkit"]),
    ("nanopore-assembly-flye", ["flye"]),
    ("nanopore-assembly-medaka", ["medaka"]),
    ("nanopore-assembly-qc-asm", ["quast", "checkv"]),
    ("nanopore-assembly-pharokka", ["pharokka", "dnaapler"]),
    ("nanopore-assembly-report", ["multiqc"]),
]


def list_env(env):
    """Return parsed `conda list -n <env> --json` output, or [] on failure."""
    try:
        r = subprocess.run(
            ["conda", "list", "-n", env, "--json"],
            capture_output=True, text=True, timeout=60, check=True,
        )
        return json.loads(r.stdout)
    except Exception:
        return []


def find_version(packages, query):
    """Exact match first, then substring fallback. Returns version or None."""
    q = query.lower()
    for entry in packages:
        if entry.get("name", "").lower() == q:
            return entry.get("version")
    for entry in packages:
        if q in entry.get("name", "").lower():
            return entry.get("version")
    return None


sm = snakemake  # type: ignore[name-defined]
out_path = Path(sm.output[0])
out_path.parent.mkdir(parents=True, exist_ok=True)

with out_path.open("w") as f:
    f.write("tool\tversion\tenvironment\n")
    for env, pkgs in ENV_TOOLS:
        listing = list_env(env)
        if not listing:
            continue
        for pkg in pkgs:
            ver = find_version(listing, pkg)
            if ver:
                f.write(f"{pkg}\t{ver}\t{env}\n")
