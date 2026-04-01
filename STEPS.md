# pico-dag — Development Steps

## Prerequisites

1. UMLS API key set in environment: `export UMLS_API_KEY=<your-key>`
2. Nix installed (for reproducible R environment)
3. Git configured with GitHub SSH access

## Getting Started

```bash
cd ~/projects/pico-dag
nix develop                              # enter dev shell (first time builds R + packages)
Rscript -e 'shiny::runApp("app")'        # launch app at http://127.0.0.1:3838
```

## Phase 1: Core Shiny App (CURRENT)

**Status:** Built, needs testing in Nix environment

- [x] UMLS REST API client (`app/R/umls_client.R`)
  - [x] Search concepts by name
  - [x] Get concept details by CUI
  - [x] Get all relations (paginated)
  - [x] Get source codes by vocabulary (ICD-10, SNOMED, RxNorm, LOINC, CPT)
- [x] DAG walker (`app/R/dag_walker.R`)
  - [x] Categorize RELA labels → clinical groups (treatment, comorbidity, lab, procedure, anatomy)
  - [x] Second-hop traversal: treatment → monitoring labs
  - [x] PICO element walker (intervention, comparator, outcome)
- [x] Code list generation (`app/R/code_lists.R`)
  - [x] ICD-10-CM with hierarchy expansion
  - [x] SNOMED codes
  - [x] RxNorm codes for treatments
  - [x] LOINC codes for labs
  - [x] CPT codes for procedures
  - [x] Package all code lists for ZIP export
- [x] Network visualization (`app/R/network_viz.R`)
  - [x] visNetwork with domain-colored nodes
  - [x] Second-hop edges (drug → monitoring lab) as dashed lines
  - [x] Interactive: highlight neighbors, zoom, filter
- [x] Shiny app (`app/app.R`)
  - [x] PICO sidebar with search for each element
  - [x] Concept DAG tab with network graph + value boxes
  - [x] Treatments tab with DT table
  - [x] Labs tab with DT table
  - [x] Comorbidities tab with DT table
  - [x] Procedures tab with DT table
  - [x] Code Lists tab with generation + ZIP download
  - [x] Data Pull Request tab with QMD download
- [ ] **Test in Nix environment** — verify `nix develop` + `runApp()` works
- [ ] **Test with AFib** — verify DAG matches the manual pull request we generated
- [ ] **Test with SCD** — verify against SCDCernerProject's known code lists
- [ ] **Test with Troponin/STEMI** — verify cardiac workup labs discovered

## Phase 2: Code Generation

Generate executable extraction pipelines for three targets.

- [ ] Config YAML generator from PICO + DAG results
- [ ] HDL / lhn target
  - [ ] Generate `config.yaml` compatible with lhn `ExtractConfig`
  - [ ] Generate PySpark extraction script skeleton
- [ ] Databricks / OMOP target
  - [ ] Generate `_targets.R` pipeline skeleton
  - [ ] Generate `R/functions.R` extraction functions using OMOP SQL
- [ ] IUH EDW target
  - [ ] Generate `_targets.R` pipeline skeleton
  - [ ] Generate `R/functions.R` with dbplyr queries
- [ ] Pipeline tab in Shiny app
  - [ ] Target selector (HDL, Databricks, EDW)
  - [ ] Preview generated config + code
  - [ ] Download complete pipeline package (ZIP)

## Phase 3: Risk Score Integration

Auto-detect and include standard clinical risk scores when applicable.

- [ ] Risk score template registry (condition → applicable scores)
- [ ] CHA₂DS₂-VASc (triggered by AFib)
  - [ ] Map each component to DAG-discovered comorbidity
  - [ ] Auto-include all component flags in data pull
- [ ] HAS-BLED (triggered by AFib + anticoagulation)
  - [ ] Map components to comorbidities + treatment monitoring
- [ ] Charlson Comorbidity Index (general — always available)
  - [ ] Map 17 condition categories to ICD-10 code sets
- [ ] Elixhauser Comorbidity Index (general — always available)
  - [ ] Map 31 condition categories to ICD-10 code sets
- [ ] Risk Scores tab in Shiny app
  - [ ] Auto-detected scores for this condition
  - [ ] Component checklist with DAG sources
  - [ ] Include/exclude toggle

## Phase 4: Concept DAG Integration

Connect to `concept-dag` project for per-person graph building.

- [ ] Export PICO-derived code lists to concept-dag format
- [ ] Generate `concept_dag` node creation script from patient data
- [ ] Generate edge builder configuration from UMLS relationships
- [ ] Matrix algebra integration (centrality, reachability, evidence chains)
- [ ] Per-person DAG visualization tab in Shiny app
- [ ] Link to knowledge-graph Shiny app for detailed exploration

## Phase 5: Deployment

- [ ] Dockerize for OpenShift deployment
- [ ] UMLS API key management (environment variable, not hardcoded)
- [ ] Caching layer (DuckDB) for previously queried CUIs
- [ ] Rate limiting for UMLS API (0.25s between calls)
- [ ] User authentication (if deployed to shared environment)
- [ ] Documentation / user guide

## Testing Checklist

| Condition | Expected Treatments | Expected Labs | Expected Comorbidities |
|-----------|-------------------|---------------|----------------------|
| Atrial Fibrillation | warfarin, amiodarone, metoprolol, diltiazem, apixaban | INR, digoxin level, amiodarone level, TSH, BNP | CHF, HTN, DM, stroke, MI |
| Sickle Cell Disease | hydroxyurea, voxelotor, crizanlizumab | HbF, HbS, CBC, reticulocytes, LDH, bilirubin | stroke, CKD, pulmonary HTN, avascular necrosis |
| Myocardial Infarction | heparin, lisinopril, nitroglycerin, metoprolol | troponin, BNP, CK-MB, lipid panel | HTN, DM, hyperlipidemia, HF |
| Type 2 Diabetes | metformin, insulin, empagliflozin | HbA1c, fasting glucose, creatinine, lipids | HTN, CKD, retinopathy, neuropathy |

## Related Projects

| Project | Role |
|---------|------|
| `concept-dag` | Per-person graph engine (DuckDB + matrix algebra) |
| `umls_codeset_builder` | Python UMLS client (reference implementation) |
| `omop_concept_mapper` | NLP concept resolution (Phase B) |
| `lhn` | HDL extraction target |
| `SCDCernerProject` | Databricks extraction target template |
| `patientvolumeIUH` | EDW extraction target template |
| `AI` | Architecture docs (`pico-dag-architecture.qmd`, `omop-concept-dag-architecture.qmd`) |
