#' DAG walker — BFS traversal of UMLS concept graph

# ---------------------------------------------------------------------------
# RELA → clinical category mapping
# ---------------------------------------------------------------------------

RELA_CATEGORIES <- c(
  # Treatments (disease→drug or drug→disease)
  "may_be_treated_by"      = "treatment",
  "may_treat"              = "treatment",
  "may_be_prevented_by"    = "treatment",    # vaccines, prophylactics

  # Anatomy
  "has_finding_site"       = "anatomy",
  "finding_site_of"        = "anatomy",

  # Labs
  "component_of"           = "monitoring_lab",
  "has_component"          = "monitoring_lab",
  "has_evaluation"         = "diagnostic_lab",
  "evaluated_by"           = "diagnostic_lab",
  "has_associated_finding" = "diagnostic_lab",
  "finding_of"             = "diagnostic_lab",
  "diagnoses"              = "diagnostic_lab",
  "diagnosed_by"           = "diagnostic_lab",
  "has_finding"            = "diagnostic_lab",

  # Comorbidities / sequelae
  "clinically_associated_with" = "comorbidity",
  "co-occurs_with"             = "comorbidity",
  "cause_of"                   = "comorbidity",
  "associated_condition_of"    = "comorbidity",

  # Procedures
  "focus_of"               = "procedure",

  # Hierarchy
  "inverse_isa"            = "subtype",
  "isa"                    = "parent",

  # Genetic
  "manifestation_of"       = "genetic",

  # Etiology
  "has_causative_agent"    = "etiology",
  "causative_agent_of"     = "etiology",

  # Interpretation
  "has_interpretation"     = "interpretation",
  "interprets"             = "interpretation",

  # Associated (expandable but lower priority)
  "associated_with"        = "associated",
  "associated_finding_of"  = "associated",

  # Contraindications
  "contraindicated_with_disease" = "contraindication",
  "has_contraindicated_drug"     = "contraindication",

  # Pharmaceutical product relations — map to "pharmaceutical" so they
  # don't pollute other_rela for drug concepts
  "ingredient_of"              = "pharmaceutical",
  "active_ingredient_of"       = "pharmaceutical",
  "active_moiety_of"           = "pharmaceutical",
  "basis_of_strength_substance_of" = "pharmaceutical",
  "has_tradename"              = "pharmaceutical",
  "tradename_of"               = "pharmaceutical",

  # Classification / mapping noise — sink to "other" not "other_rela"
  "classifies"             = "other",
  "classified_as"          = "other",
  "mapped_from"            = "other",
  "mapped_to"              = "other",
  "concept_in_subset"      = "other",
  "member_of"              = "other",
  "has_permuted_term"      = "other",
  "permuted_term_of"       = "other",
  "expanded_form_of"       = "other",
  "has_expanded_form"      = "other",
  "same_as"                = "other"
)

REL_CATEGORIES <- c(
  "CHD" = "narrower",
  "RN"  = "narrower",
  "PAR" = "broader",
  "RB"  = "broader"
)

# ---------------------------------------------------------------------------
# Human-readable RELA labels for the visNetwork edges + CSV exports
# ---------------------------------------------------------------------------

#' Map raw UMLS rela strings to user-friendly display labels.
#' Single source of truth — used by network_viz.R for edges and by dag_export.R
#' to add a rela_display column alongside the raw rela in CSV/GraphML exports.
RELA_DISPLAY <- c(
  "isa"                          = "is a kind of",
  "inverse_isa"                  = "has subtype",
  "may_be_treated_by"            = "may be treated by",
  "may_treat"                    = "may treat",
  "may_be_prevented_by"          = "may be prevented by",
  "may_prevent"                  = "may prevent",
  "has_causative_agent"          = "caused by",
  "causative_agent_of"           = "causes",
  "induced_by"                   = "induced by",
  "clinically_associated_with"   = "associated with",
  "co-occurs_with"               = "co-occurs with",
  "associated_condition_of"      = "occurs with",
  "cause_of"                     = "causes",
  "has_finding_site"             = "occurs in",
  "finding_site_of"              = "site of",
  "evaluated_by"                 = "evaluated by",
  "has_evaluation"               = "evaluates",
  "has_associated_finding"       = "presents with",
  "associated_finding_of"        = "finding of",
  "finding_of"                   = "is a finding of",
  "has_finding"                  = "has finding",
  "diagnoses"                    = "diagnoses",
  "diagnosed_by"                 = "diagnosed by",
  "component_of"                 = "component of",
  "has_component"                = "has component",
  "focus_of"                     = "focus of procedure",
  "has_contraindicated_drug"     = "contraindicated drug",
  "contraindicated_with_disease" = "contraindicated with",
  "manifestation_of"             = "manifestation of",
  "has_interpretation"           = "interpreted by",
  "interprets"                   = "interprets",
  "ingredient_of"                = "ingredient of",
  "active_ingredient_of"         = "active ingredient of",
  "active_moiety_of"             = "active moiety of",
  "has_tradename"                = "tradename",
  "tradename_of"                 = "tradename of",
  "lexical_neighbor"             = "lexically related",
  "associated_with"              = "associated with"
)

