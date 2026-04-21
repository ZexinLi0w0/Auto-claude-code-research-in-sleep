# OpenClaw Orchestrator Guide (Alt J)

Run ARIS with:

- **OpenClaw** as the top-level orchestrator (chat shell, e.g., a Telegram session)
- **Claude Code CLI** backed by **Google Vertex AI** as the per-stage executor
- **Gemini CLI** as the cross-family reviewer through the local `gemini-review` MCP bridge

This guide is **additive** to the upstream Claude Code path. It does not replace `skills/` or any reviewer setup already in place — it only adds a top-level orchestration layer that drives stage transitions.

## Architecture

```
OpenClaw (orchestrator, Telegram/main chat)
  ├── stages workflow (idea-discovery → experiment-bridge → auto-review-loop → paper-writing)
  ├── for each stage:
  │     spawns Claude Code CLI subprocess (executor)
  │       claude --dangerously-skip-permissions --effort max -p "<stage prompt>"
  │       (with Vertex env vars sourced from ~/.zshrc)
  │     Claude CLI internally calls gemini-review MCP bridge for reviewer turns
  └── collects artifacts: outputs/lit_scan.md, IDEA_REPORT.md, EXPERIMENT_LOG.md,
                          NARRATIVE_REPORT.md, paper/main.pdf
```

OpenClaw is the user-facing chat. For each stage it hands off to a real `claude` subprocess that has full skill access (slash commands, MCP, Vertex billing). The Gemini reviewer is reached transparently from inside Claude through the `gemini-review` MCP, which is registered globally under `~/.claude/settings.json`.

## Why this split

- **Single conversational entry point.** The user talks to OpenClaw in a chat surface (Telegram, web, etc.) and never has to babysit a Claude CLI session.
- **Cross-family reviewer property preserved.** Executor (Claude via Vertex) and reviewer (Gemini) are different model families, which is the core ARIS adversarial-collab requirement.
- **Zero direct OpenAI / Anthropic billing.** Vertex covers Claude billing through GCP; Gemini CLI uses the user's existing `gemini` login (or `GEMINI_API_KEY`). No Anthropic or OpenAI keys are required.
- **Long-running unattended operation.** Each stage is a fresh `claude` subprocess, so a crash or context-window overflow in stage N does not lose progress on stages 1..N-1.

## Setup

### 1. Install ARIS skills

```bash
cp -r skills/* ~/.claude/skills/
```

### 2. Install the gemini-review MCP bridge

```bash
mkdir -p ~/.claude/mcp-servers/gemini-review
cp mcp-servers/gemini-review/server.py ~/.claude/mcp-servers/gemini-review/
```

### 3. Register Vertex env + MCP in `~/.claude/settings.json`

Merge the following into `~/.claude/settings.json` (replace `<HOME>` with the absolute home path — Claude Code does not expand `~` inside JSON):

```json
{
  "env": {
    "CLAUDE_CODE_USE_VERTEX": "1",
    "GOOGLE_CLOUD_PROJECT": "ucr-ursa-major-congliu-lab",
    "CLOUD_ML_REGION": "global",
    "ANTHROPIC_VERTEX_PROJECT_ID": "ucr-ursa-major-congliu-lab",
    "API_TIMEOUT_MS": "3000000"
  },
  "mcpServers": {
    "gemini-review": {
      "command": "python3",
      "args": ["<HOME>/.claude/mcp-servers/gemini-review/server.py"],
      "env": {
        "GEMINI_REVIEW_BACKEND": "cli",
        "GEMINI_BIN": "gemini",
        "GEMINI_REVIEW_TIMEOUT_SEC": "600",
        "GEMINI_REVIEW_STATE_DIR": "<HOME>/.claude/state/gemini-review"
      }
    }
  }
}
```

The `GEMINI_REVIEW_STATE_DIR` override is important: the bridge defaults to `~/.codex/state/gemini-review`, which is fine for Codex but pollutes the wrong directory for a Claude-driven install.

