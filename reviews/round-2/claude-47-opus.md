

# pico-dag review

## Critical Issues (P1)

### 1. CUI leaks into visible labels via missing/empty `related_name`
**Severity:** High. **Files:** `app/R/network_viz.R` (`build_dag_network` / `make_category_rows`), `app/R/umls_client_duckdb.R` (`umls_get_relations`), `app/R/dag_walker.R` (`extend_concept_dag`, `combine_dags`).

**Root cause:** Multiple paths set `related_name` to a value that can be `NA`, `""`, or a CUI string:

- `umls_get_relations` (DuckDB layer 1):
  ```r
  coalesce(cp.preferred_name, r.cui2) AS related_name
  ```
  When the related concept has no `concept_preferred` row (CHV, OMIM, NCI-only atoms; or any CUI inserted in `mrconso` whose strict `ts='P' AND tty='PT' AND lat='ENG'` rule failed), the CUI string is written into `related_name` and ends up on the node. This is the dominant source of the bug.

- `hier` block: `related_name = unname(name_lookup[hier$cui2])` then `filter(!is.na(related_name))` — so `NA` rows are dropped, but the bidir path above is not filtered, so the CUI version leaks through.

- `medrt_compat` uses `drugs$name` straight from RxNav — fine for drugs, but never reconciled against `concept_preferred`.

- `clean_node_label("")` returns `""`, and visNetwork falls back to the node id (the CUI) when the label is empty.

- `extend_concept_dag` resets `from_cui` but never rewrites `related_name` for the link row, and in the click case the clicked node id may be a source-vocab id never present in `concept_preferred`.

**Fix:** One central resolver + a hard guarantee in the viz builder. Add to `umls_client_duckdb.R`:

```r
#' Resolve a vector of CUIs to preferred names, with UMLS fallback chain.
#' Never returns NA or the CUI string — always a human-readable label.
umls_resolve_names <- function(cuis) {
  cuis <- as.character(cuis); cuis[is.na(cuis)] <- ""
  uniq <- unique(cuis[nzchar(cuis)])
  if (length(uniq) == 0) return(setNames(character(0), character(0)))
  con <- umls_db_connect()
  out <- setNames(rep(NA_character_, length(uniq)), uniq)
  if (!is.null(con)) {
    ph <- paste(rep("?", length(uniq)), collapse = ",")
    r <- DBI::dbGetQuery(con, sprintf(
      "SELECT cui, preferred_name FROM concept_preferred WHERE cui IN (%s)", ph),
      params = as.list(uniq))
    out[r$cui] <- r$preferred_name
    miss <- uniq[is.na(out[uniq])]
    if (length(miss) > 0) {
      ph2 <- paste(rep("?", length(miss)), collapse = ",")
      # Fallback: shortest English string with non-suppressed status
      r2 <- DBI::dbGetQuery(con, sprintf(
        "SELECT cui, str FROM (
           SELECT cui, str,
             row_number() OVER (PARTITION BY cui ORDER BY length(str)) rn
           FROM mrconso
           WHERE cui IN (%s) AND lat = 'ENG' AND suppress NOT IN ('O','E')
         ) WHERE rn = 1", ph2), params = as.list(miss))
      out[r2$cui] <- r2$str
    }
  }
  # Final fallback: the CUI itself with a marker so reviewers spot it
  out[is.na(out)] <- paste0("(", names(out)[is.na(out)], ")")
  out[cuis]
}
```

Then in `network_viz.R::make_category_rows`, replace `clean_node_label(data$related_name)` with a resolver call when the name is empty/equals the CUI:

```r
needs_fix <- !nzchar(data$related_name) | data$related_name == data$related_cui
if (any(needs_fix)) {
  resolved <- umls_resolve_names(data$related_cui[needs_fix])
  data$related_name[needs_fix] <- resolved
}
```

Also: fix the DuckDB query to stop emitting CUIs as names — change `COALESCE(cp.preferred_name, r.cui2)` to `COALESCE(cp.preferred_name, NULL)` and do the resolver fallback in R, where you have the full chain (mrconso shortest, RxNav cached name, etc.).

---

### 2. Edge labels show raw UMLS relas (`isa`, `inverse_isa`, `may_be_treated_by`)
**Severity:** High. **Files:** `app/R/network_viz.R` (edge `label = data$rela`), `app/R/dag_export.R` (edges.csv exports `rela` as-is), Mermaid/GraphML/JSON-LD exports.