#' Vectorized display label for a rela vector.
#' Unknown relas are humanized (underscore→space); empty rela → "related to".
display_rela <- function(rela) {
  rela <- as.character(rela)
  rela[is.na(rela)] <- ""
  out <- unname(RELA_DISPLAY[rela])
  needs_humanize <- is.na(out)
  if (any(needs_humanize)) {
    humanized <- gsub("_", " ", rela[needs_humanize])
    out[needs_humanize] <- humanized
  }
  out[is.na(out) | !nzchar(out)] <- "related to"
  out
}

# ---------------------------------------------------------------------------
# MRSTY → category map for post-walk reclassification
# ---------------------------------------------------------------------------

#' Semantic-type groups. Used to reroute concepts to their clinical category
#' regardless of which UMLS rela surfaced them. Order matters: the first match
#' wins per CUI, so list the most specific clinical types first.
STY_TO_CATEGORY <- list(
  diagnostic_lab = c("Laboratory Procedure", "Laboratory or Test Result",
                     "Clinical Attribute"),
  procedure      = c("Therapeutic or Preventive Procedure",
                     "Diagnostic Procedure",
                     "Health Care Activity",
                     "Molecular Biology Research Technique"),
  treatment      = c("Pharmacologic Substance", "Clinical Drug",
                     "Antibiotic", "Vitamin", "Immunologic Factor",
                     "Biologically Active Substance",
                     "Hormone", "Enzyme", "Receptor", "Steroid",
                     "Indicator, Reagent, or Diagnostic Aid",
                     "Amino Acid, Peptide, or Protein"),
  anatomy        = c("Body Part, Organ, or Organ Component",
                     "Body Location or Region",
                     "Tissue", "Anatomical Structure", "Body System",
                     "Cell", "Cell Component",
                     "Embryonic Structure", "Fully Formed Anatomical Structure"),
  comorbidity    = c("Disease or Syndrome", "Neoplastic Process",
                     "Mental or Behavioral Dysfunction",
                     "Pathologic Function", "Sign or Symptom",
                     "Cell or Molecular Dysfunction",
                     "Acquired Abnormality",
                     "Congenital Abnormality",
                     "Injury or Poisoning",
                     "Anatomical Abnormality")
)

#' Reclassify rows of `rels` whose surfacing-rela bucket disagrees with their
#' MRSTY semantic type. A concept whose intrinsic type is "Procedure" should
#' appear in dag$procedures regardless of whether it was reached via
#' `focus_of`, `inverse_isa`, or any other path.
#'
#' Rule: only promote rows whose current category is hierarchy-derived
#' (subtype/parent) or non-specific (other/other_rela/associated/narrower/
#' broader). Existing clinical assignments (treatment/comorbidity etc.) are
#' preserved — we only fill gaps, never downgrade a specific category.
reclassify_by_sty <- function(rels) {
  if (is.null(rels) || nrow(rels) == 0) return(rels)
  if (!"category" %in% names(rels) || !"related_cui" %in% names(rels)) return(rels)

  stys <- umls_mrsty_for_cuis(unique(rels$related_cui))
  if (nrow(stys) == 0) return(rels)

  # First-match-by-priority category per CUI
  sty_map <- stys |>
    dplyr::group_by(cui) |>
    dplyr::summarize(
      sty_category = {
        s <- unique(sty)
        result <- NA_character_
        for (cat in names(STY_TO_CATEGORY)) {
          if (any(s %in% STY_TO_CATEGORY[[cat]])) { result <- cat; break }
        }
        result
      },
      .groups = "drop"
    )

  promote_from <- c("subtype", "parent", "other", "other_rela",
                    "associated", "narrower", "broader")

  rels |>
    dplyr::left_join(sty_map, by = c("related_cui" = "cui")) |>
    dplyr::mutate(
      category = dplyr::case_when(
        !is.na(sty_category) & category %in% promote_from ~ sty_category,
        TRUE ~ category
      )
    ) |>
    dplyr::select(-sty_category)
}

# Categories whose nodes are expanded further in BFS.
# Labs, anatomy, procedures are leaves — collecting them is useful but
# walking their children produces noise.
BFS_EXPAND_CATEGORIES <- c(
  "treatment", "comorbidity", "etiology", "parent", "subtype", "associated"
)

# UMLS CUIs always start with C followed by digits.
# Source-specific IDs (RxCUI "736680", atom IDs "A12345") will 404 if used
# as the subject of a UMLS REST call — guard all BFS expansion against this.
is_umls_cui <- function(x) grepl("^C\\d+$", x)

# Resolve a source-vocabulary concept URL to its UMLS CUI.
# UMLS disease→drug relations return RxNorm IDs, not UMLS CUIs.
# Calling /content/current/source/{SAB}/{code} gives the concept URL with CUI.
# Returns NA_character_ on any failure. Results are memoized in .cui_cache.
.cui_cache <- new.env(parent = emptyenv())

