#!/usr/bin/env Rscript
# Read pico-dag telemetry events into a tibble for inspection.
#
# Usage:
#   Rscript scripts/read_events.R                 # local dev (./logs/events)
#   Rscript scripts/read_events.R --dir <path>    # custom directory
#   Rscript scripts/read_events.R --vps           # tail from VPS via ssh
#   Rscript scripts/read_events.R --errors        # only app_error events
#   Rscript scripts/read_events.R --since 2026-05-08
#
# Outputs a markdown table summary, plus saves the full tibble to
# /tmp/pico_events.rds for further inspection in R.

suppressPackageStartupMessages({
  library(jsonlite); library(dplyr); library(purrr); library(tibble)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[i + 1L]
}
has_flag <- function(flag) flag %in% args

dir <- if (has_flag("--vps")) {
  # Pull from VPS — relies on configured ssh key.
  tmp <- tempfile("pico_events_", fileext = ".tar")
  message("Pulling events from VPS...")
  system2("ssh", c("root@5.78.69.136",
    "tar -cf - -C /srv/shiny-server/pico-dag/app/logs events"),
    stdout = tmp)
  out <- file.path(tempdir(), "pico_events_extracted")
  dir.create(out, showWarnings = FALSE)
  utils::untar(tmp, exdir = out)
  file.path(out, "events")
} else {
  get_arg("--dir", "./logs/events")
}

if (!dir.exists(dir)) {
  message("Events directory not found: ", dir)
  quit(status = 1)
}

files <- list.files(dir, pattern = "\\.json$", full.names = TRUE)
message("Reading ", length(files), " events from ", dir)

events <- purrr::map(files, \(f) {
  tryCatch(jsonlite::read_json(f, simplifyVector = FALSE),
           error = \(e) { message("skipped: ", basename(f)); NULL })
}) |> purrr::compact()

# Flatten data.* into top-level columns, preserving event_type / ts / session.
flatten_event <- function(e) {
  d <- e$data %||% list()
  base <- tibble::tibble(
    ts = e$ts %||% NA_character_,
    event_type = e$event_type %||% NA_character_,
    session = e$session %||% NA_character_
  )
  if (length(d) == 0) return(base)
  data_tib <- tibble::as_tibble(lapply(d, \(x) {
    if (is.null(x)) NA
    else if (length(x) > 1) paste(unlist(x), collapse = ",")
    else x
  }))
  dplyr::bind_cols(base, data_tib)
}

tib <- purrr::map(events, flatten_event) |>
  purrr::list_rbind() |>
  dplyr::mutate(ts = as.POSIXct(ts, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"))

since <- get_arg("--since", NULL)
if (!is.null(since)) {
  cutoff <- as.POSIXct(since, tz = "UTC")
  tib <- tib |> dplyr::filter(ts >= cutoff)
}

if (has_flag("--errors")) {
  tib <- tib |> dplyr::filter(event_type == "app_error")
}

saveRDS(tib, "/tmp/pico_events.rds")

cat("\n=== EVENT TYPE SUMMARY ===\n")
tib |>
  dplyr::count(event_type, sort = TRUE) |>
  print(n = Inf)

cat("\n=== APP_ERROR EVENTS ===\n")
errors <- tib |> dplyr::filter(event_type == "app_error")
if (nrow(errors) == 0) {
  cat("(none)\n")
} else {
  errors |>
    dplyr::select(ts, where, message) |>
    dplyr::arrange(dplyr::desc(ts)) |>
    print(n = 30)
}

cat("\n=== LAST 10 EVENTS (any type) ===\n")
tib |>
  dplyr::arrange(dplyr::desc(ts)) |>
  dplyr::select(ts, event_type, session, dplyr::any_of(c("term", "cui", "to_id", "where", "message"))) |>
  utils::head(10) |>
  print(width = Inf)

cat("\nFull tibble saved to /tmp/pico_events.rds (", nrow(tib), "rows,",
    ncol(tib), "cols)\n")
