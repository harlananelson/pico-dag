#' DAG walker — BFS traversal of UMLS concept graph

# ---------------------------------------------------------------------------
# RELA → clinical category mapping
# ---------------------------------------------------------------------------

RELA_CATEGORIES <- c(
  "may_be_treated_by"      = "treatment",
  "may_treat"              = "treatment",
  "has_finding_site"       = "anatomy",
  "finding_site_of"        = "anatomy",
  "component_of"           = "monitoring_lab",
  "has_component"          = "monitoring_lab",
  "clinically_associated_with" = "comorbidity",
  "co-occurs_with"         = "comorbidity",
  "cause_of"               = "comorbidity",
  "focus_of"               = "procedure",
  "inverse_isa"            = "subtype",
  "isa"                    = "parent",
  "manifestation_of"       = "genetic",
  "has_causative_agent"    = "etiology",
  "causative_agent_of"     = "etiology",
  "has_interpretation"     = "interpretation",
  "interprets"             = "interpretation",
  "associated_with"        = "associated",
  "associated_finding_of"  = "associated",
  "has_evaluation"         = "diagnostic_lab",
  "evaluated_by"           = "diagnostic_lab",
  "has_associated_finding" = "diagnostic_lab",
  "finding_of"             = "diagnostic_lab",
  "diagnoses"              = "diagnostic_lab",
  "diagnosed_by"           = "diagnostic_lab",
  "has_finding"            = "diagnostic_lab"
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
#' @param root_cui     Root concept CUI.
#' @param max_depth    Maximum hops from root (default 2).
#' @param expand_n     Max nodes to expand per depth level (controls API calls).
#' @param progress     Optional progress callback function(message).
#' @return Tibble of all collected relations with depth and via columns.
bfs_walk <- function(root_cui, max_depth = 2L, expand_n = 8L, progress = NULL) {
  visited  <- character()
  # queue entries: list(cui, depth, via)
  queue    <- list(list(cui = root_cui, depth = 0L, via = NA_character_))
  all_rels <- list()
  # Track how many nodes we have expanded at each depth > 0
  expanded_at_depth <- integer(max_depth + 1L)

  while (length(queue) > 0) {
    node  <- queue[[1]]
    queue <- queue[-1]

    if (node$cui %in% visited)        next
    if (node$depth > max_depth)        next
    # Cap expansions at depth > 0
    if (node$depth > 0L) {
      if (expanded_at_depth[node$depth] >= expand_n) next
      expanded_at_depth[node$depth] <- expanded_at_depth[node$depth] + 1L
    }

    visited <- c(visited, node$cui)

    if (!is.null(progress)) {
      msg <- if (is.na(node$via)) {
        "Fetching root concept relations..."
      } else {
        paste0("[depth ", node$depth, "] ", node$via)
      }
      progress(msg)
    }

    rels <- tryCatch({
      umls_get_relations(node$cui) |>
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

    all_rels[[length(all_rels) + 1]] <- rels

    # Queue children from expandable categories
    if (node$depth < max_depth) {
      children <- rels |>
        dplyr::filter(
          category %in% BFS_EXPAND_CATEGORIES,
          !related_cui %in% visited
        ) |>
        # Prioritise: named rela over blank, shorter names first as a tiebreak
        dplyr::arrange(nchar(rela) == 0, nchar(related_name))

      for (i in seq_len(nrow(children))) {
        child_cui  <- children$related_cui[i]
        child_name <- children$related_name[i]
        if (!child_cui %in% visited) {
          via_label <- if (is.na(node$via)) child_name
                       else paste0(node$via, " → ", child_name)
          queue[[length(queue) + 1]] <- list(
            cui   = child_cui,
            depth = node$depth + 1L,
            via   = via_label
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
#'   monitoring_labs, etiology, genetic, interpretation.
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
    concept        = concept,
    relations      = all_rels,
    treatments     = extract("treatment"),
    comorbidities  = extract("comorbidity"),
    procedures     = extract("procedure"),
    anatomy        = extract("anatomy"),
    subtypes       = extract("subtype"),
    parents        = extract("parent"),
    etiology       = extract("etiology"),
    genetic        = extract("genetic"),
    interpretation = extract("interpretation"),
    diagnostic_labs = extract(c("diagnostic_lab", "monitoring_lab")),
    monitoring_labs = tibble::tibble()   # kept for UI compatibility
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
