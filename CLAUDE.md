# pico-dag — PICO-Driven Clinical Research Accelerator

## Overview

Shiny app that translates PICO research questions into data pull specifications by walking the UMLS concept graph. No LLM required — pure graph traversal + vocabulary API.

**Architecture:** See `/projects/AI/pico-dag-architecture.qmd` for full specification.

## Running

```bash
# Enter Nix dev shell (installs R + all packages)
nix develop

# Run the app
Rscript -e 'shiny::runApp("app")'
```

Requires `UMLS_API_KEY` environment variable (NLM license).

## Structure

```
pico-dag/
├── flake.nix              # Nix reproducible R environment
├── app/
│   ├── app.R              # Main Shiny app (UI + server)
│   └── R/
│       ├── umls_client.R  # UMLS REST API client (httr2)
│       ├── dag_walker.R   # Categorize relations, second-hop traversal
│       ├── code_lists.R   # Generate ICD/SNOMED/LOINC/RxNorm code lists
│       └── network_viz.R  # visNetwork DAG visualization
└── CLAUDE.md
```

## Conventions

- R with tidyverse (per positron-verse rules)
- `httr2` for HTTP (not httr)
- `|>` native pipe
- `\(x)` lambda syntax
- bslib for theming (Bootstrap 5)
