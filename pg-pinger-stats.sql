SET search_path TO pinger;
WITH recent_1d AS (
    SELECT ts,
        latency_ms
    FROM pings
    WHERE ts >= now() - INTERVAL '1 day'
),
recent_7d AS (
    SELECT ts,
        latency_ms
    FROM pings
    WHERE ts >= now() - INTERVAL '7 days'
),
diffs1d AS (
    SELECT ABS(
            latency_ms - LAG(latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff
    FROM recent_1d
),
diffs7d AS (
    SELECT ABS(
            latency_ms - LAG(latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff
    FROM recent_7d
),
agg1d AS (
    SELECT MIN(latency_ms) AS min_v,
        MAX(latency_ms) AS max_v,
        AVG(latency_ms) AS avg_v,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS median_v,
        PERCENTILE_CONT(0.01) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS p01_v,
        PERCENTILE_CONT(0.99) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS p99_v,
        (
            SELECT AVG(diff)
            FROM diffs1d
        ) AS jitter_v
    FROM recent_1d
),
agg7d AS (
    SELECT MIN(latency_ms) AS min_v,
        MAX(latency_ms) AS max_v,
        AVG(latency_ms) AS avg_v,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS median_v,
        PERCENTILE_CONT(0.01) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS p01_v,
        PERCENTILE_CONT(0.99) WITHIN GROUP (
            ORDER BY latency_ms
        ) AS p99_v,
        (
            SELECT AVG(diff)
            FROM diffs7d
        ) AS jitter_v
    FROM recent_7d
)
SELECT '1d Minimum' AS metric,
    format('%s ms', round(min_v::numeric, 3)) AS result
FROM agg1d
UNION ALL
SELECT '1d Maximum',
    format('%s ms', round(max_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '1d Average',
    format('%s ms', round(avg_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '1d Median',
    format('%s ms', round(median_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '1d 1st percentile',
    format('%s ms', round(p01_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '1d 99th percentile',
    format('%s ms', round(p99_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '1d Jitter',
    format('%s ms', round(jitter_v::numeric, 3))
FROM agg1d
UNION ALL
SELECT '7d Minimum',
    format('%s ms', round(min_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d Maximum',
    format('%s ms', round(max_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d Average',
    format('%s ms', round(avg_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d Median',
    format('%s ms', round(median_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d 1st percentile',
    format('%s ms', round(p01_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d 99th percentile',
    format('%s ms', round(p99_v::numeric, 3))
FROM agg7d
UNION ALL
SELECT '7d Jitter',
    format('%s ms', round(jitter_v::numeric, 3))
FROM agg7d;