**Root cause:** No display-label mapping exists. `make_category_rows` does `label = data$rela`.

**Fix:** One lookup table, applied in viz + exports. Add to `dag_walker.R` (next to `RELA_CATEGORIES`):

```r
RELA_DISPLAY <- c(
  "isa"                          = "is a kind of",
  "inverse_isa"                  = "has subtype",
  "may_be_treated_by"            = "may be treated by",
  "may_treat"                    = "may treat",
  "may_be_prevented_by"          = "may be prevented by",
  "may_prevent"                  = "may prevent",
  "has_causative_agent"          = "caused by",
  "causative_agent_of"           = "causes",
  "clinically_associated_with"   = "associated with",
  "co-occurs_with"               = "co-occurs with",
  "has_finding_site"             = "occurs in",
  "finding_site_of"              = "site of",
  "evaluated_by"                 = "evaluated by",
  "has_evaluation"               = "evaluates",
  "has_associated_finding"       = "presents with",
  "finding_of"                   = "is a finding of",
  "diagnoses"                    = "diagnoses",
  "diagnosed_by"                 = "diagnosed by",
  "component_of"                 = "component of",
  "has_component"                = "has component",
  "focus_of"                     = "focus of procedure",
  "has_contraindicated_drug"     = "contraindicated drug",
  "contraindicated_with_disease" = "contraindicated with",
  "induced_by"                   = "induced by",
  "manifestation_of"             = "manifestation of",
  "has_interpretation"           = "interpreted by",
  "interprets"                   = "interprets",
  "lexical_neighbor"             = "lexically related"
)

display_rela <- function(rela) {
  out <- unname(RELA_DISPLAY[rela])
  empty <- is.na(out) | !nzchar(out)
  # Humanize unknown relas: replace _ with space
  out[empty] <- gsub("_", " ", rela[empty])
  out[is.na(out) | !nzchar(out)] <- "related to"
  out
}
```

Use `display_rela(data$rela)` for the visNetwork edge `label`, and in `dag_export.R` add a `rela_display` column to edges.csv alongside `rela` (keep `rela` for machine round-tripping).

---

### 3. Procedures-tab/graph desync (Atrial Tumor C0741300)
**Severity:** High. **Files:** `app/R/dag_walker.R` (`RELA_CATEGORIES`, `walk_concept_dag`, `walk_concept_dag_dense`), `app/R/network_viz.R`.

**Root cause (confirmed by reading the routing logic):**

"Transplant of Heart" and "Operative Procedure on Corona[ry artery]" reach the graph through one of two paths:

1. **Densifier subtype/parent walk.** `walk_concept_dag_dense` walks parents (Tier 1, up to 4) and subtypes (Tier 2, up to 2). Each merged sub-walk's procedure-flavored neighbors arrive labelled with whatever `rela` connected them — and `inverse_isa` / `isa` route them to `subtypes` / `parents` per `RELA_CATEGORIES`, **not** `procedures`. So a procedure CUI reachable as a sibling under a parent like "Cardiac Procedure" lands in `subtypes` (rela=`inverse_isa`), then renders via `make_category_rows(dag$subtypes, ...)` and shows up on the graph.

2. **`focus_of` is the only mapping to `procedure`.** That's an extremely narrow door — most procedure CUIs are reached via hierarchy (`isa`/`inverse_isa`) or `method_of`/`procedure_site_of`/`direct_procedure_site_of` etc., none of which are in `RELA_CATEGORIES`.

The Procedures tab reads only `dag_result$procedures`, so it's empty even though the procedure node is visible.

**Fix:** Classify by MRSTY semantic type after the walk, not solely by source rela. Add a post-walk reclassifier:

