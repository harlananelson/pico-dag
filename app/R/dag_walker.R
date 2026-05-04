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
#' @param root_cui     Root concept CUI.
#' @param max_depth    Maximum hops from root (default 2).
#' @param expand_n     Max nodes to expand per depth level (controls API calls).
#' @param progress     Optional progress callback function(message).
#' @return Tibble of all collected relations with depth and via columns.
bfs_walk <- function(root_cui, max_depth = 2L, expand_n = 8L, progress = NULL) {
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

    if (!is.null(progress)) {
      msg <- if (is.na(node$via)) {
        "Fetching root concept relations..."
      } else {
        paste0("[depth ", node$depth, "] ", node$via)
      }
      progress(msg)
    }

    rels <- tryCatch({
      umls_get_relations(effective_cui) |>
        categorize_relations() |>
        dplyr::mutate(
          depth = node$depth,
          via   = node$via
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

  if (length(all_rels) == 0) return(tibble::tibble())

  purrr::list_rbind(all_rels) |>
    # Keep first occurrence of each (related_cui, category) pair —
    # shallowest path wins (queue is FIFO so depth order is preserved)
    dplyr::distinct(related_cui, category, .keep_all = TRUE)
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
#' @param cui          Root CUI.
#' @param max_depth    Hops from root (1 = direct relations only; 2 = default).
#' @param expand_n     Max nodes expanded per depth level (caps API calls).
#' @param progress     Optional progress callback.
#' @return Named list: concept, relations, treatments, comorbidities,
#'   procedures, anatomy, subtypes, parents, diagnostic_labs,
#'   monitoring_labs, etiology, genetic, interpretation, contraindications.
walk_concept_dag <- function(cui, max_depth = 2L, expand_n = 8L,
                             progress = NULL) {
  if (!is.null(progress)) progress("Fetching concept details...")
  concept <- umls_get_concept(cui)

  all_rels <- bfs_walk(cui,
                       max_depth = max_depth,
                       expand_n  = expand_n,
                       progress  = progress)

  extract <- function(cats) {
    if (nrow(all_rels) == 0) return(tibble::tibble())
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
    diagnostic_labs  = extract(c("diagnostic_lab", "monitoring_lab")),
    monitoring_labs  = tibble::tibble()   # kept for UI compatibility
  )
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
