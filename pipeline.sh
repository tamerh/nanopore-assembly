#!/usr/bin/env bash
# ============================================================================
# Pipeline orchestrator. Single entry point for setup and execution.
#
#   ./pipeline.sh install [-f|--force] [--skip-data]
#                                   create/update all conda envs and download
#                                   reference databases under resources/
#   ./pipeline.sh check             verify envs + reference DBs are present
#   ./pipeline.sh run [-c N] [...]  full pipeline run (defensive: idempotent
#                                   + handles incomplete jobs from prior kills)
#   ./pipeline.sh dryrun [...]      preview the DAG without executing
#   ./pipeline.sh unlock            release a stale .snakemake lock
#   ./pipeline.sh clean [-f]        remove results/<project>/ + .snakemake/
#   ./pipeline.sh help              show this help
# ============================================================================
set -euo pipefail

ENVS_DIR="config/envs"
CONFIG_FILE="config/config.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- pretty output --------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
else
    BOLD=""; RED=""; GRN=""; YEL=""; RST=""
fi

log()  { echo "${BOLD}==>${RST} $*"; }
ok()   { echo "${GRN}ok:${RST} $*"; }
warn() { echo "${YEL}warn:${RST} $*" >&2; }
err()  { echo "${RED}error:${RST} $*" >&2; }

# ---- helpers --------------------------------------------------------------

# Print env name from a YAML file's `name:` field.
yaml_env_name() {
    awk '/^name:/ {print $2; exit}' "$1"
}

# Yes/no whether a conda env with the given name exists.
env_exists() {
    conda env list | awk '{print $1}' | grep -qx "$1"
}

# Find all env YAMLs, sorted (base.yaml first because of alphabetical order).
list_env_yamls() {
    find "$SCRIPT_DIR/$ENVS_DIR" -maxdepth 1 -type f -name "*.yaml" | sort
}

# Detect available solver. Echoes "mamba" or "conda".
detect_solver() {
    if command -v mamba >/dev/null 2>&1; then
        echo mamba
    else
        echo conda
    fi
}

# Read default project from config.yaml (top-level `project:` key).
config_project() {
    awk '/^project:/ {print $2; exit}' "$SCRIPT_DIR/$CONFIG_FILE"
}

# Make sure the orchestrator env (with snakemake) is active. No-op if already
# active; otherwise sources conda.sh and activates `nanopore-assembly`.
ensure_base_env() {
    if command -v snakemake >/dev/null 2>&1; then
        return 0
    fi

    local conda_base
    conda_base="$(conda info --base 2>/dev/null)"
    if [[ -z "$conda_base" ]]; then
        err "conda not on PATH"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$conda_base/etc/profile.d/conda.sh"

    if ! conda activate nanopore-assembly 2>/dev/null; then
        err "could not activate 'nanopore-assembly' env"
        err "have you run './pipeline.sh install' yet?"
        return 1
    fi
}

# ---- reference data setup -------------------------------------------------

# CheckV DB. Idempotent — skips if already set up.
setup_checkv_db() {
    local db_dir="$SCRIPT_DIR/resources/databases/checkv"
    local current_link="$db_dir/current"

    if [[ -L "$current_link" && -d "$current_link" ]]; then
        ok "CheckV DB already present ($current_link → $(readlink "$current_link"))"
        return 0
    fi

    if ! env_exists "nanopore-assembly-qc-asm"; then
        warn "qc-asm env missing — skipping CheckV DB download"
        warn "run install again after envs are ready"
        return 0
    fi

    log "downloading CheckV database (~5 GB) into $db_dir/"
    log "this is a one-time download — go get a coffee"
    mkdir -p "$db_dir"
    conda run -n nanopore-assembly-qc-asm checkv download_database "$db_dir"

    # Symlink the versioned dir to a stable name "current" (relative target
    # so the symlink is portable across machines / mount points).
    local versioned
    versioned=$(ls -d "$db_dir"/checkv-db-v* 2>/dev/null | sort -V | tail -1)
    if [[ -z "$versioned" ]]; then
        err "CheckV download appears to have failed — no checkv-db-v* directory under $db_dir/"
        return 1
    fi
    rm -f "$current_link"
    ln -s "$(basename "$versioned")" "$current_link"
    ok "CheckV DB ready at $current_link → $(basename "$versioned")"
}

