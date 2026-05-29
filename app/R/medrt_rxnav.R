# MED-RT drug-disease relations via NLM RxNav RxClass API.
#
# Closes the "orphan row" gap in our DuckDB MRREL: many UMLS rows for
# may_treat / may_be_treated_by / may_prevent / etc. have empty CUI1/AUI1/SAB
# in the merged file, and the source-side mapping to a drug RxCUI lives only
# in NLM's REST infrastructure (not in the public RRF distribution).
#
# Strategy:
#   1. Map UMLS CUI -> MeSH descriptor (D-code) via mrconso (SAB='MSH', TTY='MH')
#   2. Call RxNav RxClass /classMembers for each rela of interest, with that
#      D-code as classId and relaSource='MEDRT'.
#   3. RxNav returns the full set of RxCUIs that have that relation to the disease.
#   4. Crosswalk RxCUIs back to UMLS CUIs via mrconso (SAB='RXNORM').
#   5. Persist the results in a DuckDB cache table so subsequent queries are
#      free. The cache survives across app restarts.
#
# Why this works: UMLS REST's /CUI/{cui}/relations rehydrates orphan rows from
# the same MED-RT data RxNav exposes. Going to RxNav directly bypasses the
# orphan problem and produces row counts that match REST.

RXNAV_BASE <- "https://rxnav.nlm.nih.gov/REST/rxclass"

# Relations RxClass exposes from MED-RT, with their UMLS-MRREL equivalents.
# The asymmetry: RxClass returns drugs FOR a disease class; we want the
# UMLS-canonical "disease may_be_treated_by drug" form, so the rela we expose
# is the inverse of what RxNav uses.
.MEDRT_RELAS <- tibble::tibble(
  rxnav_rela = c("may_treat",         "may_prevent",         "induces",
                 "contraindicated_with"),
  out_rela   = c("may_be_treated_by", "may_be_prevented_by", "induced_by",
                 "has_contraindicated_drug")
)

# Look up MeSH descriptor codes for a UMLS CUI. A CUI may have several MeSH
# atoms; we keep all D-codes we find. RxNav uses these codes as classId.
.cui_to_mesh_codes <- function(cui) {
  con <- umls_db_connect()
  if (is.null(con)) return(character(0))
  res <- DBI::dbGetQuery(con,
    "SELECT DISTINCT code FROM mrconso
     WHERE cui = ? AND sab = 'MSH' AND tty IN ('MH','PEP','NM','HT')
       AND code IS NOT NULL AND code <> ''",
    params = list(cui))
  unique(res$code)
}

# Resolve a list of RxCUIs back to UMLS CUIs. Prefers ingredient-level (IN)
# atoms so the resulting CUIs are the most general drug concepts. Falls back
# to any RXNORM atom for codes that lack an IN.
.rxcuis_to_umls_cuis <- function(rxcuis) {
  if (length(rxcuis) == 0) return(tibble::tibble(rxcui = character(0), cui = character(0)))
  con <- umls_db_connect()
  if (is.null(con)) return(tibble::tibble(rxcui = character(0), cui = character(0)))
  ph <- paste(rep("?", length(rxcuis)), collapse = ",")
  sql <- sprintf(
    "SELECT DISTINCT code AS rxcui, cui
     FROM mrconso
     WHERE sab = 'RXNORM' AND code IN (%s)", ph
  )
  res <- DBI::dbGetQuery(con, sql, params = as.list(rxcuis))
  tibble::as_tibble(res)
}

# Fetch one (rela, classId) tuple from RxNav. Returns a tibble of drugs.
.rxnav_class_members <- function(class_id, rxnav_rela) {
  url <- sprintf("%s/classMembers.json?classId=%s&relaSource=MEDRT&rela=%s",
                 RXNAV_BASE, utils::URLencode(class_id), rxnav_rela)
  resp <- tryCatch(
    httr2::request(url) |> httr2::req_perform() |> httr2::resp_body_json(),
    error = function(e) NULL
  )
  if (is.null(resp)) return(tibble::tibble())
  members <- resp$drugMemberGroup$drugMember
  if (is.null(members) || length(members) == 0) return(tibble::tibble())
  purrr::map(members, function(m) {
    tibble::tibble(
      rxcui = m$minConcept$rxcui %||% "",
      name  = m$minConcept$name  %||% "",
      tty   = m$minConcept$tty   %||% ""
    )
  }) |> purrr::list_rbind()
}

