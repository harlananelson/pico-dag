#' pico-dag: PICO-Driven Clinical Research Accelerator
#'
#' Enter a PICO research question → walk UMLS concept graph →
#' explore treatments, labs, comorbidities → export code lists + data pull spec

library(shiny)
library(bslib)
library(DT)
library(visNetwork)
library(httr2)
library(tidyverse)
library(DBI)
library(duckdb)

# Source modules — DuckDB client auto-falls-back to REST when DB absent
source("R/umls_client_duckdb.R")
source("R/medrt_rxnav.R")  # MED-RT drug-disease relations cache via RxNav
source("R/dag_walker.R")
source("R/code_lists.R")
source("R/network_viz.R")
source("R/telemetry.R")
source("R/dag_export.R")

# Initialize the MED-RT cache table (creates if missing, no-op otherwise)
medrt_cache_init()

# --- UI ---

ui <- page_navbar(
  title = "pico-dag",
  theme = bs_theme(bootswatch = "flatly", version = 5),

  # PICO Input sidebar
  sidebar = sidebar(
    width = 350,
    h4("PICO Study Design"),
    hr(),

    # Population
    h5("P — Population"),
    layout_columns(
      textInput("pop_term", NULL, placeholder = "e.g., Atrial Fibrillation"),
      actionButton("pop_search", "Search", class = "btn-primary btn-sm"),
      col_widths = c(8, 4)
    ),
    uiOutput("pop_result"),
    actionButton("pop_walk", "Walk DAG", class = "btn-success btn-sm", width = "100%"),
    hr(),

    # Intervention
    h5("I — Intervention"),
    layout_columns(
      textInput("int_term", NULL, placeholder = "e.g., Catheter ablation"),
      actionButton("int_search", "Search", class = "btn-primary btn-sm"),
      col_widths = c(8, 4)
    ),
    uiOutput("int_result"),
    hr(),

    # Comparator
    h5("C — Comparator"),
    layout_columns(
      textInput("comp_term", NULL, placeholder = "e.g., Rate control"),
      actionButton("comp_search", "Search", class = "btn-primary btn-sm"),
      col_widths = c(8, 4)
    ),
    uiOutput("comp_result"),
    hr(),

    # Outcome
    h5("O — Outcome"),
    layout_columns(
      textInput("out_term", NULL, placeholder = "e.g., Ischemic stroke"),
      actionButton("out_search", "Search", class = "btn-primary btn-sm"),
      col_widths = c(8, 4)
    ),
    uiOutput("out_result"),
    hr(),

    # Time
    h5("T — Time"),
    layout_columns(
      numericInput("lookback", "Lookback (yr)", 1, min = 0),
      numericInput("followup", "Follow-up (yr)", 5, min = 1),
      col_widths = c(6, 6)
    ),
    hr(),

    # Target
    radioButtons("target", "Execution Target",
      choices = c(
        "HDL / lhn (PySpark)" = "hdl",
        "Databricks (OMOP)" = "databricks",
        "IUH EDW (R/dbplyr)" = "edw"
      ),
      selected = "databricks"
    ),
    hr(),

    # Privacy
    checkboxInput("incognito_mode",
      label = HTML("&#128274; Incognito — don't log my searches"),
      value = FALSE),
    tags$div(
      style = "font-size: 0.75rem; color: #6c757d; margin-top: -8px;",
      "Default: search terms and DAG actions are logged anonymously",
      tags$br(),
      "(session ID hashed daily) to improve the tool."
    )
  ),

  # Main panels
  nav_panel("Concept DAG",
    card(
      card_header(
        "Concept Relationship Graph",
        tags$div(style = "float:right; font-size: 0.75rem;",
          "Click a node to expand it. ",
          actionLink("dag_reset", "Reset to seed",
                     style = "color:#3498DB; text-decoration:underline;")
        )
      ),
      visNetworkOutput("dag_network", height = "600px")
    ),
    layout_columns(
      value_box("Treatments", textOutput("n_treatments"), theme = "primary"),
      value_box("Comorbidities", textOutput("n_comorbidities"), theme = "warning"),
      value_box("Labs", textOutput("n_labs"), theme = "success"),
      value_box("Procedures", textOutput("n_procedures"), theme = "info"),
      col_widths = c(3, 3, 3, 3)
    )
  ),

  nav_panel("Treatments",
    card(
      card_header(
        "Treatments (from UMLS may_be_treated_by)",
        tags$div(style = "float:right;",
          actionButton("retraverse_treatments", "Re-traverse all treatments",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrow-up-right-dots"))
        )
      ),
      DTOutput("treatments_table")
    )
  ),

  nav_panel("Labs",
    card(
      card_header(
        "Diagnostic Labs (from disease → evaluated_by / has_associated_finding)",
        tags$div(style = "float:right;",
          actionButton("retraverse_diag_labs", "Re-traverse",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrow-up-right-dots"))
        )
      ),
      DTOutput("diagnostic_labs_table")
    ),
    card(
      card_header(
        "Monitoring Labs (from treatment → component_of)",
        tags$div(style = "float:right;",
          actionButton("retraverse_mon_labs", "Re-traverse",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrow-up-right-dots"))
        )
      ),
      DTOutput("monitoring_labs_table")
    )
  ),

  nav_panel("Comorbidities",
    card(
      card_header(
        "Comorbidities (from UMLS clinically_associated_with)",
        tags$div(style = "float:right;",
          actionButton("retraverse_comorbidities", "Re-traverse all comorbidities",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrow-up-right-dots"))
        )
      ),
      DTOutput("comorbidities_table")
    )
  ),

  nav_panel("Procedures",
    card(
      card_header(
        "Procedures (from UMLS focus_of)",
        tags$div(style = "float:right;",
          actionButton("retraverse_procedures", "Re-traverse all procedures",
                       class = "btn-sm btn-outline-primary",
                       icon = icon("arrow-up-right-dots"))
        )
      ),
      DTOutput("procedures_table")
    )
  ),

  nav_panel("Code Lists",
    card(
      card_header("Generated Code Lists"),
      layout_columns(
        actionButton("gen_codes", "Generate Code Lists",
                     class = "btn-success", icon = icon("download")),
        downloadButton("download_codes", "Download All (ZIP)",
                       class = "btn-primary"),
        col_widths = c(4, 4)
      ),
      hr(),
      uiOutput("code_list_tabs")
    )
  ),

  nav_panel("Export / Import",
    card(
      card_header("Export DAG to a standard graph format"),
      p(class = "text-muted small",
        "JSON-LD uses the biolink-model context (best for AI / knowledge-graph ",
        "tools). GraphML is interoperable with Cytoscape, Gephi, yEd, and igraph. ",
        "CSV bundle is the simplest — two CSVs in a zip. Mermaid is plain text ",
        "you can paste into Markdown or an LLM."),
      layout_columns(
        radioButtons("export_format", "Format:",
          choices = c(
            "JSON-LD (biolink)" = "jsonld",
            "GraphML"           = "graphml",
            "CSV bundle (zip)"  = "csvzip",
            "Mermaid (text)"    = "mermaid"
          ),
          selected = "jsonld",
          inline   = FALSE
        ),
        downloadButton("download_dag", "Download current DAG",
                       class = "btn-primary"),
        col_widths = c(6, 6)
      )
    ),
    card(
      card_header("Import a manipulated DAG"),
      p(class = "text-muted small",
        "Upload a JSON-LD, GraphML, or CSV-bundle (.zip) file. The current ",
        "DAG will be replaced with the uploaded one. The clicked-node ",
        "expansion and re-traverse buttons all continue to work on imports."),
      fileInput("upload_dag", NULL,
                accept = c(".json", ".jsonld", ".graphml", ".xml", ".zip"),
                buttonLabel = "Choose file...",
                placeholder = "JSON-LD / GraphML / CSV.zip"),
      verbatimTextOutput("upload_status")
    )
  ),

  nav_panel("Data Pull Request",
    card(
      card_header("Data Pull Specification"),
      downloadButton("download_pull_request", "Download (.qmd)",
                     class = "btn-primary"),
      hr(),
      htmlOutput("pull_request_preview")
    )
  )
)


# --- Server ---

server <- function(input, output, session) {

  # Privacy gate. When the user enables Incognito, log_event() is never called.
  # We read input$incognito_mode via isolate() inside event handlers so that
  # toggling the checkbox does NOT itself trigger a re-run of every observer.
  track <- function(event_type, ...) {
    if (isTRUE(isolate(input$incognito_mode))) return(invisible())
    log_event(event_type, session_id = session$token, ...)
  }

  # Convenience wrapper bound to this session — uses the session token so
  # error events are attributed (anonymously hashed) to the session that
  # produced them. Even errors are written when incognito is on, because
  # crashes are diagnostic, not behavioral, and the session id is hashed.
  safe <- function(expr, where, fallback = NULL, notify = TRUE) {
    safely_run(expr, where, session_id = session$token,
               fallback = fallback, notify = notify)
  }

  # Session-level error hook. shiny::onSessionEnded fires after the session
  # closes; we capture a final lifecycle marker for completeness.
  session$onSessionEnded(function() {
    log_event("session_end", session_id = session$token)
  })
  log_event("session_start", session_id = session$token,
            user_agent = paste(session$request$HTTP_USER_AGENT %||% "", collapse = ""))

  # Visual indicator when incognito is on.
  observeEvent(input$incognito_mode, ignoreInit = TRUE, {
    if (isTRUE(input$incognito_mode)) {
      showNotification(
        HTML("&#128274; Incognito mode is on — your searches are not being logged."),
        type = "message", duration = 4
      )
    }
  })

  # Reactive values
  rv <- reactiveValues(
    pop_cui = NULL,
    pop_concept = NULL,
    dag_result = NULL,
    int_cui = NULL,
    int_result = NULL,
    comp_cui = NULL,
    comp_result = NULL,
    out_cui = NULL,
    out_result = NULL,
    code_lists = NULL
  )

  # --- Population search ---
  observeEvent(input$pop_search, {
    req(nchar(input$pop_term) > 0)
    results <- umls_search(input$pop_term)
    if (nrow(results) > 0) {
      rv$pop_search_results <- results
    }
    track("search_pico",
      element    = "population",
      term       = input$pop_term,
      n_results  = nrow(results),
      top_cui    = if (nrow(results) > 0) results$cui[1] else NA,
      top_name   = if (nrow(results) > 0) results$name[1] else NA
    )
  })

  output$pop_result <- renderUI({
    req(rv$pop_search_results)
    results <- rv$pop_search_results
    choices <- setNames(results$cui, paste0(results$name, " (", results$cui, ")"))
    selectInput("pop_cui_select", "Select concept:", choices = choices)
  })

  observeEvent(input$pop_cui_select, {
    rv$pop_cui <- input$pop_cui_select
  })

  # --- Walk DAG ---
  observeEvent(input$pop_walk, {
    req(rv$pop_cui)
    safe(where = "pop_walk", expr = {
      withProgress(message = "Walking UMLS concept graph...", {
        rv$dag_result <- walk_concept_dag_dense(
          rv$pop_cui,
          progress = \(msg) setProgress(message = msg)
        )
        rv$pop_concept <- rv$dag_result$concept
        if (isTRUE(rv$dag_result$concept$not_found)) {
          showNotification(
            "Concept not found in current UMLS release. Try a different search term.",
            type = "error", duration = 8
          )
        }
      })
      track("dag_build",
        cui               = rv$pop_cui,
        concept_name      = rv$dag_result$concept$name,
        n_treatments      = nrow(rv$dag_result$treatments),
        n_comorbidities   = nrow(rv$dag_result$comorbidities),
        n_procedures      = nrow(rv$dag_result$procedures),
        n_diagnostic_labs = nrow(rv$dag_result$diagnostic_labs),
        n_parents         = nrow(rv$dag_result$parents),
        not_found         = isTRUE(rv$dag_result$concept$not_found)
      )
    })
  })

  # Node click: ADDITIVELY expand around the clicked concept. The existing
  # DAG is preserved; new nodes from the clicked concept's relations are
  # merged in with edges originating from the clicked node id.
  # Accepts UMLS CUIs and source-vocab ids (RxNorm/SNOMED/AUI/HPO) — the
  # extender resolves source ids to CUIs via the relations table.
  observeEvent(input$dag_node_click, safe(where = "dag_node_click", expr = {
    new_id <- input$dag_node_click
    req(nzchar(new_id %||% ""))
    if (is.null(rv$dag_result)) return()
    snapshot <- function(d) c(
      treatments    = nrow(d$treatments),
      comorbidities = nrow(d$comorbidities),
      procedures    = nrow(d$procedures),
      diag_labs     = nrow(d$diagnostic_labs),
      mon_labs      = nrow(d$monitoring_labs)
    )
    before <- snapshot(rv$dag_result)
    withProgress(message = paste0("Expanding around ", new_id, "..."), {
      rv$dag_result <- extend_concept_dag(
        rv$dag_result, new_id,
        progress = \(msg) setProgress(message = msg)
      )
    })
    after <- snapshot(rv$dag_result)
    delta <- after - before
    grew <- delta[delta > 0]
    if (length(grew) > 0) {
      pretty <- c(treatments = "treatments", comorbidities = "comorbidities",
                  procedures = "procedures", diag_labs = "diagnostic labs",
                  mon_labs = "monitoring labs")
      parts <- paste0("+", grew, " ", pretty[names(grew)])
      showNotification(
        paste0("Expanded: ", paste(parts, collapse = ", ")),
        type = "message", duration = 5
      )
    } else {
      showNotification(
        "Clicked node has no new related concepts to add.",
        type = "warning", duration = 4
      )
    }
    track("node_click_extend",
      to_id            = new_id,
      d_treatments     = unname(delta["treatments"]),
      d_comorbidities  = unname(delta["comorbidities"]),
      d_procedures     = unname(delta["procedures"]),
      d_diagnostic_labs = unname(delta["diag_labs"]),
      d_monitoring_labs = unname(delta["mon_labs"])
    )
  }))

  # Reset DAG to original seed walk
  observeEvent(input$dag_reset, safe(where = "dag_reset", expr = {
    req(rv$pop_cui)
    withProgress(message = "Resetting DAG to seed...", {
      rv$dag_result <- walk_concept_dag_dense(
        rv$pop_cui,
        progress = \(msg) setProgress(message = msg)
      )
      rv$pop_concept <- rv$dag_result$concept
    })
    track("dag_reset", cui = rv$pop_cui)
  }))

  # --- Intervention search ---
  observeEvent(input$int_search, {
    req(nchar(input$int_term) > 0)
    results <- umls_search(input$int_term)
    if (nrow(results) > 0) rv$int_search_results <- results
    track("search_pico",
      element   = "intervention", term = input$int_term,
      n_results = nrow(results),
      top_cui   = if (nrow(results) > 0) results$cui[1] else NA
    )
  })

  output$int_result <- renderUI({
    req(rv$int_search_results)
    results <- rv$int_search_results
    choices <- setNames(results$cui, paste0(results$name, " (", results$cui, ")"))
    selectInput("int_cui_select", "Select:", choices = choices)
  })

  observeEvent(input$int_cui_select, { rv$int_cui <- input$int_cui_select })

  # --- Comparator search ---
  observeEvent(input$comp_search, {
    req(nchar(input$comp_term) > 0)
    results <- umls_search(input$comp_term)
    if (nrow(results) > 0) rv$comp_search_results <- results
    track("search_pico",
      element   = "comparator", term = input$comp_term,
      n_results = nrow(results),
      top_cui   = if (nrow(results) > 0) results$cui[1] else NA
    )
  })

  output$comp_result <- renderUI({
    req(rv$comp_search_results)
    results <- rv$comp_search_results
    choices <- setNames(results$cui, paste0(results$name, " (", results$cui, ")"))
    selectInput("comp_cui_select", "Select:", choices = choices)
  })

  observeEvent(input$comp_cui_select, { rv$comp_cui <- input$comp_cui_select })

  # --- Outcome search ---
  observeEvent(input$out_search, {
    req(nchar(input$out_term) > 0)
    results <- umls_search(input$out_term)
    if (nrow(results) > 0) rv$out_search_results <- results
    track("search_pico",
      element   = "outcome", term = input$out_term,
      n_results = nrow(results),
      top_cui   = if (nrow(results) > 0) results$cui[1] else NA
    )
  })

  output$out_result <- renderUI({
    req(rv$out_search_results)
    results <- rv$out_search_results
    choices <- setNames(results$cui, paste0(results$name, " (", results$cui, ")"))
    selectInput("out_cui_select", "Select:", choices = choices)
  })

  observeEvent(input$out_cui_select, { rv$out_cui <- input$out_cui_select })

  # --- DAG Network ---
  output$dag_network <- renderVisNetwork({
    req(rv$dag_result)
    safe(where = "render_dag_network", expr = build_dag_network(rv$dag_result))
  })

  # --- Value boxes ---
  output$n_treatments <- renderText({
    if (is.null(rv$dag_result)) return("—")
    nrow(rv$dag_result$treatments)
  })

  output$n_comorbidities <- renderText({
    if (is.null(rv$dag_result)) return("—")
    nrow(rv$dag_result$comorbidities)
  })

  output$n_labs <- renderText({
    if (is.null(rv$dag_result)) return("—")
    nrow(rv$dag_result$monitoring_labs) + nrow(rv$dag_result$diagnostic_labs)
  })

  output$diagnostic_labs_table <- renderDT({
    req(rv$dag_result)
    safe(where = "diagnostic_labs_table",
         fallback = datatable(tibble::tibble(Error = "Failed to render — see telemetry")),
         expr = {
      if (is.null(rv$dag_result$diagnostic_labs) ||
          nrow(rv$dag_result$diagnostic_labs) == 0) {
        return(datatable(tibble::tibble(
          Message = "No diagnostic labs found — tried root concept, causative agent, parents, and subtypes"
        )))
      }
      df <- rv$dag_result$diagnostic_labs |>
        dplyr::select(
          Lab        = related_name,
          CUI        = related_cui,
          Relationship = rela,
          `Via`      = dplyr::any_of("via_neighbor")
        )
      datatable(df, filter = "top", options = list(pageLength = 25), rownames = FALSE)
    })
  })

  output$n_procedures <- renderText({
    if (is.null(rv$dag_result)) return("—")
    nrow(rv$dag_result$procedures)
  })

  # --- Data tables ---
  output$treatments_table <- renderDT({
    req(rv$dag_result)
    safe(where = "treatments_table",
         fallback = datatable(tibble::tibble(Error = "Failed to render — see telemetry")),
         expr = {
      rv$dag_result$treatments |>
        dplyr::select(Drug = related_name, CUI = related_cui, Relationship = rela) |>
        datatable(filter = "top", options = list(pageLength = 25), rownames = FALSE)
    })
  })

  output$monitoring_labs_table <- renderDT({
    req(rv$dag_result)
    safe(where = "monitoring_labs_table",
         fallback = datatable(tibble::tibble(Error = "Failed to render — see telemetry")),
         expr = {
      if (nrow(rv$dag_result$monitoring_labs) == 0) {
        return(datatable(tibble::tibble(Message = "No monitoring labs discovered")))
      }
      drug_lookup <- rv$dag_result$relations |>
        dplyr::distinct(related_cui, related_name) |>
        dplyr::rename(from_cui = related_cui, drug_name = related_name)
      rv$dag_result$monitoring_labs |>
        dplyr::left_join(drug_lookup, by = "from_cui") |>
        dplyr::transmute(
          Lab            = related_name,
          CUI            = related_cui,
          `Monitors Drug` = dplyr::coalesce(drug_name, from_cui),
          Relationship   = rela
        ) |>
        datatable(filter = "top", options = list(pageLength = 25), rownames = FALSE)
    })
  })

  output$comorbidities_table <- renderDT({
    req(rv$dag_result)
    safe(where = "comorbidities_table",
         fallback = datatable(tibble::tibble(Error = "Failed to render — see telemetry")),
         expr = {
      rv$dag_result$comorbidities |>
        dplyr::select(Condition = related_name, CUI = related_cui, Relationship = rela) |>
        datatable(filter = "top", options = list(pageLength = 25), rownames = FALSE)
    })
  })

  output$procedures_table <- renderDT({
    req(rv$dag_result)
    safe(where = "procedures_table",
         fallback = datatable(tibble::tibble(Error = "Failed to render — see telemetry")),
         expr = {
      rv$dag_result$procedures |>
        dplyr::select(Procedure = related_name, CUI = related_cui, Relationship = rela) |>
        datatable(filter = "top", options = list(pageLength = 25), rownames = FALSE)
    })
  })

  # --- Code list generation ---
  observeEvent(input$gen_codes, {
    req(rv$dag_result)
    withProgress(message = "Generating code lists...", {
      rv$code_lists <- package_code_lists(rv$dag_result)
    })
    track("code_generate",
      cui          = rv$dag_result$concept$cui,
      concept_name = rv$dag_result$concept$name,
      n_tables     = length(rv$code_lists)
    )
  })

  output$code_list_tabs <- renderUI({
    req(rv$code_lists)
    tabs <- purrr::imap(rv$code_lists, \(data, name) {
      tabPanel(
        name,
        DTOutput(paste0("cl_", name))
      )
    })
    do.call(tabsetPanel, tabs)
  })

  observe({
    req(rv$code_lists)
    purrr::iwalk(rv$code_lists, \(data, name) {
      output_id <- paste0("cl_", name)
      output[[output_id]] <- renderDT({
        datatable(data, filter = "top", options = list(pageLength = 20), rownames = FALSE)
      })
    })
  })

  # --- Downloads ---
  output$download_codes <- downloadHandler(
    filename = function() {
      condition <- rv$pop_concept$name %||% "study"
      condition_clean <- stringr::str_replace_all(tolower(condition), "[^a-z0-9]+", "-")
      paste0(condition_clean, "-code-lists-", Sys.Date(), ".zip")
    },
    content = function(file) {
      req(rv$code_lists)
      tmpdir <- tempdir()
      code_dir <- file.path(tmpdir, "code-lists")
      dir.create(code_dir, showWarnings = FALSE, recursive = TRUE)

      purrr::iwalk(rv$code_lists, \(data, name) {
        readr::write_csv(data, file.path(code_dir, paste0(name, ".csv")))
      })

      # Create zip
      old_wd <- setwd(tmpdir)
      on.exit(setwd(old_wd))
      utils::zip(file, files = list.files("code-lists", full.names = TRUE))
    }
  )

  # --- Export DAG to standard graph formats ---
  .export_filename_for <- function(fmt) {
    cond <- rv$pop_concept$name %||% "dag"
    slug <- stringr::str_replace_all(tolower(cond), "[^a-z0-9]+", "-")
    ext <- switch(fmt, jsonld = "jsonld", graphml = "graphml",
                       csvzip = "zip", mermaid = "mmd", "txt")
    paste0(slug, "-dag-", Sys.Date(), ".", ext)
  }

  output$download_dag <- downloadHandler(
    filename = function() .export_filename_for(input$export_format),
    content  = function(file) {
      req(rv$dag_result)
      fmt <- input$export_format
      safe(where = paste0("export_", fmt), expr = {
        if (fmt == "jsonld") {
          writeLines(export_jsonld(rv$dag_result), file)
        } else if (fmt == "graphml") {
          writeLines(export_graphml(rv$dag_result), file)
        } else if (fmt == "csvzip") {
          export_csv_zip(rv$dag_result, file)
        } else if (fmt == "mermaid") {
          writeLines(export_mermaid(rv$dag_result), file)
        }
        track("dag_export", format = fmt,
              cui = rv$dag_result$concept$cui,
              n_relations = nrow(rv$dag_result$relations))
      })
    }
  )

  # --- Import a manipulated DAG ---
  output$upload_status <- renderPrint({
    if (is.null(rv$upload_status)) cat("(no file uploaded yet)") else cat(rv$upload_status)
  })

  observeEvent(input$upload_dag, safe(where = "import_dag", expr = {
    info <- input$upload_dag
    req(info)
    new_dag <- import_dag(info$datapath)
    if (is.null(new_dag) || isTRUE(new_dag$concept$not_found) ||
        nrow(new_dag$relations) == 0) {
      rv$upload_status <- paste0("Imported but empty: ", info$name)
      showNotification("Uploaded file produced an empty DAG. Check format.",
                       type = "warning", duration = 5)
      return(NULL)
    }
    rv$dag_result <- new_dag
    rv$pop_concept <- new_dag$concept
    rv$pop_cui    <- new_dag$concept$cui
    rv$upload_status <- sprintf(
      "Imported %s: %d nodes, %d relations\nRoot: %s (%s)",
      info$name, nrow(new_dag$relations) + 1L, nrow(new_dag$relations),
      new_dag$concept$name, new_dag$concept$cui
    )
    showNotification(
      paste0("Imported DAG: ", new_dag$concept$name,
             " (", nrow(new_dag$relations), " relations)"),
      type = "message", duration = 5
    )
    track("dag_import",
      file_name   = info$name,
      file_size   = info$size,
      n_relations = nrow(new_dag$relations),
      root_cui    = new_dag$concept$cui
    )
  }))

  # --- Re-traverse buttons (one per category) ---
  .retraverse_handler <- function(category, label) {
    function() {
      safe(where = paste0("retraverse_", category), expr = {
        req(rv$dag_result)
        before <- nrow(rv$dag_result$relations)
        withProgress(message = paste0("Re-traversing ", label, "..."), {
          rv$dag_result <- retraverse_category(
            rv$dag_result, category, max_calls = 8L,
            progress = \(m) setProgress(message = m)
          )
        })
        after <- nrow(rv$dag_result$relations)
        added <- after - before
        showNotification(
          paste0("Re-traversed ", label, ": ", added, " new relations added."),
          type = if (added > 0) "message" else "warning", duration = 5
        )
        track("retraverse",
          category    = category,
          delta       = added,
          n_relations = after
        )
      })
    }
  }
  observeEvent(input$retraverse_treatments,
               .retraverse_handler("treatments",      "treatments")())
  observeEvent(input$retraverse_comorbidities,
               .retraverse_handler("comorbidities",   "comorbidities")())
  observeEvent(input$retraverse_procedures,
               .retraverse_handler("procedures",      "procedures")())
  observeEvent(input$retraverse_diag_labs,
               .retraverse_handler("diagnostic_labs", "diagnostic labs")())
  observeEvent(input$retraverse_mon_labs,
               .retraverse_handler("monitoring_labs", "monitoring labs")())

  output$download_pull_request <- downloadHandler(
    filename = function() {
      condition <- rv$pop_concept$name %||% "study"
      condition_clean <- stringr::str_replace_all(tolower(condition), "[^a-z0-9]+", "-")
      paste0(condition_clean, "-data-pull-request.qmd")
    },
    content = function(file) {
      req(rv$dag_result)

      # Generate QMD content
      concept <- rv$dag_result$concept
      treatments <- rv$dag_result$treatments
      comorbidities <- rv$dag_result$comorbidities
      procedures <- rv$dag_result$procedures
      monitoring <- rv$dag_result$monitoring_labs

      lines <- c(
        "---",
        paste0('title: "Data Pull Request — ', concept$name, '"'),
        paste0('subtitle: "DAG-derived from UMLS (', concept$cui, ')"'),
        "date: today",
        "format:",
        "  html:",
        "    toc: true",
        "    number-sections: true",
        "    theme: cosmo",
        "execute:",
        "  eval: false",
        "---",
        "",
        "# Population",
        "",
        paste0("**Condition:** ", concept$name, " (CUI: ", concept$cui, ")"),
        paste0("**Semantic types:** ", paste(concept$semantic_types, collapse = ", ")),
        "",
        "# Treatments",
        "",
        "| Drug | CUI | Relationship |",
        "|------|-----|-------------|"
      )

      for (i in seq_len(nrow(treatments))) {
        lines <- c(lines, paste0(
          "| ", treatments$related_name[i],
          " | ", treatments$related_cui[i],
          " | ", treatments$rela[i], " |"
        ))
      }

      lines <- c(lines, "", "# Comorbidities", "",
                  "| Condition | CUI | Relationship |",
                  "|-----------|-----|-------------|")

      for (i in seq_len(nrow(comorbidities))) {
        lines <- c(lines, paste0(
          "| ", comorbidities$related_name[i],
          " | ", comorbidities$related_cui[i],
          " | ", comorbidities$rela[i], " |"
        ))
      }

      if (nrow(procedures) > 0) {
        lines <- c(lines, "", "# Procedures", "",
                    "| Procedure | CUI | Relationship |",
                    "|-----------|-----|-------------|")
        for (i in seq_len(nrow(procedures))) {
          lines <- c(lines, paste0(
            "| ", procedures$related_name[i],
            " | ", procedures$related_cui[i],
            " | ", procedures$rela[i], " |"
          ))
        }
      }

      if (nrow(monitoring) > 0) {
        lines <- c(lines, "", "# Monitoring Labs", "",
                    "| Lab | Monitors | CUI |",
                    "|-----|----------|-----|")
        unique_labs <- monitoring |>
          dplyr::distinct(related_cui, .keep_all = TRUE) |>
          utils::head(30)
        for (i in seq_len(nrow(unique_labs))) {
          lines <- c(lines, paste0(
            "| ", unique_labs$related_name[i],
            " | ", unique_labs$parent_drug_name[i],
            " | ", unique_labs$related_cui[i], " |"
          ))
        }
      }

      writeLines(lines, file)
    }
  )

  # --- Pull request preview ---
  output$pull_request_preview <- renderUI({
    req(rv$dag_result)
    concept <- rv$dag_result$concept

    tags$div(
      tags$h3(paste0("Data Pull Request — ", concept$name)),
      tags$p(paste0("CUI: ", concept$cui)),
      tags$p(paste0("Semantic types: ", paste(concept$semantic_types, collapse = ", "))),
      tags$hr(),
      tags$p(paste0(
        "This specification covers ",
        nrow(rv$dag_result$treatments), " treatments, ",
        nrow(rv$dag_result$comorbidities), " comorbidities, ",
        nrow(rv$dag_result$procedures), " procedures, ",
        nrow(rv$dag_result$diagnostic_labs), " diagnostic labs, and ",
        nrow(rv$dag_result$monitoring_labs), " monitoring labs ",
        "discovered via UMLS concept graph traversal."
      )),
      tags$p("Click 'Download (.qmd)' for the full document.")
    )
  })
}

shinyApp(ui, server)
