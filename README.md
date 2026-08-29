# Spotify Analytics — Advanced SQL Project

Analysis of ~20,600 tracks combining Spotify streaming counts, YouTube engagement metrics and audio features, using MySQL for the analysis and Python for orchestration and benchmarking.

**Stack:** MySQL 8.0 · Python (pandas, SQLAlchemy, PyMySQL) · Jupyter

---

## Contents

| File | Description |
|---|---|
| `spotify_sql_analysis.ipynb` | Full notebook — loading, data quality audit, EDA, 15 business problems, query optimization |
| `queries.sql` | The analysis queries as a standalone SQL file |
| `README.md` | This file |

---

## Setup

**Requires MySQL 8.0 or later.** Window functions and CTEs are not available in 5.7.

```bash
pip install pandas sqlalchemy pymysql matplotlib jupyter
```

Set your credentials and the CSV path in the configuration cell at the top of the notebook, then run it top to bottom. The notebook creates the database, defines the schema and loads the data — no manual CSV import step.

---

## Approach

### Loading

The data is loaded through pandas with **explicit SQL types** rather than inferred ones. Two reasons this matters:

- Text columns default to `TEXT`, and MySQL cannot index a `TEXT` column without a prefix length. Declaring `artist` as `VARCHAR(100)` lets the index in the optimization section be created cleanly.
- `views`, `likes`, `comments` and `stream` arrive as floats but are counts. Rounding them to `BIGINT` avoids the "invalid input syntax for type bigint" import failure and keeps aggregates exact.

Loading through a driver also removes the quoting and escaping problems that break manual CSV imports — apostrophes inside track names are handled by parameter binding.

### Data quality

Two issues surfaced before any analysis:

**Impossible durations.** Two tracks report a duration of zero minutes while carrying non-zero views and stream counts. These are corrupt rather than unusual, and were removed.

**Malformed boolean flags.** 469 rows store `0` in `licensed` and `official_video`, columns that otherwise hold `True` / `False`. It is the same 469 rows in both columns, which points to a row-level export fault rather than a real value.

These were preserved as `NULL` rather than coerced to `False`. Coercing them would silently inflate the "unlicensed" population by 469 tracks and bias every downstream comparison. `NULL` correctly encodes *unknown*, and MySQL excludes it from `= TRUE` and `= FALSE` filters automatically.

---

## Business problems

Fifteen problems across three difficulty tiers.

**Easy (Q1–Q5)** — filtering, aggregation, `GROUP BY`.

**Medium (Q6–Q10)** — multi-column grouping, `HAVING`, safe division with `NULLIF`, and conditional aggregation.

Q10 is the most instructive of the tier. The platform lives in a single `most_playedon` column, so Spotify and YouTube figures must be pivoted into separate columns with `CASE` inside `SUM` before they can be compared, then wrapped in a derived table because `SELECT`-list aliases are not visible to `WHERE` in the same query block.

**Advanced (Q11–Q15)** — window functions and CTEs.

Q11 ranks each artist's top 3 tracks with `DENSE_RANK() OVER (PARTITION BY ...)`. Dense ranking is the correct choice: tied tracks share a rank and the next rank is not skipped, so "top 3" returns the three best performance levels rather than three arbitrary rows. Q15 computes a running total with an explicitly stated window frame, since the default frame changes behaviour when the `ORDER BY` column contains ties.

---

## Query optimization

A single-column index on the filter column was added, and the execution plan measured before and after:

| | Access type | Rows examined | Execution time |
|---|---|---|---|
| Before index | `ALL` (full table scan) | ~20,592 | ~5.0 ms |
| After index | `ref` (index lookup) | ~10 | ~0.2 ms |

The access type change from `ALL` to `ref` is the meaningful result — timings vary by machine, but the plan change is deterministic. The optimizer's row estimate collapses from the entire table to roughly the number of rows that actually match.

**The trade-off.** Indexing is not free. Every index is a separate B-tree that must be maintained on write, so `INSERT` / `UPDATE` / `DELETE` all slow down as index count grows. Low-cardinality columns rarely benefit — an index on `most_playedon`, with two distinct values across 20,000 rows, would be ignored by the optimizer, because scanning half a table through an index is slower than scanning it directly. A composite index on `(artist, most_playedon)` would serve this particular query better, but composite indexes are usable left-to-right only, so it would not help a query filtering on `most_playedon` alone.

---

## Findings

**Catalogue**
- 20,592 tracks after cleaning, across 2,074 artists and 11,854 albums
- 385 tracks (1.9%) exceed 1 billion Spotify streams
- Singles account for roughly a quarter of the catalogue

**Platform behaviour**
- Only 189 tracks present on both platforms out-stream their YouTube performance on Spotify — cross-platform dominance is the exception

**Audio features**
- Mean liveness is 0.19; 6,364 tracks sit above it
- The highest-energy tracks are ambient and white-noise recordings, confirming that `energy` measures acoustic intensity rather than musical intensity — relevant if this feature ever feeds a recommendation model

---

## SQL concepts demonstrated

Filtering · `GROUP BY` / `HAVING` · aggregate functions · conditional aggregation (`CASE` within `SUM`) · `NULL` handling (`COALESCE`, `NULLIF`) · scalar subqueries · derived tables · common table expressions · window functions (`DENSE_RANK`, running totals with explicit frames) · execution plan analysis and index design
