# Snapshot — pico-dag production VPS has diverged from GitHub

> **POINT-IN-TIME ASSESSMENT — 2026-05-30.** This describes the VPS state at the
> moment it was inspected. It is **not** an enduring description; the box may
> have changed since. Re-check live before acting on it. See `snapshots/README.md`.

---

## ⚠️ CORRECTION (added 2026-05-30, after the companion notes)

**The *interpretation* in the body below is superseded — read this header with
it.** Independent git verification (run 2026-05-30) plus the globalpatientsafety
`DECISION_LOG` show that this snapshot's framing — "diverged histories" and a
"unique, un-captured ~1,200-line artifact that lives only on prod" — is **wrong**:

- The VPS commit `d8f095b` **is a clean ancestor of `origin/main`**
  (`git merge-base --is-ancestor d8f095b origin/main` → true). The VPS is **18
  commits *behind***, not on a forked line of history.
- The diverging code is **this project's own review-fix-loop work (2026-05-16)
  plus the 2026-05-29 fixes — already committed and pushed to `origin/main`** and
  preserved in `pico-dag/reviews/`. It is **not** an "SCD-agent artifact" and
  **not** one-of-a-kind on the box. (Verified: the 18 commits `d8f095b..origin/main`
  are exactly that work; `dag_export.R`/`medrt_rxnav.R`/`telemetry.R` are tracked
  upstream; `umls_client.R` was deleted upstream as dead code.)
- The "untracked-but-upstream-tracked" collisions and "local modifications" are
  the signature of a **deploy-by-copy onto a stale checkout**, not original work.

**What still stands:** the *mechanics* (a plain `git pull` will abort) and
**preserve-first** before any reset. **What changes:** urgency is **lower** —
this is a deploy-hygiene problem, not a lost masterpiece.

Companion notes (read alongside this):
- `2026-05-30-vps-divergence-globalpatientsafety-agent-note.md` — the correcting
  analysis, with the DECISION_LOG record.
- `2026-05-30-vps-divergence-claude-assessment.md`

### Open item — the one confirming test (recommended; to be run by the globalpatientsafety agent)

No one has yet diffed the **actual VPS working tree** against `origin/main`, so a
genuine prod-only residual cannot be 100% ruled out. This **read-only** test
settles it without changing anything on the box:

```bash
ssh root@5.78.69.136 'cd /srv/shiny-server/pico-dag && git fetch -q origin && \
  git diff --stat origin/main -- ":!.Renviron" ":!app/R/umls_client*"'
```

Interpret the result:
- **Empty** (after ignoring `.Renviron` and the `umls_client*` rename noise) →
  the VPS tree is just a **stale copy of already-committed work**. Safe path is
  **capture-then-fast-forward** to `origin/main` — not a hand-merge.
- **Non-trivial extra lines** → there **is** a prod-only delta layered on top.
  Preserve and reconcile that residual, and find what wrote straight to prod.

Why the `umls_client*` exclusion: the VPS still carries `umls_client.R` (deleted
upstream) while `origin/main` has `umls_client_duckdb.R`, so that file pair shows
as diff noise even in the pure-copy case — read past it.

**Regardless of the outcome: snapshot the VPS tree to a branch first** (e.g.
`git checkout -b vps-snapshot-2026-05-30 && git add -A && git commit -m "VPS tree
2026-05-30"`). It is cheap insurance that makes any later reset/fast-forward
non-destructive.

---

## TL;DR

The production VPS that hosts pico-dag has **~1,200 lines of uncommitted local
code edits that exist nowhere in git**, and its working tree has **untracked
files that collide with now-tracked upstream files**. As a result:

- A routine `git pull` deploy **cannot run** (it would abort), and
- Forcing it (`reset --hard` / `stash` / `checkout`) would **destroy the
  uncommitted production work**.

The VPS and GitHub `origin/main` have **diverged** independently. New fixes on
`origin/main` cannot simply be deployed on top of the VPS until this is
reconciled. **Nothing was changed on the VPS** — this was a read-only inspection.

## How this came up

While deploying four code-list/relation fixes that had been pushed to
`origin/main` (commits `2c52d47`, `77d4075`, `baa158d`, `560740d`), the
pre-deploy read-only check revealed the VPS was not a clean target.

## Deployment context

