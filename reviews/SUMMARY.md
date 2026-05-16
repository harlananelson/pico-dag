# Review-Fix Loop — pico-dag

**Started:** 2026-05-16 11:05 UTC
**Mode:** production (real edits, real commits)
**Starting commit:** `9fe0953c` (HEAD)
**Final commit:** `5936cc0`
**Rounds run:** 2 full + 1 single-model spot + 1 convergence = converged in 4 logical passes
**Models used:** `google-claude-47-opus`, `gpt-5`, `google-gemini-2.5-pro`, `grok-4-20-reasoning`
**Target:** `/home/harlan/projects/pico-dag` (full Shiny app, ~196 KB archive, 6 R files + scripts)

## Commits

| SHA | Round | Scope |
|---|---|---|
| `3e158c9` | baseline | seal prior WIP (BFS density, exports, telemetry, MED-RT cache, DuckDB client) |
| `bd14aa6` | round 2 | P1 user-flagged + 4-model consensus (label leakage, isa/inverse_isa, MRSTY reclassifier, MRSTY-typed densifier, cluster_id exports, combine_dags edge key, parent_drug_name crash, diagnostic_lab miscoloring, GraphML duplicate keys) |
| `5936cc0` | round 4 | round-3 follow-ups: IN-list chunking, fallback threshold lowered, STY coverage expanded, link_row label leak, cluster_id fallback semantics, dead `umls_client.R` deleted |

Round 1 was a prior dry-run validation pass (`reviews/round-1/gemini-2.5-flash.md` — single-file, ~$0.05). Round 2 was the first real multi-model production pass. Round 3 was a single-model claude-47-opus spot-check that flagged residuals → round 4 closed them. Round 5 single-model convergence verifier reported `CONVERGED`.

## User-reported issues, all resolved

1. **Bare CUI labels (e.g. `C0018821`)** — `umls_preferred_name()` bulk resolver with concept_preferred → mrconso English fallback chain; SQL no longer emits CUI as name; last-mile resolver in `make_category_rows`; `clean_node_label` recovers any leaked bare CUI as `(unnamed CXXX)`.
2. **`isa` / `inverse_isa` jargon** — `RELA_DISPLAY` lookup (50+ relas), `display_rela()`. Applied to edges + tooltips + CSV/GraphML/Mermaid exports.
3. **Atrial Tumor procedures-tab/graph desync (C0741300)** — `reclassify_by_sty()` after BFS promotes hierarchy-surfaced concepts to their MRSTY-derived clinical category. Procedure CUIs that arrived via `inverse_isa` now populate `dag$procedures`.
4. **Star-pattern clutter — grouping factor** — `cluster_id` computed via `igraph::components()` on the rendered edge set. Added to `nodes.csv` and `edges.csv`. (Viz-side `visClusterByGroup` deliberately surfaced as P0, not auto-applied — see below.)
5. **CSV exports need grouping column** — `cluster_id` (int) + `rela_display` (human-readable) added to both `nodes.csv` and `edges.csv`. Mermaid uses `rela_display`; GraphML key ids namespaced (`node_*`/`edge_*`).
6. **Sparse lab/procedure recall** — new tier-4 densifier `mrsty_typed_fallback()` joins `mrrel_bidir` with `mrsty` for direct neighbors of the seed when buckets are below `SPARSE_THRESHOLD=3`. Covers 38 semantic types across 5 categories.
7. **General improvements** — see round-2 commit body.

## Other consensus fixes landed

