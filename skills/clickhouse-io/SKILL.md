---
name: clickhouse-io
description: ClickHouse database patterns, query optimization, analytics, and data engineering best practices for high-performance analytical workloads.
when_to_use: Use when the user is modeling analytics tables, tuning ClickHouse queries, or building ingestion and reporting workflows on ClickHouse.
---

# ClickHouse Analytics Patterns

ClickHouse is a column-oriented DBMS for OLAP, optimized for fast analytical queries on large datasets. Key strengths: columnar storage, compression, parallel execution, distributed queries, real-time analytics.

## Reference Files

| File | Contents |
|------|----------|
| [references/table-design.md](references/table-design.md) | MergeTree engine types, table creation patterns, partitioning, ordering keys, data type selection |
| [references/query-optimization.md](references/query-optimization.md) | Filtering best practices, aggregations, window functions, materialized views, performance monitoring |
| [references/data-pipeline.md](references/data-pipeline.md) | Bulk/streaming insert, ETL/CDC patterns, time series, funnel, cohort, and retention query templates |

## Engine Selection Guide

| Engine | Use When | Trade-off |
|--------|----------|-----------|
| MergeTree | Default for most tables | No dedup or pre-aggregation |
| ReplacingMergeTree | Data has duplicates from multiple sources | Dedup only on merge, not query time |
| AggregatingMergeTree | Pre-computed rollups (hourly/daily stats) | Requires `*State`/`*Merge` function pairs |

## Core Rules

- **Batch inserts** -- never insert row-by-row
- **Specify columns** -- avoid `SELECT *`
- **Filter on indexed columns first** -- match ORDER BY key order
- **Denormalize** -- minimize JOINs for analytical tables
- **Leverage materialized views** -- for real-time aggregations

ClickHouse excels at analytical workloads. Design tables for your query patterns, batch inserts, and leverage materialized views for real-time aggregations.