# Pharokka DB. Idempotent.
setup_pharokka_db() {
    local db_dir="$SCRIPT_DIR/resources/databases/pharokka"

    # Pharokka writes DB files flat into the target dir; treat any non-empty
    # dir as "already set up".
    if [[ -d "$db_dir" ]] && [[ -n "$(ls -A "$db_dir" 2>/dev/null)" ]]; then
        ok "Pharokka DB already present at $db_dir"
        return 0
    fi

    if ! env_exists "nanopore-assembly-pharokka"; then
        warn "pharokka env missing — skipping Pharokka DB download"
        return 0
    fi

    log "downloading Pharokka database (~1.2 GB) into $db_dir/"
    mkdir -p "$db_dir"
    # Pharokka 1.7+ renamed the script: pharokka_install_databases.py → install_databases.py
    conda run -n nanopore-assembly-pharokka install_databases.py -o "$db_dir"
    ok "Pharokka DB ready at $db_dir"
}

# Run all reference data setup steps. Add new tools here as they're added.
setup_reference_data() {
    log "setting up reference databases"
    setup_checkv_db
    setup_pharokka_db
}

# ---- subcommands ----------------------------------------------------------

usage() {
    cat <<EOF
Usage: ./pipeline.sh <command> [options]

Commands:
  install [-f|--force] [--skip-data]
                         Create or update every conda env defined under
                         ${ENVS_DIR}/, then download reference databases
                         under resources/databases/. Idempotent.
                         --force: remove and recreate envs.
                         --skip-data: skip reference DB downloads.
  check                  Verify all envs and reference DBs are present.
  run [-c|--cores N] [extra-snakemake-args]
                         Run the full pipeline. Defaults: --use-conda,
                         --rerun-incomplete, --rerun-triggers mtime.
                         Default cores: 8. Extra args forwarded to snakemake.
  dryrun [args]          Preview the DAG via 'snakemake -n --rerun-triggers
                         mtime'. Mirrors what 'run' would actually execute.
  unlock                 Release a stale .snakemake lock (after a kill).
  clean [-f|--force]     Remove results/<current-project>/ and .snakemake/.
                         Prompts unless --force. Project comes from
                         config/config.yaml's 'project:' key.
  help                   Show this help.
EOF
}

