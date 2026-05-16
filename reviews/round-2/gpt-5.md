

## Critical Issues (P1)

1) Unresolved CUI labels leak into node labels and exports
- Severity: High (user-facing labels show bare CUIs; undermines usability)
- Files/lines:
  - app/R/umls_client_duckdb.R: function umls_get_relations() — medrt_compat builds related_name from RxNav without joining concept_preferred; bidir fallback to CUI when preferred name missing: coalesce(cp.preferred_name, r.cui2).
  - app/R/dag_export.R: .dag_to_nodes_edges() sets label = tbl$related_name without a guaranteed preferred-name backfill.
  - app/R/network_viz.R: build_dag_network() uses label = clean_node_label(data$related_name), no fallback to preferred_name.
- Root cause:
  - MED-RT rows keep RxNav drug names; no concept_preferred join.
  - When concept_preferred lacks a row (rare but present), related_name falls back to CUI (r.cui2), which then propagates to the graph and CSV.
- Recommended fix:
  - Ensure every (related_cui) has a preferred name. For DuckDB, left join concept_preferred for both MRREL and MED-RT derived rows and overwrite related_name when available.
  - As an additional guard, add a last-mile relabel step in exports/visualization to coalesce label to concept_preferred.preferred_name where related_name is blank or looks like a CUI.
- Suggested patch (<30 lines) — join preferred names for MED-RT rows:
  ```
  # app/R/umls_client_duckdb.R — inside umls_get_relations(), just after medrt_compat creation
  if (!is.null(medrt) && nrow(medrt) > 0) {
    medrt_compat <- tibble::tibble(
      cui            = medrt$cui,
      related_cui    = medrt$related_cui,
      related_name   = medrt$related_name,
      rel            = "RO",
      rela           = medrt$rela,
      related_id_url = ""
    )
    # Prefer UMLS preferred name when available
    pref <- DBI::dbGetQuery(con,
      "SELECT cui, preferred_name FROM concept_preferred WHERE cui IN (?)",
      params = list(unique(medrt_compat$related_cui)))
    if (nrow(pref) > 0) {
      medrt_compat <- medrt_compat |>
        dplyr::left_join(tibble::as_tibble(pref), by = c("related_cui" = "cui")) |>
        dplyr::mutate(related_name = dplyr::coalesce(preferred_name, related_name)) |>
        dplyr::select(-preferred_name)
    }
    rels <- dplyr::bind_rows(bidir, medrt_compat)
  } else {
    rels <- bidir
  }
  ```
  - Optional guard in network_viz build: coalesce labels with concept_preferred when they look like “C\d+”.

2) Edge labels use UMLS jargon (isa/inverse_isa) instead of human-readable phrases
- Severity: Medium-High (poor UX; confusing)
- Files/lines:
  - app/R/network_viz.R: build_dag_network() → edges$label <- data$rela
  - app/R/dag_export.R: export_graphml() writes <data key="rela"> raw; CSV edges.csv has rela raw only.
- Root cause:
  - No display-label mapping is applied for visualization/exports.
- Recommended fix:
  - Create a single rela→display label mapping and apply consistently in network_viz and dag_export (add a display_rela column in exports).
- Suggested patch (<30 lines) — add display mapping in network_viz and use it:
  ```
  # app/R/network_viz.R — near top
  RELA_DISPLAY <- c(
    "isa" = "is a kind of",
    "inverse_isa" = "has subtype",
    "may_be_treated_by" = "may be treated by",
    "may_treat" = "may treat",
    "may_be_prevented_by" = "may be prevented by",
    "clinically_associated_with" = "is associated with",
    "co-occurs_with" = "co-occurs with",
    "has_finding_site" = "has finding site",
    "finding_site_of" = "finding site of",
    "evaluated_by" = "evaluated by",
    "has_associated_finding" = "has associated finding",
    "has_causative_agent" = "caused by",
    "focus_of" = "has procedure"
  )
  .rela_display <- function(x) {
    y <- RELA_DISPLAY[x]; ifelse(is.na(y) | !nzchar(y), "related to", unname(y))
  }

  # inside make_category_rows(): set edge label via display mapping
  edges <- tibble::tibble(
    from   = edge_from,
    to     = data$related_cui,
    label  = .rela_display(data$rela),
    arrows = "to",
    color  = DOMAIN_COLORS[category] %||% "#7F8C8D"
  )
  ```
  - Mirror this by adding a display_rela column in dag_export (not shown here due to 30-line cap; see P2 for details).

