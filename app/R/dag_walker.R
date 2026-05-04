#' DAG walker — categorize UMLS relations and perform second-hop traversal

# --- RELA → category mapping ---

RELA_CATEGORIES <- c(
  "may_be_treated_by" = "treatment",
  "may_treat" = "treatment",
  "has_finding_site" = "anatomy",
  "finding_site_of" = "anatomy",
  "component_of" = "monitoring_lab",
  "has_component" = "monitoring_lab",
  "clinically_associated_with" = "comorbidity",
  "focus_of" = "procedure",
  "inverse_isa" = "subtype",
  "isa" = "parent",
  "manifestation_of" = "genetic",
  "has_causative_agent" = "etiology",
  "causative_agent_of" = "etiology",
  "has_interpretation" = "interpretation",
  "interprets" = "interpretation",
  "associated_with" = "associated",
  "associated_finding_of" = "associated",
  # Direct disease → diagnostic test relations
  "evaluated_by" = "diagnostic_lab",
  "has_associated_finding" = "diagnostic_lab",
  "finding_of" = "diagnostic_lab",
  "diagnoses" = "diagnostic_lab",
  "diagnosed_by" = "diagnostic_lab",
  "has_finding" = "diagnostic_lab"
)

REL_CATEGORIES <- c(
  "CHD" = "narrower",
  "RN" = "narrower",
  "PAR" = "broader",
  "RB" = "broader"
)

#' Categorize UMLS relations into clinical groups
#'
#' @param relations Tibble from umls_get_relations()
#' @return Tibble with added category column
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

#' Walk the full concept DAG from a root CUI
#'
#' Fetches relations, categorizes them, and optionally performs
#' second-hop traversal for treatments (to find monitoring labs).
#'
#' @param cui Character. Root concept CUI
#' @param discover_monitoring_labs Logical. Follow treatments to their labs?
#' @param progress Function. Called with status messages for UI updates
#' @return List with components: concept, relations, treatments,
#'         monitoring_labs, comorbidities, procedures, anatomy
walk_concept_dag <- function(cui, discover_monitoring_labs = TRUE, progress = NULL) {
  if (!is.null(progress)) progress("Fetching concept details...")
  concept <- umls_get_concept(cui)

  if (!is.null(progress)) progress("Fetching relationships...")
  relations <- umls_get_relations(cui) |>
    categorize_relations()

  result <- list(
    concept = concept,
    relations = relations,
    treatments = relations |> dplyr::filter(category == "treatment"),
    comorbidities = relations |> dplyr::filter(category == "comorbidity"),
    procedures = relations |> dplyr::filter(category == "procedure"),
    anatomy = relations |> dplyr::filter(category == "anatomy"),
    subtypes = relations |> dplyr::filter(category == "subtype"),
    parents = relations |> dplyr::filter(category == "parent"),
    interpretation = relations |> dplyr::filter(category == "interpretation"),
    genetic = relations |> dplyr::filter(category == "genetic"),
    diagnostic_labs = relations |> dplyr::filter(category == "diagnostic_lab"),
    monitoring_labs = tibble::tibble()
  )

  # Second-hop: for each treatment, find monitoring labs
  if (discover_monitoring_labs && nrow(result$treatments) > 0) {
    if (!is.null(progress)) progress("Discovering monitoring labs for treatments...")

    lab_list <- list()
    treatments_to_check <- result$treatments

    for (i in seq_len(min(nrow(treatments_to_check), 20))) {
      drug_cui <- treatments_to_check$related_cui[i]
      drug_name <- treatments_to_check$related_name[i]

      if (!is.null(progress)) {
        progress(paste0("Labs for ", drug_name, " (", i, "/",
                        min(nrow(treatments_to_check), 20), ")"))
      }

      tryCatch({
        drug_rels <- umls_get_relations(drug_cui) |>
          categorize_relations()

        labs <- drug_rels |>
          dplyr::filter(category == "monitoring_lab") |>
          dplyr::mutate(
            parent_drug_cui = drug_cui,
            parent_drug_name = drug_name
          )

        if (nrow(labs) > 0) {
          lab_list[[length(lab_list) + 1]] <- labs
        }

        Sys.sleep(0.25) # rate limit
      }, error = \(e) {
        # Skip on API errors
        NULL
      })
    }

    if (length(lab_list) > 0) {
      result$monitoring_labs <- purrr::list_rbind(lab_list)
    }
  }

  result
}

#' Walk a PICO element (intervention, comparator, or outcome)
#'
#' @param cui Character. CUI for this PICO element
#' @param element Character. "intervention", "comparator", or "outcome"
#' @param progress Function. Status callback
#' @return List with concept, relations, and element-specific data
walk_pico_element <- function(cui, element, progress = NULL) {
  if (!is.null(progress)) progress(paste0("Walking ", element, "..."))

  concept <- umls_get_concept(cui)
  relations <- umls_get_relations(cui) |>
    categorize_relations()

  result <- list(
    concept = concept,
    relations = relations,
    element = element
  )

  # For interventions/comparators: get monitoring labs
  if (element %in% c("intervention", "comparator")) {
    labs <- relations |> dplyr::filter(category == "monitoring_lab")
    result$monitoring_labs <- labs

    # Also find what else this drug treats
    result$also_treats <- relations |> dplyr::filter(category == "treatment")
  }

  # For outcomes: get related conditions to adjust for
  if (element == "outcome") {
    result$related_conditions <- relations |>
      dplyr::filter(category %in% c("comorbidity", "associated"))
    result$subtypes <- relations |> dplyr::filter(category == "subtype")
  }

  result
}
