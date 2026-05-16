# Empirical Association Augmentation for pico-dag

## Methodological precedent: this is signal detection, generalized

The methodology proposed here is the same **disproportionality / signal
detection** paradigm already implemented in this codebase's pharmacovigilance
suite — `faers-mobi`, `aers-mobi`, `vaers-mobi`, the `safetysignal` R
package, and the `signal-compute` pipeline. The only generalization is the
data source and the concept space.

| Aspect            | Pharmacovigilance (existing)        | pico-dag empirical (proposed)        |
|-------------------|-------------------------------------|--------------------------------------|
| Data source       | Spontaneous reports (FAERS, VAERS)  | De-identified EHR (Cerner / HDL)     |
| "Subject" entity  | Drug (RxNorm)                       | Any UMLS CUI                         |
| "Object" entity   | Adverse event (MedDRA PT)           | Any UMLS CUI                         |
| Unit of obs.      | Spontaneous report                  | Patient-encounter pair               |
| Statistics        | GPS/EBGM, PRR, ROR, BCPNN/IC        | Same — plus lift, OR, PMI            |
| Detection goal    | Drug-AE signals not yet labeled     | Concept-pair relations not in UMLS   |
| Curation analog   | FDA labels, FDA-approved indications| UMLS MRREL                           |
| Output gap        | Signals above threshold             | High-association pairs absent in MRREL |

In VAERS specifically, empirical analysis routinely surfaces drug-event
relations that were unknown to curators at the time of reporting — myocarditis
with COVID mRNA vaccines being the canonical recent example. The same
mechanism applies here: a clinical association strong in EHR data but absent
from UMLS MRREL is a candidate for the same kind of investigation, with the
benefit that EHR data is far denser per concept than spontaneous reporting.

The infrastructure for this work already exists in the project:

- **`safetysignal` R package** — implements GPS/EBGM, PRR, ROR, BCPNN/IC.
  Reusable as-is; the inputs are an Nx2 contingency table per concept pair.
- **`signal-compute` pipeline** — runs the safetysignal package across
  quarterly contingency snapshots and emits parquet. The pipeline pattern
  ports directly: replace the FAERS contingency input with an EHR-derived
  contingency table.
- **Splash/visualization patterns** — `faers-mobi`'s rendered signal table
  with EB05/PRR/IC etc. is the exact UI we'd want for the pico-dag empirical
  view, with concept-pair edges in place of drug-AE pairs.

So pico-dag's empirical augmentation is best framed not as new methodology
but as **applying the same signal-detection paradigm — already validated in
this codebase against FDA spontaneous-report data — to EHR data, with the
concept space generalized beyond drug-AE.**

## Problem statement

Current `pico-dag` edges are **categorical** — present or absent. A UMLS row says
"AFib `may_be_treated_by` warfarin" but doesn't quantify how strongly this holds
in practice. Three real questions cannot be answered from UMLS alone:

1. **Strength** — among AFib patients, what fraction actually receive warfarin?
   What's the lift over the population baseline?
2. **Temporality** — does the drug follow the diagnosis, as expected, or
   precede it (as it would in a chart-prep flow)?
3. **Discovery** — are there concept pairs with strong real-world co-occurrence
   that UMLS has *not* curated as related? Those are the candidate hypotheses.

UMLS (and the MED-RT cache we just added) gives us the *frame* — the DAG
structure of which concept pairs *might* be related. EHR data turns that frame
into evidence by attaching an **empirical association score** to every edge
and surfacing pairs that the literature/curation hasn't yet recognized.

## Data layer (HealtheDataLab / SCDCernerProject)

Per DUA: **patient-level data stays on HDL**. What can leave HDL is aggregate
statistics with small-cell suppression — the exact payload pico-dag would
ingest.

EHR tables that map cleanly onto UMLS CUIs:

| EHR source           | Native code          | UMLS crosswalk (MRCONSO SAB) |
|----------------------|----------------------|------------------------------|
| Diagnosis (encounter)| ICD-10-CM            | `ICD10CM`                    |
| Medication order/admin| RxNorm (or NDC→RxNorm)| `RXNORM`                   |
| Lab result           | LOINC                | `LNC`                        |
| Procedure            | CPT / ICD-10-PCS / SNOMED| `CPT`, `ICD10PCS`, `SNOMEDCT_US` |
| Problem list (EHR)   | SNOMED-CT            | `SNOMEDCT_US`                |

Each event flattens to `(patient_id, cui, datetime)`. From this single long
table all downstream statistics derive.

