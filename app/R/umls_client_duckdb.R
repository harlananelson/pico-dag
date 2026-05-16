#' UMLS DuckDB client for pico-dag
#'
#' Drop-in replacement for umls_client.R when the local UMLS DuckDB is present.
#' Falls back to REST API automatically if the DB file is not found.
#'
#' DB path: /srv/umls/umls.duckdb  (built by scripts/build_umls_db.R)

UMLS_DB_PATH <- "/srv/umls/umls.duckdb"

# --- Connection management ---

.umls_con <- NULL

umls_db_connect <- function() {
  if (!is.null(.umls_con) && DBI::dbIsValid(.umls_con)) return(.umls_con)
  if (!file.exists(UMLS_DB_PATH)) return(NULL)
  con <- DBI::dbConnect(duckdb::duckdb(), UMLS_DB_PATH, read_only = TRUE)
  assign(".umls_con", con, envir = .GlobalEnv)
  con
}

umls_db_available <- function() {
  con <- umls_db_connect()
  !is.null(con)
}

# --- Search ---

#' Search UMLS for a concept by name
#'
#' @param term Character. Search term
#' @param max_results Integer. Max results to return
#' @return Tibble with cui, name, root_source
umls_search <- function(term, max_results = 10) {
  con <- umls_db_connect()
  if (is.null(con)) return(umls_search_rest(term, max_results))

  pattern <- paste0("%", tolower(term), "%")
  DBI::dbGetQuery(con, "
    SELECT m.cui, m.str AS name, m.sab AS root_source
    FROM mrconso m
    WHERE lower(m.str) LIKE ?
      AND m.ispref = 'Y'
      AND m.tty    = 'PT'
      AND m.lat    = 'ENG'
    ORDER BY length(m.str)
    LIMIT ?
  ", params = list(pattern, as.integer(max_results))) |>
    tibble::as_tibble()
}

# --- Concept details ---

#' Get concept details by CUI
#'
#' @param cui Character. UMLS CUI
#' @return List with name, semantic_types, atom_count
umls_get_concept <- function(cui) {
  con <- umls_db_connect()
  if (is.null(con)) return(umls_get_concept_rest(cui))

  name_row <- DBI::dbGetQuery(con, "
    SELECT preferred_name FROM concept_preferred WHERE cui = ?
  ", params = list(cui))

  found_in_pref <- nrow(name_row) > 0
  name <- if (found_in_pref) name_row$preferred_name[1] else {
    fb <- DBI::dbGetQuery(con,
      "SELECT str FROM mrconso WHERE cui = ? AND lat = 'ENG' LIMIT 1",
      params = list(cui))
    if (nrow(fb) > 0) fb$str[1] else NA_character_
  }

  stys <- DBI::dbGetQuery(con,
    "SELECT sty FROM mrsty WHERE cui = ?",
    params = list(cui))$sty

  atom_count <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM mrconso WHERE cui = ?",
    params = list(cui))$n[1]

  not_found <- is.na(name) || atom_count == 0
  list(
    cui            = cui,
    name           = if (not_found) paste0("(", cui, " — not found)") else name,
    semantic_types = stys,
    atom_count     = as.integer(atom_count),
    not_found      = not_found
  )
}

# --- Relations ---

#' Get all relations for a CUI
#'
#' @param cui Character. UMLS CUI
#' @return Tibble with cui, related_cui, related_name, rel, rela, related_id_url
umls_get_relations <- function(cui) {
  con <- umls_db_connect()
  if (is.null(con)) return(umls_get_relations_rest(cui))

  # Layer 1: bidirectional MRREL view — UMLS-merged relations (both directions
  # with rela inverted via MRDOC). Misses the "orphan rows" where MRREL stores
  # a relation with empty CUI1/AUI1/SAB.
  bidir <- DBI::dbGetQuery(con, "
    SELECT
      r.cui1        AS cui,
      r.cui2        AS related_cui,
      coalesce(cp.preferred_name, r.cui2) AS related_name,
      r.rel,
      coalesce(r.rela, '') AS rela,
      ''            AS related_id_url
    FROM mrrel_bidir r
    LEFT JOIN concept_preferred cp ON cp.cui = r.cui2
    WHERE r.cui1 = ?
  ", params = list(cui)) |>
    tibble::as_tibble() |>
    dplyr::filter(
      !rela %in% c("translation_of", "has_translation"),
      nchar(related_cui) > 0
    )

  # Layer 1b: MRHIER hierarchy edges — supplements MRREL's hierarchical
  # relations with paths that are encoded only in MRHIER (path-to-root view).
  # Adds parent (cui1=child→cui2=parent) and child edges (cui1=parent→
  # cui2=child) by querying both directions.
  hier <- tryCatch(DBI::dbGetQuery(con, "
    SELECT cui1, cui2, rela FROM (
      SELECT cui1, cui2, rela FROM mrhier_cui_edges WHERE cui1 = ?
      UNION ALL
      SELECT cui2 AS cui1, cui1 AS cui2, 'inverse_isa' AS rela
        FROM mrhier_cui_edges WHERE cui2 = ?
    )
  ", params = list(cui, cui)), error = function(e) NULL)
  if (!is.null(hier) && nrow(hier) > 0) {
    hier_compat <- DBI::dbGetQuery(con,
      "SELECT cui, preferred_name FROM concept_preferred WHERE cui IN (
         SELECT cui2 FROM mrhier_cui_edges WHERE cui1 = ?
         UNION SELECT cui1 FROM mrhier_cui_edges WHERE cui2 = ?
       )", params = list(cui, cui))
    name_lookup <- setNames(hier_compat$preferred_name, hier_compat$cui)
    hier <- tibble::tibble(
      cui            = hier$cui1,
      related_cui    = hier$cui2,
      related_name   = unname(name_lookup[hier$cui2]),
      rel            = ifelse(hier$rela == "isa", "PAR", "CHD"),
      rela           = hier$rela,
      related_id_url = ""
    ) |>
      dplyr::filter(!is.na(related_name) & nchar(related_cui) > 0)
    bidir <- dplyr::bind_rows(bidir, hier)
  }

  # Layer 2: MED-RT drug-disease relations from RxNav (cached locally).
  # These supply the may_be_treated_by / may_be_prevented_by / induced_by /
  # has_contraindicated_drug rows that NLM stores as orphan rows in MRREL.
  # Cached after first fetch, so this is free on subsequent walks.
  medrt <- if (exists("medrt_get_relations", mode = "function")) {
    tryCatch(medrt_get_relations(cui), error = function(e) NULL)
  } else NULL

  if (!is.null(medrt) && nrow(medrt) > 0) {
    medrt_compat <- tibble::tibble(
      cui            = medrt$cui,
      related_cui    = medrt$related_cui,
      related_name   = medrt$related_name,
      rel            = "RO",
      rela           = medrt$rela,
      related_id_url = ""
    )
    rels <- dplyr::bind_rows(bidir, medrt_compat)
  } else {
    rels <- bidir
  }

  rels |> dplyr::distinct(related_cui, rela, .keep_all = TRUE)
}

# --- Definitions (for tooltips) ---

#' Get the source-prioritized concept definition for a CUI.
#'
#' Returns a list with `cui`, `definition`, `source` from concept_definition
#' (which picks one definition per CUI prioritized by SAB: MSH > NCI >
#' SNOMEDCT_US > others). NULL if no definition found.
umls_get_definition <- function(cui) {
  con <- umls_db_connect()
  if (is.null(con)) return(NULL)
  res <- tryCatch(
    DBI::dbGetQuery(con,
      "SELECT cui, definition, def_sab AS source
       FROM concept_definition WHERE cui = ?",
      params = list(cui)),
    error = function(e) NULL
  )
  if (is.null(res) || nrow(res) == 0) return(NULL)
  list(cui = res$cui[1], definition = res$definition[1], source = res$source[1])
}

# --- Source codes ---

#' Get source codes for a CUI in a vocabulary
#'
#' @param cui Character. UMLS CUI
#' @param vocabulary Character. e.g. "ICD10CM", "SNOMEDCT_US", "LNC", "RXNORM"
#' @return Tibble with code, name, vocabulary, source_cui
umls_get_source_codes <- function(cui, vocabulary) {
  con <- umls_db_connect()
  if (is.null(con)) return(umls_get_source_codes_rest(cui, vocabulary))

  DBI::dbGetQuery(con, "
    SELECT DISTINCT
      m.code,
      m.str  AS name,
      m.sab  AS vocabulary,
      ?      AS source_cui
    FROM mrconso m
    WHERE m.cui = ?
      AND m.sab = ?
      AND m.code != 'NOCODE'
      AND m.suppress NOT IN ('O', 'E')
  ", params = list(cui, cui, vocabulary)) |>
    tibble::as_tibble()
}

# --- LOINC class (replaces .loinc_class_number) ---

#' Get LOINC class number for a LOINC code (1=Lab, 2=Clinical, 3=Claims, 4=Survey)
.loinc_class_number <- function(loinc_code) {
  con <- umls_db_connect()
  if (is.null(con)) return(.loinc_class_number_rest(loinc_code))

  row <- DBI::dbGetQuery(con,
    "SELECT atn_value FROM mrsat_loinc WHERE code = ? LIMIT 1",
    params = list(loinc_code))
  if (nrow(row) == 0) return(NA_integer_)
  suppressWarnings(as.integer(row$atn_value[1]))
}

# --- REST fallbacks (thin wrappers around original umls_client.R names) ------
# These are the original implementations, renamed. They activate automatically
# when the DuckDB file is absent (e.g. local dev without /srv/umls/umls.duckdb).

UMLS_BASE_URL <- "https://uts-ws.nlm.nih.gov/rest"

get_api_key <- function() {
  key <- Sys.getenv("UMLS_API_KEY", "")
  if (nchar(key) == 0) stop("UMLS_API_KEY environment variable not set")
  key
}

umls_search_rest <- function(term, max_results = 10) {
  resp <- httr2::request(UMLS_BASE_URL) |>
    httr2::req_url_path_append("search", "current") |>
    httr2::req_url_query(
      apiKey     = get_api_key(),
      string     = term,
      pageSize   = max_results,
      searchType = "words"
    ) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  results <- resp$result$results
  if (length(results) == 0) return(tibble::tibble())

  purrr::map(results, \(r) tibble::tibble(
    cui         = r$ui         %||% "",
    name        = r$name       %||% "",
    root_source = r$rootSource %||% ""
  )) |> purrr::list_rbind()
}

umls_get_concept_rest <- function(cui) {
  resp <- httr2::request(UMLS_BASE_URL) |>
    httr2::req_url_path_append("content", "current", "CUI", cui) |>
    httr2::req_url_query(apiKey = get_api_key()) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  result <- resp$result
  list(
    cui            = result$ui           %||% cui,
    name           = result$name         %||% "",
    semantic_types = purrr::map_chr(
      result$semanticTypes %||% list(), \(st) st$name %||% ""
    ),
    atom_count     = result$atomCount %||% 0L
  )
}

umls_get_relations_rest <- function(cui) {
  all_results <- list()
  page <- 1L

  repeat {
    resp <- httr2::request(UMLS_BASE_URL) |>
      httr2::req_url_path_append("content", "current", "CUI", cui, "relations") |>
      httr2::req_url_query(
        apiKey     = get_api_key(),
        pageSize   = 200L,
        pageNumber = page
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    results <- resp$result
    if (length(results) == 0) break
    all_results <- c(all_results, results)
    if (length(results) < 200L) break
    page <- page + 1L
  }

  if (length(all_results) == 0) return(tibble::tibble())

  purrr::map(all_results, \(item) {
    related_id <- item$relatedId %||% ""
    tibble::tibble(
      cui            = cui,
      related_cui    = if (nchar(related_id) > 0) stringr::str_extract(related_id, "[^/]+$") else "",
      related_name   = item$relatedIdName              %||% "",
      rel            = item$relationLabel               %||% "",
      rela           = item$additionalRelationLabel     %||% "",
      related_id_url = related_id
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::filter(
      !rela %in% c("translation_of", "has_translation"),
      nchar(related_cui) > 0
    ) |>
    dplyr::distinct(related_cui, rela, .keep_all = TRUE)
}

umls_get_source_codes_rest <- function(cui, vocabulary) {
  all_codes <- list()
  page <- 1L

  repeat {
    resp <- httr2::request(UMLS_BASE_URL) |>
      httr2::req_url_path_append("content", "current", "CUI", cui, "atoms") |>
      httr2::req_url_query(
        apiKey     = get_api_key(),
        sabs       = vocabulary,
        pageSize   = 200L,
        pageNumber = page
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    results <- resp$result
    if (!is.list(results) || length(results) == 0) break

    for (atom in results) {
      code_uri <- atom$code %||% ""
      all_codes[[length(all_codes) + 1]] <- tibble::tibble(
        code       = if (nchar(code_uri) > 0) stringr::str_extract(code_uri, "[^/]+$") else "",
        name       = atom$name %||% "",
        vocabulary = vocabulary,
        source_cui = cui
      )
    }

    if (length(results) < 200L) break
    page <- page + 1L
  }

  if (length(all_codes) == 0) return(tibble::tibble())
  purrr::list_rbind(all_codes) |> dplyr::distinct(code, .keep_all = TRUE)
}

.loinc_class_number_rest <- function(loinc_code) {
  tryCatch({
    resp <- httr2::request(UMLS_BASE_URL) |>
      httr2::req_url_path_append("content", "current", "source", "LNC",
                                  loinc_code, "attributes") |>
      httr2::req_url_query(apiKey = get_api_key(), pageSize = 50L) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    attrs <- resp$result %||% list()
    val   <- purrr::keep(attrs, \(a) (a$name %||% "") == "LCN")
    if (length(val) == 0) return(NA_integer_)
    as.integer(val[[1]]$value)
  }, error = \(e) NA_integer_)
}