```r
# In dag_walker.R, after walk_concept_dag builds `all_rels`:

# Semantic-type groups → category (one CUI can have multiple TUIs; first match wins)
STY_TO_CATEGORY <- list(
  procedure = c("Therapeutic or Preventive Procedure",
                "Diagnostic Procedure", "Health Care Activity"),
  diagnostic_lab = c("Laboratory Procedure", "Laboratory or Test Result"),
  treatment = c("Pharmacologic Substance", "Clinical Drug",
                "Antibiotic", "Vitamin", "Immunologic Factor"),
  anatomy = c("Body Part, Organ, or Organ Component", "Body Location or Region",
              "Tissue", "Anatomical Structure", "Body System"),
  comorbidity = c("Disease or Syndrome", "Neoplastic Process",
                  "Mental or Behavioral Dysfunction", "Sign or Symptom",
                  "Pathologic Function")
)

reclassify_by_sty <- function(rels) {
  if (nrow(rels) == 0) return(rels)
  con <- umls_db_connect()
  if (is.null(con)) return(rels)
  uniq <- unique(rels$related_cui)
  ph <- paste(rep("?", length(uniq)), collapse = ",")
  sty <- DBI::dbGetQuery(con, sprintf(
    "SELECT cui, sty FROM mrsty WHERE cui IN (%s)", ph),
    params = as.list(uniq))
  # First STY-derived category for each CUI
  classify <- function(cui_stys) {
    for (cat in names(STY_TO_CATEGORY)) {
      if (any(cui_stys %in% STY_TO_CATEGORY[[cat]])) return(cat)
    }
    NA_character_
  }
  sty_cat <- sty |>
    dplyr::group_by(cui) |>
    dplyr::summarise(sty_cat = classify(sty), .groups = "drop")
  rels |>
    dplyr::left_join(sty_cat, by = c("related_cui" = "cui")) |>
    dplyr::mutate(
      # Promote to STY category when the rela-derived category is hierarchy/other
      # but the STY says it's a clinical thing. Don't downgrade treatments etc.
      category = dplyr::case_when(
        !is.na(sty_cat) & category %in% c("subtype", "parent", "other",
                                          "other_rela", "associated") ~ sty_cat,
        TRUE ~ category
      )
    ) |>
    dplyr::select(-sty_cat)
}
```

Call `all_rels <- reclassify_by_sty(all_rels)` in `walk_concept_dag` before the `extract(...)` block. Procedure CUIs reached via `inverse_isa` will now correctly populate `dag$procedures`.

---

### 4. `monitoring_labs_table` will crash on `parent_drug_name` reference / silent table failure
**Severity:** Medium-High. **Files:** `app/app.R` lines in `download_pull_request` content function and `monitoring_labs_table`.

**Root cause:** In `download_pull_request`:
```r
unique_labs$parent_drug_name[i]
```
There is no `parent_drug_name` column anywhere in the walker output. The download will error out (caught by Shiny but the file will be malformed/missing the column). Separately, the `monitoring_labs_table` was patched to derive `drug_name` via a join — good — but if `from_cui` is missing (early walk paths set it to root), the "Monitors Drug" column will show the root condition name, which is wrong.

**Fix:** Remove the `parent_drug_name` reference and derive it the same way the table does:

```r
drug_lookup <- rv$dag_result$relations |>
  dplyr::distinct(related_cui, related_name) |>
  dplyr::rename(from_cui = related_cui, drug_name = related_name)
unique_labs <- monitoring |>
  dplyr::left_join(drug_lookup, by = "from_cui") |>
  dplyr::distinct(related_cui, .keep_all = TRUE) |>
  utils::head(30)
# then: ", unique_labs$drug_name[i], "
```

---

### 5. `umls_search` is defined twice — REST version always wins
**Severity:** Medium. **Files:** `app/R/umls_client.R` (line: `umls_search <- function(...)`) and `app/R/umls_client_duckdb.R` (line: `umls_search <- function(...)`).

**Root cause:** `app/app.R` sources `umls_client_duckdb.R` (which defines `umls_search` as DuckDB-first) but **does not** source `umls_client.R`. Good. But `code_lists.R` references `umls_get_source_codes`, `umls_get_relations`, `umls_get_concept` — all also redefined. The duckdb file re-defines REST fallbacks under `_rest` suffix, so it's fine — except `umls_client.R` is still in the repo and could be sourced by tests or future contributors and shadow the DB-first versions silently. The `generate_icd10_codes` function in `code_lists.R` calls `umls_get_relations` directly, which is fine, but it also calls `Sys.sleep(0.25)` between every child — that's appropriate for REST but wasted latency for DuckDB.