## Statistics computed (per concept pair)

For a candidate edge `(cui_a, cui_b)` over the patient cohort `N`, compute
the same statistics the project already produces for FAERS/VAERS via
`safetysignal`, plus a few EHR-specific additions for temporality:

**Primary disproportionality statistics (from `safetysignal`):**

| Statistic                  | Source                  | Meaning                                              |
|----------------------------|-------------------------|------------------------------------------------------|
| `eb05`, `eb50`, `eb95`     | GPS dual-Gamma posterior| 5/50/95-percentile credible bounds, linear RR scale  |
| `prr`, `prr_lci`, `prr_uci`| Proportional Reporting Ratio | Frequentist relative reporting rate              |
| `prr_chisq`                | χ² for the PRR cell     | Significance test                                    |
| `ror`, `ror_lci`, `ror_uci`| Reporting Odds Ratio    | Odds-ratio formulation of the same 2×2               |
| `ic`, `ic025`, `ic975`     | BCPNN Information Component | Bayesian shrinkage estimate                      |
| `n_methods_flagged`        | Count of methods firing | Same multi-method consensus rule used in faers-mobi  |
| `is_signal_any`            | `n_methods_flagged ≥ 1` | Same threshold semantics as the existing apps        |

A pair is a "candidate empirical association" by the same definition the
existing pharmacovigilance apps use: **flagged by ≥ 2 of the 4 methods.**

**Secondary frequentist statistics:**

| Statistic                | Formula                              | Meaning                                    |
|--------------------------|--------------------------------------|--------------------------------------------|
| `n_a`                    | patients with ≥1 cui_a event         | Marginal exposure                          |
| `n_b`                    | patients with ≥1 cui_b event         | Marginal exposure                          |
| `n_both`                 | patients with both                   | Co-occurrence                              |
| `lift`                   | `(n_both × N) / (n_a × n_b)`         | How much more than chance                  |
| `pmi`                    | `log2(lift)`                         | Pointwise mutual information               |
| `phi`                    | √(χ² / N)                            | Effect-size, comparable across N           |
| `p_b_given_a`            | `n_both / n_a`                       | Conditional prevalence                     |
| `p_a_given_b`            | `n_both / n_b`                       | Reverse conditional                        |

**EHR-specific temporality (not in spontaneous-report analysis):**

| Statistic                | Formula                              | Meaning                                    |
|--------------------------|--------------------------------------|--------------------------------------------|
| `median_days_a_to_b`     | median over co-occurrence patients   | Temporal lag                               |
| `pct_a_before_b`         | fraction where A's first ≤ B's first | Temporal direction                         |
| `pct_within_30d`         | fraction where \|Δt\| ≤ 30 days       | Tight clinical coupling                    |

The temporality columns are the genuine new contribution beyond what
spontaneous-report analysis provides — VAERS knows the report date but not a
clean drug-event temporal sequence; EHR data does.

Privacy guard: any cell where `n_both < 10` (configurable threshold) is
suppressed in export — the row is dropped entirely, not zeroed. The existing
`gps-patient` project already enforces an `N<10` rule per the SCDCerner DUA;
we use the same threshold.

## Schema

The schema mirrors `signal-compute`'s `signals_faers_v<date>.parquet` output
so the same downstream readers work. Add cui_a/cui_b in place of
drug_concept_id/outcome_concept_id, plus EHR temporality columns.

