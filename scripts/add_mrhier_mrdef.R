#!/usr/bin/env Rscript
# Append MRHIER + MRDEF + MRRANK to an existing /srv/umls/umls.duckdb.
# Side-effect: extends the bidir relations view to include hierarchy edges
# derived from MRHIER, and exposes definitions via a new concept_definition
# table for tooltip lookup.
#
# MRHIER row shape: AUI|CUI|CXN|PAUI|SAB|RELA|PTR|HCD|CVF
#   - AUI       child atom
#   - CUI       child's CUI
#   - CXN       depth (1 = root path #N for this CUI)
#   - PAUI      immediate parent atom
#   - SAB       source vocabulary asserting the hierarchy
#   - RELA      relation label (often empty; 'isa' implied)
#   - PTR       dot-separated chain of ancestor AUIs (root → ... → parent)
#
# MRDEF row shape: CUI|AUI|ATUI|SATUI|SAB|DEF|SUPPRESS|CVF
#
# MRRANK row shape: RANK|SAB|TTY|SUPPRESS

library(DBI)
library(duckdb)

DB_PATH <- "/srv/umls/umls.duckdb"
RRF_DIR <- "/srv/umls/rrf"

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE))

cat_progress <- function(msg) {
  message(format(Sys.time(), "[%H:%M:%S]"), " ", msg)
}

# ── Drop old artifacts if rerun ─────────────────────────────────────────────
for (obj in c("mrhier", "mrdef", "mrrank", "concept_definition",
              "mrhier_cui_edges")) {
  tryCatch(dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", obj)),
           error = function(e) NULL)
  tryCatch(dbExecute(con, sprintf("DROP VIEW IF EXISTS %s", obj)),
           error = function(e) NULL)
}

# ── MRHIER ──────────────────────────────────────────────────────────────────
cat_progress("Loading MRHIER.RRF (path hierarchy)...")
# MRHIER columns: CUI|AUI|CXN|PAUI|SAB|RELA|PTR|HCD|CVF
# In 2026AA, NLM populates PAUI as empty for all rows; the immediate parent
# is the last AUI in the dot-delimited PTR (path-to-root) string instead.
# regexp_extract(ptr, '([^.]+)$', 1) pulls the last segment.
dbExecute(con, sprintf("
  CREATE TABLE mrhier AS
  SELECT
    column0 AS cui,
    column1 AS aui,
    column2 AS cxn,
    column4 AS sab,
    column5 AS rela,
    regexp_extract(column6, '([^.]+)$', 1) AS paui,
    column6 AS ptr
  FROM read_csv('%s/MRHIER.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',
      'column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR',
      'column6':'VARCHAR','column7':'VARCHAR','column8':'VARCHAR'
    },
    ignore_errors = true
  )
  WHERE column6 IS NOT NULL AND column6 <> ''
", RRF_DIR))
cat_progress(sprintf("  mrhier rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrhier")[[1]]))
dbExecute(con, "CREATE INDEX idx_mrhier_aui  ON mrhier(aui)")
dbExecute(con, "CREATE INDEX idx_mrhier_cui  ON mrhier(cui)")
dbExecute(con, "CREATE INDEX idx_mrhier_paui ON mrhier(paui)")

# ── MRDEF ───────────────────────────────────────────────────────────────────
cat_progress("Loading MRDEF.RRF (definitions)...")
dbExecute(con, sprintf("
  CREATE TABLE mrdef AS
  SELECT
    column0 AS cui,
    column1 AS aui,
    column4 AS sab,
    column5 AS def,
    column6 AS suppress
  FROM read_csv('%s/MRDEF.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',
      'column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR',
      'column6':'VARCHAR','column7':'VARCHAR'
    }
  )
  WHERE column6 NOT IN ('O', 'E')
", RRF_DIR))
cat_progress(sprintf("  mrdef rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrdef")[[1]]))
dbExecute(con, "CREATE INDEX idx_mrdef_cui ON mrdef(cui)")

# ── MRRANK (SAB priority for preferred-name tie-breaking) ───────────────────
cat_progress("Loading MRRANK.RRF...")
dbExecute(con, sprintf("
  CREATE TABLE mrrank AS
  SELECT
    column0 AS rank,
    column1 AS sab,
    column2 AS tty,
    column3 AS suppress
  FROM read_csv('%s/MRRANK.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR','column3':'VARCHAR'
    }
  )
", RRF_DIR))
cat_progress(sprintf("  mrrank rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrrank")[[1]]))

# ── Curated definition: prefer MSH > NCI > SNOMEDCT_US > others ─────────────
# UMLS has multiple definitions per CUI from different sources; pick one for
# UI display, keep the rest queryable via mrdef.
cat_progress("Building concept_definition (one per CUI, source-prioritized)...")
dbExecute(con, "
  CREATE TABLE concept_definition AS
  SELECT DISTINCT ON (cui)
    cui,
    def AS definition,
    sab AS def_sab
  FROM mrdef
  ORDER BY
    cui,
    CASE sab
      WHEN 'MSH'         THEN 1
      WHEN 'NCI'         THEN 2
      WHEN 'SNOMEDCT_US' THEN 3
      WHEN 'CSP'         THEN 4
      WHEN 'HPO'         THEN 5
      WHEN 'OMIM'        THEN 6
      ELSE 99
    END,
    sab
")
dbExecute(con, "CREATE INDEX idx_cdef_cui ON concept_definition(cui)")
cat_progress(sprintf("  concept_definition rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM concept_definition")[[1]]))

# ── MRHIER → CUI-level edges ────────────────────────────────────────────────
# MRHIER stores AUI-level parent edges. Join twice through MRCONSO to lift to
# CUI-level. We materialize as a view rather than a table because the data is
# fully derived and a join-time view keeps storage flat.
cat_progress("Creating mrhier_cui_edges view (AUI hierarchy → CUI edges)...")
dbExecute(con, "
  CREATE VIEW mrhier_cui_edges AS
  SELECT DISTINCT
    h.cui AS cui1,
    pc.cui AS cui2,
    'PAR' AS rel,
    coalesce(NULLIF(h.rela, ''), 'isa') AS rela,
    h.sab AS sab,
    'H' AS direction
  FROM mrhier h
  JOIN mrconso pc ON pc.aui = h.paui
  WHERE h.cui <> pc.cui
")

# ── Verification probes ─────────────────────────────────────────────────────
cat_progress("Verification probes:")
n_hier_afib <- dbGetQuery(con,
  "SELECT count(DISTINCT cui2) AS n FROM mrhier_cui_edges WHERE cui1 = 'C0004238'")[[1]]
cat_progress(sprintf("  AFib distinct hierarchy parents via MRHIER: %s", n_hier_afib))

afib_def <- dbGetQuery(con,
  "SELECT def_sab, definition FROM concept_definition WHERE cui = 'C0004238'")
if (nrow(afib_def) > 0) {
  cat_progress(sprintf("  AFib def (%s): %s",
    afib_def$def_sab[1],
    substr(afib_def$definition[1], 1, 80)))
} else {
  cat_progress("  AFib def: (none)")
}

cat_progress("Done.")
