# DAG export / import in standard graph formats.
#
# Exporters produce content from a dag_result. Importers reconstruct a
# minimal dag_result that the existing UI / build_dag_network can consume.
# All formats round-trip the same node + edge set.

# ---------------------------------------------------------------------------
# Internal flatteners
# ---------------------------------------------------------------------------

# Map dag_result category fields to a (category-name, tibble) list.
.DAG_CATEGORIES <- c(
  treatment       = "treatments",
  comorbidity     = "comorbidities",
  procedure       = "procedures",
  diagnostic_lab  = "diagnostic_labs",
  monitoring_lab  = "monitoring_labs",
  anatomy         = "anatomy",
  subtype         = "subtypes",
  parent          = "parents",
  etiology        = "etiology"
)

# Flatten dag_result to (nodes, edges) tibbles. Each node has id, label,
# category. Each edge has from, to, rela, category. Suitable for any
# downstream serialization.
.dag_to_nodes_edges <- function(dag) {
  if (is.null(dag) || is.null(dag$concept)) {
    return(list(
      nodes = tibble::tibble(id = character(0), label = character(0), category = character(0)),
      edges = tibble::tibble(from = character(0), to = character(0),
                             rela = character(0), category = character(0))
    ))
  }
  root_id <- dag$concept$cui
  root_node <- tibble::tibble(
    id       = root_id,
    label    = dag$concept$name %||% root_id,
    category = "population"
  )
  parts <- purrr::imap(.DAG_CATEGORIES, function(field, cat) {
    tbl <- dag[[field]]
    if (is.null(tbl) || nrow(tbl) == 0) return(NULL)
    from <- if ("from_cui" %in% names(tbl)) tbl$from_cui else rep(root_id, nrow(tbl))
    from[is.na(from) | !nzchar(from)] <- root_id
    list(
      nodes = tibble::tibble(
        id       = tbl$related_cui,
        label    = tbl$related_name,
        category = cat
      ),
      edges = tibble::tibble(
        from     = from,
        to       = tbl$related_cui,
        rela     = tbl$rela %||% "",
        category = cat
      )
    )
  }) |> purrr::compact()

  nodes <- purrr::list_rbind(c(list(root_node), unname(purrr::map(parts, "nodes")))) |>
    dplyr::distinct(id, .keep_all = TRUE)
  edges <- purrr::list_rbind(unname(purrr::map(parts, "edges"))) |>
    dplyr::distinct(from, to, rela, .keep_all = TRUE)
  list(nodes = nodes, edges = edges)
}

# Best-effort biolink class for a category. Used by JSON-LD export.
.biolink_type <- function(cat) {
  m <- c(
    population     = "biolink:Disease",
    treatment      = "biolink:ChemicalSubstance",
    comorbidity    = "biolink:Disease",
    procedure      = "biolink:Procedure",
    diagnostic_lab = "biolink:LaboratoryProcedure",
    monitoring_lab = "biolink:LaboratoryProcedure",
    anatomy        = "biolink:AnatomicalEntity",
    subtype        = "biolink:Disease",
    parent         = "biolink:Disease",
    etiology       = "biolink:Disease",
    other          = "biolink:NamedThing"
  )
  unname(m[cat]) %||% "biolink:NamedThing"
}

# Map UMLS rela strings to biolink predicates (best-effort).
.biolink_predicate <- function(rela) {
  m <- c(
    "may_be_treated_by"          = "treated_by",
    "may_treat"                  = "treats",
    "may_be_prevented_by"        = "prevented_by",
    "isa"                        = "subclass_of",
    "inverse_isa"                = "superclass_of",
    "clinically_associated_with" = "associated_with",
    "co-occurs_with"             = "coexists_with",
    "has_finding_site"           = "has_anatomical_entity",
    "finding_site_of"            = "anatomical_entity_of",
    "focus_of"                   = "subject_of",
    "component_of"               = "part_of",
    "evaluated_by"               = "measured_by",
    "has_associated_finding"     = "has_phenotype",
    "has_causative_agent"        = "caused_by",
    "expanded_from"              = "related_to"
  )
  out <- unname(m[rela])
  if (is.null(out) || is.na(out) || !nzchar(out)) "related_to" else out
}

