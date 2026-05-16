#' Network visualization for the concept DAG

# ---------------------------------------------------------------------------
# Shared helpers (used by both build_dag_network and dag_export.R)
# ---------------------------------------------------------------------------

#' Compute connected-component (cluster) ids over a node/edge set.
#'
#' Returns list(nodes = int vec aligned to nodes$id,
#'              edges = int vec aligned to edges).
#' Lives in network_viz.R so both the renderer (visClusterByGroup) and the
#' exporter (.dag_to_nodes_edges) can call it. Falls back to all-1L when no
#' edges exist or igraph is unavailable.
.compute_cluster_ids <- function(nodes, edges) {
  n <- nrow(nodes)
  if (n == 0) return(list(nodes = integer(0), edges = integer(0)))
  if (!requireNamespace("igraph", quietly = TRUE) || nrow(edges) == 0) {
    return(list(
      nodes = rep(1L, n),
      edges = if (nrow(edges) > 0) rep(1L, nrow(edges)) else integer(0)
    ))
  }
  in_nodes <- edges$from %in% nodes$id & edges$to %in% nodes$id
  edges_for_graph <- edges[in_nodes, c("from", "to"), drop = FALSE]
  g <- igraph::graph_from_data_frame(
    d        = edges_for_graph,
    vertices = data.frame(name = nodes$id, stringsAsFactors = FALSE),
    directed = FALSE
  )
  comp <- igraph::components(g)
  node_clusters <- as.integer(comp$membership[nodes$id])
  node_clusters[is.na(node_clusters)] <- 0L
  edge_clusters <- node_clusters[match(edges$to, nodes$id)]
  na_idx <- is.na(edge_clusters)
  if (any(na_idx)) {
    edge_clusters[na_idx] <- node_clusters[match(edges$from[na_idx], nodes$id)]
  }
  edge_clusters[is.na(edge_clusters)] <- 0L
  list(nodes = node_clusters, edges = edge_clusters)
}

# Domain → color mapping
DOMAIN_COLORS <- c(
  "population"     = "#E74C3C", # red
  "treatment"      = "#3498DB", # blue
  "monitoring_lab" = "#2ECC71", # green
  "diagnostic_lab" = "#27AE60", # darker green — distinct from monitoring
  "comorbidity"    = "#E67E22", # orange
  "procedure"      = "#9B59B6", # purple
  "anatomy"        = "#F39C12", # yellow
  "subtype"        = "#95A5A6", # gray
  "parent"         = "#BDC3C7", # light gray
  "outcome"        = "#E74C3C", # red (same as population)
  "intervention"   = "#1ABC9C", # teal
  "comparator"     = "#16A085", # dark teal
  "etiology"       = "#C0392B", # deep red
  "other"          = "#7F8C8D"  # dark gray
)

# Strip generic UMLS scaffolding phrases before truncating node labels.
# Vectorized: gsub/sub/str_trunc all operate elementwise on character vectors.
# Also recovers any label that slipped through as a bare CUI (e.g. when the
# upstream concept_preferred / mrconso fallback both miss) by substituting
# a marker the user can recognize.
clean_node_label <- function(x, max_chars = 32, cuis = NULL) {
  x <- ifelse(is.na(x), "", as.character(x))
  # Recover: if a label looks like a bare CUI, replace with "(unnamed)".
  # Resolution should happen upstream via umls_preferred_name(); this is the
  # last-mile safety net.
  if (!is.null(cuis)) {
    leaked <- grepl("^C\\d+$", x) | !nzchar(x)
    if (any(leaked)) x[leaked] <- paste0("(unnamed ", cuis[leaked], ")")
  } else {
    leaked <- grepl("^C\\d+$", x)
    if (any(leaked)) x[leaked] <- "(unnamed)"
  }
  y <- gsub("\\s+", " ", x)
  y <- sub("^Disorder characterized by\\s+", "", y, ignore.case = TRUE)
  y <- sub("^Disease or Syndrome\\s*:?\\s*", "", y, ignore.case = TRUE)
  y <- sub("^Finding of\\s+", "", y, ignore.case = TRUE)
  y <- sub("^Morphologic abnormality\\s*:?\\s*", "", y, ignore.case = TRUE)
  y <- sub("\\s*\\((disease|disorder|finding|procedure|morphologic abnormality)\\)\\s*$", "", y, ignore.case = TRUE)
  ifelse(nzchar(y), stringr::str_trunc(y, width = max_chars, side = "right"), "")
}

