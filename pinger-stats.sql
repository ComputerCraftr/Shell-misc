.headers on
.mode column

-- pinger_stats.sql
-- Usage:
--   sqlite3 /var/db/pinger/pings.db < pinger_stats.sql
--   or use -header -column flags instead of directives in file
--
-- This script computes latency stats and jitter over past day (1d) and week (7d).
-- Metrics: Minimum, Maximum, Average, Median, 1st percentile, 99th percentile, Jitter (mean abs).

WITH recent AS (
    SELECT ts,
        latency_ms
    FROM pings
    WHERE ts >= datetime ('now', '-1 day')
),
recent_7d AS (
    SELECT ts,
        latency_ms
    FROM pings
    WHERE ts >= datetime ('now', '-7 days')
),
diffs1d AS (
    SELECT ABS(
            latency_ms - LAG (latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff
    FROM recent
),
diffs7d AS (
    SELECT ABS(
            latency_ms - LAG (latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff
    FROM recent_7d
) -- 1d metrics
SELECT '1d Minimum' AS metric,
    printf ('%.3f ms', MIN(latency_ms)) AS result
FROM recent
UNION ALL
SELECT '1d Maximum',
    printf ('%.3f ms', MAX(latency_ms))
FROM recent
UNION ALL
SELECT '1d Average',
    printf ('%.3f ms', AVG(latency_ms))
FROM recent
UNION ALL
SELECT '1d Median',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent
            ORDER BY latency_ms
            LIMIT 1 OFFSET (
                    (
                        SELECT COUNT(*)
                        FROM recent
                    ) - 1
                ) / 2
        )
    )
UNION ALL
SELECT '1d 1st percentile',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent
                        ) - 1
                    ) * 0.01 AS INTEGER
                )
        )
    )
UNION ALL
SELECT '1d 99th percentile',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent
                        ) - 1
                    ) * 0.99 AS INTEGER
                )
        )
    )
UNION ALL
SELECT '1d Jitter' AS metric,
    printf ('%.3f ms', AVG(diff)) AS result
FROM diffs1d -- 7d metrics
UNION ALL
SELECT '7d Minimum' AS metric,
    printf ('%.3f ms', MIN(latency_ms)) AS result
FROM recent_7d
UNION ALL
SELECT '7d Maximum',
    printf ('%.3f ms', MAX(latency_ms))
FROM recent_7d
UNION ALL
SELECT '7d Average',
    printf ('%.3f ms', AVG(latency_ms))
FROM recent_7d
UNION ALL
SELECT '7d Median',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent_7d
            ORDER BY latency_ms
            LIMIT 1 OFFSET (
                    (
                        SELECT COUNT(*)
                        FROM recent_7d
                    ) - 1
                ) / 2
        )
    )
UNION ALL
SELECT '7d 1st percentile',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent_7d
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent_7d
                        ) - 1
                    ) * 0.01 AS INTEGER
                )
        )
    )
UNION ALL
SELECT '7d 99th percentile',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent_7d
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent_7d
                        ) - 1
                    ) * 0.99 AS INTEGER
                )
        )
    )
UNION ALL
SELECT '7d Jitter' AS metric,
    printf ('%.3f ms', AVG(diff)) AS result
FROM diffs7d;