# XML-escape a character vector.
.xml_escape <- function(x) {
  x <- as.character(x); x[is.na(x)] <- ""
  x <- gsub("&",  "&amp;",  x, fixed = TRUE)
  x <- gsub("<",  "&lt;",   x, fixed = TRUE)
  x <- gsub(">",  "&gt;",   x, fixed = TRUE)
  x <- gsub('"',  "&quot;", x, fixed = TRUE)
  x <- gsub("'",  "&apos;", x, fixed = TRUE)
  x
}

# ---------------------------------------------------------------------------
# Exporters
# ---------------------------------------------------------------------------

#' Export DAG as JSON-LD with biolink-model `@context`.
export_jsonld <- function(dag) {
  ne <- .dag_to_nodes_edges(dag)
  node_objs <- lapply(seq_len(nrow(ne$nodes)), function(i) {
    list(
      `@id`      = paste0("umls:", ne$nodes$id[i]),
      `@type`    = .biolink_type(ne$nodes$category[i]),
      `name`     = ne$nodes$label[i],
      `category` = ne$nodes$category[i]
    )
  })
  edge_objs <- lapply(seq_len(nrow(ne$edges)), function(i) {
    list(
      `@type`     = "biolink:Association",
      `subject`   = paste0("umls:", ne$edges$from[i]),
      `predicate` = paste0("biolink:", .biolink_predicate(ne$edges$rela[i])),
      `object`    = paste0("umls:", ne$edges$to[i]),
      `original_predicate` = ne$edges$rela[i],
      `category`  = ne$edges$category[i]
    )
  })
  doc <- list(
    `@context` = list(
      umls    = "https://identifiers.org/umls/",
      biolink = "https://w3id.org/biolink/vocab/",
      name    = "rdfs:label",
      category = "biolink:category"
    ),
    `@id`    = paste0("umls:", dag$concept$cui),
    `@type`  = "biolink:KnowledgeGraph",
    `name`   = dag$concept$name %||% dag$concept$cui,
    `@graph` = c(node_objs, edge_objs)
  )
  jsonlite::toJSON(doc, auto_unbox = TRUE, pretty = TRUE)
}

#' Export DAG as GraphML XML.
export_graphml <- function(dag) {
  ne <- .dag_to_nodes_edges(dag)
  esc <- .xml_escape
  node_lines <- if (nrow(ne$nodes) > 0) sprintf(
    '    <node id="%s"><data key="label">%s</data><data key="category">%s</data></node>',
    esc(ne$nodes$id), esc(ne$nodes$label), esc(ne$nodes$category)
  ) else character(0)
  edge_lines <- if (nrow(ne$edges) > 0) sprintf(
    '    <edge source="%s" target="%s"><data key="rela">%s</data><data key="category">%s</data></edge>',
    esc(ne$edges$from), esc(ne$edges$to), esc(ne$edges$rela), esc(ne$edges$category)
  ) else character(0)
  paste(c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">',
    '  <key id="label"    for="node" attr.name="label"    attr.type="string"/>',
    '  <key id="category" for="node" attr.name="category" attr.type="string"/>',
    '  <key id="rela"     for="edge" attr.name="rela"     attr.type="string"/>',
    '  <key id="category" for="edge" attr.name="category" attr.type="string"/>',
    sprintf('  <graph id="%s" edgedefault="directed">', esc(dag$concept$cui %||% "DAG")),
    node_lines,
    edge_lines,
    '  </graph>',
    '</graphml>'
  ), collapse = "\n")
}