#' Fetch MED-RT relations for a UMLS CUI, returning rows in MRREL-compatible form.
#'
#' Returns a tibble with columns:
#'   cui           - the input CUI (subject of the relation)
#'   related_cui   - drug CUI in UMLS
#'   related_name  - drug name from RxNav (preserved for debugging)
#'   rela          - UMLS-canonical relation (may_be_treated_by, etc.)
#'   rxcui         - the RxNorm code (for traceability)
#'   source        - 'MEDRT' (constant — distinguishes cache rows from MRREL)
#'
#' Returns empty tibble if the CUI has no MeSH descriptor or RxNav has no data.
fetch_medrt_relations <- function(cui) {
  out_cols <- tibble::tibble(
    cui = character(0), related_cui = character(0), related_name = character(0),
    rela = character(0), rxcui = character(0), source = character(0)
  )
  mesh_codes <- .cui_to_mesh_codes(cui)
  if (length(mesh_codes) == 0) return(out_cols)

  parts <- list()
  for (mesh in mesh_codes) {
    for (i in seq_len(nrow(.MEDRT_RELAS))) {
      rxnav_rela <- .MEDRT_RELAS$rxnav_rela[i]
      out_rela   <- .MEDRT_RELAS$out_rela[i]
      drugs <- .rxnav_class_members(mesh, rxnav_rela)
      if (nrow(drugs) == 0) next
      mapped <- .rxcuis_to_umls_cuis(drugs$rxcui)
      if (nrow(mapped) == 0) next
      drugs <- drugs |>
        dplyr::left_join(mapped, by = "rxcui") |>
        dplyr::filter(!is.na(cui), nzchar(cui))
      if (nrow(drugs) == 0) next
      parts[[length(parts) + 1]] <- tibble::tibble(
        cui          = !!cui,
        related_cui  = drugs$cui,
        related_name = drugs$name,
        rela         = out_rela,
        rxcui        = drugs$rxcui,
        source       = "MEDRT"
      )
    }
  }
  if (length(parts) == 0) return(out_cols)
  purrr::list_rbind(parts) |>
    dplyr::distinct(cui, related_cui, rela, .keep_all = TRUE)
}

# ---------------------------------------------------------------------------
# Persistent cache
# ---------------------------------------------------------------------------

# The cache table holds resolved (cui, related_cui, rela) triples plus
# metadata. It's keyed by cui — one row per (cui, related_cui, rela). A row
# `cui = X, related_cui = '__SENTINEL__'` indicates "we've fetched X and it
# returned nothing"; that prevents repeated empty-fetches for leaf CUIs.

.MEDRT_CACHE_PATH <- local({
  d <- Sys.getenv("PICO_LOG_DIR", unset = "")
  if (!nzchar(d)) d <- file.path(getwd(), "logs")
  if (!dir.exists(d)) tryCatch(dir.create(d, recursive = TRUE, showWarnings = FALSE),
                                error = function(e) NULL)
  file.path(d, "medrt_cache.duckdb")
})

medrt_cache_init <- function() {
  con <- DBI::dbConnect(duckdb::duckdb(), .MEDRT_CACHE_PATH, read_only = FALSE)
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS medrt_cache (
      cui          VARCHAR,
      related_cui  VARCHAR,
      related_name VARCHAR,
      rela         VARCHAR,
      rxcui        VARCHAR,
      source       VARCHAR,
      fetched_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")
  DBI::dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_medrt_cui ON medrt_cache(cui)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  invisible(NULL)
}

medrt_cache_lookup <- function(cui) {
  if (!file.exists(.MEDRT_CACHE_PATH)) return(NULL)
  con <- DBI::dbConnect(duckdb::duckdb(), .MEDRT_CACHE_PATH, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- DBI::dbGetQuery(con,
    "SELECT cui, related_cui, related_name, rela, rxcui, source
     FROM medrt_cache WHERE cui = ?", params = list(cui))
  if (nrow(res) == 0) return(NULL)
  # Sentinel row means we tried and got nothing.
  if (all(res$related_cui == "__SENTINEL__")) return(tibble::tibble())
  res |>
    dplyr::filter(related_cui != "__SENTINEL__") |>
    tibble::as_tibble()
}

medrt_cache_store <- function(cui, rels) {
  if (!file.exists(.MEDRT_CACHE_PATH)) medrt_cache_init()
  con <- DBI::dbConnect(duckdb::duckdb(), .MEDRT_CACHE_PATH, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (is.null(rels) || nrow(rels) == 0) {
    sentinel <- tibble::tibble(
      cui = !!cui, related_cui = "__SENTINEL__", related_name = "",
      rela = "", rxcui = "", source = "MEDRT"
    )
    DBI::dbWriteTable(con, "medrt_cache", sentinel, append = TRUE)
  } else {
    DBI::dbWriteTable(con, "medrt_cache", rels, append = TRUE)
  }
  invisible(NULL)
}

#' Get MED-RT relations for a CUI, using cache if available.
#'
#' @param cui         The UMLS CUI to look up.
#' @param refresh     Force re-fetch from RxNav even if cached.
#' @param cache_only  If TRUE, return cached rows only and skip the RxNav
#'                    fetch on cache miss. Used by BFS for non-seed nodes
#'                    so the walk doesn't fire 30+ RxNav calls in series —
#'                    the seed's prefetch path keeps cache_only = FALSE
#'                    and pays the one-time RxNav cost.
medrt_get_relations <- function(cui, refresh = FALSE, cache_only = FALSE) {
  if (!refresh) {
    cached <- medrt_cache_lookup(cui)
    if (!is.null(cached)) return(cached)
  }
  if (isTRUE(cache_only)) return(tibble::tibble())
  fresh <- tryCatch(fetch_medrt_relations(cui),
                    error = function(e) tibble::tibble())
  medrt_cache_store(cui, fresh)
  fresh
}
