# D0002: Use partitioned Postgres (no TimescaleDB) for MVP

Date: 2026-04-20
Status: accepted

## Context

The insights warehouse is append-heavy, time-series-shaped, and dominated by rolling-window queries (last 7 days CTR, 30-day CPA baseline, etc.). Two plausible approaches:

1. **TimescaleDB hypertables** with continuous aggregates.
2. **Plain partitioned Postgres** using native declarative partitioning by date.

MVP will run on a self-hosted Postgres Docker container on a VPS. The founder is already pulling 1k+ ads from live campaigns as part of the Track 2 spike.

## Decision

Use native partitioned Postgres. No Timescale extension for MVP.

- `insights_daily` partitioned by `date_start`, weekly partitions.
  - ~1k accounts × ~50 ads × 7 days × ~200 bytes/row ≈ 70 MB/partition. Comfortable.
- Partitions created on a rolling schedule by a small `PartitionManager` Oban job — creates next week's partition on Sunday, drops partitions older than retention cutoff.
- Retention: keep 13 months of daily insights (enough for YoY comparisons), archive beyond that to cold storage.
- Rolling-window aggregates computed via **materialized views** refreshed on a schedule (every 15 minutes for 7-day windows, hourly for 30-day windows), plus query-time aggregation when a finding needs fresher data.
- Indexes: `(ad_id, date_start)` on every partition. Postgres propagates the index definition across partitions when done at the partitioned table level.

## Consequences

- **Simpler ops.** No extension to install, version-track, or debug. A vanilla Postgres Docker image works.
- **No continuous aggregates.** We lose Timescale's incremental aggregate refresh; materialized views recompute in full on refresh. At MVP scale (small-100s of users, <100GB data) this is fine — the refresh takes seconds. Watch refresh time as data grows.
- **No automatic chunk compression.** Storage will grow linearly. At retention limits, storage is bounded; dropping old partitions is O(1) (fast ALTER TABLE DETACH).
- **Manual partition lifecycle.** The `PartitionManager` job is a net-new thing to monitor. Its failure mode is "no new partition exists when the first write of the new week happens" — add a monitor that alerts if fewer than 2 future partitions exist.
- **Migration path is open.** If we outgrow this, swapping to TimescaleDB is mechanical — Timescale has a migration tool for existing partitioned tables. Decision is reversible.

## When to revisit

- Materialized view refresh exceeds ~5 minutes or blocks other queries.
- Storage on VPS approaches 70% of disk with retention already at 13 months.
- Query latency on common analytics passes exceeds 500ms on warm cache.
- VPS becomes operationally painful (backups, failover, disk resizing) — time to move to managed Postgres; at that point re-evaluate Timescale Cloud as a one-step upgrade.

## Alternatives considered

- **TimescaleDB** — better long-term fit technically, but adds an extension to manage, and Docker-image choice (vanilla vs timescale/timescaledb:*) becomes an early lock-in. Defer.
- **Citus / distributed Postgres** — over-engineered for MVP scale.
- **ClickHouse or DuckDB as a side warehouse** — interesting for analytics but adds a second database to sync. Not MVP.

## Operational notes

Two things to get right in v0.1:

- **Persistent Docker volume.** Mount `/var/lib/postgresql/data` to a named volume on the host, not the container's writable layer. Ephemeral storage in Docker is a data-loss foot-gun.
- **Automated backups.** `pg_dump` to S3/B2/any object storage on a cron, with a recovery-test runbook. Set this up in v0.1 before there's a single customer, not after.
