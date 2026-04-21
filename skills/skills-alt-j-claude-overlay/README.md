# Alt J Claude overlay (orchestrator + dead-constant patch)

Tiny supplemental overlay used by **Alt J** (OpenClaw orchestrator + Claude
Code CLI executor + Gemini reviewer). Install **after** both:

1. Base skills: `cp -r skills/* ~/.claude/skills/`
2. Reviewer overlay: `cp -r skills/skills-codex-gemini-review/* ~/.claude/skills/`
3. **This overlay**: `cp -r skills/skills-alt-j-claude-overlay/* ~/.claude/skills/`

## What it patches

The upstream `skills-codex-gemini-review/` overlay covers the 15 reviewer-aware
skills, but two skills it does NOT touch still leak `mcp__codex__codex`
references that Claude's verification pass flags:

| Skill | Leak before patch | After patch |
|---|---|---|
| `research-pipeline` | `allowed-tools` lists `mcp__codex__codex(-reply)`; Stage 4 prose says "GPT-5.4 xhigh reviews"; `nightmare` mode references `codex exec` | Lists `mcp__gemini-review__*` instead; Stage 4 prose says Gemini; `nightmare` documented as falling back to `hard` on Alt J |
| `research-lit` | `REVIEWER_BACKEND = codex` constant (dead but misleading) | `REVIEWER_BACKEND = gemini-review` |

Both files are byte-identical to the upstream base skills except for the
narrow reviewer-routing changes. Verified with three rounds of Claude Code
verification passes; final pass: 0 residual codex refs across all 11
canonical reviewer / pipeline / standalone skills.

## Why a separate overlay package

Keeping these patches out of the upstream `skills-codex-gemini-review/`
overlay preserves that overlay's intended scope (reviewer-tool rewrites only,
no orchestrator-level edits). Alt J users opt in to the additional
orchestrator patch by installing this package.