**Fix:** Either delete `app/R/umls_client.R` outright (it's now superseded) or rename its functions to the `_rest` suffix used in `umls_client_duckdb.R` and have it sourced first as a pure REST fallback module. I'd delete it; the REST shims already live in `umls_client_duckdb.R`. Also gate the `Sys.sleep(0.25)` in `generate_icd10_codes` on `!umls_db_available()`.

---

### 6. `extend_concept_dag` discards relations whose `related_cui` is already visited
**Severity:** Medium. **Files:** `app/R/dag_walker.R` (`bfs_walk`'s `distinct(related_cui, category, .keep_all = TRUE)` at the tail).

**Root cause:** When a user clicks a node to extend, the new walk's `bfs_walk` ends with:
```r
dplyr::distinct(related_cui, category, .keep_all = TRUE)
```
keyed only on `(related_cui, category)`. The shallowest-path-wins comment is correct for an isolated walk, but in `combine_dags` the `bind_distinct` for each category does:
```r
bound |> dplyr::distinct(related_cui, .keep_all = TRUE)
```
which drops any new edge whose `related_cui` already exists in the prior DAG. That means clicking node B never produces an edge from B to an existing node — the relationship is silently dropped, leaving an unconnected star. This is one of the root causes of issue #4 (star clutter).

**Fix:** Key the distinct on `(from_cui, related_cui, rela)` — relationships are edges, not nodes:

```r
# bind_distinct in combine_dags:
if (all(c("from_cui","related_cui","rela") %in% names(bound))) {
  bound <- bound |> dplyr::distinct(from_cui, related_cui, rela, .keep_all = TRUE)
} else if ("related_cui" %in% names(bound)) {
  bound <- bound |> dplyr::distinct(related_cui, .keep_all = TRUE)
}
```

Same fix in `bfs_walk`'s tail distinct.

---

### 7. CSV exports lack `cluster_id` and `rela_display`
**Severity:** Medium. **Files:** `app/R/dag_export.R` (`.dag_to_nodes_edges`).

**Fix:** Add cluster computation and display label:

```r
.dag_to_nodes_edges <- function(dag) {
  # ... existing code that produces nodes, edges ...

  # Cluster id by weakly-connected components of the rendered edge set
  if (nrow(edges) > 0 && requireNamespace("igraph", quietly = TRUE)) {
    g <- igraph::graph_from_data_frame(
      edges |> dplyr::select(from, to),
      vertices = nodes |> dplyr::select(id),
      directed = FALSE
    )
    comp <- igraph::components(g)
    nodes$cluster_id <- unname(comp$membership[nodes$id])
    # Edge cluster = its endpoint cluster (always equal for connected components)
    edge_cluster <- nodes$cluster_id[match(edges$from, nodes$id)]
    edges$cluster_id <- edge_cluster
  } else {
    nodes$cluster_id <- 1L
    edges$cluster_id <- 1L
  }

  if ("rela" %in% names(edges)) edges$rela_display <- display_rela(edges$rela)

  list(nodes = nodes, edges = edges)
}
```

Also worth: write a small `attestation.json` alongside the CSV bundle with the seed CUI, walk depth, expand_n, UMLS release version, RxNav cache timestamp, and a generation timestamp — answers the "missing column attestation in exports" concern.

---

### 8. Sparse lab/procedure recall — no MRSTY-typed fallback
**Severity:** Medium. **Files:** `app/R/dag_walker.R` (`walk_concept_dag_dense`).

**Root cause:** `walk_concept_dag_dense` densifies via parents → subtypes → lexical neighbors. None of these specifically targets missing labs or missing procedures. For seeds that have neither `evaluated_by` nor `has_associated_finding` rows in MRREL (common for narrow OMIM/CHV terms), labs stay at zero even though MRREL has neighbor concepts at semantic type 'Laboratory Procedure' one hop away.

**Fix:** Add a tier-4 typed-neighbor query keyed on MRSTY:

```r
# In dag_walker.R, end of walk_concept_dag_dense, before return:

if (nrow(base$diagnostic_labs) == 0 || nrow(base$procedures) == 0) {
  con <- umls_db_connect()
  if (!is.null(con)) {
    target_stys <- list(
      diagnostic_lab = c("Laboratory Procedure", "Diagnostic Procedure"),
      procedure      = c("Therapeutic or Preventive Procedure", "Health Care Activity")
    )
    for (cat in names(target_stys)) {
      if (nrow(base[[paste0(cat, "s")]] %||% base[[cat]] %||% tibble::tibble()) > 0) next
      stys <- target_stys[[cat]]
      ph <- paste(rep("?", length(stys)), collapse = ",")
      neighbors <- DBI::dbGetQuery(con, sprintf("
        SELECT DISTINCT r.cui2 AS related_cui, cp.preferred_name AS related_name,
                        r.rel, r.rela
        FROM mrrel_bidir r
        JOIN mrsty s ON s.cui = r.cui2 AND s.sty IN (%s)
        LEFT JOIN concept_preferred cp ON cp.cui = r.cui2
        WHERE r.cui1 = ? LIMIT 25", ph),
        params = c(as.list(stys), list(cui)))
      if (nrow(neighbors) > 0) {
        neighbors <- neighbors |>
          dplyr::mutate(category = !!cat, depth = 1L, via = "sty_fallback",
                        from_cui = cui, related_id_url = "")
        target_field <- if (cat == "diagnostic_lab") "diagnostic_labs" else "procedures"
        base[[target_field]] <- dplyr::bind_rows(base[[target_field]], neighbors)
        base$relations <- dplyr::bind_rows(base$relations, neighbors)
      }
    }
  }
}
```

The same pattern can fill `treatments` when empty (add `Pharmacologic Substance`, `Clinical Drug` to the map).

---

## Architectural Concerns (P0)

### A. Category routing should be MRSTY-first, not rela-first
The current design treats `RELA_CATEGORIES` as the source of truth and uses MRSTY only at concept-detail time. This is backwards for clinical filtering:

- A "Procedure" is a procedure no matter which rela got you there.
- A "Drug" is a treatment whether you arrived via `may_be_treated_by` or `inverse_isa` from a drug class.

The fix in P1 #3 is a tactical patch. The strategic move is to make MRSTY-derived category the **primary** label and treat rela as **secondary attribution** ("how we found it"). This collapses several of the listed bugs (3, 4 partially, 6 partially) into one design change.

**Decision needed from a human:** Are you OK with a CUI appearing in *two* category tables when its semantic types span both (e.g., "Cardiac transplant" as both `Procedure` and `Therapeutic Procedure`)? My recommendation: one CUI → one primary category by priority order (treatment > procedure > diagnostic_lab > comorbidity > anatomy > subtype > parent > other), so the category tabs partition the node set.

### B. Visible-graph filter independent of walker
Issue 4 (star clutter) is really two problems: too many peripheral nodes, and disconnected stars. Both are *rendering* problems, not walker problems. Recommend keeping the walker greedy (it's already capped) but adding a `viz_filter` step in `network_viz.R` before building visNetwork:

1. Filter nodes to clinical STYs (Disease, Procedure, Lab, Drug, Sign/Symptom, Anatomy).
2. Compute `igraph::components()` on the rendered edges.
3. Drop components of size ≤ 2 unless they include the root.
4. Use `visNetwork::visClusterByGroup` on the remaining components by `cluster_id`.

This is the same `cluster_id` you'd add to CSV exports — compute once, use twice.

### C. `Sys.sleep` in BFS while DuckDB is the backend
`bfs_walk` does `Sys.sleep(0.15)` after every node. That sleep is correct for the REST fallback but pure latency cost when DuckDB is available (which is the production path on `/srv/umls/umls.duckdb`). Gate it on `umls_db_available()`. For a 30-node walk this saves ~5 seconds per build.

### D. `medrt_get_relations` blocking call inside `umls_get_relations`
Every DuckDB `umls_get_relations(cui)` call invokes `medrt_get_relations(cui)`, which on a cache miss makes 4 HTTP calls to RxNav (one per `.MEDRT_RELAS` rela). During BFS that's 4 calls per node — a 20-node walk on a previously-unseen seed makes ~80 HTTP calls inside what looks like a local DB query. The sentinel handles "no MeSH code → don't ask again", but the **first** walk on a seed is dramatically slower than subsequent ones, and there's no user feedback that this is happening.

**Recommend:** Either (a) batch-prefetch MED-RT for the seed and its top-N most-connected hops only, or (b) make MED-RT lookups async (future package) and merge results in a second pass, or (c) at minimum, surface "Fetching drug relations from RxNav (one-time, ~30s)" in the progress callback.

### E. `.umls_con` global, single-shared DuckDB connection across Shiny sessions
```r
assign(".umls_con", con, envir = .GlobalEnv)
```
This is a single global connection shared by all Shiny sessions. DuckDB R driver isn't guaranteed thread-safe across concurrent queries on the same connection. For multi-user deployment, recommend per-session connections (using `session$userData`) or `pool::dbPool`. Low-impact at low user counts; will bite at scale.

### F. Telemetry never records the visible graph
`dag_build` logs counts of treatments/comorbidities/procedures/diagnostic_labs/parents, but not which CUIs ended up visible vs. dropped by the `MAX_RENDERED_NODES=180` cap, and never logs the cap firing. You can't reproduce a user's "the graph looked weird" report without that.

**Recommend:** Add `n_rendered_nodes`, `n_rendered_edges`, `n_clipped_by_cap`, and (if present) `cluster_count` to the `dag_build` event.

### G. PHI/security: search terms are logged by default
The Incognito checkbox is good UX, but the **default** is "log everything", including raw `term`, top_cui, and top_name. If a clinician searches for a patient-identifying string (rare but happens — "John Doe pulmonary embolism"), it lands in `logs/events/*.json` in clear text. Recommend either (a) defaulting Incognito to ON for a clinical environment, or (b) hashing free-text `term` the same way you hash session IDs, with a short opt-in window for usability research. At minimum, document this in the privacy notice next to the checkbox.

---

## Style/Lint (P2)

- **`dag_walker.R::extract`** in `walk_concept_dag` was patched to preserve column structure, but `.empty_relations_tibble()` already exists and is the canonical empty form. Use it: `if (nrow(all_rels) == 0) return(list(... = .empty_relations_tibble(), ...))` and skip the manual `filter()` dance.
- **`dag_export.R::.dag_to_nodes_edges`** silently substitutes `root_id` for missing `from_cui`. Log a warning when this fires — it usually means a walker change broke `from_cui` propagation upstream.
- **`network_viz.R`** keeps a hand-maintained list of `visGroups()` calls. Drive it from `DOMAIN_COLORS` directly: `purrr::reduce(names(DOMAIN_COLORS), \(net, g) visNetwork::visGroups(net, groupname = g, color = DOMAIN_COLORS[[g]]), .init = net)`.
- **`dag_walker.R::BFS_EXPAND_CATEGORIES`** includes `"associated"` but `RELA_CATEGORIES` only maps two relas to `associated`. Likely overexpansion vector — recommend dropping it from the expand set.
- **`medrt_rxnav.R`** `.MEDRT_CACHE_PATH` and the read-only/write reconnect pattern open and close the DuckDB on every lookup. For a hot path, a single long-lived `read_only=TRUE` connection mirroring the UMLS pattern would be cheaper.
- **`telemetry.R`** writes one file per event. On a busy day with thousands of events the `events/` directory becomes slow to `list.files()`. Add a daily roll-up script that concatenates `events/YYYY-MM-DD/*.json` into one NDJSON file and removes the originals.
- **`code_lists.R::generate_loinc_codes`** still calls `.loinc_class_number` with a `Sys.sleep(0.1)` per code — but the DuckDB override is now O(1). Drop the sleep when DB-backed.
- **`app.R`** sources files with bare `source("R/...")` paths, depending on the working directory. Use `source(file.path("R", "..."))` after `setwd(getSrcDirectory(function() {}))` or move to a package layout. Currently works because `shiny::runApp("app")` sets the wd, but it's a foot-gun for `Rscript` invocations.
- **`dag_walker.R::categorize_relations`** uses `dplyr::case_when` with `RELA_CATEGORIES[rela]` — a named-vector lookup inside `case_when` returns a vector that may not align with row order in edge cases. Safer: `categories <- coalesce(unname(RELA_CATEGORIES[rela]), unname(REL_CATEGORIES[rel]), if_else(nchar(rela) > 0, "other_rela", "other"))`.

---

## What I'd do first

1. **Fix #6 (edge-key distinct in `combine_dags`).** Two-line change, unblocks click-to-extend showing edges back into the existing graph, and reduces star clutter for free. Highest impact-to-effort.
2. **Add `umls_resolve_names()` and call it from `make_category_rows` whenever `related_name` is empty or equals the CUI (#1).** Kills the visible-label bug everywhere in one shot.
3. **Add the `RELA_DISPLAY` table and `display_rela()`, wire into viz + CSV exports (#2).** ~30 lines, instant UX improvement, also makes the GraphML/Mermaid exports readable.
4. **Add `reclassify_by_sty()` post-walk (#3).** Fixes the procedures-tab desync and primes the architectural shift to STY-first categorization. One join, ~25 lines.
5. **Add `cluster_id` (via `igraph::components()`) to both the CSV exports and the visNetwork builder (#7 + Architectural B).** Same computation, dual benefit: stratifiable exports plus `visClusterByGroup` for the star-clutter problem.

Everything else (MED-RT prefetch redesign, per-session DB connections, telemetry coverage, privacy default) is real work but not on the critical path for the user-reported bugs.