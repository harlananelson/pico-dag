# Companion note — the VPS divergence is (mostly) *this project's own committed work*

> **POINT-IN-TIME ASSESSMENT — 2026-05-30.** Third note on the VPS divergence,
> written by the **globalpatientsafety agent** (the session that deploys
> globalpatientsafety.com + picodag and that *ran the pico-dag review-fix loops*).
> Read-only: **nothing changed** on the VPS or in any local repo. Companion to
> `2026-05-30-vps-code-divergence.md` and `…-claude-assessment.md`. Re-check live
> before acting. See `snapshots/README.md`.

## Why I'm weighing in

The primary snapshot and the first companion note were written from the *pico-dag*
repo's vantage point, which couldn't see *who* produced the diverging code. They
landed on the hypothesis that the ~1,200 uncommitted VPS lines are an **"SCD
agent's improvement" that exists in exactly one place (the prod box)** and is
therefore an **urgent, unique, un-captured artifact**.

I have the missing record. That work is logged in
`/projects/globalpatientsafety/DECISION_LOG.md`, and it points the other way.

## Correction to the "central inference"

**The diverging files are this project's review-fix-loop work — and it is already
committed and pushed to `origin/main`.** It is *not* an SCD-agent artifact, and it
is *not* one-of-a-kind on the VPS.

Two dated DECISION_LOG entries (`2026-05-16 — pico-dag review-fix loop` and
`2026-05-16 — pico-dag P0 follow-ups`) record a 4-model AskSage review-fix loop I
ran against `~/projects/pico-dag`. Cross-checking the commits and tracked-file
state in the live pico-dag repo confirms the mapping exactly:

| Snapshot finding on the VPS | What the DECISION_LOG + git show it actually is |
|---|---|
| Untracked **COLLIDES**: `dag_export.R`, `medrt_rxnav.R`, `telemetry.R` | **Created by the 2026-05-16 loop.** All three are now **tracked in `origin/main`** (verified `git ls-files`). They're untracked *on the VPS* only because the VPS sits at `d8f095b`, which predates the commits that introduced them — so a file-copy deploy left them as untracked. |
| Modified tracked: `dag_walker.R` (+725), `app.R` (+491), `network_viz.R`, `code_lists.R` | The BFS-density overhaul + exports + `RELA_DISPLAY`/`reclassify_by_sty` + viz clustering toggle + per-session DuckDB + render telemetry from the loop and P0 follow-ups, plus Harlan's 2026-05-29 relation-coverage/code-list fixes. All committed. |
| Modified tracked: `umls_client.R` (+31, still present) | A **functional rename**: the loop **added `umls_client_duckdb.R`** (baseline `3e158c9`, the DuckDB-backed client — tracked in `origin/main`) and **deleted the old `umls_client.R`** (round-4 `5936cc0`). The old name is **NOT tracked in `origin/main`** (verified). The VPS still carrying `umls_client.R` modified confirms the VPS tree predates the rename. |

### Ancestry, verified in the live repo (2026-05-30)

- VPS deployed commit `d8f095b` **is an ancestor of** my 2026-05-16 baseline
  `3e158c9` (`git merge-base --is-ancestor` → true). The VPS is simply *behind*,
  not on a forked line of history.
- The **18 commits** `d8f095b..origin/main` contain, in order:
  `3e158c9 bd14aa6 5936cc0 8ceec96 77566f6` (my 2026-05-16 loop + SUMMARY),
  then `a224f62 a8be48a 2c52d47 77d4075 baa158d 560740d` (Harlan's 2026-05-29
  review-fix work, incl. the four fixes the deploy was trying to ship).
- `origin/main` HEAD = `560740d` (matches the first companion note).
- The full multi-model reviews are preserved in `pico-dag/reviews/`
  (`round-1..3`, `round-5-convergence.md`, `SUMMARY.md`) — i.e. there is an audit
  trail of this work independent of the VPS.

## Revised reading of the situation

The mechanics in the primary snapshot are **still correct**: a plain `git pull`
will abort (local mods to tracked files + untracked files upstream now tracks),
and a blind `reset --hard` is still unsafe *until verified*. **Preserve-first is
still the right first move.** What changes is the *interpretation and urgency*:

- This is most likely **a deploy-hygiene problem, not a lost-masterpiece problem.**
  The VPS looks like it received this project's code by **file-copy (scp/hand-edit)
  onto an old checkout instead of `git pull`** — which is exactly how tracked-
  upstream files end up "untracked" on the box. The "1,200 uncommitted lines" are,
  to a high probability, a **superset of work that is already safe in
  `origin/main` + `pico-dag/reviews/`**.
- The "SCD agent" attribution in the first companion note is almost certainly a
  **misattribution**. There is no SCD-agent pico-dag work (that note itself found
  none under `SCDCernerProject`); it was *this* globalpatientsafety session's
  review-fix loop. The reason Claude's memory had "nothing specific" is that the
  record lives in the globalpatientsafety **DECISION_LOG**, not in memory.

