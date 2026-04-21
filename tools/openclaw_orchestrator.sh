#!/usr/bin/env bash
# openclaw_orchestrator.sh — OpenClaw-driven Alt J orchestrator for ARIS.
#
# Walks a research direction through the ARIS workflow by spawning a fresh
# `claude` CLI subprocess per stage. Claude is backed by Google Vertex AI
# (per the env vars below) and uses the gemini-review MCP bridge for any
# reviewer turn. OpenClaw is expected to be the parent process that calls
# this script and surfaces progress to the user.
#
# Usage:
#   bash tools/openclaw_orchestrator.sh "<research direction>"
#   bash tools/openclaw_orchestrator.sh --brief path/to/RESEARCH_BRIEF.md
#   bash tools/openclaw_orchestrator.sh --brief brief.md --only lit-scan
#   bash tools/openclaw_orchestrator.sh "topic" --dry-run
#
# Stages (run in order unless --only is supplied):
#   lit-scan, idea-creator, novelty-check, experiment-plan,
#   run-experiment, auto-review-loop, paper-writing

set -euo pipefail

# --- argument parsing ---
DRY_RUN=0
BRIEF_PATH=""
ONLY_STAGE=""
DIRECTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --brief)
      BRIEF_PATH="${2:-}"
      if [[ -z "$BRIEF_PATH" ]]; then
        echo "ERROR: --brief requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    --only)
      ONLY_STAGE="${2:-}"
      if [[ -z "$ONLY_STAGE" ]]; then
        echo "ERROR: --only requires a stage name" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      cat <<'HLP'
openclaw_orchestrator.sh — drive ARIS stages through Claude (Vertex) + Gemini.

Usage:
  openclaw_orchestrator.sh "<research direction>"
  openclaw_orchestrator.sh --brief path/to/RESEARCH_BRIEF.md
  openclaw_orchestrator.sh [...] --only <stage>
  openclaw_orchestrator.sh [...] --dry-run

Stages:
  lit-scan, idea-creator, novelty-check, experiment-plan,
  run-experiment, auto-review-loop, paper-writing

Environment (overridable, defaults shown):
  CLAUDE_CODE_USE_VERTEX=1
  GOOGLE_CLOUD_PROJECT=ucr-ursa-major-congliu-lab
  CLOUD_ML_REGION=global
  ANTHROPIC_VERTEX_PROJECT_ID=ucr-ursa-major-congliu-lab
  API_TIMEOUT_MS=3000000
  GEMINI_REVIEW_BACKEND=api    # "api" (default) or "cli"
  GEMINI_API_KEY=...           # required when backend=api (or set GOOGLE_API_KEY)
  OPENCLAW_MCP_CONFIG=<path>   # optional: passed to `claude --mcp-config`
HLP
      exit 0
      ;;
    *)
      if [[ -z "$DIRECTION" ]]; then
        DIRECTION="$1"
      else
        echo "ERROR: unexpected positional arg: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$BRIEF_PATH" && -z "$DIRECTION" ]]; then
  echo "ERROR: provide a research direction (positional) or --brief <path>" >&2
  exit 2
fi

if [[ -n "$BRIEF_PATH" && ! -f "$BRIEF_PATH" ]]; then
  echo "ERROR: brief file not found: $BRIEF_PATH" >&2
  exit 2
fi

# --- env: enforce required Vertex vars (inherit from parent shell if already set) ---
# We intentionally do NOT source ~/.zshrc here — many user zshrcs invoke Oh My Zsh
# which calls `exit` when sourced from bash and would kill this script. Set the
# vars in your parent shell (or in ~/.claude/settings.json env block) instead.

export CLAUDE_CODE_USE_VERTEX="${CLAUDE_CODE_USE_VERTEX:-1}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-ucr-ursa-major-congliu-lab}"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-ucr-ursa-major-congliu-lab}"
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-3000000}"
export GEMINI_REVIEW_BACKEND="${GEMINI_REVIEW_BACKEND:-api}"