#' Write a DAG as a CSV bundle (nodes.csv + edges.csv) into a zip file.
#' Uses the `zip` package when available (no system dep); falls back to the
#' `zip` binary via R_ZIPCMD / `which zip`. Errors out cleanly if neither.
export_csv_zip <- function(dag, zipfile) {
  ne <- .dag_to_nodes_edges(dag)
  td <- tempfile("dagcsv")
  dir.create(td)
  utils::write.csv(ne$nodes, file.path(td, "nodes.csv"), row.names = FALSE)
  utils::write.csv(ne$edges, file.path(td, "edges.csv"), row.names = FALSE)
  if (requireNamespace("zip", quietly = TRUE)) {
    zip::zipr(zipfile, files = c(file.path(td, "nodes.csv"),
                                 file.path(td, "edges.csv")))
  } else {
    zip_bin <- Sys.getenv("R_ZIPCMD", "")
    if (!nzchar(zip_bin)) zip_bin <- Sys.which("zip")
    if (!nzchar(zip_bin)) {
      stop("Neither 'zip' R package nor a 'zip' binary is available; ",
           "cannot create CSV bundle. Use JSON-LD or GraphML export instead.")
    }
    old_wd <- setwd(td); on.exit(setwd(old_wd))
    system2(zip_bin, c(shQuote(zipfile), "nodes.csv", "edges.csv"))
  }
  zipfile
}

#' Export DAG as a Mermaid graph definition (capped at max_nodes for size).
export_mermaid <- function(dag, max_nodes = 80L) {
  ne <- .dag_to_nodes_edges(dag)
  if (nrow(ne$nodes) > max_nodes) {
    keep <- utils::head(ne$nodes$id, max_nodes)
    ne$nodes <- ne$nodes[ne$nodes$id %in% keep, ]
    ne$edges <- ne$edges[ne$edges$from %in% keep & ne$edges$to %in% keep, ]
  }
  sid <- function(x) gsub("[^A-Za-z0-9]", "_", x)
  sl  <- function(x) gsub('"', "'", as.character(x), fixed = TRUE)
  paste(c(
    "graph LR",
    if (nrow(ne$nodes) > 0)
      sprintf('  %s["%s"]', sid(ne$nodes$id), sl(ne$nodes$label)),
    if (nrow(ne$edges) > 0)
      sprintf('  %s -->|%s| %s',
              sid(ne$edges$from), sl(ne$edges$rela), sid(ne$edges$to))
  ), collapse = "\n")
}

# ---------------------------------------------------------------------------
# Importers
# ---------------------------------------------------------------------------

# Reconstruct a dag_result-shaped list from flat (nodes, edges) tibbles.
.nodes_edges_to_dag <- function(nodes, edges) {
  if (nrow(nodes) == 0) {
    return(list(
      concept = list(cui = "", name = "(empty graph)",
                     semantic_types = character(0), atom_count = 0L,
                     not_found = TRUE),
      relations = .empty_relations_tibble()
    ))
  }
  # Root: prefer "population" category, else the first node.
  root_idx <- which(tolower(nodes$category) == "population")[1]
  if (is.na(root_idx)) root_idx <- 1L
  concept <- list(
    cui            = nodes$id[root_idx],
    name           = nodes$label[root_idx],
    semantic_types = character(0),
    atom_count     = 0L,
    not_found      = FALSE
  )
  # Build relations tibble.
  cat_lookup <- setNames(nodes$category, nodes$id)
  name_lookup <- setNames(nodes$label, nodes$id)
  cat_for_edge <- if ("category" %in% names(edges) && any(nzchar(as.character(edges$category)))) {
    edges$category
  } else {
    unname(cat_lookup[edges$to])
  }
  cat_for_edge[is.na(cat_for_edge)] <- "other"
  relations <- tibble::tibble(
    cui            = concept$cui,
    related_cui    = edges$to,
    related_name   = unname(name_lookup[edges$to]),
    rel            = "",
    rela           = if ("rela" %in% names(edges)) edges$rela else "",
    related_id_url = "",
    category       = cat_for_edge,
    depth          = 0L,
    via            = NA_character_,
    from_cui       = edges$from
  )
  extract <- function(cats) relations |> dplyr::filter(category %in% cats)
  list(
    concept          = concept,
    relations        = relations,
    treatments       = extract("treatment"),
    comorbidities    = extract("comorbidity"),
    procedures       = extract("procedure"),
    anatomy          = extract("anatomy"),
    subtypes         = extract("subtype"),
    parents          = extract("parent"),
    etiology         = extract("etiology"),
    diagnostic_labs  = extract("diagnostic_lab"),
    monitoring_labs  = extract("monitoring_lab"),
    genetic          = extract("genetic"),
    interpretation   = extract("interpretation"),
    contraindications = extract("contraindication")
  )
}

