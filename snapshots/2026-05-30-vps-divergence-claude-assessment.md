# Companion note — assessment of the 2026-05-30 VPS-divergence snapshot

> **POINT-IN-TIME ASSESSMENT — 2026-05-30.** Companion to
> `2026-05-30-vps-code-divergence.md`. Read-only review by Claude at Harlan's
> request; **nothing was changed** (local repo or VPS). Like all files here,
> this is a dated snapshot, not maintained documentation — re-check live before
> acting. See `snapshots/README.md`.

## Correction — my "central inference" below is superseded (added 2026-05-30, after the globalpatientsafety note)

A third note in this folder —
`2026-05-30-vps-divergence-globalpatientsafety-agent-note.md`, written by the
globalpatientsafety session that *ran the pico-dag review-fix loops* — has the
record my vantage point lacked (`~/projects/globalpatientsafety/DECISION_LOG.md`,
entries 2026-05-16). It shows the diverging VPS code is **this project's own
review-fix-loop work, already committed and pushed to `origin/main`** — not an
"SCD-agent improvement," and not a one-of-a-kind prod-only artifact. So my
**"central inference" below is most likely a misattribution.** The VPS appears to
be ~18 commits behind via **deploy-by-copy onto a stale checkout** (which is what
made upstream-tracked files look "untracked" on the box), so the bulk of the
divergence is already safe in `origin/main` + `pico-dag/reviews/`.

What still stands from my note: the snapshot mechanics, **preserve-first**, the
three-way-vs-two-way reconciliation point, and the workflow root cause. What
changes: **urgency is lower** (likely deploy hygiene, not a lost masterpiece).
The remaining open item is the globalpatientsafety note's cheap confirming diff
(VPS tree vs `origin/main`) to rule out a genuine prod-only residual.

## Verdict on the primary snapshot

Accurate and well-reasoned. The diagnosis of *why* a `git pull` aborts (local
edits to tracked files **plus** untracked files that upstream now tracks) is
correct, and the **"preserve first, reconcile second"** ordering is the right
call. No corrections to its mechanics.

## What a read-only cross-check (local repo + Claude memory) adds

- **The four `origin/main` "fixes" (`2c52d47`→`560740d`) are Harlan's own commits
  from 2026-05-29**, and they came out of a **review-fix-loop** session (repo
  `PLAN.md` + the "CONVERGED after 4 logical rounds" SUMMARY). This is a
  **separate line of work** from the VPS edits — likely the Claude session Harlan
  was half-remembering.
- **No `scd` / `vps` / `snapshot` branch exists on `origin`.**
- **No pico-dag copy is tracked under `~/projects/SCDCernerProject`** (grep found
  none).
- **Claude's stored memory has nothing specific** about this revision — only a
  tangential note that pico-dag is one of the tool projects. No memory of having
  reviewed the SCD-agent improvement.

## Central inference (for the owner to confirm)

The SCD agent's "significant improvement" is **not** in the clean local clone and
**not** in `origin/main`. The snapshot reports ~1,200 uncommitted lines on the
VPS that are *larger and more extensive* than the upstream fixes
(`dag_walker.R` +725, `app.R` +491). Most likely reading:

> **The VPS's uncommitted edits *are* the SCD agent's improvement** — written
> straight into the prod clone `/srv/shiny-server/pico-dag` and never committed.

If so, those 1,200 lines are the **most valuable artifact and exist in exactly
one place: a production box.** That makes "preserve first" **urgent**, not merely
prudent — a bad deploy/reset/disk event loses the improvement. Capture should
happen independent of whether the new fixes ship.

**To confirm without touching the VPS:** if the SCD agent's output exists
anywhere else (a transcript, a separate clone, a log), diff it against the VPS
tree. If it matches → VPS tree is the canonical SCD-agent work. If nothing else
has it → the VPS tree is the only copy.

## Two points the primary snapshot under-emphasizes

1. **There are potentially three versions to reconcile, not two:**
   `origin/main` (Harlan's review-fix commits), the VPS uncommitted edits (likely
   the SCD-agent improvement), and the SCD-agent's own source-of-truth if that's
   not the VPS. The merge question is whether the SCD-agent work **supersedes** or
   **must be merged with** the review-fix commits, since both touched
   `dag_walker.R`.
2. **Root cause is the workflow.** An agent (or hand-edits) writing to the prod
   clone without committing is what produced an 18-commit + 1,200-line
   divergence. After capture, the durable fix is commit-locally → push →
   pull-on-prod, and never let the SCD agent edit prod directly.

## Code & document locations

**The pico-dag code**
- GitHub (source of truth): `git@github.com:harlananelson/pico-dag.git` — branch
  `origin/main`, HEAD `560740d`.
- Local clone: `~/projects/pico-dag` (clean; where the review-fix loops ran).
- Production VPS clone: `/srv/shiny-server/pico-dag` on host `5.78.69.136`
  (Hetzner), served at `https://picodag.globalpatientsafety.com` (owner
  `shiny:shiny`; restart `systemctl restart shiny-server`). At commit `d8f095b`,
  ~18 behind — the divergence in the primary snapshot.

**The diverging files** (under `app/R/` unless noted)
- Modified-on-VPS: `dag_walker.R`, `code_lists.R`, `network_viz.R`,
  `umls_client_duckdb.R`, and the root `app.R`.
- "Collide" (untracked on VPS, tracked upstream): `dag_export.R`,
  `medrt_rxnav.R`, `telemetry.R`.
- (`umls_client.R` was deleted upstream as dead code; a stale VPS still carrying
  it is why that path shows as modified.)

**Audit trail / records** (the work is not VPS-only)
- Multi-model review-fix output: `~/projects/pico-dag/reviews/`
  (`round-1..3`, `round-5-convergence.md`, `SUMMARY.md`, `review_prompt.md`) and
  `~/projects/pico-dag/PLAN.md`.
- Decision record: `~/projects/globalpatientsafety/DECISION_LOG.md`
  (entries 2026-05-16).

**These snapshot documents** — all in `~/projects/pico-dag/snapshots/`
- `2026-05-30-vps-code-divergence.md` (primary)
- `2026-05-30-vps-divergence-claude-assessment.md` (this note)
- `2026-05-30-vps-divergence-globalpatientsafety-agent-note.md` (the correcting note)

## Secrets

Per Harlan: `.Renviron` is **stable and does not need updating**. Keep it
VPS-local; if a preserve branch is committed, keep `.Renviron` out of any push to
a public remote (private remote only, or gitignored).

## Not done

No files changed (local or VPS); no pull / reset / deploy / restart. This note is
the only addition, placed in `snapshots/` per the dated-snapshot convention
rather than editing the primary snapshot.
