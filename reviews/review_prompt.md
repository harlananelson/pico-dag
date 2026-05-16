You are reviewing the `pico-dag` R/Shiny application. It's a clinical-research DAG explorer backed by UMLS (DuckDB at `/srv/umls/umls.duckdb`) and augmented by RxNav MED-RT drug-disease relations. Users search for a clinical concept (CUI or term), and the app walks the UMLS graph to surface related treatments, comorbidities, procedures, labs, anatomy, subtypes, parents, and etiologies, then renders an interactive visNetwork DAG and per-category data tables, with CSV/GraphML export.

**Architecture notes:**
- `app/app.R` — Shiny server + UI
- `app/R/umls_client_duckdb.R` — direct DuckDB queries against mrconso/mrrel/mrsty/mrhier/mrdef/concept_preferred/concept_definition
- `app/R/dag_walker.R` — BFS walker (`bfs_walk`, `walk_concept_dag`, `walk_concept_dag_dense`) with category routing
- `app/R/network_viz.R` — visNetwork builder, color palette, label cleaner, per-anchor edge cap
- `app/R/dag_export.R` — flatten dag_result → nodes/edges tibbles → CSV/GraphML
- `app/R/medrt_rxnav.R` — RxNav cache for MED-RT drug-disease relations (closes a gap in public UMLS RRF)
- `app/R/telemetry.R` — NDJSON per-event logging, hashed session salt, `safely_run` wrapper

**Specific user-reported issues to prioritize in your review:**

1. **Unresolved CUI labels.** Some nodes in the DAG display the bare CUI string (e.g. `C0018821` instead of "Heart"). Find every place a CUI could leak through unresolved. Every visible label should be the concept's preferred name from `concept_preferred` (or a UMLS fallback).

2. **Awkward UMLS jargon for edge labels.** The edges show `isa` and `inverse_isa`. These should be human-readable: "is a kind of", "has subtype", "may treat", "affects", "caused by", etc. Recommend a single rela→display-label lookup table and apply it consistently across the visualization and CSV exports.

3. **Procedures-tab/graph desync (CONCRETE REPRO).** Searching for "Atrial Tumor" (C0741300) renders nodes like "Transplant of Heart" and "Operative Procedure on Corona" in the graph, but the Procedures table is empty. Diagnose why these procedure-flavored nodes don't end up in `dag$procedures`. Hypothesis: they're surfaced via `inverse_isa` (subtype) or generic hierarchy expansion, then routed to `subtypes`/`parents` instead of `procedures`. Recommend: cross-reference rendered nodes against the typed-tab filters; classify by MRSTY semantic type, not just by source rela.

4. **Star-pattern clutter.** The walker produces multiple disconnected star patterns, and most peripheral nodes are not clinically informative. The user wants the center and immediate neighborhood to be **only** condition/disease/treatment/lab/procedure (i.e., clinical semantic types). Recommend filtering visible nodes by MRSTY semantic type, and adding cluster grouping (e.g., `igraph::components()` on the rendered edge set, then `visNetwork::visClusterByGroup`).

5. **CSV exports need a grouping column.** `dag_export.R` flattens to nodes.csv/edges.csv but there's no field indicating which cluster/star a node belongs to. Add a `cluster_id` (or `group`) column to both nodes.csv and edges.csv, computed from connected components on the rendered edge set, so downstream consumers can stratify.

6. **Sparse lab/procedure recall.** For some seeds, the walker returns zero labs or zero procedures even when they exist in UMLS. Audit the densifier. Recommend an MRSTY-typed fallback: when procedures/labs come back empty after the standard walk, run a targeted neighbor-query filtered by semantic types ('Therapeutic or Preventive Procedure', 'Laboratory Procedure', 'Diagnostic Procedure', 'Clinical Drug', 'Pharmacologic Substance', etc.).

7. **General improvements.** Surface anything else in the same family — viz/data inconsistencies, walker completeness gaps, missing telemetry coverage, undocumented edge cases, UI ergonomic issues, missing column attestation in exports, performance hotspots, error-handling gaps, security/PHI concerns. Use your fresh eyes; the user wants the panel to catch issues they haven't noticed yet.

**Output format:**
Provide your review as markdown with these sections:

```
## Critical Issues (P1)
For each: title, severity, files/lines, root cause, recommended fix.
Use a code block for the suggested patch if the change is < 30 lines.

## Architectural Concerns (P0)
Big-picture / design issues that need a human decision.

## Style/Lint (P2)
Minor quality wins.

## What I'd do first
A 5-bullet punch list ordered by impact-to-effort ratio.
```

Be specific: name files and functions. Quote the offending code. If you're unsure, say so explicitly. Don't pad with generic advice — focus on issues you can locate in the actual code.