resolve_source_url_to_cui <- function(source_url) {
  if (!nchar(source_url)) return(NA_character_)

  key <- source_url
  if (exists(key, envir = .cui_cache, inherits = FALSE))
    return(get(key, envir = .cui_cache, inherits = FALSE))

  cui <- tryCatch({
    if (grepl("/source/", source_url)) {
      # /source/{SAB}/{code} → need /atoms/preferred to get the concept CUI
      sab  <- stringr::str_extract(source_url, "(?<=/source/)[^/]+")
      code <- stringr::str_extract(source_url, "[^/]+$")
      if (is.na(sab) || is.na(code)) return(NA_character_)
      resp <- httr2::request(UMLS_BASE_URL) |>
        httr2::req_url_path_append("content", "current", "source", sab, code,
                                   "atoms", "preferred") |>
        httr2::req_url_query(apiKey = get_api_key()) |>
        httr2::req_perform() |>
        httr2::resp_body_json()
      concept_url <- resp$result$concept %||% ""
      if (!nchar(concept_url)) NA_character_
      else stringr::str_extract(concept_url, "(?<=/CUI/)[^/]+")
    } else if (grepl("/AUI/", source_url)) {
      # /AUI/{aui} → resolve atom to concept directly
      aui  <- stringr::str_extract(source_url, "(?<=/AUI/)[^/?]+")
      if (is.na(aui)) return(NA_character_)
      resp <- httr2::request(UMLS_BASE_URL) |>
        httr2::req_url_path_append("content", "current", "AUI", aui) |>
        httr2::req_url_query(apiKey = get_api_key()) |>
        httr2::req_perform() |>
        httr2::resp_body_json()
      concept_url <- resp$result$concept %||% ""
      if (!nchar(concept_url)) NA_character_
      else stringr::str_extract(concept_url, "(?<=/CUI/)[^/]+")
    } else {
      NA_character_
    }
  }, error = \(e) NA_character_)

  Sys.sleep(0.1)
  assign(key, cui, envir = .cui_cache)
  cui
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

categorize_relations <- function(relations) {
  relations |>
    dplyr::mutate(
      category = dplyr::case_when(
        rela %in% names(RELA_CATEGORIES) ~ RELA_CATEGORIES[rela],
        rela == "" & rel %in% names(REL_CATEGORIES) ~ REL_CATEGORIES[rel],
        nchar(rela) > 0 ~ "other_rela",
        .default = "other"
      )
    )
}

# ---------------------------------------------------------------------------
# BFS core
# ---------------------------------------------------------------------------

#' BFS walk over the UMLS concept graph from a root CUI.
#'
#' At each visited node, fetches all relations and categorizes them.
#' Nodes whose category is in BFS_EXPAND_CATEGORIES are queued for
#' further traversal (up to max_depth hops from root).
#'
#' Only nodes with valid UMLS CUIs (C\d+) are ever queued — source-specific
#' IDs (RxCUI numerics, AUI atom IDs) are collected for display but not
#' expanded because the UMLS REST API returns 404 for them.
#'
#' @param root_cui          Root concept CUI.
#' @param max_depth         Maximum hops from root (default 2).
#' @param expand_n          Max nodes to expand per depth level (controls API calls).
#' @param progress          Optional progress callback function(message).
#' @param fetch_medrt_root  If TRUE (default), the root node fetches MED-RT
#'                          drug-disease relations from RxNav on cache miss.
#'                          BFS neighbors (depth > 0) always run in cache-only
#'                          mode regardless. Set FALSE on sub-walks invoked
#'                          by the densifier — the seed already has its
#'                          drug-disease data, and re-fetching for a parent
#'                          / subtype just adds latency.
#' @return Tibble of all collected relations with depth and via columns.
bfs_walk <- function(root_cui, max_depth = 2L, expand_n = 8L,
                     progress = NULL, fetch_medrt_root = TRUE) {
  visited  <- character()
  # queue entries: list(cui, source_url, depth, via)
  # source_url is carried for lazy CUI resolution when the node is dequeued.
  queue    <- list(list(cui = root_cui, source_url = "",
                        depth = 0L, via = NA_character_))
  all_rels <- list()
  # Track how many nodes we have expanded at each depth > 0
  expanded_at_depth <- integer(max_depth + 1L)

  while (length(queue) > 0) {
    node  <- queue[[1]]
    queue <- queue[-1]

    # Check depth and budget cap BEFORE resolution — the queue can be large
    # and resolving every node before knowing whether to skip it would make
    # hundreds of wasted API calls.
    if (node$depth > max_depth) next
    if (node$depth > 0L && expanded_at_depth[node$depth] >= expand_n) next

    # Lazy resolution: only nodes that pass the budget check get resolved.
    effective_cui <- node$cui
    if (!is_umls_cui(effective_cui)) {
      effective_cui <- resolve_source_url_to_cui(node$source_url)
      if (is.na(effective_cui)) next
    }

    if (effective_cui %in% visited) next

    # Commit to expanding this node
    if (node$depth > 0L) {
      expanded_at_depth[node$depth] <- expanded_at_depth[node$depth] + 1L
    }

    visited <- c(visited, effective_cui)

    # Only the seed (depth 0) pays the RxNav round-trip on a MED-RT cache
    # miss; deeper BFS nodes run cache-only so a single walk doesn't fire
    # 30+ sequential HTTP calls. Sub-walks invoked by the densifier opt out
    # entirely via fetch_medrt_root = FALSE.
    medrt_for_this_node <- isTRUE(fetch_medrt_root) && node$depth == 0L

    if (!is.null(progress)) {
      msg <- if (is.na(node$via)) {
        if (medrt_for_this_node) {
          paste0("Fetching root concept relations ",
                 "(drug-disease lookup via NLM RxNav — may take 5-10s ",
                 "on first walk of a new concept)...")
        } else {
          "Fetching root concept relations..."
        }
      } else {
        paste0("[depth ", node$depth, "] ", node$via)
      }
      progress(msg)
    }

    rels <- tryCatch({
      umls_get_relations(effective_cui, fetch_medrt = medrt_for_this_node) |>
        categorize_relations() |>
        dplyr::mutate(
          depth    = node$depth,
          via      = node$via,
          from_cui = effective_cui    # who these relations came from
        )
    }, error = \(e) NULL)

    if (is.null(rels) || nrow(rels) == 0) {
      Sys.sleep(0.15)
      next
    }

    # At depth > 0, suppress categories that are only useful when the concept
    # is the root (pharmaceutical product variants, admin "other" noise).
    # Clinical categories (monitoring_lab, treatment, comorbidity, etc.) are kept.
    if (node$depth > 0L) {
      rels <- rels |>
        dplyr::filter(!category %in% c("pharmaceutical", "other", "other_rela",
                                       "broader", "narrower"))
    }
    if (nrow(rels) == 0) { Sys.sleep(0.15); next }

    all_rels[[length(all_rels) + 1]] <- rels

    # Queue children from expandable categories.
    # Source-vocabulary IDs (RxNorm numerics, AUI atoms) are only worth
    # resolving for treatment and etiology: those are the paths that lead to
    # monitoring labs and diagnostic test code lists.  For comorbidity/parent/
    # subtype/associated the depth-0 collection already captured the names;
    # expanding their resolved CUIs would pull in large disease ontologies and
    # add thousands of noisy rows.
    if (node$depth < max_depth) {
      children <- rels |>
        dplyr::filter(
          category %in% BFS_EXPAND_CATEGORIES,
          !related_cui %in% visited
        ) |>
        dplyr::arrange(nchar(rela) == 0, nchar(related_name))

      resolve_cats <- c("treatment", "etiology")

      for (i in seq_len(nrow(children))) {
        child_cui  <- children$related_cui[i]
        child_name <- children$related_name[i]
        child_cat  <- children$category[i]

        # For non-C CUIs: only carry the source URL if the category benefits
        # from deep resolution.  Others are skipped (display only at depth 0).
        child_url <- ""
        if (!is_umls_cui(child_cui)) {
          if (!child_cat %in% resolve_cats) next
          child_url <- children$related_id_url[i] %||% ""
        }

        if (!child_cui %in% visited) {
          via_label <- if (is.na(node$via)) child_name
                       else paste0(node$via, " → ", child_name)
          queue[[length(queue) + 1]] <- list(
            cui        = child_cui,
            source_url = child_url,
            depth      = node$depth + 1L,
            via        = via_label
          )
        }
      }
    }

    Sys.sleep(0.15)
  }

  if (length(all_rels) == 0) return(.empty_relations_tibble())

  purrr::list_rbind(all_rels) |>
    # Keep first occurrence of each (related_cui, category) pair —
    # shallowest path wins (queue is FIFO so depth order is preserved)
    dplyr::distinct(related_cui, category, .keep_all = TRUE)
}

# Canonical zero-row, fully-typed relations tibble. Returned when a walk
# produces no relations (true UMLS leaf, 404, network failure). All
# downstream code assumes these columns exist; an empty tibble with no
# columns crashes dplyr verbs that reference `related_cui` etc.
.empty_relations_tibble <- function() {
  tibble::tibble(
    cui            = character(0),
    related_cui    = character(0),
    related_name   = character(0),
    rel            = character(0),
    rela           = character(0),
    related_id_url = character(0),
    category       = character(0),
    depth          = integer(0),
    via            = character(0),
    from_cui       = character(0)
  )
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Walk the UMLS concept DAG from a root CUI.
#'
#' Performs BFS up to max_depth hops, collecting clinical relations at every
#' level. Nodes in BFS_EXPAND_CATEGORIES are queued for further traversal;
#' leaf categories (labs, anatomy, procedures) are collected but not expanded.
#'
#' @param cui              Root CUI.
#' @param max_depth        Hops from root (1 = direct relations only; 2 = default).
#' @param expand_n         Max nodes expanded per depth level (caps API calls).
#' @param progress         Optional progress callback.
#' @param fetch_medrt_root If TRUE (default), the root node fetches MED-RT
#'                         from RxNav on cache miss. Set FALSE for densifier
#'                         sub-walks where the seed has already paid the cost.
#' @return Named list: concept, relations, treatments, comorbidities,
#'   procedures, anatomy, subtypes, parents, diagnostic_labs,
#'   monitoring_labs, etiology, genetic, interpretation, contraindications.
walk_concept_dag <- function(cui, max_depth = 2L, expand_n = 8L,
                             progress = NULL, fetch_medrt_root = TRUE) {
  if (!is.null(progress)) progress("Fetching concept details...")
  concept <- umls_get_concept(cui)

  all_rels <- bfs_walk(cui,
                       max_depth        = max_depth,
                       expand_n         = expand_n,
                       progress         = progress,
                       fetch_medrt_root = fetch_medrt_root)

  # MRSTY-based reclassification: route concepts to their clinical category
  # by semantic type, not just by surfacing rela. Fixes the procedure-tab
  # desync where procedure-flavored concepts arrive via inverse_isa and end
  # up in `subtypes` instead of `procedures` (user-reported Atrial Tumor bug).
  all_rels <- reclassify_by_sty(all_rels)

  extract <- function(cats) {
    # Preserve column structure even when no rows match — combine_dags's
    # bind_distinct uses dplyr::distinct(related_cui, ...) which crashes
    # on a 0-column tibble.
    all_rels |> dplyr::filter(category %in% cats)
  }

  list(
    concept          = concept,
    relations        = all_rels,
    treatments       = extract("treatment"),
    comorbidities    = extract("comorbidity"),
    procedures       = extract("procedure"),
    anatomy          = extract("anatomy"),
    subtypes         = extract("subtype"),
    parents          = extract("parent"),
    etiology         = extract("etiology"),
    genetic          = extract("genetic"),
    interpretation   = extract("interpretation"),
    contraindications = extract("contraindication"),
    diagnostic_labs  = extract("diagnostic_lab"),
    monitoring_labs  = extract("monitoring_lab")
  )
}

#' Count visible nodes a DAG would produce in build_dag_network.
.dag_visible_count <- function(dag) {
  if (is.null(dag) || is.null(dag$concept)) return(0L)
  1L +  # root
    nrow(dag$treatments)      +
    nrow(dag$comorbidities)   +
    nrow(dag$procedures)      +
    nrow(dag$diagnostic_labs) +
    nrow(dag$anatomy)         +
    nrow(dag$subtypes)        +
    nrow(dag$parents)         +
    nrow(dag$etiology)
}

#' Merge dag_b's relations into dag_a, attributing them to dag_b$concept.
#'
#' Each row already carries `from_cui` (the concept whose relations produced
#' it). For relations from dag_b, from_cui is dag_b$concept$cui or its BFS
#' descendants — meaning edges in build_dag_network will originate from the
#' right anchor automatically.
#'
#' Caller can pass link_via = list(rela = "isa") to record how dag_a$concept
#' connects to dag_b$concept. The link is added as a "parent" or "subtype"
#' row attributed from_cui = dag_a$concept$cui.
#'
#' Both DAGs must have populated $concept; concept is preserved from dag_a.
combine_dags <- function(dag_a, dag_b,
                         link_rela = "isa",
                         link_category = "parent") {
  if (is.null(dag_b) || is.null(dag_b$concept)) return(dag_a)

  bind_distinct <- function(a, b) {
    if (is.null(b) || nrow(b) == 0) return(a)
    # If `a` was an untyped empty tibble (no columns), adopt b's structure
    # so dplyr verbs below can find `related_cui`.
    if (is.null(a) || ncol(a) == 0) a <- b[FALSE, , drop = FALSE]
    common <- intersect(names(a), names(b))
    if (length(common) == 0) return(a)
    a2 <- a[, common, drop = FALSE]
    b2 <- b[, common, drop = FALSE]
    bound <- dplyr::bind_rows(a2, b2)
    # Relationships are edges, not nodes — dedupe on (from_cui, related_cui,
    # rela) so click-to-extend can add an edge from the clicked concept back
    # into an existing node. Keying solely on related_cui silently dropped
    # those edges and was a major source of disconnected star clutter.
    if (all(c("from_cui", "related_cui", "rela") %in% names(bound))) {
      bound <- bound |>
        dplyr::distinct(from_cui, related_cui, rela, .keep_all = TRUE)
    } else if ("related_cui" %in% names(bound)) {
      bound <- bound |> dplyr::distinct(related_cui, .keep_all = TRUE)
    }
    bound
  }

  result <- dag_a

  # Optional synthetic link row connecting dag_a$concept → dag_b$concept.
  # Skipped when link_rela=NULL — used by extend_concept_dag because the
  # clicked node is already in the graph and the new walk's from_cui values
  # naturally connect new edges to it.
  if (!is.null(link_rela)) {
    # umls_get_concept returns a "(CXXX — not found)" stub when the CUI
    # can't be resolved. That stub would land on the visible node label
    # since clean_node_label's ^C\d+$ regex doesn't match it. Drop the
    # stub here and let make_category_rows' last-mile resolver substitute
    # an actual UMLS name (or the "(unnamed)" marker) instead.
    link_name <- dag_b$concept$name
    if (!is.null(link_name) &&
        grepl("not found", link_name, fixed = TRUE)) {
      link_name <- NA_character_
    }
    link_row <- tibble::tibble(
      related_cui  = dag_b$concept$cui,
      related_name = link_name,
      rela         = link_rela,
      rel          = "",
      category     = link_category,
      depth        = 0L,
      via          = NA_character_,
      from_cui     = dag_a$concept$cui
    )
    cat_for_link <- switch(link_category,
                           parent  = "parents",
                           subtype = "subtypes",
                           "parents")
    result[[cat_for_link]] <- bind_distinct(result[[cat_for_link]], link_row)
  }

  result$treatments      <- bind_distinct(result$treatments,      dag_b$treatments)
  result$comorbidities   <- bind_distinct(result$comorbidities,   dag_b$comorbidities)
  result$procedures      <- bind_distinct(result$procedures,      dag_b$procedures)
  result$diagnostic_labs <- bind_distinct(result$diagnostic_labs, dag_b$diagnostic_labs)
  result$monitoring_labs <- bind_distinct(result$monitoring_labs, dag_b$monitoring_labs)
  result$anatomy         <- bind_distinct(result$anatomy,         dag_b$anatomy)
  result$subtypes        <- bind_distinct(result$subtypes,        dag_b$subtypes)
  result$parents         <- bind_distinct(result$parents,         dag_b$parents)
  result$etiology        <- bind_distinct(result$etiology,        dag_b$etiology)

  if (!is.null(dag_b$relations) && nrow(dag_b$relations) > 0) {
    common <- intersect(names(result$relations), names(dag_b$relations))
    result$relations <- dplyr::bind_rows(
      result$relations[, common, drop = FALSE],
      dag_b$relations[, common, drop = FALSE]
    ) |> dplyr::distinct(related_cui, category, .keep_all = TRUE)
  }
  result
}

#' Densified DAG walk: standard walk + parent/sibling supplementation.
#'
#' Strategy:
#'   1. Standard walk_concept_dag at the seed CUI.
#'   2. If visible-node count < min_visible AND root has parents:
#'        a. Walk the first parent (depth 1, cheap).
#'        b. Merge into result with the parent linked via `isa`.
#'   3. If still sparse, walk the first subtype (depth 1) and merge.
#'   4. Stop — further expansion crosses too many semantic boundaries.
#'
#' Each merged sub-walk's relations carry their own from_cui values so that
#' build_dag_network draws edges from the correct anchor concept.
walk_concept_dag_dense <- function(cui, max_depth = 2L, expand_n = 8L,
                                   min_visible = 25L, progress = NULL) {
  base <- walk_concept_dag(cui, max_depth = max_depth,
                           expand_n = expand_n, progress = progress)

  if (.dag_visible_count(base) >= min_visible) return(base)

  # Generic single-word catch-all parents are noise — walking them returns
  # only hierarchy relations to other generic concepts. Skip these by name.
  GENERIC_PARENTS <- c("syndrome", "disease", "disorder", "finding",
                       "condition", "abnormality", "process", "procedure")
  is_generic_name <- function(n) {
    if (is.na(n)) return(TRUE)
    tolower(trimws(n)) %in% GENERIC_PARENTS
  }

  # Resolve a row's CUI: return its UMLS CUI directly, or resolve from
  # source URL if the row is a SNOMED/RxNorm/etc id. NA if unresolvable.
  resolve_row_cui <- function(row) {
    if (is_umls_cui(row$related_cui)) return(row$related_cui)
    url <- if ("related_id_url" %in% names(row)) row$related_id_url else ""
    if (is.na(url) || !nzchar(url)) return(NA_character_)
    cui <- resolve_source_url_to_cui(url)
    if (is.na(cui) || !is_umls_cui(cui)) NA_character_ else cui
  }

  # Walk a list of candidate rows in order, merging each, until we cross
  # the visibility threshold or exhaust the list. Caps API calls at `max_calls`.
  expand_via <- function(base, candidates, link_category, max_calls = 4L) {
    if (is.null(candidates) || nrow(candidates) == 0) return(base)
    calls <- 0L
    for (i in seq_len(nrow(candidates))) {
      if (calls >= max_calls) break
      if (.dag_visible_count(base) >= min_visible) break
      row <- candidates[i, , drop = FALSE]
      if (is_generic_name(row$related_name)) next
      target_cui <- resolve_row_cui(row)
      if (is.na(target_cui)) next
      if (!is.null(progress)) {
        progress(paste0("Densifying via ", link_category, ": ", row$related_name))
      }
      # Use depth=2 so that walking a sparse parent still picks up its
      # parent-of-parent relations — handles chains of leaf concepts where
      # each link in the chain has only one relation (its own parent).
      sub_depth <- if (link_category == "parent") 2L else 1L
      # Densifier sub-walks expand hierarchy / lexical neighbors; they
      # don't need their own MED-RT fetch (the seed already has its
      # drug-disease relations, and refetching for parents adds latency
      # without clinical value).
      sub_dag <- tryCatch(
        walk_concept_dag(target_cui, max_depth = sub_depth,
                         expand_n = expand_n, fetch_medrt_root = FALSE),
        error = function(e) NULL
      )
      calls <- calls + 1L
      if (is.null(sub_dag)) next
      base <- combine_dags(
        base, sub_dag,
        link_rela = row$rela %||% (if (link_category == "parent") "isa" else "inverse_isa"),
        link_category = link_category
      )
    }
    base
  }

  # Tier 1: parents (walk up to 4)
  base <- expand_via(base, base$parents, "parent", max_calls = 4L)
  if (.dag_visible_count(base) >= min_visible) return(base)

  # Tier 2: subtypes (walk up to 2)
  base <- expand_via(base, base$subtypes, "subtype", max_calls = 2L)
  if (.dag_visible_count(base) >= min_visible) return(base)

  # Tier 3: progressive-truncation lexical search. Concept has no neighbors
  # via parents or subtypes — search increasingly broad name variants to
  # find a non-leaf umbrella concept. Handles OMIM-style suffixed names
  # ("VENTRICULAR TACHYCARDIA, CATECHOLAMINERGIC POLYMORPHIC, 3" →
  #  "VENTRICULAR TACHYCARDIA, CATECHOLAMINERGIC POLYMORPHIC" →
  #  "VENTRICULAR TACHYCARDIA").
  cname <- base$concept$name %||% ""
  if (nzchar(cname) && !grepl("not found", cname, fixed = TRUE)) {
    cname <- sub("\\s*\\([^)]+\\)\\s*$", "", cname)        # strip "(disorder)"
    queries <- unique(c(
      cname,
      sub(",[^,]+$", "", cname),                          # drop trailing comma-clause
      sub(",[^,]+,[^,]+$", "", cname),                    # drop two trailing clauses
      stringr::word(cname, 1L, 2L),                       # first two words only
      stringr::word(cname, 1L, 1L)                        # first word only
    ))
    queries <- queries[nzchar(queries) & nchar(queries) >= 4L]
    queries <- queries[!duplicated(tolower(queries))]
    for (q in queries) {
      if (.dag_visible_count(base) >= min_visible) break
      if (!is.null(progress)) progress(paste0("Trying lexical neighbors: \"", q, "\""))
      hits <- tryCatch(umls_search(q, max_results = 5L),
                       error = function(e) tibble::tibble())
      if (nrow(hits) == 0) next
      hits <- hits[hits$cui != base$concept$cui, , drop = FALSE]
      if (nrow(hits) == 0) next
      candidates <- tibble::tibble(
        related_cui    = hits$cui,
        related_name   = hits$name,
        rela           = "lexical_neighbor",
        related_id_url = ""
      )
      base <- expand_via(base, candidates, "parent", max_calls = 2L)
    }
  }

  # Tier 4: MRSTY-typed direct-neighbor fallback. When the standard walk +
  # densifier still leaves procedures or labs empty, query mrrel_bidir
  # joined to mrsty for direct neighbors of the seed CUI whose semantic
  # type is procedure/lab. Closes the recall gap for narrow concepts whose
  # surfacing rela is not in RELA_CATEGORIES.
  base <- mrsty_typed_fallback(base, cui, progress = progress)

  base
}

#' MRSTY-typed direct-neighbor fallback for empty procedure / lab buckets.
#'
#' Used after the standard densifier when categories of interest are still
#' empty. Adds rows to base$procedures or base$diagnostic_labs (and to
#' base$relations) with the same column shape as the BFS output, attributed
#' from_cui = seed_cui so build_dag_network draws edges from the root.
mrsty_typed_fallback <- function(base, seed_cui, progress = NULL) {
  if (is.null(base)) return(base)
  if (!exists("umls_get_neighbors_by_sty", mode = "function")) return(base)

  targets <- list(
    procedure       = list(field = "procedures",
                           stys  = STY_TO_CATEGORY$procedure),
    diagnostic_lab  = list(field = "diagnostic_labs",
                           stys  = STY_TO_CATEGORY$diagnostic_lab),
    treatment       = list(field = "treatments",
                           stys  = STY_TO_CATEGORY$treatment)
  )

  # Fire the fallback whenever the typed bucket is meaningfully sparse, not
  # only when it's literally empty. One stray focus_of edge should not block
  # the typed query from filling the bucket up to a useful size.
  SPARSE_THRESHOLD <- 3L

  for (cat in names(targets)) {
    field <- targets[[cat]]$field
    current <- base[[field]]
    if (!is.null(current) && nrow(current) >= SPARSE_THRESHOLD) next

    if (!is.null(progress)) {
      progress(paste0("MRSTY fallback: ", cat))
    }
    neigh <- tryCatch(
      umls_get_neighbors_by_sty(seed_cui, targets[[cat]]$stys, limit = 25L),
      error = function(e) NULL
    )
    if (is.null(neigh) || nrow(neigh) == 0) next

    addn <- neigh |>
      dplyr::mutate(
        category = !!cat,
        depth    = 1L,
        via      = "sty_fallback",
        from_cui = seed_cui
      )

    # Dedupe on the same edge key combine_dags now uses, so a typed-fallback
    # row whose related_cui already exists from a different from_cui doesn't
    # collide with the existing edge.
    dedupe_keys <- intersect(c("from_cui", "related_cui", "rela"), names(addn))
    addn <- addn |> dplyr::distinct(dplyr::across(dplyr::all_of(dedupe_keys)),
                                    .keep_all = TRUE)

    base[[field]] <- if (is.null(current) || ncol(current) == 0) {
      addn
    } else {
      common <- intersect(names(current), names(addn))
      dplyr::bind_rows(current[, common, drop = FALSE],
                       addn[, common, drop = FALSE]) |>
        dplyr::distinct(dplyr::across(dplyr::all_of(
          intersect(dedupe_keys, common))), .keep_all = TRUE)
    }

    if (!is.null(base$relations) && nrow(base$relations) > 0) {
      common <- intersect(names(base$relations), names(addn))
      base$relations <- dplyr::bind_rows(
        base$relations[, common, drop = FALSE],
        addn[, common, drop = FALSE]
      ) |> dplyr::distinct(related_cui, category, .keep_all = TRUE)
    } else {
      base$relations <- addn
    }
  }
  base
}

#' Extend an existing DAG by walking a clicked node and merging.
#'
#' The clicked node's id may be a UMLS CUI ("C0004238") or a source-vocab
#' identifier (RxNorm "736680", SNOMED "429211003", AUI "A1617387"). For
#' non-CUI ids, the function looks up the original `related_id_url` from the
#' existing DAG's relations and resolves it to a UMLS CUI before walking.
#'
#' Returns the existing DAG unchanged if the click cannot be resolved to a
#' walkable concept or the walk produces no new relations.
extend_concept_dag <- function(existing_dag, new_id,
                               max_depth = 1L, expand_n = 8L,
                               progress = NULL) {
  if (is.null(new_id) || !nzchar(new_id)) return(existing_dag)

  # Resolve to a UMLS CUI
  cui <- if (is_umls_cui(new_id)) {
    new_id
  } else {
    if (!is.null(progress)) progress("Resolving source-vocab id...")
    rels <- existing_dag$relations
    if (is.null(rels) || nrow(rels) == 0) return(existing_dag)
    if (!"related_id_url" %in% names(rels)) return(existing_dag)
    matches <- rels[rels$related_cui == new_id & nzchar(rels$related_id_url %||% ""), ,
                    drop = FALSE]
    if (nrow(matches) == 0) return(existing_dag)
    resolved <- tryCatch(resolve_source_url_to_cui(matches$related_id_url[1]),
                         error = function(e) NA_character_)
    if (is.na(resolved) || !is_umls_cui(resolved)) return(existing_dag)
    resolved
  }

  if (!is.null(progress)) progress(paste0("Expanding around ", cui, "..."))
  new_walk <- tryCatch(
    walk_concept_dag(cui, max_depth = max_depth, expand_n = expand_n,
                     progress = progress),
    error = function(e) NULL
  )
  if (is.null(new_walk) || isTRUE(new_walk$concept$not_found)) return(existing_dag)

  # Rewrite from_cui in the new walk's relations: BFS attributed them to the
  # resolved UMLS CUI, but the rendered graph's node id is the original
  # source-vocab id the user clicked. Use that so edges connect correctly.
  if (cui != new_id && !is.null(new_walk$relations) && nrow(new_walk$relations) > 0) {
    new_walk$relations$from_cui[new_walk$relations$from_cui == cui] <- new_id
    rewrite_cat <- function(tbl) {
      if (is.null(tbl) || nrow(tbl) == 0) return(tbl)
      if ("from_cui" %in% names(tbl)) {
        tbl$from_cui[tbl$from_cui == cui] <- new_id
      }
      tbl
    }
    for (k in c("treatments","comorbidities","procedures","diagnostic_labs",
                "monitoring_labs","anatomy","subtypes","parents","etiology")) {
      new_walk[[k]] <- rewrite_cat(new_walk[[k]])
    }
  }

  combine_dags(existing_dag, new_walk, link_rela = NULL)
}

#' Walk a single PICO element (intervention, comparator, or outcome).
#'
#' Uses depth-1 only — PICO elements are already specific enough that
#' deep BFS would wander.
#'
#' @param cui     CUI for this PICO element.
#' @param element "intervention", "comparator", or "outcome".
#' @param progress Status callback.
walk_pico_element <- function(cui, element, progress = NULL) {
  if (!is.null(progress)) progress(paste0("Walking ", element, "..."))

  concept   <- umls_get_concept(cui)
  relations <- umls_get_relations(cui) |> categorize_relations() |>
    dplyr::mutate(depth = 0L, via = NA_character_)

  result <- list(concept = concept, relations = relations, element = element)

  if (element %in% c("intervention", "comparator")) {
    result$monitoring_labs <- relations |>
      dplyr::filter(category == "monitoring_lab")
    result$also_treats <- relations |>
      dplyr::filter(category == "treatment")
  }

  if (element == "outcome") {
    result$related_conditions <- relations |>
      dplyr::filter(category %in% c("comorbidity", "associated"))
    result$subtypes <- relations |>
      dplyr::filter(category == "subtype")
  }

  result
}
