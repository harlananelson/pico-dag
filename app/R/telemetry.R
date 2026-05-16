# Non-blocking, concurrent-safe NDJSON event logger.
#
# Each event is written as its own file under <log_dir>/events/<ts>-<short>.json
# to sidestep the cat()-append race condition (multiple Shiny workers writing
# to one file can interleave bytes mid-line). Read-time concatenation reproduces
# the NDJSON stream:
#
#   readr::read_lines(fs::dir_ls("logs/events", glob = "*.json"))
#
# Log directory resolution happens once at source-load time so there is no
# dependency on getwd() being stable through the app's lifetime.
#
# Session IDs are hashed with a daily-rotating salt so logs cannot be tied
# back to a Shiny session token after the day rolls over.

.PICO_LOG_DIR <- local({
  d <- Sys.getenv("PICO_LOG_DIR", unset = "")
  if (!nzchar(d)) d <- file.path(getwd(), "logs")
  events_dir <- file.path(d, "events")
  tryCatch(dir.create(events_dir, recursive = TRUE, showWarnings = FALSE),
           error = function(e) NULL)
  d
})

.PICO_EVENTS_DIR <- file.path(.PICO_LOG_DIR, "events")

# Daily-rotating salt: stored in <log_dir>/.salt, regenerated each UTC day.
# Hashed session tokens cannot be linked across days.
.daily_salt <- function() {
  salt_file <- file.path(.PICO_LOG_DIR, ".salt")
  today <- format(Sys.Date(), "%Y-%m-%d")
  if (file.exists(salt_file)) {
    contents <- tryCatch(readLines(salt_file, n = 1, warn = FALSE),
                         error = function(e) "")
    parts <- strsplit(contents, "\t", fixed = TRUE)[[1]]
    if (length(parts) == 2 && parts[1] == today) return(parts[2])
  }
  new_salt <- paste0(sample(c(0:9, letters), 32, replace = TRUE), collapse = "")
  tryCatch(writeLines(paste(today, new_salt, sep = "\t"), salt_file),
           error = function(e) NULL)
  new_salt
}

hash_session <- function(token) {
  if (is.null(token) || !nzchar(token)) return("")
  substr(digest::digest(paste0(.daily_salt(), token), algo = "sha256"), 1, 16)
}

#' Append a structured event to the telemetry log.
#'
#' @param event_type  Short string identifying the event class.
#' @param session_id  Shiny session token (hashed before write).
#' @param ...         Named values stored under the "data" key.
log_event <- function(event_type, session_id = "", ...) {
  tryCatch({
    record <- list(
      ts         = format(Sys.time(), "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"),
      event_type = event_type,
      session    = hash_session(session_id),
      data       = list(...)
    )
    line <- jsonlite::toJSON(record, auto_unbox = TRUE, null = "null")
    fname <- sprintf("%s-%s.json",
                     format(Sys.time(), "%Y%m%dT%H%M%OS3"),
                     paste0(sample(c(0:9, letters), 6, replace = TRUE),
                            collapse = ""))
    writeLines(line, file.path(.PICO_EVENTS_DIR, fname))
  }, error = function(e) NULL)
  invisible(NULL)
}

#' Wrap an expression so any error is logged to telemetry as app_error
#' and the user sees a friendly notification instead of a silent disconnect.
#'
#' @param expr        The expression to evaluate (typically a renderer body).
#' @param where       Short label identifying the call site (for telemetry).
#' @param session_id  Shiny session token to attach to the error.
#' @param fallback    Value to return if the expression errors. NULL by default.
#' @param notify      If TRUE, show a Shiny notification on error.
safely_run <- function(expr, where, session_id = "", fallback = NULL,
                       notify = TRUE) {
  tryCatch(
    force(expr),
    error = function(e) {
      log_event("app_error", session_id = session_id,
                where   = where,
                message = conditionMessage(e),
                call    = paste(utils::head(deparse(conditionCall(e)), 1L), collapse = " "))
      if (isTRUE(notify) && exists("showNotification", mode = "function")) {
        try(showNotification(
          paste0("Error in ", where, ": ", conditionMessage(e),
                 " (logged for investigation)."),
          type = "error", duration = 8
        ), silent = TRUE)
      }
      fallback
    }
  )
}
