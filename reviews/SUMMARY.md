# Review-Fix Loop — pico-dag (DRY-RUN, single-model validation pass)

**Started:** 2026-05-14 ~20:42 UTC
**Mode:** dry-run (no edits, no commits)
**Starting commit:** `9fe0953c` (HEAD)
**Stash:** `review-fix-loop dry-run snapshot 20260514-203924` (your WIP — restore at end)
**Rounds run:** 1 (single-model validation only)
**Models used:** `google-gemini-2.5-flash` (cheap pass — ~$0.05)
**Target:** `app/R/dag_walker.R` (394 lines, ~2K tokens)
**Why only one file:** `asksage_review.py` has a broken import (`create_llm_archive` missing from current `txtarchive.packunpack`) when reviewing whole directories. **Real bug surfaced — see "Issues with the tooling itself" below.** Single-file mode bypasses it.

---

## Issues the loop would act on (P1 + P2)

If this were a real run, the loop would attempt to fix these and commit.

### P1 — would fix and commit

None confirmed. The "API key handling" callout is a check, not a known bug — it surfaces below as a P0 verification item.

### P2 — would auto-fix and commit (4 items)

| # | Issue | Source location | Fix |
|---|---|---|---|
| 1 | `tryCatch` blocks silently swallow errors (return `NA`/`NULL` with no log) | `resolve_source_url_to_cui`, `bfs_walk` tryCatch handlers | Add `warning("...", call. = FALSE)` in each error handler before returning |
| 2 | Manual `Sys.sleep()` rate limiting; modern pattern is `httr2::req_retry()` | `resolve_source_url_to_cui` httr2 chain | Add `req_retry(max_tries = 3, backoff = exponential)` before `req_perform()` |
| 3 | No input validation on `root_cui`, `max_depth`, `expand_n` | `bfs_walk`, `walk_concept_dag` function tops | Add `stopifnot()` or `cli::cli_abort()` calls for invalid inputs |
| 4 | External deps (`UMLS_BASE_URL`, `get_api_key`, `umls_get_relations`, `umls_get_concept`) not documented | Roxygen blocks for `walk_concept_dag` and `bfs_walk` | Add `@seealso` or `@details` listing where each is defined |

---

## P0 — surfaced for your decision (2 items)

### 1. `monitoring_labs = tibble::tibble()` may be dead code or unfinished

In `walk_concept_dag` the return list contains:

```r
monitoring_labs = tibble::tibble() # kept for UI compatibility
```

The reviewer notes that `diagnostic_labs` already extracts both `"diagnostic_lab"` and `"monitoring_lab"` categories. So either:

- `monitoring_labs` should be populated by a separate extraction (currently a bug — UI sees empty)
- `monitoring_labs` is dead and should be removed
- The comment "kept for UI compatibility" is the true reason and the empty value is intentional

**Decision needed:** populate, remove, or leave with clearer doc?

### 2. `get_api_key()` source unverified

Reviewer flags that the security posture depends on where `get_api_key()` retrieves the API key from. Not a known bug, but a sanity check worth confirming since the file isn't in this review's scope. Verify it reads from `Sys.getenv("UMLS_API_KEY")` (or similar env-var pattern) and not a hardcoded value or committed file.

---

## Things the loop would NOT touch

- "BFS queue efficiency" (reviewer explicitly says "unlikely to be a bottleneck for current parameters")
- General praise (memoization, lazy resolution, modular structure)

---

## Issues with the tooling itself (surfaced this run)

1. **`asksage_review.py` calls `txtarchive.packunpack.create_llm_archive`** — function doesn't exist in current `txtarchive`. Closest available: `archive_subdirectories`, `concatenate_files`, or `run_concat`. **Action:** patch `asksage_review.py:104` to use the current API, OR add a compat shim in `txtarchive`. This blocks all directory-mode reviews via asksage today.

2. **The loop's pre-flight stash worked correctly.** 4 modified + 5 untracked items captured, working tree now clean, can be restored.

---

## How the loop would have run for real

Had this been a non-dry-run with the full 4-model panel:

```
Round 1: 4 model calls, ~$3-5 total
  Auto-fix: 4 P2 items (one commit, with warning+req_retry+stopifnot+roxygen)
  Surface: 2 P0 items (monitoring_labs, get_api_key check)

Round 2: re-review the modified file with the same 4 models
  Either zero new issues → converge and stop
  Or new issues → repeat fix-commit
  Max 3 rounds total
```

The single-model dry-run here proves: review fetches work, output parses, categorization is sensible. The remaining unknowns are (a) whether the four models would agree (consensus = higher confidence), and (b) whether the auto-fixes hold under re-review.

---

## Your one decision now

Three possible next steps. Pick one or skip entirely:

1. **Patch `asksage_review.py`** so directory-mode works → unblocks reviewing the whole `pico-dag/` at once, not file-by-file.
2. **Run the loop for real** on `dag_walker.R` only (the four-model panel + commit fixes) → ~$3-5, leaves you with concrete commits to review.
3. **Skip** — the dry-run validated the skill works; come back when you have ~30 minutes to do the real cycle.

Either way: **your WIP is stashed** as `review-fix-loop dry-run snapshot 20260514-203924`. To restore:

```bash
cd ~/projects/pico-dag && git stash list
cd ~/projects/pico-dag && git stash pop
```