| Item | Value |
|------|-------|
| Host | Hetzner box `5.78.69.136` (nginx + Shiny Server) |
| URL | `https://picodag.globalpatientsafety.com` |
| App path | `/srv/shiny-server/pico-dag` (owner `shiny:shiny`) |
| Service | `systemctl restart shiny-server` |
| Documented deploy | `ssh root@… 'cd /srv/shiny-server/pico-dag && git pull && systemctl restart shiny-server'` (per `PLAN.md`) |
| UMLS DuckDB | `/srv/umls/umls.duckdb` — present on the VPS (built there) |
| MED-RT cache | `/srv/shiny-server/pico-dag/app/logs/medrt_cache.duckdb` (VPS; not poisoned — the sentinel issue was local-workstation only) |

## What the inspection found (read-only, 2026-05-30)

**Deployed commit:** `d8f095b` — *"Use shinyAppDir('app') in root app.R"*
**Distance from origin:** `git rev-list --count HEAD..origin/main` = **18 commits behind**

### Uncommitted local edits to tracked files (1,213 insertions / 246 deletions)

```
 app/R/code_lists.R  |  55 ++-
 app/R/dag_walker.R  | 725 +++++++++++++++++++++++++++++++++++++++--------
 app/R/network_viz.R | 157 +++++++-----
 app/R/umls_client.R |  31 ++-
 app/app.R           | 491 +++++++++++++++++++++++++++++++-----
 5 files changed, 1213 insertions(+), 246 deletions(-)
```

These overlap the very files changed on `origin/main`. The VPS edits are
substantially larger than the upstream fixes — i.e. the VPS carries its own,
more extensive, independent line of work (especially `dag_walker.R` +725 and
`app.R` +491).

### Untracked files on the VPS

| File | Status |
|------|--------|
| `.Renviron` | safe — not tracked upstream (likely env/secrets; leave in place) |
| `app/R/app.R` | safe — not tracked upstream |
| `app/R/dag_export.R` | **COLLIDES** — tracked in `origin/main` |
| `app/R/medrt_rxnav.R` | **COLLIDES** — tracked in `origin/main` |
| `app/R/telemetry.R` | **COLLIDES** — tracked in `origin/main` |

The three "COLLIDES" files exist as untracked local files on the VPS but are now
tracked upstream, so `git pull`/`merge` would refuse to overwrite them
("untracked working tree files would be overwritten").

## Why this is a problem

1. **`git pull` will abort.** Local modifications to tracked files + untracked
   files that upstream now tracks both block a clean fast-forward/merge.
2. **Force-deploying is destructive.** `git reset --hard`, `git stash` (then
   pop-conflict), or `git checkout -- .` would discard 1,200+ lines of work that
   exists **only** on the VPS.
3. **Histories have diverged.** `origin/main` and the VPS evolved separately on
   the same files. The upstream fixes can't be "layered on"; they must be
   reconciled with the VPS work.

## The real risk (independent of any deploy)

**~1,200 lines of code live only on the production box, uncommitted and
un-pushed.** A disk failure, a botched deploy, or an accidental reset loses it.
Capturing it should happen regardless of whether the new fixes ship.

## Recommended path (in order)

1. **Preserve first (non-destructive).** Snapshot the VPS working tree into git
   before anything else — e.g. on the VPS:
   ```bash
   cd /srv/shiny-server/pico-dag
   git config --global --add safe.directory /srv/shiny-server/pico-dag   # already set 2026-05-30
   git checkout -b vps-snapshot-2026-05-30
   git add -A && git commit -m "Snapshot VPS working tree 2026-05-30 (uncommitted prod edits)"
   git push origin vps-snapshot-2026-05-30
   ```
   (Confirm `.Renviron` is gitignored / scrub secrets before pushing, or commit
   it only to a private branch and never to a public remote.)
2. **Reconcile.** Diff `vps-snapshot-2026-05-30` against `origin/main`. Expect
   overlap in `dag_walker.R` (the VPS may already contain relation/treatment
   work similar to the upstream fixes). Decide per-file what wins or how to merge.
3. **Deploy the merged result**, then `systemctl restart shiny-server` and
   smoke-test `picodag.globalpatientsafety.com`.

## What was NOT done

- No files changed on the VPS.
- No deploy / pull / reset / restart executed.
- The only write to the VPS was `git config --global --add safe.directory …`
  (required just to read git status as root; harmless and reversible).

## Open questions for the owner

- Are the VPS local edits the current source of truth, or superseded by
  `origin/main`? (Determines merge direction.)
- Is `.Renviron` expected to stay VPS-only (secrets)?
- Why has the box drifted 18 commits + 1,200 uncommitted lines — is there a
  habit of editing directly on prod that the workflow should fix?