cmd_install() {
    local force=0
    local skip_data=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force=1; shift ;;
            --skip-data) skip_data=1; shift ;;
            -h|--help)
                echo "Usage: ./pipeline.sh install [-f|--force] [--skip-data]"
                return 0
                ;;
            *) err "unknown option: $1"; return 1 ;;
        esac
    done

    # 1. conda is required
    if ! command -v conda >/dev/null 2>&1; then
        err "conda not found on PATH."
        err "install Miniconda: https://docs.conda.io/en/latest/miniconda.html"
        return 1
    fi
    ok "conda found ($(conda --version))"

    # 2. mamba preferred but optional
    local solver
    solver=$(detect_solver)
    if [[ "$solver" == "mamba" ]]; then
        ok "mamba found ($(mamba --version 2>/dev/null | head -1))"
    else
        warn "mamba not found — falling back to conda (slower env creation)"
        warn "to install: conda install -n base -c conda-forge mamba"
    fi

    # 3. find env YAMLs
    local yamls
    mapfile -t yamls < <(list_env_yamls)
    if [[ ${#yamls[@]} -eq 0 ]]; then
        err "no env YAMLs found under $ENVS_DIR/"
        return 1
    fi
    log "found ${#yamls[@]} env YAML(s) in $ENVS_DIR/"

    # 4. process each: create, update, or recreate
    local yaml env_name
    for yaml in "${yamls[@]}"; do
        env_name=$(yaml_env_name "$yaml")
        if [[ -z "$env_name" ]]; then
            warn "no 'name:' field in $(basename "$yaml") — skipping"
            continue
        fi

        if env_exists "$env_name"; then
            if [[ $force -eq 1 ]]; then
                log "removing $env_name (--force)"
                conda env remove -n "$env_name" -y >/dev/null
                log "creating $env_name from $(basename "$yaml")"
                "$solver" env create -f "$yaml"
            else
                log "$env_name exists — updating from $(basename "$yaml")"
                "$solver" env update -n "$env_name" -f "$yaml" --prune
            fi
        else
            log "creating $env_name from $(basename "$yaml")"
            "$solver" env create -f "$yaml"
        fi
        ok "$env_name ready"
    done

    log "all envs ready (${#yamls[@]} total)"

    # 5. reference data (databases) — large, one-time downloads
    if [[ $skip_data -eq 0 ]]; then
        setup_reference_data
    else
        warn "skipping reference data setup (--skip-data)"
    fi
}

cmd_check() {
    local yamls
    mapfile -t yamls < <(list_env_yamls)
    if [[ ${#yamls[@]} -eq 0 ]]; then
        err "no env YAMLs found under $ENVS_DIR/"
        return 1
    fi

    local missing=0
    local yaml env_name
    for yaml in "${yamls[@]}"; do
        env_name=$(yaml_env_name "$yaml")
        if [[ -z "$env_name" ]]; then
            warn "no 'name:' field in $(basename "$yaml") — skipping"
            continue
        fi
        if env_exists "$env_name"; then
            ok "env: $env_name"
        else
            err "env: $env_name (missing)"
            missing=$((missing + 1))
        fi
    done

    # Check reference databases.
    local checkv_link="$SCRIPT_DIR/resources/databases/checkv/current"
    if [[ -L "$checkv_link" && -d "$checkv_link" ]]; then
        ok "db: checkv ($(readlink "$checkv_link"))"
    else
        err "db: checkv (missing at $checkv_link)"
        missing=$((missing + 1))
    fi

    local pharokka_dir="$SCRIPT_DIR/resources/databases/pharokka"
    if [[ -d "$pharokka_dir" ]] && [[ -n "$(ls -A "$pharokka_dir" 2>/dev/null)" ]]; then
        ok "db: pharokka"
    else
        err "db: pharokka (missing at $pharokka_dir)"
        missing=$((missing + 1))
    fi

    if [[ $missing -gt 0 ]]; then
        err "$missing item(s) missing — run './pipeline.sh install'"
        return 1
    fi
    ok "all envs and DBs present"
}

cmd_run() {
    local cores=8
    local extra_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--cores) cores="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: ./pipeline.sh run [-c|--cores N] [extra-snakemake-args]"
                return 0
                ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done

    cd "$SCRIPT_DIR" || return 1
    ensure_base_env || return 1
    local project
    project=$(config_project)
    log "running pipeline (project: $project, cores: $cores)"
    # --rerun-triggers mtime: only re-run when an input is newer than an
    # output (or output is missing). Snakemake 8+ defaults to a more
    # comprehensive trigger set (params, code, software-env) which can
    # flag spurious reruns from cosmetic edits to rules/envs. We use mtime
    # so that 'run' and 'dryrun' agree on what actually needs to run.
    # User can override by passing --rerun-triggers explicitly.
    snakemake \
        --use-conda \
        --cores "$cores" \
        --rerun-incomplete \
        --rerun-triggers mtime \
        "${extra_args[@]}"
}

cmd_dryrun() {
    cd "$SCRIPT_DIR" || return 1
    ensure_base_env || return 1
    snakemake -n --rerun-triggers mtime "$@"
}

cmd_unlock() {
    cd "$SCRIPT_DIR" || return 1
    ensure_base_env || return 1
    log "releasing .snakemake lock"
    snakemake --unlock
    ok "unlocked"
}

cmd_clean() {
    local force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force=1; shift ;;
            -h|--help)
                echo "Usage: ./pipeline.sh clean [-f|--force]"
                return 0
                ;;
            *) err "unknown option: $1"; return 1 ;;
        esac
    done

    local project
    project=$(config_project)
    if [[ -z "$project" ]]; then
        err "could not determine project from $CONFIG_FILE"
        return 1
    fi

    local results_dir="$SCRIPT_DIR/results/$project"
    local snakemake_dir="$SCRIPT_DIR/.snakemake"

    log "will remove:"
    log "  $results_dir"
    log "  $snakemake_dir"

    if [[ $force -eq 0 ]]; then
        read -rp "proceed? [y/N] " ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            log "aborted"
            return 0
        fi
    fi

    rm -rf "$results_dir" "$snakemake_dir"
    ok "cleaned project '$project'"
}

# ---- dispatch -------------------------------------------------------------

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    local cmd="$1"; shift
    case "$cmd" in
        install)         cmd_install "$@" ;;
        check)           cmd_check "$@" ;;
        run)             cmd_run "$@" ;;
        dryrun|-n)       cmd_dryrun "$@" ;;
        unlock)          cmd_unlock "$@" ;;
        clean)           cmd_clean "$@" ;;
        help|-h|--help)  usage ;;
        *)
            err "unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