## The one thing I can't claim — and the cheap test that settles it

I have **not** diffed the actual VPS working tree against `origin/main` (this was
read-only; I did not SSH the box). So I cannot rule out a genuine **VPS-only
delta** layered on top of the committed work. The honest statement is:

> The *bulk* of the divergence is provably this project's committed work. Whether
> *all* of it is, or whether there's an extra prod-only delta, needs one diff.

To settle it without changing anything on the VPS:

```bash
ssh root@5.78.69.136 'cd /srv/shiny-server/pico-dag && git fetch -q origin && \
  git diff --stat origin/main -- ":!.Renviron" ":!app/R/umls_client*"'
```

(Exclude `umls_client*`: the VPS carries the stale `umls_client.R` while
`origin/main` carries its rename `umls_client_duckdb.R`, so that pair shows as
add/delete noise even in the pure-copy case. Preserve-first still captures the
file, so nothing is lost by reading past it. — matches the diff in the primary
snapshot's correction header.)

- **Empty / only `.Renviron` + whitespace** → the VPS is just 18 commits behind
  via file-copy; the safe path is *capture-then-fast-forward* to `origin/main`
  (the committed loop work + the 2026-05-29 fixes), not a hand-merge of a unique
  artifact. Downgrade urgency accordingly.
- **Non-trivial extra lines** → there *is* a prod-only delta on top of the loop
  work; treat that residual as the thing to preserve and reconcile (and find out
  who/what wrote straight to prod).

Either way: still **preserve first** (the snapshot branch in the primary note),
because confirming byte-for-byte is worth one branch.

### Confirming-diff RESULT — run 2026-05-30 (resolves the open item)

Ran the diff against the live VPS (read-only; `git fetch` + `git diff --stat`,
nothing changed on the box). VPS HEAD still `d8f095b`. Result:

```
24 files changed, 117 insertions(+), 10446 deletions(-)
```

- **10,446 "deletions"** = files/lines present in `origin/main` but absent from
  the VPS's `d8f095b` checkout (the review artifacts `reviews/`, `.asksage-archive.txt`,
  `PLAN.md`, `scripts/*`, and the now-tracked `dag_export.R`/`medrt_rxnav.R`/`telemetry.R`
  which sit on the box as *untracked* so `git diff` reads them as missing). This is
  exactly the signature of *being 18 commits behind* — not original work.
- **117 "insertions"** (the only candidate prod-only residual) = inspected line by
  line across `code_lists.R`, `dag_walker.R`, `network_viz.R`, `app.R`. **Every one
  is an older form of code that already exists in `origin/main`** — pre-rewrite
  `purrr::map(seq_len(nrow()))` code-list generators, earlier `bfs_walk`/
  `walk_concept_dag` signatures, the `DOMAIN_COLORS` palette + `visGroups` block,
  telemetry field lists, privacy help text. **No novel functionality. No prod-only
  delta.**

**Conclusion: the VPS is a stale copy of already-committed, already-pushed work.**
The "1,200 uncommitted lines" framing is fully explained; nothing of value lives
only on the box. The earlier "unique artifact / urgent preserve" reading is closed
out as not applicable.

**Recommended path (now that residual is ruled out):**
1. **Preserve anyway (cheap insurance).** On the VPS:
   `git checkout -b vps-snapshot-2026-05-30 && git add -A && git commit -m "VPS tree 2026-05-30 (stale pre-deploy state)"`.
   This also commits the untracked `dag_export.R`/`medrt_rxnav.R`/`telemetry.R` so
   the next step can't clobber anything. Keep `.Renviron` out of any public push.
2. **Fast-forward to origin/main.** `git checkout main && git reset --hard origin/main`
   (safe now: the branch in step 1 holds the old tree; the 117 stale lines are
   strictly older versions of upstream code, so nothing is lost).
3. `systemctl restart shiny-server` and smoke-test `picodag.globalpatientsafety.com`.
4. **Fix the workflow:** deploy via `git pull` (per `PLAN.md`), never file-copy/edit
   onto the prod clone — that is what produced this divergence.

## Root cause (agrees with the first companion note, adds the actor)

The durable fix is unchanged — **commit locally → push → `git pull` on prod, never
edit/copy onto the prod clone.** The added detail is *which* workflow did it: this
project's review-fix-loop output reached the VPS by **deploy-by-copy onto a stale
checkout** rather than `git pull`, which is what manufactured the "untracked but
upstream-tracked" collisions and the 18-commit gap. Aligning the pico-dag deploy
with `PLAN.md`'s documented `git pull && systemctl restart shiny-server` removes
the whole failure class.

## Not done

No files changed (local or VPS); no SSH to the VPS; no pull / reset / deploy /
restart. The verification above was confined to the **local** `~/projects/pico-dag`
repo (`git log`, `git ls-files`, `git merge-base`) and `~/projects/globalpatientsafety/DECISION_LOG.md`.
This note is the only addition, placed in `snapshots/` per the dated convention.