3) Procedures tab empty while procedure-flavored nodes appear in the graph (repro: “Atrial Tumor” C0741300)
- Severity: High (tab-graph inconsistency; user-reported repro)
- Files/lines:
  - app/R/dag_walker.R: RELA_CATEGORIES maps only "focus_of" to "procedure"; hierarchy- or other-rela-introduced procedures are categorized as parent/subtype/other.
  - app/R/network_viz.R: graph shows those nodes (as parent/subtype), so users see procedures, but dag_result$procedures remains empty.
- Root cause:
  - Classification purely by RELA misses concepts whose semantic type is a Procedure but surface via hierarchy (isa/inverse_isa) or generic associations.
- Recommended fix:
  - Post-process relations by MRSTY: if related_cui has a procedure STY (e.g., 'Therapeutic or Preventive Procedure', 'Diagnostic Procedure', 'Laboratory Procedure'), override category to 'procedure' (or 'diagnostic_lab' for Lab procedures) unless already a lab/anatomy leaf.
  - Apply this enrichment before splitting into dag_result$procedures et al.
- Suggested patch (<30 lines) — semantic-type recategorization hook:
  ```
  # app/R/dag_walker.R — add helper and apply in walk_concept_dag()
  recategorize_by_semtype <- function(relations) {
    con <- umls_db_connect(); if (is.null(con) || nrow(relations) == 0) return(relations)
    stys <- DBI::dbGetQuery(con,
      "SELECT cui, sty FROM mrsty WHERE cui IN (?)", params = list(unique(relations$related_cui)))
    if (nrow(stys) == 0) return(relations)
    proc_sty <- c("Therapeutic or Preventive Procedure","Diagnostic Procedure")
    lab_sty  <- c("Laboratory Procedure")
    sty_lu <- tapply(stys$sty, stys$cui, function(v) unique(v))
    relations$category <- vapply(seq_len(nrow(relations)), function(i) {
      rc <- relations$related_cui[i]; cat0 <- relations$category[i]
      s <- sty_lu[[rc]] %||% character(0)
      if (any(s %in% proc_sty)) "procedure"
      else if (any(s %in% lab_sty) && cat0 != "monitoring_lab") "diagnostic_lab"
      else cat0
    }, FUN.VALUE = character(1))
    relations
  }

  # in walk_concept_dag(), just after all_rels <- bfs_walk(...):
  all_rels <- recategorize_by_semtype(all_rels)
  ```
  - This will route hierarchy-surfaced procedure CUIs into dag$procedures, fixing the tab/graph desync for the repro and similar cases.

4) Diagnostic labs mis-grouped and legend mismatch
- Severity: Medium (confusing coloring/legend; lab counts ok)
- Files/lines:
  - app/R/network_viz.R: cats list calls make_category_rows(dag_result$diagnostic_labs, "monitoring_lab", max_nodes = 15) — diagnostic labs rendered under monitoring_lab group.
  - DOMAIN_COLORS lacks a "diagnostic_lab" entry.
- Root cause:
  - Typo in category routing for visualization; missing color key.
- Recommended fix:
  - Render diagnostic_labs with group "diagnostic_lab" and add a matching color (can reuse monitoring green).