```sql
CREATE TABLE empirical_associations (
  -- Edge identity (general-purpose UMLS CUIs in place of drug/event)
  cui_a              VARCHAR    NOT NULL,
  cui_b              VARCHAR    NOT NULL,

  -- Counts (the only patient-level data, suppressed if too small)
  n_a                INTEGER    NOT NULL,
  n_b                INTEGER    NOT NULL,
  n_both             INTEGER    NOT NULL,
  n_total            INTEGER    NOT NULL,    -- cohort denominator

  -- Disproportionality statistics (same columns as signal-compute output)
  eb05               DOUBLE,                 -- GPS dual-Gamma posterior 5%
  eb50               DOUBLE,
  eb95               DOUBLE,
  prr                DOUBLE,
  prr_lci            DOUBLE,
  prr_uci            DOUBLE,
  prr_chisq          DOUBLE,
  ror                DOUBLE,
  ror_lci            DOUBLE,
  ror_uci            DOUBLE,
  ic                 DOUBLE,                 -- BCPNN Information Component
  ic025              DOUBLE,
  ic975              DOUBLE,
  n_methods_flagged  INTEGER,                -- 0..4
  is_signal_any      BOOLEAN,

  -- Secondary statistics
  lift               DOUBLE,
  pmi                DOUBLE,
  phi                DOUBLE,
  chi2               DOUBLE,
  p_b_given_a        DOUBLE,
  p_a_given_b        DOUBLE,

  -- EHR-only temporality
  median_days_a_to_b INTEGER,
  pct_a_before_b     DOUBLE,
  pct_within_30d     DOUBLE,

  -- Provenance / audit
  data_source        VARCHAR    NOT NULL,    -- 'CERNER_RWD', 'OPTUM', etc.
  data_period_start  DATE       NOT NULL,
  data_period_end    DATE       NOT NULL,
  computed_at        TIMESTAMP  NOT NULL,
  cohort_definition  VARCHAR,                -- e.g. "all adult patients"
  suppressed         BOOLEAN    DEFAULT FALSE -- true if any cell suppressed
);
CREATE INDEX idx_emp_a ON empirical_associations(cui_a);
CREATE INDEX idx_emp_b ON empirical_associations(cui_b);
```

**Code reuse:** `signal-compute/scripts/run_signals.R` already produces a
parquet with `eb05/eb50/eb95/prr/ror/ic/n_methods_flagged/is_signal_any`
columns. The transform from EHR contingency to that parquet is the same
function call as for FAERS contingency — both go through `safetysignal::run_all_methods()`. The new file
schema is a strict superset.

## Pipeline (HDL → off-HDL)

```
HDL / PySpark 2.4.4 (SCDCernerProject pattern)
└─ 1. Lift EHR events to (patient_id, cui, ts) via MRCONSO crosswalk
└─ 2. Compute marginal counts per cui (n_a)
└─ 3. For every pair where both n >= MIN_MARGINAL (e.g. 100):
       └─ Compute 2x2, lift, PMI, OR with CI, temporal stats
└─ 4. Apply small-cell suppression (drop rows where n_both < 10)
└─ 5. Write parquet → empirical_associations_<period>.parquet
└─ 6. Per DUA: only the parquet leaves HDL (aggregates, no patient IDs)

Off-HDL (pico-dag VPS or local DuckDB)
└─ 7. Load parquet into empirical_associations table
└─ 8. Update umls_get_relations to LEFT JOIN association stats
└─ 9. DAG renderer:
       └─ Edge thickness ∝ log(lift)
       └─ Edge color = OR significance
       └─ Hover: "AFib → warfarin · lift 4.2 · OR 3.8 (3.4-4.3) · n=15,234 · 78% drug-after-dx"
└─10. New-relationship discovery: list pairs with high lift + no UMLS rela
```

## Three classes of edges

1. **UMLS-asserted + empirically supported** — UMLS says they're related and
   the data confirms it. Highest confidence. Renders solid.

2. **UMLS-asserted, empirically weak or absent** — UMLS says related but the
   data doesn't bear it out (lift ≈ 1, OR ≈ 1, or n_both below threshold). May
   reflect sampling, mis-coding, or genuinely outdated curation. Renders
   solid but de-emphasized; flagged in the table.

3. **Empirically strong, no UMLS rela** — discovered associations. These are
   the hypotheses worth investigating. Renders as dashed edges with a
   distinct color. Flagged for follow-up.

## IRB application support

Three live, public-facing artifacts in this codebase materially strengthen
the application:

1. **`picodag.globalpatientsafety.com`** demonstrates the *structural*
   framework — concepts as nodes, UMLS-curated relations as edges, walked
   on demand from a 53M-row local UMLS Metathesaurus.

2. **`faers.mobi`, `aers.mobi`, `vaers.globalpatientsafety.com`** demonstrate
   the *signal-detection methodology* — the exact GPS/PRR/ROR/IC pipeline
   we'd apply to EHR data, already producing public outputs against
   FDA/CDC spontaneous-report data with peer-reviewed methods.

3. **`safetysignal` R package + `signal-compute` pipeline** — the
   computational machinery, open-sourced and reproducible.

Together these establish that the methodology is not novel-and-untested but
**already validated against ~35 years of FDA/CDC data** and merely
generalized in this proposal to a denser, longitudinal data source.

Components useful for an IRB submission:

