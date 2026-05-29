#' Code list generation from DAG results

#' Generate ICD-10-CM codes for a concept (with hierarchy expansion)
#'
#' @param cui Character. Root CUI
#' @param max_depth Integer. Hierarchy expansion depth
#' @return Tibble with code, name, vocabulary, source_cui
generate_icd10_codes <- function(cui, max_depth = 1) {
  all_codes <- list()
  seen_cuis <- character()

  expand <- function(current_cui, depth) {
    if (current_cui %in% seen_cuis || depth > max_depth) return()
    seen_cuis <<- c(seen_cuis, current_cui)

    tryCatch({
      codes <- umls_get_source_codes(current_cui, "ICD10CM")
      if (nrow(codes) > 0) {
        all_codes[[length(all_codes) + 1]] <<- codes
      }

      if (depth < max_depth) {
        children <- umls_get_relations(current_cui) |>
          dplyr::filter(rela == "inverse_isa" | (rel == "CHD" & rela == ""))
        for (i in seq_len(nrow(children))) {
          expand(children$related_cui[i], depth + 1)
          Sys.sleep(0.25)
        }
      }
    }, error = \(e) NULL)
  }

  expand(cui, 0)

  if (length(all_codes) == 0) return(tibble::tibble())
  purrr::list_rbind(all_codes) |>
    dplyr::distinct(code, .keep_all = TRUE) |>
    dplyr::arrange(code)
}

#' Generate SNOMED codes for a concept
#'
#' @param cui Character. CUI
#' @return Tibble with code, name, vocabulary
generate_snomed_codes <- function(cui) {
  umls_get_source_codes(cui, "SNOMEDCT_US")
}

#' Harvest source codes directly from a DAG relation table.
#'
#' The DAG walker stores each related concept's source atom in
#' `related_id_url` as `.../source/{SAB}/{code}`. Its `related_cui` column is
#' therefore usually a SOURCE CODE or AUI, NOT a CUI — so the previous approach
#' of calling the `CUI/{id}/atoms` crosswalk endpoint returned HTTP 404 and
#' silently yielded nothing for comorbidities/treatments/labs. We instead read
#' the (vocabulary, code) pair straight from `related_id_url`: no extra API
#' calls, no 404s, and multi-vocabulary by design (filter via the `vocab` arg).
#'
#' @param tbl   a DAG relation tibble (comorbidities / treatments / *_labs)
#' @param vocab optional character vector of source abbreviations to keep
#' @return tibble(code, name, vocabulary, source_cui)
.codes_from_relations <- function(tbl, vocab = NULL) {
  if (is.null(tbl) || !is.data.frame(tbl) || nrow(tbl) == 0) return(tibble::tibble())
  if (!"related_id_url" %in% names(tbl)) return(tibble::tibble())
  m <- stringr::str_match(tbl$related_id_url, "/source/([^/]+)/([^/?]+)")
  out <- tibble::tibble(
    code       = m[, 3],
    name       = if ("related_name" %in% names(tbl)) tbl$related_name else NA_character_,
    vocabulary = m[, 2],
    source_cui = if ("from_cui" %in% names(tbl)) tbl$from_cui
                 else if ("cui" %in% names(tbl)) tbl$cui else NA_character_
  )
  out <- out[!is.na(out$code), , drop = FALSE]
  if (!is.null(vocab)) out <- out[out$vocabulary %in% vocab, , drop = FALSE]
  dplyr::distinct(out, code, vocabulary, .keep_all = TRUE)
}

#' Resolve a DAG relation table to source codes in a target vocabulary.
#'
#' Crosswalk-first, harvest-fallback:
#'  - When `related_cui` is a real CUI (the DuckDB backend, or any CUI-valued
#'    relation), look the concept up in the requested vocabulary via
#'    umls_get_source_codes() — this yields clean billing codes (e.g. ICD-10).
#'  - When the id is a source code / AUI (the bare REST relations endpoint),
#'    harvest the code straight from `related_id_url`.
#' This way the same generators give precise ICD-10/RxNorm/LOINC when the local
#' UMLS DuckDB is present, and still produce useful (multi-vocab) output over
#' REST when it is not.
#'
#' @param tbl   a DAG relation tibble
#' @param vocab target source abbreviation (e.g. "ICD10CM", "RXNORM", "LNC")
#' @return tibble(code, name, vocabulary, source_cui)
.resolve_codes <- function(tbl, vocab) {
  if (is.null(tbl) || !is.data.frame(tbl) || nrow(tbl) == 0) return(tibble::tibble())

  # (1) Native codes harvested from related_id_url — multi-vocabulary, never
  #     empty when the URL is source-coded; keeps breadth (MSH/SNOMED/LNC/...).
  parts <- list(.codes_from_relations(tbl, vocab = NULL))

  # (2) Target-vocabulary codes via crosswalk for CUI-valued relations (DuckDB
  #     mrconso, or REST atoms) — adds clean billing codes (e.g. ICD-10) that
  #     the native atom may not be expressed in.
  rcui <- tbl$related_cui %||% rep(NA_character_, nrow(tbl))
  cui_rows <- tbl[grepl("^C[0-9]+$", rcui), , drop = FALSE]
  if (nrow(cui_rows) > 0) {
    parts[[2]] <- purrr::map(seq_len(nrow(cui_rows)), function(i) {
      codes <- tryCatch(umls_get_source_codes(cui_rows$related_cui[i], vocab),
                        error = function(e) tibble::tibble())
      if (nrow(codes) > 0) codes$name <- cui_rows$related_name[i]
      codes
    }) |> purrr::list_rbind()
  }

  res <- purrr::list_rbind(parts)
  if (nrow(res) == 0) return(tibble::tibble())
  dplyr::distinct(res, code, vocabulary, .keep_all = TRUE)
}

