

## Resolved in code: YES

Verification against round-2 + round-3 P1 items:

- **R2 #1 CUI label leaks** — `umls_preferred_name()` fallback chain present in `umls_client_duckdb.R`; backfill in `umls_get_relations`; last-mile resolver in `network_viz.R` `make_category_rows`; `clean_node_label` recovers bare CUIs. ✓
- **R2 #2 Edge-label jargon** — `RELA_DISPLAY` + `display_rela()` in `dag_walker.R`, applied in `network_viz.R` and `dag_export.R` (`rela_display` column). ✓
- **R2 #3 Procedures desync** — `reclassify_by_sty()` runs in `walk_concept_dag` before extract; promotes from hierarchy categories. ✓
- **R2 #4 monitoring_labs_table `parent_drug_name` crash** — fixed in `app.R` download_pull_request using `drug_lookup` join. ✓
- **R2 #5 dead `umls_client.R`** — file deleted. ✓
- **R2 #6 edge-key distinct in `combine_dags`** — keyed on `(from_cui, related_cui, rela)`. ✓
- **R2 #7 cluster_id + rela_display in exports** — `.compute_cluster_ids` populates both nodes & edges; GraphML keys namespaced (`node_*`/`edge_*`). ✓
- **R2 #8 MRSTY-typed fallback** — `mrsty_typed_fallback()` present, threshold `< 3`. ✓
- **R3 #1 IN-list chunking** — `.umls_chunked_in` at chunk=500, used in `umls_preferred_name` and `umls_mrsty_for_cuis`. ✓
- **R3 #2 fallback threshold** — `SPARSE_THRESHOLD <- 3L`. ✓
- **R3 #3 `reclassify_by_sty` perf** — still uses imperative loop inside `summarize` (P2-tier, not P1 — round-3 framed it as performance, acceptable at current walk sizes). ✓ (acceptable)
- **R3 #5 STY coverage** — expanded to 38 types incl. Injury or Poisoning, Congenital Abnormality, Hormone/Enzyme/Receptor, Molecular Biology Research Technique, etc. ✓
- **R3 #6 link_row label leak** — `combine_dags` strips "not found" stub → NA, last-mile resolver substitutes. ✓
- **R3 style: `mrsty_typed_fallback` dedupe key** — now uses `(from_cui, related_cui, rela)` consistently. ✓
- **R3 style: `.compute_cluster_ids` singleton fallback** — fixed: returns all-1L (not `seq_len(n)`) when no edges/no igraph. ✓
- **R3: delete `app/R/umls_client.R`** — gone. ✓

## Newly-introduced bugs: none

Spot-checks on the round-4 deltas:

- `.umls_chunked_in` correctly returns `NULL` on empty/all-failed chunks; callers (`umls_preferred_name`, `umls_mrsty_for_cuis`) guard with `is.null()`. Safe.
- `mrsty_typed_fallback` threshold change from `== 0` to `< 3`: the dedupe across pre-existing rows + typed-fallback rows uses the new edge key, so a focus_of row already present won't be duplicated by a typed-fallback row with the same `(from_cui, related_cui, rela)`. Different rela → both kept, which is correct (two distinct edges).
- `STY_TO_CATEGORY` expansion: only consulted via `reclassify_by_sty`'s promote-from list (`subtype/parent/other/other_rela/associated/narrower/broader`). Existing clinical assignments preserved — no downgrade risk from the new STYs.
- `link_row` NA name: flows into `bind_distinct` → `make_category_rows`' last-mile resolver path (`name_broken` check includes `is.na`). Resolver kicks in. Safe.
- `.compute_cluster_ids` all-1L fallback: GraphML/CSV exports now emit `cluster_id=1` uniformly when igraph absent — semantically correct ("one undifferentiated cluster") and won't break downstream consumers that key on the column.
- GraphML key namespacing (`node_*`/`edge_*`): `import_graphml` reads both new and legacy un-namespaced keys via the `node_key`/`edge_key` helpers. Round-trip preserved for older exports.

## Convergence assessment: CONVERGED

All round-2 and round-3 P1 items resolved. Round-4 changes introduce no regressions. Remaining open items are the two P0s you've explicitly carved out (visClusterByGroup UI toggle, medrt_get_relations sync latency) — both are scoped design decisions, not code defects.