# Reviewer credentials must be present in the parent env so the spawned MCP
# subprocess (gemini-review) can read them. The orchestrator does NOT source
# ~/.zshrc (see note above), so the user is responsible for exporting one of
# GEMINI_API_KEY or GOOGLE_API_KEY before invoking this script. We also
# auto-load ~/.gemini/.env if present (the bridge supports this directly, but
# loading it here surfaces problems earlier).
if [[ -z "${GEMINI_API_KEY:-}" && -z "${GOOGLE_API_KEY:-}" ]]; then
  if [[ -f "$HOME/.gemini/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$HOME/.gemini/.env"; set +a
  fi
fi
if [[ "$GEMINI_REVIEW_BACKEND" == "api" ]] && [[ -z "${GEMINI_API_KEY:-}" && -z "${GOOGLE_API_KEY:-}" ]]; then
  echo "WARNING: GEMINI_REVIEW_BACKEND=api but neither GEMINI_API_KEY nor GOOGLE_API_KEY is exported." >&2
  echo "         Reviewer turns will fail. Export the key in the parent shell, or unset GEMINI_REVIEW_BACKEND" >&2
  echo "         to fall back to the CLI backend (see docs/OPENCLAW_ORCHESTRATOR_GUIDE.md troubleshooting)." >&2
fi

# --- workspace ---
WORKDIR="$(pwd)"
OUTPUTS_DIR="$WORKDIR/outputs"
mkdir -p "$OUTPUTS_DIR"

LOG_FILE="$OUTPUTS_DIR/ORCHESTRATOR_LOG.md"
if [[ ! -f "$LOG_FILE" ]]; then
  {
    echo "# OpenClaw Orchestrator Log (Alt J)"
    echo
    echo "| Timestamp (UTC) | Stage | Status | Detail |"
    echo "|---|---|---|---|"
  } > "$LOG_FILE"
fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_event() {
  local stage="$1"
  local status="$2"
  local detail="$3"
  printf -- "| %s | %s | %s | %s |\n" "$(ts)" "$stage" "$status" "$detail" >> "$LOG_FILE"
}

# --- stages: pipe-delimited "name|prompt|expected_artifact" ---
STAGES=(
  "lit-scan|Run /research-lit on the research direction. If RESEARCH_BRIEF.md exists in the cwd, read it first; otherwise use the inline direction provided above. Save the structured literature scan and gap list to outputs/lit_scan.md.|outputs/lit_scan.md"
  "idea-creator|Run /idea-creator using outputs/lit_scan.md as landscape context. Generate, filter, and rank ideas. Write the report to outputs/idea_report.md (and copy a stable alias to idea-stage/IDEA_REPORT.md if that directory exists).|outputs/idea_report.md"
  "novelty-check|Run /novelty-check on the top-ranked idea from outputs/idea_report.md. Append the novelty verdict (with citations) to outputs/novelty_check.md.|outputs/novelty_check.md"
  "experiment-plan|Run /experiment-bridge in planning-only mode for the top idea. Produce outputs/experiment_plan.md with the experiment matrix, success metrics, and runbook commands. Do NOT deploy.|outputs/experiment_plan.md"
  "run-experiment|Run /run-experiment for the experiment plan in outputs/experiment_plan.md. Use local GPUs if available; otherwise queue and write outputs/experiment_log.md with the launch state.|outputs/experiment_log.md"
  "auto-review-loop|Run /auto-review-loop with REVIEWER_MODEL routed through the gemini-review MCP. Iterate up to 4 rounds. Write the cumulative log to review-stage/AUTO_REVIEW.md and a stable copy to outputs/auto_review.md.|outputs/auto_review.md"
  "paper-writing|Run /paper-writing for the validated work. Produce outputs/paper_draft.md and, if /paper-compile is available, paper/main.pdf.|outputs/paper_draft.md"
)

# --- per-stage runner ---
run_stage() {
  local stage_name="$1"
  local prompt_template="$2"
  local artifact="$3"

  local context
  if [[ -n "$BRIEF_PATH" ]]; then
    context="The research brief is at: $BRIEF_PATH (relative or absolute). Read it before doing anything else."
  else
    context="Research direction: $DIRECTION"
  fi

  local full_prompt
  full_prompt="$context

$prompt_template

Reasoning effort: max. Always prefer the gemini-review MCP for any reviewer turn. Write outputs to the cwd's outputs/ directory."

  local stage_log="$OUTPUTS_DIR/${stage_name}.log"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] stage=$stage_name"
    echo "[dry-run]   command: claude --dangerously-skip-permissions --effort max -p <prompt>"
    echo "[dry-run]   prompt-bytes: $(printf '%s' "$full_prompt" | wc -c | tr -d ' ')"
    echo "[dry-run]   expected artifact: $artifact"
    echo "[dry-run]   log: $stage_log"
    log_event "$stage_name" "DRY-RUN" "would invoke claude (Vertex, --effort max)"
    return 0
  fi

  log_event "$stage_name" "START" "spawning claude executor (Vertex, --effort max)"
  echo "==> [$stage_name] starting at $(ts)"

  local rc=0
  local mcp_arg=()
  if [[ -n "${OPENCLAW_MCP_CONFIG:-}" ]]; then
    if [[ ! -f "$OPENCLAW_MCP_CONFIG" ]]; then
      log_event "$stage_name" "FAIL" "OPENCLAW_MCP_CONFIG not found: $OPENCLAW_MCP_CONFIG"
      echo "ERROR: OPENCLAW_MCP_CONFIG points to missing file: $OPENCLAW_MCP_CONFIG" >&2
      return 2
    fi
    mcp_arg=(--mcp-config "$OPENCLAW_MCP_CONFIG")
  fi
  if claude "${mcp_arg[@]}" --dangerously-skip-permissions --effort max -p "$full_prompt" >"$stage_log" 2>&1; then
    if [[ -f "$artifact" ]]; then
      log_event "$stage_name" "OK" "artifact present: $artifact"
      echo "==> [$stage_name] done. artifact: $artifact"
      return 0
    fi
    log_event "$stage_name" "FAIL" "claude exited 0 but artifact missing: $artifact (see $stage_log)"
    echo "ERROR: $stage_name produced no artifact at $artifact" >&2
    echo "       see $stage_log for the executor transcript" >&2
    return 3
  else
    rc=$?
    log_event "$stage_name" "FAIL" "claude exit=$rc (see $stage_log)"
    echo "ERROR: $stage_name failed (exit $rc); see $stage_log" >&2
    return "$rc"
  fi
}

# --- main loop ---
echo "OpenClaw orchestrator (Alt J) starting at $(ts)"
echo "  direction : ${DIRECTION:-<from brief>}"
echo "  brief     : ${BRIEF_PATH:-<none>}"
echo "  outputs   : $OUTPUTS_DIR"
echo "  dry-run   : $DRY_RUN"
echo "  only      : ${ONLY_STAGE:-<all stages>}"
echo "  vertex    : project=$GOOGLE_CLOUD_PROJECT region=$CLOUD_ML_REGION"
echo "  reviewer  : gemini-review MCP backend=$GEMINI_REVIEW_BACKEND"
echo

log_event "pipeline" "START" "direction=${DIRECTION:-<brief>} brief=${BRIEF_PATH:-<none>} dry_run=$DRY_RUN only=${ONLY_STAGE:-all}"

ran_any=0
for entry in "${STAGES[@]}"; do
  IFS='|' read -r stage_name prompt_template artifact <<<"$entry"
  if [[ -n "$ONLY_STAGE" && "$ONLY_STAGE" != "$stage_name" ]]; then
    continue
  fi
  ran_any=1
  run_stage "$stage_name" "$prompt_template" "$artifact"
done

if [[ "$ran_any" -eq 0 ]]; then
  echo "ERROR: --only stage '$ONLY_STAGE' did not match any known stage" >&2
  log_event "pipeline" "FAIL" "unknown --only stage: $ONLY_STAGE"
  exit 2
fi

log_event "pipeline" "DONE" "all selected stages completed"
echo
echo "Pipeline complete. Log: $LOG_FILE"