#' Generate drug codes for treatment concepts (multi-vocabulary).
#'
#' @param treatments Tibble of treatment concepts (from DAG walker)
#' @return Tibble with code, name, vocabulary, source_cui, drug_name
generate_rxnorm_codes <- function(treatments) {
  codes <- .resolve_codes(treatments, "RXNORM")
  if (nrow(codes) == 0) return(tibble::tibble())
  codes$drug_name <- codes$name
  codes
}

#' Fetch the LOINC class number (LCN) for a single LOINC code via UMLS.
#' Returns integer: 1=Lab, 2=Clinical, 3=Claims, 4=Survey. NA on failure.
.loinc_class_number <- function(loinc_code) {
  tryCatch({
    resp <- httr2::request("https://uts-ws.nlm.nih.gov/rest") |>
      httr2::req_url_path_append("content", "current", "source", "LNC",
                                  loinc_code, "attributes") |>
      httr2::req_url_query(apiKey = get_api_key(), pageSize = 50) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    attrs <- resp$result %||% list()
    val <- purrr::keep(attrs, \(a) (a$name %||% "") == "LCN")
    if (length(val) == 0) return(NA_integer_)
    as.integer(val[[1]]$value)
  }, error = \(e) NA_integer_)
}

#' Generate LOINC codes for lab concepts, filtered to laboratory class only.
#'
#' Uses the UMLS LCN attribute (LOINC Class Number) to exclude surveys (4),
#' clinical notes (2), and claims attachments (3). Only LCN=1 (Laboratory)
#' codes are returned.
#'
#' @param labs Tibble of lab concepts (from DAG walker)
#' @param lab_only Logical. If TRUE (default), filter to LCN=1 only.
#' @return Tibble with code, name, vocabulary, source_cui, loinc_class
generate_loinc_codes <- function(labs, lab_only = TRUE) {
  rows <- .resolve_codes(labs, "LNC")
  if (nrow(rows) == 0) return(tibble::tibble())
  # Classify each LOINC by LCN (1=Lab); keep NA on lookup failure.
  rows$loinc_class <- purrr::map_int(rows$code, \(lc) {
    Sys.sleep(0.05)
    .loinc_class_number(lc)
  })
  if (lab_only) rows <- rows |> dplyr::filter(loinc_class == 1L | is.na(loinc_class))
  rows
}

#' Generate CPT codes for procedure concepts
#'
#' @param procedures Tibble of procedure concepts (from DAG walker)
#' @return Tibble with code, name, vocabulary, source_cui
generate_cpt_codes <- function(procedures) {
  .resolve_codes(procedures, "CPT")
}

#' Package all code lists into a named list for export
#'
#' @param dag_result List from walk_concept_dag()
#' @param pico_elements List of PICO element results
#' @return Named list of tibbles ready for CSV export
package_code_lists <- function(dag_result, pico_elements = list()) {
  code_lists <- list()

  # Population ICD-10
  pop_icd <- generate_icd10_codes(dag_result$concept$cui)
  if (nrow(pop_icd) > 0) code_lists$population_icd10 <- pop_icd

  # Population SNOMED
  pop_snomed <- generate_snomed_codes(dag_result$concept$cui)
  if (nrow(pop_snomed) > 0) code_lists$population_snomed <- pop_snomed

  # Comorbidity codes (multi-vocabulary, harvested from relation URLs)
  if (nrow(dag_result$comorbidities) > 0) {
    comorbidity_codes <- .resolve_codes(dag_result$comorbidities, "ICD10CM")
    if (nrow(comorbidity_codes) > 0) {
      comorbidity_codes$condition_name <- comorbidity_codes$name
      code_lists$comorbidity_icd10 <- comorbidity_codes
    }
  }

  # Treatment RxNorm
  if (nrow(dag_result$treatments) > 0) {
    tx_codes <- generate_rxnorm_codes(dag_result$treatments)
    if (nrow(tx_codes) > 0) code_lists$treatment_rxnorm <- tx_codes
  }

  # Diagnostic LOINC — direct from disease via evaluated_by / has_associated_finding etc.
  if (!is.null(dag_result$diagnostic_labs) && nrow(dag_result$diagnostic_labs) > 0) {
    diag_loinc <- generate_loinc_codes(dag_result$diagnostic_labs)
    if (nrow(diag_loinc) > 0) code_lists$diagnostic_loinc <- diag_loinc
  }

  # Monitoring LOINC — from treatment second-hop
  if (nrow(dag_result$monitoring_labs) > 0) {
    mon_loinc <- generate_loinc_codes(dag_result$monitoring_labs)
    if (nrow(mon_loinc) > 0) code_lists$monitoring_loinc <- mon_loinc
  }

  # PICO elements
  for (elem in pico_elements) {
    prefix <- elem$element
    if (!is.null(elem$concept)) {
      elem_icd <- generate_icd10_codes(elem$concept$cui)
      if (nrow(elem_icd) > 0) {
        code_lists[[paste0(prefix, "_icd10")]] <- elem_icd
      }
    }
  }

  code_lists
}
