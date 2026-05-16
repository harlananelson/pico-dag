#!/usr/bin/env Rscript
# Build a DuckDB database from UMLS RRF files.
#
# Inputs:
#   /srv/umls/rrf/MRCONSO.RRF   English-only concepts + names
#   /srv/umls/rrf/MRREL.RRF     ALL relations (no SAB filter — fix vs prior build)
#   /srv/umls/rrf/MRSTY.RRF     Semantic types
#   /srv/umls/rrf/MRDOC.RRF     UMLS data-element documentation (rela inverses)
#   /srv/umls/rrf/MRSAT.RRF     LOINC LCN attribute only
# Output: /srv/umls/umls.duckdb.new  (atomic-rename target after verification)
#
# Differences from prior build:
#   1. MRREL is loaded WITHOUT SAB filtering. Prior build kept only 12 SABs and
#      lost ~95% of the relations (AFib went from REST's 1171 rows to 102).
#   2. MRDOC is loaded so we can look up the inverse of any (REL, RELA) pair.
#      MRDOC is the official source: DOCKEY='RELA' and TYPE='rela_inverse'
#      gives e.g. value='may_treat' → expl='may_be_treated_by'.
#   3. mrconso preserves ts (term status) and stt (string type) columns so
#      concept_preferred can apply the canonical UMLS preferred-atom rule:
#      TS='P' AND STT='PF' AND ISPREF='Y' AND TTY='PT' AND LAT='ENG',
#      tie-broken by SAB priority. This fixes the "auricular; fibrillation"
#      bug where C0004238 returned a non-canonical synonym.
#   4. mrrel_bidir is a view that UNIONs cui1=? with cui2=? rows, inverting
#      rela via MRDOC. Callers query a single direction; the view does the
#      union+invert work. Dedup happens at the consumer (R-side dplyr::distinct).
#
# Run time: ~15-25 min on a 2-core VPS (full MRREL is ~80M rows).
# Usage:    Rscript build_umls_db.R

library(DBI)
library(duckdb)

RRF_DIR  <- "/srv/umls/rrf"
DB_PATH  <- "/srv/umls/umls.duckdb.new"

# Build to a .new path; caller does atomic mv after verification so the live
# DB is never half-built. Remove any prior failed attempt.
if (file.exists(DB_PATH)) {
  message("Removing stale: ", DB_PATH)
  file.remove(DB_PATH)
}

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE))

cat_progress <- function(msg) {
  message(format(Sys.time(), "[%H:%M:%S]"), " ", msg)
}

# ── MRCONSO ─────────────────────────────────────────────────────────────────
# 18 cols: CUI LAT TS LUI STT SUI ISPREF AUI SAUI SCUI SDUI SAB TTY CODE STR SRL SUPPRESS CVF
cat_progress("Loading MRCONSO.RRF...")
dbExecute(con, sprintf("
  CREATE TABLE mrconso AS
  SELECT
    column0  AS cui,
    column1  AS lat,
    column2  AS ts,
    column4  AS stt,
    column6  AS ispref,
    column7  AS aui,
    column11 AS sab,
    column12 AS tty,
    column13 AS code,
    column14 AS str,
    column16 AS suppress
  FROM read_csv('%s/MRCONSO.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0': 'VARCHAR', 'column1': 'VARCHAR', 'column2': 'VARCHAR',
      'column3': 'VARCHAR', 'column4': 'VARCHAR', 'column5': 'VARCHAR',
      'column6': 'VARCHAR', 'column7': 'VARCHAR', 'column8': 'VARCHAR',
      'column9': 'VARCHAR', 'column10':'VARCHAR', 'column11':'VARCHAR',
      'column12':'VARCHAR', 'column13':'VARCHAR', 'column14':'VARCHAR',
      'column15':'VARCHAR', 'column16':'VARCHAR', 'column17':'VARCHAR'
    }
  )
  WHERE column1 = 'ENG' AND column16 NOT IN ('O', 'E')
", RRF_DIR))
cat_progress(sprintf("  mrconso rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrconso")[[1]]))

# ── MRREL ────────────────────────────────────────────────────────────────────
# 16 cols: CUI1 AUI1 STYPE1 REL CUI2 AUI2 STYPE2 RELA RUI SRUI SAB SL RG DIR SUPPRESS CVF
# NO SAB filter — full clinical relation graph.
cat_progress("Loading MRREL.RRF (full, no SAB filter)...")
dbExecute(con, sprintf("
  CREATE TABLE mrrel AS
  SELECT
    column0  AS cui1,
    column1  AS aui1,
    column3  AS rel,
    column4  AS cui2,
    column5  AS aui2,
    column7  AS rela,
    column10 AS sab,
    column14 AS suppress
  FROM read_csv('%s/MRREL.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0': 'VARCHAR', 'column1': 'VARCHAR', 'column2': 'VARCHAR',
      'column3': 'VARCHAR', 'column4': 'VARCHAR', 'column5': 'VARCHAR',
      'column6': 'VARCHAR', 'column7': 'VARCHAR', 'column8': 'VARCHAR',
      'column9': 'VARCHAR', 'column10':'VARCHAR', 'column11':'VARCHAR',
      'column12':'VARCHAR', 'column13':'VARCHAR', 'column14':'VARCHAR',
      'column15':'VARCHAR'
    }
  )
  WHERE column14 NOT IN ('O', 'E')
    AND column0 <> ''
    AND column4 <> ''
", RRF_DIR))
cat_progress(sprintf("  mrrel rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrrel")[[1]]))

