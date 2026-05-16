

## Still Open (P1)

**1. `umls_preferred_name()` bulk lookup is unparameterized for large IN-lists.**
`app/R/umls_client_duckdb.R` `umls_preferred_name()` and `umls_mrsty_for_cuis()` build `IN (?,?,...)` with one placeholder per CUI. DuckDB has a parameter cap (~1000 by default via prepared statement limits) and string-building cost is O(n). `reclassify_by_sty()` in `dag_walker.R` passes `unique(rels$related_cui)` — for a dense walk this can be 200-500 CUIs per call, and it's called once per `walk_concept_dag` plus once per `combine_dags`-merged sub-walk in the densifier. **Fix:** chunk to 500 or use a temp table / `dbWriteTable` + join.

**2. `mrsty_typed_fallback()` only fills if category is _completely_ empty.**
`app/R/dag_walker.R` ~line 660: `if (!is.null(current) && nrow(current) > 0) next`. A seed that surfaces 1 procedure via `focus_of` skips the MRSTY fallback entirely, leaving a meaningful recall gap. **Fix:** lower threshold (e.g. `< 3`) or always run and dedupe.

**3. `reclassify_by_sty()` `dplyr::summarize` with imperative loop is O(n_cuis × n_categories) per group.**
The `for (cat in names(STY_TO_CATEGORY))` inside `summarize()` runs per-CUI in R; for a 400-CUI walk this is the dominant cost after the DB query. **Fix:** unnest `STY_TO_CATEGORY` to a `tibble(sty, category, priority)`, single join + `slice_min(priority)`.

## Newly Surfaced (P0)

**4. Star-clutter architecturally still open — `cluster_id` exists in exports but not in the viz.**
You correctly flagged this. `network_viz.R` `build_dag_network()` does NOT compute components or call `visClusterByGroup`. The infrastructure (igraph in `.compute_cluster_ids`) is already paid for in `dag_export.R`. **Recommendation:** extract `.compute_cluster_ids` to a shared helper and call it in `build_dag_network` before the `visNetwork()` constructor, then add `visClusterByGroup(groups = unique(paste0("cluster_", nodes$cluster_id)))` behind a UI toggle (`checkboxInput("cluster_stars", "Group disconnected components", FALSE)`). Default OFF — clustering changes the spatial intuition and some users will hate it.

**5. `STY_TO_CATEGORY` coverage gaps.**
Missing semantic types I'd expect to see surfaced:
- **procedure:** `"Molecular Biology Research Technique"` (genomic assays), `"Research Activity"` (rare but appears for clinical trials)
- **diagnostic_lab:** `"Clinical Attribute"` (e.g. vital signs that LOINC also covers), `"Quantitative Concept"` is too broad to add safely
- **treatment:** `"Hormone"`, `"Enzyme"`, `"Receptor"` (used for biologics), `"Steroid"`, `"Indicator, Reagent, or Diagnostic Aid"` (contrast agents — borderline, could argue for procedure)
- **comorbidity:** `"Congenital Abnormality"`, `"Injury or Poisoning"`, `"Anatomical Abnormality"` (covers many ICD-10 codes), `"Experimental Model of Disease"` (rare in clinical data)
- **anatomy:** `"Embryonic Structure"`, `"Fully Formed Anatomical Structure"`, `"Gene or Genome"` if you want genetic-anatomy

The Injury/Poisoning and Congenital Abnormality gaps will bite for trauma and pediatric seeds specifically.

**6. New label-leakage path: `extend_concept_dag` synthetic root link.**
`dag_walker.R` `combine_dags()` with `link_rela != NULL` constructs `link_row` with `related_name = dag_b$concept$name`. If `umls_get_concept` returned the `"(C123 — not found)"` stub (network failure or genuinely missing CUI), that stub string lands in the graph as a node label and `clean_node_label()`'s `^C\d+$` regex won't match it. Low-frequency but real for transient DuckDB hiccups. **Fix:** in `umls_get_concept` set `name <- NA_character_` on not-found and let `make_category_rows`' last-mile resolver handle it.

**7. `medrt_get_relations` still called inside `umls_get_relations` synchronously per node.**
Not new — flagged in round 2 Claude — but the round-3 changes added more DB roundtrips per node (MRHIER join + concept_preferred backfill) without addressing this. First-walk latency on an unseen seed remains 10-30s. Not a regression but worth re-flagging since it now compounds with the MRSTY query cost in #1.

## Untouched files spot-check

**`app/R/medrt_rxnav.R`:**
- `.rxcuis_to_umls_cuis` builds an IN-list with no chunking (same risk as #1; RxNav can return hundreds of RxCUIs per class).
- `medrt_cache_lookup`/`store` opens+closes a DuckDB connection on every call. For a 30-node BFS that's 60 connection cycles. Switch to a long-lived read connection with separate short-lived writes, mirroring the UMLS pattern.
- `.MEDRT_CACHE_PATH` resolution at source-load time uses `getwd()` if `PICO_LOG_DIR` unset — same wd-dependency footgun as `telemetry.R`.

**`app/R/telemetry.R`:**
- Looks clean. One nit: `.daily_salt()` reads the salt file on every `log_event` call with no in-memory cache. Cheap (it's a 1-line file) but unnecessary I/O on hot paths.
- `safely_run` doesn't capture the traceback (only the message + immediate call). For diagnosing the `dag_walker.R` chain failures you'll want `rlang::trace_back()` or at least `sys.calls()` in the error handler.

**`app/R/umls_client.R`:**
- Still present as dead code. `app/app.R` only sources `umls_client_duckdb.R`. Round-2 Claude flagged this for deletion; still not done. Risk of shadowing if anyone adds a test harness or runs scripts that source it. **Delete it** — the `_rest` shims in `umls_client_duckdb.R` cover its functionality.

## Style/Lint (P2)

- `dag_walker.R` `mrsty_typed_fallback()` line ~670: `base[[field]]` re-binds with `dplyr::bind_rows` but the dedupe key is `related_cui` alone — inconsistent with the round-3 `bind_distinct` fix that keys on `(from_cui, related_cui, rela)`. Use the same key.
- `dag_export.R` `.dag_to_nodes_edges` `cluster_id` defaults to `seq_len(n)` when igraph absent — that's "every node is its own cluster" which is technically wrong (singletons should be 0 or NA, connected pairs should share). Minor.
- `network_viz.R` `clean_node_label` does both regex stripping AND CUI recovery. Split into `recover_label()` + `truncate_label()` so the recovery step is testable in isolation.

## Convergence assessment: NEEDS-ROUND-4

Three reasons: (a) the IN-list parameterization (#1) is a latent production crash waiting for a sufficiently dense seed; (b) the star-clutter architectural fix (#4) is explicitly punted but you have all the infrastructure to land it in ~15 lines; (c) `umls_client.R` still hasn't been deleted across two rounds. One more focused round closes all three.