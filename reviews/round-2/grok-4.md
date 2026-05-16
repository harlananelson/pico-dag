

**Critical Issues (P1)**

**Unresolved CUI labels**  
*Severity:* High (directly matches user-reported bug; every visible node label is affected).  
*Files/Functions:* `app/R/umls_client_duckdb.R:148` (the `mrrel_bidir` query), `app/R/umls_client_duckdb.R:170-180` (hierarchy join), `app/R/network_viz.R:72` and `app/R/network_viz.R:92` (`make_category_rows` and root node), `app/R/dag_export.R:68` (`.dag_to_nodes_edges`).  
*Root cause:*  
```r
coalesce(cp.preferred_name, r.cui2) AS related_name
```
When `concept_preferred` has no row (build filters in `scripts/build_umls_db.R:170-190` are strict: `ts='P' AND tty='PT'` etc.), the CUI string is emitted. `clean_node_label()` only does regex stripping and `str_trunc`; it never resolves a bare CUI. Same fallback appears in MED-RT path and MRHIER name_lookup.  
*Recommended fix:* Add a `umls_preferred_name()` helper in `umls_client_duckdb.R` that always returns a human-readable string (preferred → any ENG PT → CUI as last resort). Patch (18 lines):

```r
# app/R/umls_client_duckdb.R (add after umls_db_connect)
umls_preferred_name <- function(cuis) {
  con <- umls_db_connect()
  if (is.null(con)) return(cuis)  # REST fallback path
  params <- as.list(unique(cuis))
  ph <- paste(rep("?", length(params)), collapse = ",")
  res <- DBI::dbGetQuery(con, sprintf(
    "SELECT cui, preferred_name FROM concept_preferred WHERE cui IN (%s)", ph
  ), params = params)
  lookup <- setNames(res$preferred_name, res$cui)
  dplyr::coalesce(lookup[cuis], cuis)
}

# Then replace the coalesce lines with:
# related_name = umls_preferred_name(r.cui2)
```

**Awkward UMLS jargon for edge labels**  
*Severity:* High (user-facing visualization and CSV export).  
*Files/Functions:* `app/R/network_viz.R:102` (`label = data$rela`), `app/R/dag_export.R:88` (GraphML/CSV uses raw `rela`), `app/R/dag_walker.R:30-80` (RELA_CATEGORIES).  
*Root cause:* No display mapping; raw strings `"isa"`, `"inverse_isa"`, `"may_be_treated_by"` are shown. The existing `RELA_CATEGORIES` vector is only for routing, not human labels.  
*Recommended fix:* Single lookup table (add to `network_viz.R` or a new `R/rela_display.R`). Apply to both `visNetwork` edges and all export functions. Patch for viz (12 lines):

```r
# app/R/network_viz.R (after DOMAIN_COLORS)
RELA_DISPLAY <- c(
  "isa" = "is a kind of", "inverse_isa" = "has subtype",
  "may_be_treated_by" = "may be treated by", "may_treat" = "may treat",
  "has_finding_site" = "found in", "clinically_associated_with" = "clinically associated with",
  .default = "related to"
)
# Then in edges:
label = RELA_DISPLAY[data$rela] %||% data$rela,
```

**Procedures-tab/graph desync (exact repro: C0741300 "Atrial Tumor")**  
*Severity:* High (concrete user report; data inconsistency).  
*Files/Functions:* `app/R/dag_walker.R:55` (`RELA_CATEGORIES["focus_of"] = "procedure"`), `app/R/dag_walker.R:220` (BFS depth>0 filter drops "other_rela"), `app/R/dag_walker.R:280` (`extract("procedure")`), `app/R/network_viz.R:60-110` (adds *all* category nodes).  
*Root cause:* Nodes like "Transplant of Heart" arrive via `inverse_isa` (routed to `subtypes`) or hierarchy expansion, never hit the `"procedure"` category. Tables filter strictly on `dag_result$procedures`; graph renders every category. No MRSTY cross-check.  
*Recommended fix:* After collecting relations, join `mrsty` and reclassify any related concept whose semantic type is in `c("Therapeutic or Preventive Procedure", "Laboratory Procedure", "Diagnostic Procedure")` into the correct tab list (even if rela was hierarchy). Cross-reference rendered nodes vs tab filters as suggested.

**Star-pattern clutter + missing clinical-type filter**  
*Severity:* High (core UX complaint).  
*Files/Functions:* `app/R/dag_walker.R:140` (`BFS_EXPAND_CATEGORIES`), `app/R/network_viz.R:115-130` (no semantic-type filter before `visNetwork`), `app/R/dag_export.R:50` (`.dag_to_nodes_edges`).  
*Root cause:* Walker queues anything in `BFS_EXPAND_CATEGORIES` and emits all categories; no `mrsty` guard. Peripheral non-clinical nodes create disconnected stars.  
*Recommended fix:* In `build_dag_network`, add MRSTY filter (query `mrsty` once for all node CUIs, keep only clinical types). Then compute clusters with `igraph::components()` on the edge set and call `visNetwork::visClusterByGroup`.