- **`combine_dags::bind_distinct` edge-key bug** (claude-47-opus) — was keying solely on `related_cui`, silently dropping click-to-extend edges into existing nodes. Now `(from_cui, related_cui, rela)`. Major contributor to disconnected stars.
- **`parent_drug_name` crash in `download_pull_request`** (claude + gpt-5) — column never existed; replaced with from_cui ↔ relations join.
- **`diagnostic_labs` mis-rendered as monitoring_lab group, no distinct color** (gpt-5) — added `diagnostic_lab` color, routed correctly.
- **GraphML duplicate `id="category"`** (gpt-5) — namespaced. Import path reads both new and legacy keys.
- **`visGroups` hand-list** (claude P2) — driven from DOMAIN_COLORS via `purrr::reduce`.
- **IN-list parameterization** (claude round-3) — `.umls_chunked_in` at chunk=500.
- **MRSTY coverage gaps** (claude round-3) — added Injury or Poisoning, Congenital Abnormality, Hormone, Enzyme, Receptor, Steroid, Clinical Attribute, Molecular Biology Research Technique, etc. (13 new types).
- **`extend_concept_dag` link_row label leak** (claude round-3) — `(not found)` stubs no longer reach the visible node label.
- **Dead `app/R/umls_client.R`** (claude rounds 2 + 3) — finally deleted.

## P0 still open — user decision needed

These are deliberately not auto-applied because they're design decisions or scoped redesigns, not code defects.

### 1. Star-clutter in the viz itself (cluster_id is in exports but not used by `build_dag_network`)

The infrastructure exists. `.compute_cluster_ids` could be lifted to a shared helper and used inside `network_viz.R::build_dag_network` to drive a `visNetwork::visClusterByGroup()` call. Recommendation: ~15-line change, gated behind a `checkboxInput("cluster_stars", "Group disconnected components", FALSE)` UI toggle. Default OFF so users who like the current spatial intuition aren't surprised.

**Question for the user:** ship it default-off, or hold for a separate UX pass?

### 2. `medrt_get_relations` synchronous fetch inside `umls_get_relations`

Every per-node DB read inside BFS triggers up to 4 RxNav HTTP calls on a cache miss. First walk on an unseen seed is 10-30 seconds. Subsequent walks are fast (cache populated). Three options:

- **Prefetch the seed + top-N neighbors before BFS starts** — narrow but predictable.
- **Async (`future`, `mirai`) and merge results in a second pass** — better latency, more moving parts.
- **At minimum, surface "Fetching drug relations from RxNav (one-time, ~30s)" in the progress callback** — no code restructuring.

The third option could ship now without architectural change.

### 3. MRSTY-first vs rela-first classification (architectural)

Currently rela-first with MRSTY as a post-walk corrector. The round-2 reviews recommended flipping this: MRSTY as the primary classifier, rela as edge-label only. That's a bigger rewrite — wait until the post-walk corrector proves insufficient.

### 4. PHI/search-term logging default

`Incognito` is opt-in. For a clinical environment with PHI-adjacent text in search boxes (rare but possible), flip the default. Decision for the user.

### 5. Per-session DuckDB connection

`.umls_con` is a single global. DuckDB R driver isn't documented as thread-safe across concurrent queries on one connection. Bites at scale; harmless at low concurrency.

### 6. Telemetry never records the rendered graph

`dag_build` logs walker counts but not `n_rendered_nodes`, `n_rendered_edges`, `n_clipped_by_cap`, `cluster_count`. Without these we can't reproduce a user's "the graph looked weird" report.

## Diff summary

| File | +/- (across rounds 2 + 4) |
|---|---|
| `app/R/umls_client_duckdb.R` | new bulk resolver (`umls_preferred_name`), MRSTY helpers, IN-list chunking, SQL fallback |
| `app/R/dag_walker.R` | RELA_DISPLAY, STY_TO_CATEGORY, reclassify_by_sty, mrsty_typed_fallback, combine_dags edge-key, link_row name fix |
| `app/R/network_viz.R` | last-mile name resolution, display_rela, diagnostic_lab color, visGroups reduce |
| `app/R/dag_export.R` | cluster_id, rela_display, namespaced GraphML keys, cluster_id fallback |
| `app/app.R` | parent_drug_name fix in `download_pull_request` |
| `app/R/umls_client.R` | deleted (dead code) |

## Reviews preserved

```
reviews/
  review_prompt.md
  round-1/  (prior single-model dry-run validation)
  round-2/  (4-model production: claude-47-opus, gpt-5, gemini-2.5-pro, grok-4)
  round-3/  (single-model claude residual scan → NEEDS-ROUND-4)
  round-5-convergence.md  (single-model claude verifier → CONVERGED)
```
