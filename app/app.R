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

# Source modules
source("R/umls_client.R")
source("R/dag_walker.R")
source("R/code_lists.R")
source("R/network_viz.R")

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
    )
  ),

  # Main panels
  nav_panel("Concept DAG",
    card(
      card_header("Concept Relationship Graph"),
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
      card_header("Treatments (from UMLS may_be_treated_by)"),
      DTOutput("treatments_table")
    )
  ),

  nav_panel("Labs",
    card(
      card_header("Monitoring Labs (from treatment → component_of)"),
      DTOutput("monitoring_labs_table")
    )
  ),

  nav_panel("Comorbidities",
    card(
      card_header("Comorbidities (from UMLS clinically_associated_with)"),
      DTOutput("comorbidities_table")
    )
  ),

  nav_panel("Procedures",
    card(
      card_header("Procedures (from UMLS focus_of)"),
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
    withProgress(message = "Walking UMLS concept graph...", {
      rv$dag_result <- walk_concept_dag(
        rv$pop_cui,
        discover_monitoring_labs = TRUE,
        progress = \(msg) setProgress(message = msg)
      )
      rv$pop_concept <- rv$dag_result$concept
    })
  })

  # --- Intervention search ---
  observeEvent(input$int_search, {
    req(nchar(input$int_term) > 0)
    results <- umls_search(input$int_term)
    if (nrow(results) > 0) rv$int_search_results <- results
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
    build_dag_network(rv$dag_result)
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
    nrow(rv$dag_result$monitoring_labs)
  })

  output$n_procedures <- renderText({
    if (is.null(rv$dag_result)) return("—")
    nrow(rv$dag_result$procedures)
  })

  # --- Data tables ---
  output$treatments_table <- renderDT({
    req(rv$dag_result)
    rv$dag_result$treatments |>
      dplyr::select(
        Drug = related_name,
        CUI = related_cui,
        Relationship = rela
      ) |>
      datatable(
        filter = "top",
        options = list(pageLength = 25),
        rownames = FALSE
      )
  })

  output$monitoring_labs_table <- renderDT({
    req(rv$dag_result)
    if (nrow(rv$dag_result$monitoring_labs) == 0) {
      return(datatable(tibble::tibble(Message = "No monitoring labs discovered")))
    }
    rv$dag_result$monitoring_labs |>
      dplyr::select(
        Lab = related_name,
        CUI = related_cui,
        `Monitors Drug` = parent_drug_name,
        Relationship = rela
      ) |>
      datatable(
        filter = "top",
        options = list(pageLength = 25),
        rownames = FALSE
      )
  })

  output$comorbidities_table <- renderDT({
    req(rv$dag_result)
    rv$dag_result$comorbidities |>
      dplyr::select(
        Condition = related_name,
        CUI = related_cui,
        Relationship = rela
      ) |>
      datatable(
        filter = "top",
        options = list(pageLength = 25),
        rownames = FALSE
      )
  })

  output$procedures_table <- renderDT({
    req(rv$dag_result)
    rv$dag_result$procedures |>
      dplyr::select(
        Procedure = related_name,
        CUI = related_cui,
        Relationship = rela
      ) |>
      datatable(
        filter = "top",
        options = list(pageLength = 25),
        rownames = FALSE
      )
  })

  # --- Code list generation ---
  observeEvent(input$gen_codes, {
    req(rv$dag_result)
    withProgress(message = "Generating code lists...", {
      rv$code_lists <- package_code_lists(rv$dag_result)
    })
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
        nrow(rv$dag_result$procedures), " procedures, and ",
        nrow(rv$dag_result$monitoring_labs), " monitoring labs ",
        "discovered via UMLS concept graph traversal."
      )),
      tags$p("Click 'Download (.qmd)' for the full document.")
    )
  })
}

shinyApp(ui, server)