- Suggested patch (<30 lines):
  ```
  # app/R/network_viz.R — extend colors
  DOMAIN_COLORS <- c(
    "population"="#E74C3C","treatment"="#3498DB","monitoring_lab"="#2ECC71",
    "diagnostic_lab"="#2ECC71","comorbidity"="#E67E22","procedure"="#9B59B6",
    "anatomy"="#F39C12","subtype"="#95A5A6","parent"="#BDC3C7","outcome"="#E74C3C",
    "intervention"="#1ABC9C","comparator"="#16A085","etiology"="#C0392B","other"="#7F8C8D"
  )

  # cats list: fix group for diagnostic labs
  cats <- list(
    make_category_rows(dag_result$treatments,"treatment",15),
    make_category_rows(dag_result$comorbidities,"comorbidity",15),
    make_category_rows(dag_result$procedures,"procedure",15),
    make_category_rows(dag_result$anatomy,"anatomy",10),
    make_category_rows(dag_result$subtypes,"subtype",15),
    make_category_rows(dag_result$parents,"parent",6),
    make_category_rows(dag_result$diagnostic_labs,"diagnostic_lab",15),
    if (!is.null(dag_result$etiology)) make_category_rows(dag_result$etiology,"etiology",8) else list(nodes=NULL,edges=NULL)
  )
  ```
  - Also add a visGroups line for "diagnostic_lab" mirroring monitoring_lab.

5) CSV/GraphML exports lack cluster IDs and GraphML uses duplicate key ids
- Severity: Medium (downstream stratification impossible; GraphML validity risk)
- Files/lines:
  - app/R/dag_export.R: .dag_to_nodes_edges() does not compute connected components; export_graphml() defines key id="category" for both node and edge.
- Root cause:
  - No component computation; GraphML keys not unique across node/edge namespaces.
- Recommended fix:
  - Compute connected components on the rendered edge set and add cluster_id to nodes and edges. Change GraphML keys to unique ids for node vs edge categories.
- Suggested patch (<30 lines) — unique GraphML keys:
  ```
  # app/R/dag_export.R — in export_graphml()
  paste(c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">',
    '  <key id="node_label"    for="node" attr.name="label"    attr.type="string"/>',
    '  <key id="node_category" for="node" attr.name="category" attr.type="string"/>',
    '  <key id="edge_rela"     for="edge" attr.name="rela"     attr.type="string"/>',
    '  <key id="edge_category" for="edge" attr.name="category" attr.type="string"/>',
    ...
    sprintf('  <graph id="%s" edgedefault="directed">', esc(dag$concept$cui %||% "DAG")),
    node_lines, edge_lines, '  </graph>','</graphml>'
  ), collapse = "\n")
  ```
  - Compute cluster_id and add to nodes/edges in .dag_to_nodes_edges() using igraph::components() (full patch would exceed the 30-line cap; see “Architectural Concerns” for the algorithm and schema change).

6) QMD export references nonexistent column parent_drug_name for monitoring labs
- Severity: Medium (document generation shows blank in “Monitors” column)
- Files/lines:
  - app/app.R: in output$download_pull_request content builder — uses unique_labs$parent_drug_name[i], but monitoring_labs are never given parent_drug_name; earlier the table uses joined drug_name.
- Root cause:
  - Inconsistent column name between monitoring_labs DT render and QMD generation.
- Recommended fix:
  - Replace parent_drug_name with drug_name (or re-join).
- Suggested patch (<30 lines):
  ```
  # app/app.R — inside download_pull_request content builder
  if (nrow(monitoring) > 0) {
    lines <- c(lines, "", "# Monitoring Labs", "",
                "| Lab | Monitors | CUI |",
                "|-----|----------|-----|")
    unique_labs <- monitoring |> dplyr::distinct(related_cui, .keep_all = TRUE) |> utils::head(30)
    for (i in seq_len(nrow(unique_labs))) {
      lines <- c(lines, paste0(
        "| ", unique_labs$related_name[i],
        " | ", (unique_labs$drug_name %||% unique_labs$from_cui)[i],
        " | ", unique_labs$related_cui[i], " |"
      ))
    }
  }
  ```