#' Import a DAG from a JSON-LD file (round-trip of export_jsonld).
import_jsonld <- function(path) {
  doc <- jsonlite::read_json(path)
  graph <- doc$`@graph` %||% doc$graph %||% list()
  if (length(graph) == 0) {
    return(.nodes_edges_to_dag(
      tibble::tibble(id = character(0), label = character(0), category = character(0)),
      tibble::tibble(from = character(0), to = character(0), rela = character(0))
    ))
  }
  strip_pfx <- function(x) sub("^[^:]+:", "", x %||% "")
  nodes_l <- list(); edges_l <- list()
  for (item in graph) {
    if (!is.null(item$subject) && !is.null(item$object)) {
      edges_l[[length(edges_l) + 1]] <- tibble::tibble(
        from = strip_pfx(item$subject),
        to   = strip_pfx(item$object),
        rela = item$original_predicate %||% strip_pfx(item$predicate %||% "related_to"),
        category = item$category %||% NA_character_
      )
    } else if (!is.null(item$`@id`)) {
      nodes_l[[length(nodes_l) + 1]] <- tibble::tibble(
        id       = strip_pfx(item$`@id`),
        label    = item$name %||% strip_pfx(item$`@id`),
        category = item$category %||% strip_pfx(item$`@type` %||% "other")
      )
    }
  }
  nodes <- if (length(nodes_l) > 0) purrr::list_rbind(nodes_l) else
    tibble::tibble(id = character(0), label = character(0), category = character(0))
  edges <- if (length(edges_l) > 0) purrr::list_rbind(edges_l) else
    tibble::tibble(from = character(0), to = character(0),
                   rela = character(0), category = character(0))
  .nodes_edges_to_dag(nodes, edges)
}

#' Import a DAG from a GraphML file.
import_graphml <- function(path) {
  if (!requireNamespace("xml2", quietly = TRUE)) {
    stop("xml2 package required for GraphML import")
  }
  doc <- xml2::read_xml(path)
  ns  <- xml2::xml_ns(doc)
  has_ns <- any(grepl("graphml", as.character(ns)))
  pfx <- if (has_ns) "d1:" else ""
  node_xpath <- if (has_ns) "//d1:node" else "//node"
  edge_xpath <- if (has_ns) "//d1:edge" else "//edge"

  nx <- xml2::xml_find_all(doc, node_xpath, ns = ns)
  ex <- xml2::xml_find_all(doc, edge_xpath, ns = ns)
  data_xpath <- function(node, key) {
    sel <- if (has_ns) sprintf("./d1:data[@key='%s']", key) else
                       sprintf("./data[@key='%s']", key)
    xml2::xml_text(xml2::xml_find_first(node, sel, ns = ns))
  }
  nodes <- tibble::tibble(
    id       = xml2::xml_attr(nx, "id"),
    label    = vapply(nx, data_xpath, character(1), key = "label"),
    category = vapply(nx, data_xpath, character(1), key = "category")
  )
  edges <- tibble::tibble(
    from     = xml2::xml_attr(ex, "source"),
    to       = xml2::xml_attr(ex, "target"),
    rela     = vapply(ex, data_xpath, character(1), key = "rela"),
    category = vapply(ex, data_xpath, character(1), key = "category")
  )
  .nodes_edges_to_dag(nodes, edges)
}

