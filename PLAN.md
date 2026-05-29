# pico-dag plan — resumable across sessions

State of work spawned from the multi-model review-fix loop on 2026-05-16
and the user-driven P0 follow-ups. Mark items DONE / IN-PROGRESS / TODO
as you go. Commit hashes point to where a step landed.

---

## Status snapshot

Current branch: `main` (8 commits ahead of `origin/main` — **not pushed yet**).

| Last commit | Subject |
|---|---|
| `a224f62` | Prefetch-seed-only MED-RT |
| `77566f6` | P0 follow-ups: cluster toggle, Incognito default, per-session DuckDB, render telemetry |
| `8ceec96` | SUMMARY.md |
| `5936cc0` | round 4: chunking, threshold, STY coverage, dead-code |
| `bd14aa6` | round 2: P1 user-flagged + 4-model consensus |
| `3e158c9` | baseline WIP seal |

---

## Phase 1: review-fix loop — DONE

All five P1s the user originally flagged + cross-model consensus catches.
See `reviews/SUMMARY.md` for the round-by-round breakdown.

- [x] Bare CUI labels → `umls_preferred_name()` resolver (commit `bd14aa6`)
- [x] `isa`/`inverse_isa` jargon → `RELA_DISPLAY` lookup
- [x] Atrial Tumor procedures-tab desync → `reclassify_by_sty()` MRSTY pass
- [x] Star-pattern grouping factor → `cluster_id` in CSVs
- [x] Sparse lab/procedure recall → `mrsty_typed_fallback()` tier 4
- [x] Consensus catches: combine_dags edge-key, parent_drug_name crash,
      diagnostic_lab miscoloring, GraphML duplicate keys
- [x] Round-3 residuals: IN-list chunking, threshold, STY coverage,
      link_row leak, dead `umls_client.R` deletion (commit `5936cc0`)

---

## Phase 2: P0 follow-ups (user picked these from `reviews/SUMMARY.md`)

User instruction was: "do 1, I need to understand 2 better, wait for 3,
do 4, somehow fix the problem described in 5, fix 6."

- [x] **#1** visClusterByGroup with UI toggle (default OFF) — commit `77566f6`
- [x] **#2** medrt latency — explained, then resolved via prefetch-seed-only — commit `a224f62`
- [ ] **#3** MRSTY-first vs rela-first classifier — **HELD by user.** No work to do until they revisit. Current rela-first + MRSTY-corrector is working.
- [x] **#4** Incognito default ON — commit `77566f6`
- [x] **#5** Per-session DuckDB via `getDefaultReactiveDomain()` — commit `77566f6`
- [x] **#6** Render-graph telemetry (n_rendered_nodes, cluster_count, etc.) — commit `77566f6`

---

## Phase 3: deploy + verify — TODO

The eight unpushed commits are local-only. Production at
`https://picodag.globalpatientsafety.com` is still running the pre-loop code.

Steps:

- [ ] Decide whether to push: `git push origin main` from `/home/harlan/projects/pico-dag/`
- [ ] On VPS, pull and restart shiny-server:
  ```
  ssh root@5.78.69.136 \
    'cd /srv/shiny-server/pico-dag && git pull && \
     systemctl restart shiny-server'
  ```
- [ ] Smoke-test the deployment:
  - Search "Atrial Tumor" → confirm Procedures tab now populated
  - Look at the DAG → confirm edges read "is a kind of" / "has subtype" not `isa` / `inverse_isa`
  - Toggle "Group disconnected stars" → confirm off-root clusters collapse to diamonds
  - Confirm Incognito is checked by default
  - Search a never-before-seen CUI → confirm progress message names RxNav, walk completes in ≤15s
  - Download CSV bundle → confirm `cluster_id` and `rela_display` columns present
- [ ] Skim a few `dag_build` events in `/srv/shiny-server/pico-dag/app/logs/events/` to confirm the new telemetry fields populate

---

## Phase 4: known residual items — TODO (priority order)

### High value, small effort