## Architectural Concerns (P0)

- Add a consistent semantic-typing layer in the walker
  - Decision: bake MRSTY-enriched categorization into the traversal pipeline. Today, categories are assigned from RELA alone (RELA_CATEGORIES), which misses clinically important cases (e.g., procedures via isa/inverse_isa). The proposed recategorize_by_semtype helper enables this in DuckDB-backed runs. If REST-only mode should be fully supported, you’ll need a MRSTY fetch API or a small in-memory cache hydrated from REST (higher effort, more HTTP).
- Centralize relation label display policy
  - Decision: own a single canonical mapping for rela→display label and use it in both viz and exports. Current code has biolink predicate mapping in dag_export (.biolink_predicate) and raw UMLS labels in vis; this leads to inconsistent surface area. Consider exporting both original_predicate and display_predicate.
- Graph component clustering and UI gating
  - Decision: filter and cluster the visible graph by clinical STYs and surface clusters explicitly. Implementation path:
    - Compute connected components on the current edges (igraph) and attach cluster_id.
    - Add a UI toggle to show “clinical core only” (STYs in Disease or Syndrome, Neoplastic Process, Finding, Pharmacologic Substance, Clinical Drug, Laboratory Procedure, Diagnostic Procedure, Therapeutic or Preventive Procedure). Default it ON.
    - Optional: visNetwork::visClusterByGroup is group-based, not components-based. You can still group by cluster_id by setting nodes$group <- paste0("cluster_", cluster_id), but that replaces domain-coloring. Alternatively, keep domain group for color and use shape to indicate clusters, or add a secondary grouping in the legend.
- Export schema bump (CSV)
  - Decision: include display_rela, cluster_id in edges.csv and cluster_id in nodes.csv. Backward-compatible if appended as new columns.
- Error budget and retries
  - Decision: centralize HTTP retry/backoff (httr2::req_retry) for all UMLS and RxNav calls. Current Sys.sleep sprinkling is pragmatic but brittle and increases wall time. Use req_retry with backoff on 429/5xx.

## Style/Lint (P2)

- network_viz: ensure visGroups has a group for "diagnostic_lab" (after adding it to DOMAIN_COLORS).
- dag_export GraphML: duplicate key id “category” used for node and edge—fixed in P1. Consider also adding a display_rela key for human-friendly labels.
- dag_export: .xml_escape currently handles both node and edge data; good. Add tests to ensure quotes/apostrophes in labels round-trip.
- dag_walker: tryCatch handlers silently drop errors (resolve_source_url_to_cui, bfs_walk). Emit a warning with where and the CUI/URL to ease debugging (you already have telemetry in safely_run elsewhere).
- Telemetry coverage is good; consider logging when the semantic-typing fallback reassigns a category (counts per assignment) to evaluate how often RELA-only mapping misses procedures/labs.
- app/app.R: small mismatch in terminology: “Diagnostic Labs (from disease → evaluated_by / has_associated_finding)” but visualization had all labs grouped under monitoring until the patch.

## What I'd do first

- Implement semantic-typing recategorization (P1 #3) in dag_walker and re-run the “Atrial Tumor” repro to fix the Procedures tab desync with minimal code change.
- Fix diagnostic lab grouping and add display labels for edges (P1 #2 and #4). This gives immediate UX wins in the graph.
- Patch MED-RT label resolution to concept_preferred (P1 #1) so no node shows a bare CUI string; verify a seed that previously displayed CUIs.
- Fix GraphML keys and add cluster_id computation in dag_export (P1 #5). Even adding cluster_id only to CSV first is fine; GraphML cluster attribute can follow.
- Correct the QMD export lab section to use drug_name (P1 #6) and add a quick unit test or snapshot test for the QMD generator so this doesn’t regress.

If you want me to supply follow-on patches (cluster_id in CSV, export display_rela, and an igraph-based component computation) I can draft them next.