#' Build visNetwork graph from DAG results
#'
#' @param dag_result List from walk_concept_dag()
#' @param pico_elements List of PICO element results
#' @param cluster_components If TRUE, collapse weakly-connected components
#'        in the rendered graph via visClusterByGroup. Default FALSE so the
#'        spatial intuition of the un-clustered graph is preserved unless
#'        the user explicitly opts in.
#' @return visNetwork object
build_dag_network <- function(dag_result, pico_elements = list(),
                              cluster_components = FALSE) {
  nodes_list <- list()
  edges_list <- list()

  # Root node
  root_id <- dag_result$concept$cui
  nodes_list[[1]] <- tibble::tibble(
    id = root_id,
    label = clean_node_label(dag_result$concept$name, max_chars = 40),
    group = "population",
    title = paste0(
      "<b>", dag_result$concept$name, "</b><br>",
      "CUI: ", root_id, "<br>",
      "Types: ", paste(dag_result$concept$semantic_types, collapse = ", ")
    ),
    shape = "ellipse",
    size = 30
  )

  # Vectorized: returns list(nodes=tibble, edges=tibble).
  # Edges originate from each row's `from_cui` when present (so densified /
  # extended walks correctly attribute relations to the right anchor node).
  # The max_nodes cap is applied PER-anchor (per from_cui), so an extended
  # walk can add up to max_nodes new edges per clicked node without being
  # crowded out by the original root's edges.
  make_category_rows <- function(data, category, max_nodes = 30) {
    if (nrow(data) == 0) return(list(nodes = NULL, edges = NULL))
    data <- data[data$related_cui != root_id, , drop = FALSE]
    if (nrow(data) == 0) return(list(nodes = NULL, edges = NULL))
    if (!"from_cui" %in% names(data)) {
      data$from_cui <- root_id
    } else {
      data$from_cui[is.na(data$from_cui) | !nzchar(data$from_cui)] <- root_id
    }
    # Last-mile name resolution: if a row arrived here with an empty or
    # bare-CUI name, resolve from UMLS before rendering. Eliminates the
    # remaining bare-CUI display bug for any path the SQL fallback missed.
    name_broken <- is.na(data$related_name) |
                   !nzchar(data$related_name) |
                   data$related_name == data$related_cui
    if (any(name_broken) && exists("umls_preferred_name", mode = "function")) {
      data$related_name[name_broken] <-
        unname(umls_preferred_name(data$related_cui[name_broken]))
    }
    data <- data |>
      dplyr::group_by(from_cui) |>
      dplyr::slice_head(n = max_nodes) |>
      dplyr::ungroup()
    edge_from <- data$from_cui
    rela_disp <- if (exists("display_rela", mode = "function")) {
      display_rela(data$rela)
    } else {
      data$rela
    }
    nodes <- tibble::tibble(
      id    = data$related_cui,
      label = clean_node_label(data$related_name, cuis = data$related_cui),
      group = category,
      title = paste0("<b>", data$related_name, "</b><br>CUI: ", data$related_cui,
                     "<br>Relationship: ", rela_disp,
                     " <span style='color:#888'>(", data$rela, ")</span>"),
      shape = "dot",
      size  = 15
    )
    edges <- tibble::tibble(
      from   = edge_from,
      to     = data$related_cui,
      label  = rela_disp,
      title  = data$rela,                    # raw rela in hover tooltip
      arrows = "to",
      color  = DOMAIN_COLORS[category] %||% "#7F8C8D"
    )
    list(nodes = nodes, edges = edges)
  }

  cats <- list(
    make_category_rows(dag_result$treatments,      "treatment",      max_nodes = 15),
    make_category_rows(dag_result$comorbidities,   "comorbidity",    max_nodes = 15),
    make_category_rows(dag_result$procedures,      "procedure",      max_nodes = 15),
    make_category_rows(dag_result$anatomy,         "anatomy",        max_nodes = 10),
    make_category_rows(dag_result$subtypes,        "subtype",        max_nodes = 15),
    make_category_rows(dag_result$parents,         "parent",         max_nodes =  6),
    make_category_rows(dag_result$diagnostic_labs, "diagnostic_lab", max_nodes = 15),
    make_category_rows(dag_result$monitoring_labs, "monitoring_lab", max_nodes = 15),
    if (!is.null(dag_result$etiology)) make_category_rows(dag_result$etiology, "etiology", max_nodes = 8)
    else list(nodes = NULL, edges = NULL)
  )
  nodes_list <- c(nodes_list, purrr::map(cats, "nodes"))
  edges_list <- c(edges_list, purrr::map(cats, "edges"))

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

  # Hard cap on graph size to keep visNetwork's force-directed layout
  # responsive in the browser. visNetwork starts to choke past ~200 nodes
  # because Atlas2-based physics is O(n^2). When over the cap we keep the
  # root, all PICO-element nodes, and the most-connected remaining nodes
  # (ranked by edge degree). Edges are then filtered to only those whose
  # endpoints survive.
  MAX_RENDERED_NODES <- 180L
  if (nrow(nodes) > MAX_RENDERED_NODES) {
    must_keep <- c(root_id,
                   nodes$id[nodes$group %in% c("intervention", "comparator", "outcome")])
    deg_tbl <- table(c(edges$from, edges$to))
    deg <- as.integer(deg_tbl[as.character(nodes$id)])
    deg[is.na(deg)] <- 0L
    priority <- ifelse(nodes$id %in% must_keep, 1e9, deg)
    keep_ids <- nodes$id[order(-priority)][seq_len(MAX_RENDERED_NODES)]
    nodes <- nodes[nodes$id %in% keep_ids, , drop = FALSE]
    edges <- edges[edges$from %in% keep_ids & edges$to %in% keep_ids, , drop = FALSE]
  }

  # Optional clustering: collapse disconnected components into expandable
  # cluster nodes. Done by tagging nodes with a synthetic "cluster_N" group
  # for components that don't contain the root, then using visClusterByGroup.
  cluster_groups <- character(0)
  if (isTRUE(cluster_components) && nrow(nodes) > 1 && nrow(edges) > 0) {
    cl <- .compute_cluster_ids(nodes, edges)
    root_cluster <- cl$nodes[match(root_id, nodes$id)]
    # Only cluster components that don't contain the root, so the seed
    # neighborhood stays expanded.
    needs_cluster <- !is.na(cl$nodes) & cl$nodes != root_cluster & cl$nodes > 0
    if (any(needs_cluster)) {
      cluster_names <- paste0("cluster_", cl$nodes)
      nodes$cluster_group <- ifelse(needs_cluster, cluster_names, nodes$group)
      cluster_groups <- unique(cluster_names[needs_cluster])
    }
  }

  # Build visNetwork. Drive group styling from DOMAIN_COLORS so adding a new
  # category in one place doesn't require chasing visGroups call-by-call.
  # When clustering is enabled, we render the cluster_group field instead so
  # disconnected components can be collapsed by visClusterByGroup.
  if (length(cluster_groups) > 0) {
    nodes$group <- nodes$cluster_group
    nodes$cluster_group <- NULL
  }
  net <- visNetwork::visNetwork(nodes, edges, width = "100%", height = "600px")
  net <- purrr::reduce(
    names(DOMAIN_COLORS),
    \(g, gn) visNetwork::visGroups(g, groupname = gn,
                                   color = unname(DOMAIN_COLORS[gn])),
    .init = net
  )
  # Style the synthetic cluster groups distinctly so users can see what
  # was collapsed.
  for (cg in cluster_groups) {
    net <- visNetwork::visGroups(net, groupname = cg,
                                 color = "#D6CADD", shape = "diamond")
  }
  net <- net |>
    visNetwork::visLegend(useGroups = TRUE, position = "right") |>
    visNetwork::visOptions(
      highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE),
      nodesIdSelection = TRUE
    ) |>
    visNetwork::visPhysics(
      solver = "forceAtlas2Based",
      forceAtlas2Based = list(gravitationalConstant = -100)
    ) |>
    visNetwork::visInteraction(navigationButtons = TRUE) |>
    visNetwork::visEvents(
      selectNode = "function(nodes) { Shiny.setInputValue('dag_node_click', nodes.nodes[0], {priority: 'event'}); }"
    )
  # Apply clustering after the base network is built.
  for (cg in cluster_groups) {
    net <- visNetwork::visClusteringByGroup(net, groups = cg,
                                            label = "Disconnected: ")
  }
  net
}