- [ ] **medrt_cache concurrency race.** `medrt_cache_store()` opens DuckDB
  `read_only = FALSE` which takes an exclusive lock. If two sessions
  encounter the same uncached CUI simultaneously, one write fails silently.
  Fix: wrap the connect+write in a retry-with-backoff (3 attempts,
  50ms/200ms/1s). 10-line change in `app/R/medrt_rxnav.R::medrt_cache_store`.

- [ ] **Cache path wd-dependency.** `.MEDRT_CACHE_PATH` resolves
  `file.path(getwd(), "logs", ...)` at source-load time, so smoke tests
  from the project root miss the cache at `app/logs/medrt_cache.duckdb`.
  Same footgun in `telemetry.R`. Fix: resolve relative to the file that
  defines them, or require `PICO_LOG_DIR` to be set explicitly.

### Medium value, medium effort

- [ ] **`reclassify_by_sty` perf** (round-3 P2). Currently a per-CUI
  imperative loop inside `dplyr::summarize`. For dense walks (~200-500
  CUIs after merge) this is the dominant R cost. Refactor: unnest
  `STY_TO_CATEGORY` to a `tibble(sty, category, priority)`, single
  join + `slice_min(priority)`. Probably 15-line change.

- [ ] **`.cui_to_mesh_codes` and `.rxcuis_to_umls_cuis` redundancy.**
  Inside `fetch_medrt_relations`, these mrconso queries run every time
  even though the answer for a given CUI never changes. Add a small
  in-memory lookup cache keyed on CUI.

### Speculative

- [ ] **Async RxNav (option 3 we discussed).** Only worth doing if the
  prefetch-seed-only result still feels slow. Wait 1-2 weeks of usage
  with the new telemetry, then decide based on real `dag_build` event
  data of how long walks actually take and which CUIs are MED-RT cold.

---

## Memory / hand-off notes

### How to resume

1. Read this file (`PLAN.md`).
2. `git log --oneline -10` to confirm where the last commit landed.
3. `git status` to confirm clean working tree.
4. Pick the next `[ ]` item.
5. When done, check the box and add the commit hash inline.

### Where things live

- This plan: `/home/harlan/projects/pico-dag/PLAN.md`
- Review history: `/home/harlan/projects/pico-dag/reviews/` (round-2, round-3, round-5-convergence.md, SUMMARY.md)
- Decision log: `/home/harlan/projects/globalpatientsafety/DECISION_LOG.md`
- The MED-RT cache: `/srv/shiny-server/pico-dag/app/logs/medrt_cache.duckdb` (VPS) + `/home/harlan/projects/pico-dag/app/logs/medrt_cache.duckdb` (local, seeded from VPS 2026-05-16: 193 CUIs, 2040 rows)

### Files the loop touched

- `app/R/umls_client_duckdb.R` — name resolver, MRSTY helpers, chunking, per-session connection
- `app/R/dag_walker.R` — RELA_DISPLAY, STY_TO_CATEGORY, reclassify_by_sty, mrsty_typed_fallback, BFS medrt gating, combine_dags edge-key, link_row name fix
- `app/R/network_viz.R` — display_rela, last-mile name resolution, diagnostic_lab color, cluster toggle, summarize_dag_render, `.compute_cluster_ids`
- `app/R/dag_export.R` — cluster_id, rela_display, namespaced GraphML keys
- `app/R/medrt_rxnav.R` — cache_only mode
- `app/app.R` — Incognito default, cluster checkbox, render-stats telemetry, parent_drug_name fix
- `app/R/umls_client.R` — deleted (dead code)

### Things that are NOT done and NOT in this plan

These were surfaced in the review but are explicitly held / deferred:

- MRSTY-first architectural rewrite (#3 in original P0 list — user said "wait")
- Async MED-RT via future/mirai (waiting on prefetch-seed-only telemetry)
- `pool::dbPool` for DuckDB (the per-session approach made this unnecessary at current scale)
- Daily roll-up of `events/*.json` to NDJSON (will become relevant only when event count gets unwieldy)
- Posit GitHub attribution / cross-checks for borrowed patterns