**CSV exports need grouping column**  
*Severity:* Medium-high (breaks downstream consumers).  
*Files/Functions:* `app/R/dag_export.R:40-90` (`.dag_to_nodes_edges` and `export_csv_zip`).  
*Root cause:* Nodes/edges tibbles only have `id/label/category` and `from/to/rela/category`. No `cluster_id` computed from connected components of the *rendered* edge set.  
*Recommended fix:* After building `ne <- .dag_to_nodes_edges(dag)`, run `igraph::graph_from_data_frame(ne$edges)` → `igraph::components()` → add `cluster_id` column to both tibbles before writing CSVs.

**Sparse lab/procedure recall**  
*Severity:* High (directly matches user report).  
*Files/Functions:* `app/R/dag_walker.R:310-380` (`walk_concept_dag_dense` densifier), `app/R/dag_walker.R:200` (depth>0 filter that drops "other_rela").  
*Root cause:* Densifier only walks first few parents/subtypes + lexical fallback. If a lab/procedure is only reachable via a non-mapped rela or deeper hierarchy, it is filtered out at depth > 0. No MRSTY-typed fallback query exists.  
*Recommended fix:* When `nrow(dag$procedures) == 0` or labs empty, run a targeted `umls_get_relations` filtered by semantic types from `mrsty` (`'Therapeutic or Preventive Procedure'`, `'Laboratory Procedure'`, etc.) and merge.

**Architectural Concerns (P0)**

1. **Rela-based vs semantic-type-based classification.** The entire routing (`RELA_CATEGORIES` → `categorize_relations` → `extract()`) lives in `dag_walker.R`. The concrete repro for procedures proves this is insufficient. Decision needed: do we keep rela-driven categories for the DAG structure but *post-process* every rendered node with its MRSTY type for the per-tab tables, or do we make MRSTY the primary classifier and treat rela only as edge label?

2. **Graph rendering vs tab data model divergence.** `build_dag_network` consumes the full `dag_result` list and renders *everything*; the DT tables each consume a single sliced tibble. This guarantees desync. A single source-of-truth tibble (with `category` *and* `semantic_type` columns) passed to both would be cleaner.

3. **DuckDB vs REST fallback surface area.** `umls_client_duckdb.R` is ~400 lines of duplicated fallback functions. Any new column (e.g., MRSTY for the filters above) must be added in two places. The MED-RT cache lives only in DuckDB path. Consider making the DuckDB path the only supported backend for production.

**Style/Lint (P2)**

- `app/R/dag_walker.R:250` and many `tryCatch(..., error = \(e) NULL)` silently swallow errors (same pattern in `resolve_source_url_to_cui`, `medrt_get_relations`, code_lists generators). Telemetry already has `safely_run`; these should log via it.
- `app/R/network_viz.R:40` — `clean_node_label` uses `stringr::str_trunc` but the rest is base R `gsub`/`sub`; inconsistent.
- `app/R/dag_export.R:140` — `.nodes_edges_to_dag` reconstructs a full `dag_result` shape but many fields (`genetic`, `interpretation`, `contraindications`) are never populated from imports.
- Missing column attestation in all exported CSVs (no `source`, `timestamp`, `build_version`).
- `app/app.R:380` — `safe()` wrapper is used for most renderers but not for the Mermaid/GraphML preview or pull-request QMD generation.

**What I'd do first**

- **Fix preferred-name resolution everywhere** (`umls_preferred_name` helper + update the three call sites) — highest user-visible impact, <30 lines, eliminates all bare-CUI bugs.
- **Add RELA_DISPLAY lookup table and apply to edge labels + CSV/GraphML exports** — one table, used in viz and export, directly addresses jargon complaint.
- **Add MRSTY post-classification step in `walk_concept_dag`** (join `mrsty` once, re-bucket procedures/labs regardless of original rela) — fixes the exact "Atrial Tumor" desync and sparse recall in one place.
- **Insert semantic-type filter + cluster computation in `build_dag_network`** before `visNetwork` call — removes star clutter and gives us the edge set needed for CSV `cluster_id`.
- **Add `cluster_id` column to `.dag_to_nodes_edges`** (using the same igraph components logic) and update `export_csv_zip` — low effort, high downstream value.

These five changes close every prioritized user-reported issue with minimal new architecture. The remaining P0 decisions (rela vs semantic primacy, DuckDB-only path) can be taken after the immediate bugs are gone.