#' Import a DAG from a zip with nodes.csv + edges.csv.
import_csv_zip <- function(path) {
  td <- tempfile("dagunzip")
  dir.create(td)
  utils::unzip(path, exdir = td)
  files <- list.files(td, recursive = TRUE, full.names = TRUE)
  nf <- files[grepl("nodes\\.csv$", files)][1]
  ef <- files[grepl("edges\\.csv$", files)][1]
  if (is.na(nf) || is.na(ef)) stop("zip must contain nodes.csv and edges.csv")
  nodes <- utils::read.csv(nf, stringsAsFactors = FALSE)
  edges <- utils::read.csv(ef, stringsAsFactors = FALSE)
  .nodes_edges_to_dag(tibble::as_tibble(nodes), tibble::as_tibble(edges))
}

#' Dispatch on file extension.
import_dag <- function(path) {
  ext <- tolower(tools::file_ext(path))
  switch(ext,
    json    = import_jsonld(path),
    jsonld  = import_jsonld(path),
    graphml = import_graphml(path),
    xml     = import_graphml(path),
    zip     = import_csv_zip(path),
    stop("Unsupported file extension: ", ext,
         " (expected json, jsonld, graphml, xml, zip)")
  )
}

# ---------------------------------------------------------------------------
# Re-traverse helper
# ---------------------------------------------------------------------------

#' Walk every (UMLS-CUI) member of a category and merge results.
#'
#' @param dag        Existing dag_result.
#' @param category   One of "treatments", "comorbidities", "procedures",
#'                   "diagnostic_labs", "monitoring_labs".
#' @param max_calls  Cap on number of concepts to walk (defends against
#'                   exploding API usage on very large categories).
#' @param expand_n   Forwarded to walk_concept_dag.
#' @param progress   Optional progress callback.
#' @return Updated dag_result (or unchanged if category empty / not present).
retraverse_category <- function(dag, category, max_calls = 10L,
                                expand_n = 8L, progress = NULL) {
  cat_tbl <- dag[[category]]
  if (is.null(cat_tbl) || nrow(cat_tbl) == 0) return(dag)
  # Build resolved-CUI list. UMLS CUIs are used directly; source-vocab IDs
  # (RxNorm, SNOMED, AUI, HGNC) are resolved to CUIs via their stored URL.
  walkable <- character(0)
  has_url <- "related_id_url" %in% names(cat_tbl)
  for (i in seq_len(nrow(cat_tbl))) {
    rcui <- cat_tbl$related_cui[i]
    if (grepl("^C\\d+$", rcui)) {
      walkable <- c(walkable, rcui)
    } else if (has_url) {
      url <- cat_tbl$related_id_url[i]
      if (is.na(url) || !nzchar(url)) next
      resolved <- tryCatch(resolve_source_url_to_cui(url),
                           error = function(e) NA_character_)
      if (!is.na(resolved) && grepl("^C\\d+$", resolved)) {
        walkable <- c(walkable, resolved)
      }
    }
    if (length(walkable) >= max_calls) break
  }
  walkable <- unique(walkable)
  if (length(walkable) == 0) {
    if (!is.null(progress)) progress(paste0("No walkable concepts in ", category))
    return(dag)
  }
  for (i in seq_along(walkable)) {
    if (!is.null(progress)) {
      progress(sprintf("Re-traversing %s %d/%d: %s",
                       category, i, length(walkable), walkable[i]))
    }
    sub <- tryCatch(
      walk_concept_dag(walkable[i], max_depth = 1L, expand_n = expand_n),
      error = function(e) NULL
    )
    if (is.null(sub)) next
    dag <- combine_dags(dag, sub, link_rela = NULL)
  }
  dag
}