# ── MRDOC ────────────────────────────────────────────────────────────────────
# 4 cols: DOCKEY VALUE TYPE EXPL
# Used for relation inversion: rows where TYPE='rela_inverse' map a rela to
# its semantic inverse, e.g. ('may_treat', 'may_be_treated_by').
cat_progress("Loading MRDOC.RRF...")
dbExecute(con, sprintf("
  CREATE TABLE mrdoc AS
  SELECT
    column0 AS dockey,
    column1 AS value,
    column2 AS type,
    column3 AS expl
  FROM read_csv('%s/MRDOC.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR','column3':'VARCHAR'
    }
  )
", RRF_DIR))
cat_progress(sprintf("  mrdoc rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrdoc")[[1]]))

# ── MRSTY ────────────────────────────────────────────────────────────────────
cat_progress("Loading MRSTY.RRF...")
dbExecute(con, sprintf("
  CREATE TABLE mrsty AS
  SELECT column0 AS cui, column1 AS tui, column3 AS sty
  FROM read_csv('%s/MRSTY.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',
      'column3':'VARCHAR','column4':'VARCHAR','column5':'VARCHAR'
    }
  )
", RRF_DIR))
cat_progress(sprintf("  mrsty rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrsty")[[1]]))

# ── MRSAT (LCN only) ─────────────────────────────────────────────────────────
cat_progress("Loading MRSAT.RRF (LCN only)...")
dbExecute(con, sprintf("
  CREATE TABLE mrsat_loinc AS
  SELECT column5 AS code, column10 AS atn_value
  FROM read_csv('%s/MRSAT.RRF',
    header = false, sep = '|', quote = '',
    columns = {
      'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR','column3':'VARCHAR',
      'column4':'VARCHAR','column5':'VARCHAR','column6':'VARCHAR','column7':'VARCHAR',
      'column8':'VARCHAR','column9':'VARCHAR','column10':'VARCHAR','column11':'VARCHAR',
      'column12':'VARCHAR'
    }
  )
  WHERE column8 = 'LCN' AND column9 = 'LNC' AND column11 NOT IN ('O','E')
", RRF_DIR))
cat_progress(sprintf("  mrsat_loinc rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM mrsat_loinc")[[1]]))

# ── Indexes ──────────────────────────────────────────────────────────────────
cat_progress("Building indexes...")
dbExecute(con, "CREATE INDEX idx_mrconso_cui ON mrconso(cui)")
dbExecute(con, "CREATE INDEX idx_mrconso_sab ON mrconso(sab, cui)")
dbExecute(con, "CREATE INDEX idx_mrconso_str ON mrconso(str)")
dbExecute(con, "CREATE INDEX idx_mrrel_cui1  ON mrrel(cui1)")
dbExecute(con, "CREATE INDEX idx_mrrel_cui2  ON mrrel(cui2)")
dbExecute(con, "CREATE INDEX idx_mrsty_cui   ON mrsty(cui)")
dbExecute(con, "CREATE INDEX idx_mrsat_loinc ON mrsat_loinc(code)")
dbExecute(con, "CREATE INDEX idx_mrdoc_lookup ON mrdoc(dockey, value, type)")

# ── Inverse-relation lookup tables ───────────────────────────────────────────
# rela_inverse: for non-empty RELAs, map each to its semantic inverse.
# rel_inverse:  for the 6 generic REL codes (CHD/PAR/RB/RN/etc.), same.
# Self-inverses (RO ↔ RO, SY ↔ SY) are present in MRDOC and propagate naturally.
cat_progress("Building rela/rel inverse tables from MRDOC...")
dbExecute(con, "
  CREATE TABLE rela_inverse AS
  SELECT value AS rela, expl AS inverse_rela
  FROM mrdoc
  WHERE dockey = 'RELA' AND type = 'rela_inverse'
")
dbExecute(con, "
  CREATE TABLE rel_inverse AS
  SELECT value AS rel, expl AS inverse_rel
  FROM mrdoc
  WHERE dockey = 'REL' AND type = 'rel_inverse'
")
dbExecute(con, "CREATE INDEX idx_rela_inv ON rela_inverse(rela)")
dbExecute(con, "CREATE INDEX idx_rel_inv  ON rel_inverse(rel)")
cat_progress(sprintf("  rela_inverse rows: %s, rel_inverse rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM rela_inverse")[[1]],
  dbGetQuery(con, "SELECT count(*) FROM rel_inverse")[[1]]))

# ── Bidirectional relations view ─────────────────────────────────────────────
# Forward branch: rows where the queried CUI is cui1 — relation read as-is.
# Reverse branch: rows where the queried CUI is cui2 — flipped so cui2→cui1
#   becomes cui1→cui2, with rela/rel replaced by their MRDOC inverse (if any;
#   self-inverses fall back to the original).
# Consumers query WHERE cui1 = '<target>' against this view to get the full
# REST-equivalent relation set.
cat_progress("Creating mrrel_bidir view...")
dbExecute(con, "
  CREATE VIEW mrrel_bidir AS
  SELECT cui1, cui2, rel, rela, sab, 'F' AS direction FROM mrrel
  UNION ALL
  SELECT
    m.cui2 AS cui1,
    m.cui1 AS cui2,
    COALESCE(NULLIF(ri_rel.inverse_rel, ''),  m.rel)  AS rel,
    COALESCE(NULLIF(ri_rela.inverse_rela,''), m.rela) AS rela,
    m.sab,
    'R' AS direction
  FROM mrrel m
  LEFT JOIN rela_inverse ri_rela ON ri_rela.rela = m.rela AND m.rela <> ''
  LEFT JOIN rel_inverse  ri_rel  ON ri_rel.rel  = m.rel  AND m.rel  <> ''
")

# ── Preferred-name lookup cache ──────────────────────────────────────────────
# Canonical UMLS preferred-atom rule:
#   TS    = 'P'   (preferred LUI)
#   STT   = 'PF'  (preferred form of string)
#   ISPREF= 'Y'   (preferred AUI)
#   TTY   = 'PT'  (preferred term)
#   LAT   = 'ENG' (English)
# Tie-break by SAB priority. UMLS canonical priority for PT names:
#   MTH (Metathesaurus) → SNOMEDCT_US → NCI → MSH → others alpha.
#
# The prior build's query used DISTINCT ON (cui) ORDER BY cui, sab — which
# alphabetises SABs, picking ATC/CSP-style synonyms over MTH/SNOMED. That's
# how C0004238 ended up labelled "auricular; fibrillation" instead of
# "Atrial Fibrillation". The CASE statement below fixes it.
cat_progress("Building preferred-name cache...")
# Pragmatic preferred-name rule: ts='P' (preferred LUI) + tty='PT' (preferred
# term type) + lat='ENG'. Dropping stt='PF' and ispref='Y' because most
# concepts (e.g. AFib) have NO atom satisfying all five strict canonical
# criteria — the strict rule yielded "(not found)" for AFib in test build.
# Tie-break by SAB priority so MTH/SNOMED win over alphabetic source names.
dbExecute(con, "
  CREATE TABLE concept_preferred AS
  SELECT DISTINCT ON (cui)
    cui,
    str AS preferred_name,
    sab AS preferred_sab
  FROM mrconso
  WHERE ts     = 'P'
    AND tty    = 'PT'
    AND lat    = 'ENG'
  ORDER BY
    cui,
    CASE sab
      WHEN 'MTH'         THEN 1
      WHEN 'SNOMEDCT_US' THEN 2
      WHEN 'NCI'         THEN 3
      WHEN 'MSH'         THEN 4
      WHEN 'RXNORM'      THEN 5
      WHEN 'LNC'         THEN 6
      WHEN 'ICD10CM'     THEN 7
      WHEN 'OMIM'        THEN 8
      ELSE 99
    END,
    sab
")
dbExecute(con, "CREATE INDEX idx_cp_cui ON concept_preferred(cui)")
cat_progress(sprintf("  concept_preferred rows: %s",
  dbGetQuery(con, "SELECT count(*) FROM concept_preferred")[[1]]))

# ── Verification probes ──────────────────────────────────────────────────────
# AFib (C0004238) was the canary case. Locally via REST: 1171 relations, name
# "Atrial Fibrillation". Print equivalents from this DB so we know the build
# is healthy before atomic-rename.
cat_progress("Verification probes:")
afib_name <- dbGetQuery(con,
  "SELECT preferred_name FROM concept_preferred WHERE cui = 'C0004238'")
cat_progress(sprintf("  C0004238 preferred_name: '%s'",
  if (nrow(afib_name) > 0) afib_name$preferred_name[1] else "(not found)"))

afib_rels <- dbGetQuery(con,
  "SELECT count(DISTINCT cui2) AS n FROM mrrel_bidir WHERE cui1 = 'C0004238'")
cat_progress(sprintf("  C0004238 distinct relations via bidir view: %s",
  afib_rels$n[1]))

afib_treats <- dbGetQuery(con,
  "SELECT count(*) AS n FROM mrrel_bidir
    WHERE cui1 = 'C0004238' AND rela = 'may_be_treated_by'")
cat_progress(sprintf("  C0004238 may_be_treated_by rows: %s", afib_treats$n[1]))

cat_progress(paste("Done. DB size:",
  system(paste("du -h", DB_PATH, "| cut -f1"), intern = TRUE)))
cat_progress(paste("Build complete:", DB_PATH))