#' Summarize what `build_dag_network` would render — used for telemetry.
#'
#' Replays the same node/edge assembly + MAX_RENDERED_NODES cap that
#' build_dag_network applies, then returns counts and cluster diagnostics.
#' Does not actually build a visNetwork object.
summarize_dag_render <- function(dag_result, pico_elements = list()) {
  empty <- list(n_rendered_nodes = 0L, n_rendered_edges = 0L,
                n_clipped_by_cap = 0L, cluster_count = 0L,
                n_unnamed_nodes = 0L, n_components_off_root = 0L,
                has_etiology = FALSE)
  if (is.null(dag_result) || is.null(dag_result$concept)) return(empty)
  root_id <- dag_result$concept$cui

  # Reuse the same .dag_to_nodes_edges flattener used by exports — it
  # already applies cluster_id and rela_display, and stays in lock-step
  # with the export schema.
  ne <- if (exists(".dag_to_nodes_edges", mode = "function")) {
    .dag_to_nodes_edges(dag_result)
  } else {
    list(nodes = tibble::tibble(id = character(0), category = character(0)),
         edges = tibble::tibble(from = character(0), to = character(0)))
  }

  total_nodes <- nrow(ne$nodes)
  total_edges <- nrow(ne$edges)
  MAX_RENDERED_NODES <- 180L
  n_clipped <- max(0L, total_nodes - MAX_RENDERED_NODES)
  rendered_nodes <- min(total_nodes, MAX_RENDERED_NODES)

  cluster_count <- if (total_nodes > 0 && "cluster_id" %in% names(ne$nodes)) {
    length(unique(ne$nodes$cluster_id[!is.na(ne$nodes$cluster_id)]))
  } else 0L

  # Count off-root components (the "extra stars" the user sees).
  off_root <- 0L
  if (total_nodes > 0 && "cluster_id" %in% names(ne$nodes)) {
    root_cluster <- ne$nodes$cluster_id[match(root_id, ne$nodes$id)]
    if (!is.na(root_cluster)) {
      off_root <- length(setdiff(unique(ne$nodes$cluster_id), root_cluster))
    }
  }

  # Count nodes whose label is the "(unnamed ...)" marker — diagnostic for
  # how often the name-resolution fallback chain runs out of options.
  n_unnamed <- if ("label" %in% names(ne$nodes)) {
    sum(grepl("^\\(unnamed", as.character(ne$nodes$label)))
  } else 0L

  list(
    n_rendered_nodes      = as.integer(rendered_nodes),
    n_rendered_edges      = as.integer(total_edges),
    n_clipped_by_cap      = as.integer(n_clipped),
    cluster_count         = as.integer(cluster_count),
    n_unnamed_nodes       = as.integer(n_unnamed),
    n_components_off_root = as.integer(off_root),
    has_etiology          = !is.null(dag_result$etiology) &&
                             nrow(dag_result$etiology) > 0
  )
}
