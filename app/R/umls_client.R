#' UMLS REST API client for pico-dag
#'
#' Wraps UMLS REST API v2 with httr2.
#' API key from UMLS_API_KEY environment variable.

# --- Configuration ---

UMLS_BASE_URL <- "https://uts-ws.nlm.nih.gov/rest"

get_api_key <- function() {
  key <- Sys.getenv("UMLS_API_KEY", "")
  if (nchar(key) == 0) {
    stop("UMLS_API_KEY environment variable not set")
  }
  key
}

# --- Search ---

#' Search UMLS for a concept by name
#'
#' @param term Character. Search term
#' @param max_results Integer. Max results to return
#' @return Tibble with cui, name, semantic_types
umls_search <- function(term, max_results = 10) {
  resp <- httr2::request(UMLS_BASE_URL) |>
    httr2::req_url_path_append("search", "current") |>
    httr2::req_url_query(
      apiKey = get_api_key(),
      string = term,
      pageSize = max_results,
      searchType = "words"
    ) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  results <- resp$result$results
  if (length(results) == 0) return(tibble::tibble())

  purrr::map(results, \(r) {
    tibble::tibble(
      cui = r$ui %||% "",
      name = r$name %||% "",
      root_source = r$rootSource %||% "",
    )
  }) |>
    purrr::list_rbind()
}

# --- Concept details ---

#' Get concept details by CUI
#'
#' @param cui Character. UMLS CUI
#' @return List with name, semantic_types, atom_count
umls_get_concept <- function(cui) {
  resp <- httr2::request(UMLS_BASE_URL) |>
    httr2::req_url_path_append("content", "current", "CUI", cui) |>
    httr2::req_url_query(apiKey = get_api_key()) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  result <- resp$result
  list(
    cui = result$ui %||% cui,
    name = result$name %||% "",
    semantic_types = purrr::map_chr(
      result$semanticTypes %||% list(),
      \(st) st$name %||% ""
    ),
    atom_count = result$atomCount %||% 0
  )
}

# --- Relations ---

#' Get ALL relations for a CUI (paginated)
#'
#' @param cui Character. UMLS CUI
#' @return Tibble with cui, related_cui, related_name, rel, rela
umls_get_relations <- function(cui) {
  all_results <- list()
  page <- 1

  repeat {
    resp <- httr2::request(UMLS_BASE_URL) |>
      httr2::req_url_path_append("content", "current", "CUI", cui, "relations") |>
      httr2::req_url_query(
        apiKey = get_api_key(),
        pageSize = 200,
        pageNumber = page
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    results <- resp$result
    if (length(results) == 0) break
    all_results <- c(all_results, results)
    if (length(results) < 200) break
    page <- page + 1
  }

  if (length(all_results) == 0) return(tibble::tibble())

  purrr::map(all_results, \(item) {
    related_id <- item$relatedId %||% ""
    tibble::tibble(
      cui = cui,
      related_cui = if (nchar(related_id) > 0) {
        stringr::str_extract(related_id, "[^/]+$")
      } else "",
      related_name = item$relatedIdName %||% "",
      rel = item$relationLabel %||% "",
      rela = item$additionalRelationLabel %||% "",
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::filter(
      !rela %in% c("translation_of", "has_translation"),
      nchar(related_cui) > 0
    ) |>
    dplyr::distinct(related_cui, rela, .keep_all = TRUE)
}

# --- Source codes ---

#' Get source codes for a CUI in a vocabulary
#'
#' @param cui Character. UMLS CUI
#' @param vocabulary Character. e.g., "ICD10CM", "SNOMEDCT_US", "LNC", "RXNORM"
#' @return Tibble with code, name, vocabulary
umls_get_source_codes <- function(cui, vocabulary) {
  all_codes <- list()
  page <- 1

  repeat {
    resp <- httr2::request(UMLS_BASE_URL) |>
      httr2::req_url_path_append("content", "current", "CUI", cui, "atoms") |>
      httr2::req_url_query(
        apiKey = get_api_key(),
        sabs = vocabulary,
        pageSize = 200,
        pageNumber = page
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    results <- resp$result
    if (!is.list(results) || length(results) == 0) break

    for (atom in results) {
      code_uri <- atom$code %||% ""
      code <- if (nchar(code_uri) > 0) {
        stringr::str_extract(code_uri, "[^/]+$")
      } else ""

      all_codes[[length(all_codes) + 1]] <- tibble::tibble(
        code = code,
        name = atom$name %||% "",
        vocabulary = vocabulary,
        source_cui = cui,
      )
    }

    if (length(results) < 200) break
    page <- page + 1
  }

  if (length(all_codes) == 0) return(tibble::tibble())
  purrr::list_rbind(all_codes) |>
    dplyr::distinct(code, .keep_all = TRUE)
}
