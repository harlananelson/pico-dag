#' Network visualization for the concept DAG

# Domain → color mapping
DOMAIN_COLORS <- c(
  "population" = "#E74C3C",    # red
  "treatment" = "#3498DB",     # blue
  "monitoring_lab" = "#2ECC71", # green
  "comorbidity" = "#E67E22",   # orange
  "procedure" = "#9B59B6",     # purple
  "anatomy" = "#F39C12",       # yellow
  "subtype" = "#95A5A6",       # gray
  "parent" = "#BDC3C7",        # light gray
  "outcome" = "#E74C3C",       # red (same as population)
  "intervention" = "#1ABC9C",  # teal
  "comparator" = "#16A085",    # dark teal
  "other" = "#7F8C8D"          # dark gray
)

#' Build visNetwork graph from DAG results
#'
#' @param dag_result List from walk_concept_dag()
#' @param pico_elements List of PICO element results
#' @return visNetwork object
build_dag_network <- function(dag_result, pico_elements = list()) {
  nodes_list <- list()
  edges_list <- list()

  # Root node
  root_id <- dag_result$concept$cui
  nodes_list[[1]] <- tibble::tibble(
    id = root_id,
    label = dag_result$concept$name,
    group = "population",
    title = paste0(
      "<b>", dag_result$concept$name, "</b><br>",
      "CUI: ", root_id, "<br>",
      "Types: ", paste(dag_result$concept$semantic_types, collapse = ", ")
    ),
    shape = "ellipse",
    size = 30
  )

  # Add relation nodes and edges
  add_category <- function(data, category, max_nodes = 30) {
    if (nrow(data) == 0) return()
    data <- utils::head(data, max_nodes)

    for (i in seq_len(nrow(data))) {
      node_id <- data$related_cui[i]
      if (node_id == root_id) next

      nodes_list[[length(nodes_list) + 1]] <<- tibble::tibble(
        id = node_id,
        label = stringr::str_trunc(data$related_name[i], 30),
        group = category,
        title = paste0(
          "<b>", data$related_name[i], "</b><br>",
          "CUI: ", node_id, "<br>",
          "Relationship: ", data$rela[i]
        ),
        shape = "dot",
        size = 15
      )

      edges_list[[length(edges_list) + 1]] <<- tibble::tibble(
        from = root_id,
        to = node_id,
        label = data$rela[i],
        arrows = "to",
        color = DOMAIN_COLORS[category] %||% "#7F8C8D"
      )
    }
  }

  add_category(dag_result$treatments, "treatment")
  add_category(dag_result$comorbidities, "comorbidity")
  add_category(dag_result$procedures, "procedure")
  add_category(dag_result$anatomy, "anatomy")
  add_category(dag_result$subtypes, "subtype", max_nodes = 10)

  # Monitoring labs (second-hop edges from drugs)
  if (nrow(dag_result$monitoring_labs) > 0) {
    ml <- dag_result$monitoring_labs |>
      dplyr::distinct(related_cui, .keep_all = TRUE) |>
      utils::head(40)

    for (i in seq_len(nrow(ml))) {
      lab_id <- ml$related_cui[i]

      nodes_list[[length(nodes_list) + 1]] <- tibble::tibble(
        id = lab_id,
        label = stringr::str_trunc(ml$related_name[i], 25),
        group = "monitoring_lab",
        title = paste0(
          "<b>", ml$related_name[i], "</b><br>",
          "Monitors: ", ml$parent_drug_name[i]
        ),
        shape = "triangle",
        size = 10
      )

      edges_list[[length(edges_list) + 1]] <- tibble::tibble(
        from = ml$parent_drug_cui[i],
        to = lab_id,
        label = "monitors",
        arrows = "to",
        dashes = TRUE,
        color = DOMAIN_COLORS["monitoring_lab"]
      )
    }
  }

  # PICO element nodes
  for (elem in pico_elements) {
    if (is.null(elem$concept)) next
    elem_id <- elem$concept$cui

    nodes_list[[length(nodes_list) + 1]] <- tibble::tibble(
      id = elem_id,
      label = elem$concept$name,
      group = elem$element,
      title = paste0(
        "<b>", elem$concept$name, "</b><br>",
        "PICO: ", toupper(elem$element), "<br>",
        "CUI: ", elem_id
      ),
      shape = "square",
      size = 25
    )
  }

  # Combine
  nodes <- purrr::list_rbind(nodes_list) |>
    dplyr::distinct(id, .keep_all = TRUE)

  edges <- if (length(edges_list) > 0) {
    purrr::list_rbind(edges_list)
  } else {
    tibble::tibble(from = character(), to = character())
  }

  # Build visNetwork
  visNetwork::visNetwork(nodes, edges, width = "100%", height = "600px") |>
    visNetwork::visGroups(groupname = "population", color = DOMAIN_COLORS["population"]) |>
    visNetwork::visGroups(groupname = "treatment", color = DOMAIN_COLORS["treatment"]) |>
    visNetwork::visGroups(groupname = "monitoring_lab", color = DOMAIN_COLORS["monitoring_lab"]) |>
    visNetwork::visGroups(groupname = "comorbidity", color = DOMAIN_COLORS["comorbidity"]) |>
    visNetwork::visGroups(groupname = "procedure", color = DOMAIN_COLORS["procedure"]) |>
    visNetwork::visGroups(groupname = "anatomy", color = DOMAIN_COLORS["anatomy"]) |>
    visNetwork::visGroups(groupname = "subtype", color = DOMAIN_COLORS["subtype"]) |>
    visNetwork::visGroups(groupname = "intervention", color = DOMAIN_COLORS["intervention"]) |>
    visNetwork::visGroups(groupname = "comparator", color = DOMAIN_COLORS["comparator"]) |>
    visNetwork::visLegend(useGroups = TRUE, position = "right") |>
    visNetwork::visOptions(
      highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE),
      nodesIdSelection = TRUE
    ) |>
    visNetwork::visPhysics(
      solver = "forceAtlas2Based",
      forceAtlas2Based = list(gravitationalConstant = -100)
    ) |>
    visNetwork::visInteraction(navigationButtons = TRUE)
}