- **Specific aim:** "Empirically quantify UMLS-asserted clinical concept
  relations using de-identified EHR data and surface novel concept
  associations not yet captured in curated terminologies, applying the same
  Bayesian disproportionality methods (GPS, BCPNN/IC) and frequentist
  signal-detection (PRR, ROR) the project has previously validated against
  CDC VAERS and FDA FAERS spontaneous-report data."

- **Precedent for the methods:** The PRR/ROR/IC/GPS quartet is the
  WHO Uppsala Monitoring Centre and FDA/CDC standard for pharmacovigilance
  signal detection. DuMouchel (1999) for GPS; van Puijenbroek et al. (2002)
  for PRR confidence intervals; Bate et al. (1998) for BCPNN/IC. The
  methods are textbook. The novelty is the **data source and concept
  space**, not the statistics.

- **Precedent for novel-association discovery:** VAERS empirical analysis
  has surfaced clinically relevant drug-event signals — most recently
  myocarditis with COVID-19 mRNA vaccines (Witberg et al. 2021; Mevorach
  et al. 2021), which appeared in disproportionality analyses before
  curated drug labeling caught up. Our `vaers.globalpatientsafety.com`
  reproduces exactly this kind of detection. The proposed EHR work
  generalizes the same methodology beyond drug-AE pairs to any
  clinically-relevant CUI pair.

- **Methods (privacy):** Aggregate co-occurrence statistics computed on HDL
  via PySpark; only aggregate counts and derived statistics leave HDL;
  cell-size suppression at n<10 enforces k-anonymity ≥10. Same DUA-respecting
  pattern as the project's existing SCDCernerProject pipeline.

- **No new patient-level data products.** Output is a parquet of CUI-pair
  statistics — counts and ratios, no demographics, no identifiers.

- **Risk:** Negligible. Re-identification through paired-CUI counts at n≥10
  is well-characterized in the disclosure-limitation literature and falls
  comfortably under HIPAA Safe Harbor.

- **Justification (the gap):** The UMLS gap analysis embedded in this
  codebase's commit history demonstrates the *necessity* — UMLS itself
  acknowledges the curation is incomplete via "orphan rows" in MRREL where
  source-vocabulary assertions are not promoted to CUI-level relations
  (38 of 43 may_be_treated_by rows for atrial fibrillation, e.g.).
  Empirical augmentation closes that gap with study-population evidence
  using the same disproportionality machinery already in production for
  FDA/CDC data.

- **Reproducibility:** All code and configs in `pico-dag`, `safetysignal`,
  `signal-compute`, and `faers-pipeline` repositories under the project's
  open license; the DuckDB schema in this file; the methods package on
  GitHub.

## Phased delivery

| Phase | Scope                                                              | Owner       |
|-------|--------------------------------------------------------------------|-------------|
| 0     | pico-dag DAG with UMLS + MED-RT (current state)                    | Done        |
| 1     | EMPIRICAL_ASSOCIATIONS.md (this doc) — IRB concept material        | Drafted     |
| 2     | IRB submission + Oracle Tenant request                             | User        |
| 3     | PySpark pipeline on HDL implementing the statistics above          | User        |
| 4     | One-time export of suppressed parquet (per DUA)                    | User        |
| 5     | Load into pico-dag DuckDB; surface association stats in the DAG    | This system |
| 6     | New-relationship discovery view (high-lift, no UMLS rela)          | This system |

## Operational notes

- **Concept resolution.** The HDL data is in source-vocabulary codes
  (ICD-10, RxNorm, LOINC). Lift to CUI via MRCONSO; use the preferred-atom
  rule for ties so that the same physical event always lifts to the same
  CUI.
- **Temporal alignment.** Some events are encounter-dated (diagnoses), some
  are administration-dated (medications), some are result-dated (labs).
  Document which timestamp each row uses.
- **Cohort.** Decide once: all-encounter patients, or only patients with
  ≥X encounters? Affects the marginal denominators substantially.
- **Multiple comparisons.** A pairwise sweep at this scale produces
  millions of pairs. Adjust significance thresholds (e.g. Bonferroni or
  FDR-controlled) before publishing "novel" associations.
- **Stability across data periods.** Compute on at least two non-overlapping
  time windows; an association that replicates is a much stronger signal.

## What this doesn't do

- It doesn't establish causation. Lift ≠ cause. The user (or downstream
  pharmacovigilance/methodology) must guard against confounding.
- It doesn't replace UMLS. The curated relations remain the structural
  scaffold; empirical statistics are an *attribute* of those edges, not a
  replacement.
- It doesn't compute on patient-level data off HDL. Ever. The DUA holds.