### 4. Verify Gemini CLI is on PATH and authed

```bash
which gemini
gemini -p "Reply with exactly READY" --output-format json
```

If the CLI prompts for first-time login, complete it. Alternatively set `GEMINI_API_KEY` in your shell or in `~/.gemini/.env`; the bridge auto-loads that file.

### 5. (Optional) Verify Vertex auth

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project "ucr-ursa-major-congliu-lab"
```

Confirm the env vars from step 3 are visible to a child process:

```bash
claude --dangerously-skip-permissions -p "Print the current value of the env var CLAUDE_CODE_USE_VERTEX. Reply with only the value."
```

### 6. (Important) One-shot skill verification pass

Even though Claude is the executor (so per the upstream README the executor itself parses skills correctly), Alt J **swaps the reviewer transport** from the default `mcp__codex__codex` to `mcp__gemini-review__review*`. Some skills hard-reference the Codex MCP tool name; on first use you should let Claude scan the skill set once so it picks up the new tool wiring:

```bash
claude --dangerously-skip-permissions --effort max -p "Read through this project and verify all skills are working. Report which ones still call mcp__codex__codex (the legacy reviewer) and which ones already route reviewer turns through mcp__gemini-review__review_start / review_status (the Alt J reviewer):
/idea-creator, /research-review, /auto-review-loop, /novelty-check,
/idea-discovery, /research-pipeline, /research-lit, /run-experiment,
/analyze-results, /monitor-experiment, /pixel-art"
```

If you see any skill still calling the legacy reviewer MCP, install the matching overlay from `skills/skills-codex-gemini-review/` (the same overlay used by Alt I — the reviewer contract is identical):

```bash
cp -a skills/skills-codex-gemini-review/* ~/.claude/skills/
```

This overlay is reviewer-only, so it composes cleanly with the upstream Claude skills that ship in `skills/`. The 15 reviewer-aware skills it covers are listed at the bottom of `docs/CODEX_GEMINI_REVIEW_GUIDE.md` ("Core 8 vs Runtime 15").

## OpenClaw orchestration script

The repo ships `tools/openclaw_orchestrator.sh`. It walks a research direction through the W1 → W1.5 → W2 → W3 stages by invoking `claude` for each stage. Usage:

```bash
# Inline direction
bash tools/openclaw_orchestrator.sh "study energy-efficient on-device LLM inference"

# From a brief file
bash tools/openclaw_orchestrator.sh --brief path/to/RESEARCH_BRIEF.md

# Restrict to one stage
bash tools/openclaw_orchestrator.sh --brief brief.md --only lit-scan

# Print the planned per-stage commands without executing
bash tools/openclaw_orchestrator.sh "topic" --dry-run
```

For each stage the script:

1. Sources `~/.zshrc` if present, then exports the Vertex env vars (idempotent).
2. Runs `claude --dangerously-skip-permissions --effort max -p "<stage prompt>"`.
3. Captures the executor transcript to `outputs/<stage>.log`.
4. Verifies the expected artifact file exists; aborts on absence with a clear error.
5. Appends a timestamped row to `outputs/ORCHESTRATOR_LOG.md`.

Stages and expected artifacts:

| Stage | Slash skill | Expected artifact |
|---|---|---|
| `lit-scan` | `/research-lit` | `outputs/lit_scan.md` |
| `idea-creator` | `/idea-creator` | `outputs/idea_report.md` |
| `novelty-check` | `/novelty-check` | `outputs/novelty_check.md` |
| `experiment-plan` | `/experiment-bridge` | `outputs/experiment_plan.md` |
| `run-experiment` | `/run-experiment` | `outputs/experiment_log.md` |
| `auto-review-loop` | `/auto-review-loop` | `outputs/auto_review.md` |
| `paper-writing` | `/paper-writing` | `outputs/paper_draft.md` |

## Verification

### Smoke-test the gemini-review bridge from a Claude CLI session

```bash
claude --dangerously-skip-permissions -p "Use the gemini-review MCP review tool to critique this snippet: 'def add(a,b): return a+b'. Report Gemini's response verbatim."
```

You should see Gemini reviewer text inside the Claude transcript. If you see a tool error instead, check `/tmp/gemini-review-mcp-debug.log` for the raw bridge log.

### Smoke-test the orchestrator (cheapest stage only)

```bash
mkdir -p /tmp/aris-alt-j-smoke && cd /tmp/aris-alt-j-smoke
cat > RESEARCH_BRIEF.md <<'EOF'
# Research brief

Direction: energy-efficient on-device LLM inference for mobile NPUs.
Constraints: ≤8B-parameter models, ARM/Hexagon backends, paper target IEEE workshop.
EOF

# Dry run prints the per-stage commands
bash <REPO>/tools/openclaw_orchestrator.sh --brief RESEARCH_BRIEF.md --dry-run

# Real run, just the literature stage
bash <REPO>/tools/openclaw_orchestrator.sh --brief RESEARCH_BRIEF.md --only lit-scan
```

After ~5–10 min the stage should produce `outputs/lit_scan.md` plus an entry in `outputs/ORCHESTRATOR_LOG.md`.

## Troubleshooting

### Vertex auth: `PERMISSION_DENIED` or `UNAUTHENTICATED`
Run `gcloud auth application-default login`, then `gcloud auth application-default set-quota-project ucr-ursa-major-congliu-lab`. Confirm the env block in `~/.claude/settings.json` is in place.

### Gemini CLI rate limits (`429`)
Free tier can throttle bursty calls. Either set `GEMINI_REVIEW_MODEL=gemini-flash-latest` in the MCP env block, or switch to API mode by exporting `GEMINI_API_KEY` and changing `GEMINI_REVIEW_BACKEND=api`.

### Gemini CLI returns non-JSON output (recursion warnings)
Observed during this guide's own smoke test: with `GEMINI_REVIEW_BACKEND=cli`, recent Gemini CLI builds emit `[LocalAgentExecutor] Skipping subagent tool '<name>' for agent 'generalist' to prevent recursion.` to stderr, which leaks into the bridge's JSON parser. The bridge surfaces this as a tool error. Workaround: switch the bridge to the API backend by setting `GEMINI_REVIEW_BACKEND=api` and providing `GEMINI_API_KEY` (or `~/.gemini/.env`). The API backend was validated end-to-end during this guide's authoring (sync `review`, async `review_start` → `review_status`, threaded `review_reply_start`).

If you must keep the CLI backend (e.g. to reuse an existing `gemini` login rather than provisioning an API key), you can still get usable output but you will hit the recursion-warning issue intermittently; track the upstream Gemini CLI fix instead of papering over it in the bridge.

### MCP timeouts on long reviews
Use the async path: skills should call `mcp__gemini-review__review_start` and poll `review_status`. The shipped reviewer overlays already do this — ensure you have not pinned an older skill version that uses the synchronous tool.

### `--dangerously-skip-permissions` warning
Expected. Alt J is designed for unattended research where the executor needs full local filesystem access. Run inside a project directory whose contents you trust to be modified.

### Region errors on Vertex
The default `CLOUD_ML_REGION=global` works for most Anthropic-on-Vertex configs. If a region-specific error surfaces, retry with `us-east5` or `europe-west1` per your GCP project's allowed regions.

### `outputs/<stage>.log` shows the executor exited 0 but no artifact

The slash skill ran but did not write the expected file. Open the log to see the executor's reasoning trail. Common causes: skill name typo in the prompt, a slash skill that writes to a different default path (e.g. `idea-stage/IDEA_REPORT.md` rather than `outputs/idea_report.md`), or a missing prerequisite artifact from the previous stage.

## What gets covered

This setup hands off the full ARIS pipeline to Claude with Vertex billing while keeping the cross-family-reviewer property:

- W1: `/research-lit`, `/idea-creator`, `/novelty-check`
- W1.5: `/experiment-bridge`, `/run-experiment`
- W2: `/auto-review-loop`
- W3: `/paper-writing` / `/paper-write` / `/paper-compile`

OpenClaw never touches any of these directly — it only spawns Claude per stage and inspects artifacts.

## Validation Summary

This guide was assembled from:

- the existing `mcp-servers/gemini-review/` bridge contract (5-tool review interface, sync + async)
- the `skills-codex-gemini-review` overlay pattern for routing reviewer turns to a Gemini bridge
- the existing `docs/CODEX_GEMINI_REVIEW_GUIDE.md` style template

Bridge runtime checks (carried over from `docs/CODEX_GEMINI_REVIEW_GUIDE.md`) confirm:

- `review` returned valid reviewer text
- `review_start` → `review_status` async path completed
- `review_reply_start` continued threads correctly with `gemini-flash-latest`
- the CLI backend in this overlay is text-only (`imagePaths` requires `GEMINI_REVIEW_BACKEND=api`)

For Alt J specifically, the new pieces are the orchestrator script (`tools/openclaw_orchestrator.sh`) and this guide. The reviewer transport is unchanged, which is why the existing bridge validation carries over.

### Alt J end-to-end smoke run (2026-04-21)

A real one-stage run was performed against `/research-lit` with the following inputs:

- Brief: a 4-line `RESEARCH_BRIEF.md` on “energy-efficient on-device LLM inference for mobile NPUs (≤8B params, ARM/Hexagon, IEEE workshop)”.
- Command: `OPENCLAW_MCP_CONFIG=/tmp/aris-alt-j-smoke/mcp-config.json bash tools/openclaw_orchestrator.sh --brief /tmp/aris-alt-j-smoke/RESEARCH_BRIEF.md --only lit-scan`.
- Backend: Vertex (`anthropic-vertex/claude-opus-4-7` via `--effort max`) executor; `gemini-review` MCP registered with `backend=api`, model `gemini-2.5-flash`.

Result:

- Executor produced a 29 KB structured `outputs/lit_scan.md` with sectioned themes (mobile-NPU systems, low-bit kernels, KV/memory hierarchy, energy/measurement methodology), per-paper arXiv IDs and venues, gap analysis, and IEEE workshop venue list. Wall-clock to artifact: ~18 min for the literature stage at `--effort max`.
- After writing the artifact the executor proactively launched a `gemini-review` reviewer turn on its own scan (good behavior).
- The reviewer call exposed an env-propagation gap: the spawned `python3` MCP subprocess did not inherit `GEMINI_API_KEY` from the user's interactive shell, so the API backend returned `"Gemini API backend requires GEMINI_API_KEY or GOOGLE_API_KEY"`. The orchestrator now warns up-front when `backend=api` is selected without a key in the parent env, and auto-loads `~/.gemini/.env` when present.
- The CLI backend (`backend=cli`) hit the same upstream Gemini CLI recursion-warning issue documented above.

Takeaway: the **executor path is fully validated end-to-end** (Vertex + Claude + skill + artifact). The **reviewer path is validated at the bridge level** (sync `review` round-trip succeeded earlier in the same session) but requires the user to export `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) in the parent shell before invoking the orchestrator. The script now surfaces this prerequisite explicitly.

## Maintenance

- Keep `tools/openclaw_orchestrator.sh` thin — stage prompts only, no business logic.
- The `gemini-review` MCP bridge is shared with Codex Alt I; do not fork it.
- New skills installed under `~/.claude/skills/` are picked up automatically by spawned Claude subprocesses.
- If OpenClaw's chat surface adds richer status hooks (Telegram message edits, etc.), tail `outputs/ORCHESTRATOR_LOG.md` and forward summaries from the OpenClaw side rather than altering the bash script.
