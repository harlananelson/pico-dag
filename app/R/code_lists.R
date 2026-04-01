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

#' Generate RxNorm codes for drug concepts
#'
#' @param treatments Tibble of treatment concepts (from DAG walker)
#' @return Tibble with code, name, vocabulary, source_cui, drug_name
generate_rxnorm_codes <- function(treatments) {
  if (nrow(treatments) == 0) return(tibble::tibble())

  purrr::map(seq_len(nrow(treatments)), \(i) {
    tryCatch({
      codes <- umls_get_source_codes(treatments$related_cui[i], "RXNORM")
      if (nrow(codes) > 0) {
        codes |> dplyr::mutate(drug_name = treatments$related_name[i])
      } else {
        tibble::tibble()
      }
    }, error = \(e) tibble::tibble())
  }, .progress = "Generating RxNorm codes") |>
    purrr::list_rbind()
}

#' Generate LOINC codes for lab concepts
#'
#' @param labs Tibble of lab concepts (from DAG walker)
#' @return Tibble with code, name, vocabulary, source_cui
generate_loinc_codes <- function(labs) {
  if (nrow(labs) == 0) return(tibble::tibble())

  purrr::map(seq_len(nrow(labs)), \(i) {
    tryCatch({
      umls_get_source_codes(labs$related_cui[i], "LNC")
    }, error = \(e) tibble::tibble())
  }) |>
    purrr::list_rbind()
}

#' Generate CPT codes for procedure concepts
#'
#' @param procedures Tibble of procedure concepts (from DAG walker)
#' @return Tibble with code, name, vocabulary, source_cui
generate_cpt_codes <- function(procedures) {
  if (nrow(procedures) == 0) return(tibble::tibble())

  purrr::map(seq_len(nrow(procedures)), \(i) {
    tryCatch({
      umls_get_source_codes(procedures$related_cui[i], "CPT")
    }, error = \(e) tibble::tibble())
  }) |>
    purrr::list_rbind()
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

  # Comorbidity ICD-10 (batch)
  if (nrow(dag_result$comorbidities) > 0) {
    comorbidity_codes <- purrr::map(
      seq_len(min(nrow(dag_result$comorbidities), 30)),
      \(i) {
        tryCatch({
          codes <- umls_get_source_codes(
            dag_result$comorbidities$related_cui[i], "ICD10CM"
          )
          if (nrow(codes) > 0) {
            codes |> dplyr::mutate(
              condition_name = dag_result$comorbidities$related_name[i]
            )
          } else tibble::tibble()
        }, error = \(e) tibble::tibble())
      }
    ) |> purrr::list_rbind()

    if (nrow(comorbidity_codes) > 0) {
      code_lists$comorbidity_icd10 <- comorbidity_codes
    }
  }

  # Treatment RxNorm
  if (nrow(dag_result$treatments) > 0) {
    tx_codes <- generate_rxnorm_codes(dag_result$treatments)
    if (nrow(tx_codes) > 0) code_lists$treatment_rxnorm <- tx_codes
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
