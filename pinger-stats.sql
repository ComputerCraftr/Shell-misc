.headers on
.mode column
-- pinger_stats.sql
-- Usage:
--   sqlite3 /var/db/pinger/pings.db < pinger_stats.sql
--   or use -header -column flags instead of directives in file
--
-- This script computes latency stats and jitter over past day (1d) and week (7d).
-- Metrics: Minimum, Maximum, Average, Median, 1st percentile, 99th percentile, Jitter (mean abs).
WITH recent_1d AS (
    SELECT ts,
        latency_ms,
        CAST(strftime('%s', ts) AS INTEGER) AS tsec
    FROM pings
    WHERE ts >= datetime('now', '-1 day')
),
recent_7d AS (
    SELECT ts,
        latency_ms,
        CAST(strftime('%s', ts) AS INTEGER) AS tsec
    FROM pings
    WHERE ts >= datetime('now', '-7 days')
),
diffs_1d AS (
    SELECT ts,
        tsec,
        ABS(
            latency_ms - LAG(latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff,
        (
            tsec - LAG(tsec) OVER (
                ORDER BY ts
            )
        ) AS gap
    FROM recent_1d
),
diffs_7d AS (
    SELECT ts,
        tsec,
        ABS(
            latency_ms - LAG(latency_ms) OVER (
                ORDER BY ts
            )
        ) AS diff,
        (
            tsec - LAG(tsec) OVER (
                ORDER BY ts
            )
        ) AS gap
    FROM recent_7d
),
-- Outage records (gap > 2s) with start/end times (1d)
outages_1d AS (
    SELECT ts,
        gap,
        tsec,
        (CAST(strftime('%s', ts) AS INTEGER) - gap) AS start_sec,
        CAST(strftime('%s', ts) AS INTEGER) AS end_sec,
        (gap - 1) AS lost_sec
    FROM diffs_1d
    WHERE gap IS NOT NULL
        AND gap > 2
),
-- Cluster outages with a 5s healing interval (1d)
clusters_1d AS (
    SELECT *,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    ORDER BY start_sec
                )
            ) + 5 THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM outages_1d
),
clustered_1d AS (
    SELECT *,
        SUM(new_cluster_flag) OVER (
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM clusters_1d
),
agg_1d AS (
    SELECT cluster_id,
        MIN(start_sec) AS cluster_start,
        MAX(end_sec) AS cluster_end,
        SUM(lost_sec) AS cluster_lost_sec,
        (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
    FROM clustered_1d
    GROUP BY cluster_id
),
-- Outage records (gap > 2s) with start/end times (7d)
outages_7d AS (
    SELECT ts,
        gap,
        tsec,
        (CAST(strftime('%s', ts) AS INTEGER) - gap) AS start_sec,
        CAST(strftime('%s', ts) AS INTEGER) AS end_sec,
        (gap - 1) AS lost_sec
    FROM diffs_7d
    WHERE gap IS NOT NULL
        AND gap > 2
),
-- Cluster outages with a 5s healing interval (7d)
clusters_7d AS (
    SELECT *,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    ORDER BY start_sec
                )
            ) + 5 THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM outages_7d
),
clustered_7d AS (
    SELECT *,
        SUM(new_cluster_flag) OVER (
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM clusters_7d
),
agg_7d AS (
    SELECT cluster_id,
        MIN(start_sec) AS cluster_start,
        MAX(end_sec) AS cluster_end,
        SUM(lost_sec) AS cluster_lost_sec,
        (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
    FROM clustered_7d
    GROUP BY cluster_id
) -- 1d metrics
SELECT '1d Minimum' AS metric,
    printf ('%.3f ms', MIN(latency_ms)) AS result
FROM recent_1d
UNION ALL
SELECT '1d Maximum',
    printf ('%.3f ms', MAX(latency_ms))
FROM recent_1d
UNION ALL
SELECT '1d Average',
    printf ('%.3f ms', AVG(latency_ms))
FROM recent_1d
UNION ALL
SELECT '1d Median',
    printf (
        '%.3f ms',
        (
            SELECT latency_ms
            FROM recent_1d
            ORDER BY latency_ms
            LIMIT 1 OFFSET (
                    (
                        SELECT COUNT(*)
                        FROM recent_1d
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
            FROM recent_1d
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent_1d
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
            FROM recent_1d
            ORDER BY latency_ms
            LIMIT 1 OFFSET CAST(
                    (
                        (
                            SELECT COUNT(*)
                            FROM recent_1d
                        ) - 1
                    ) * 0.99 AS INTEGER
                )
        )
    )
UNION ALL
SELECT '1d Jitter' AS metric,
    printf('%.3f ms', AVG(diff)) AS result
FROM diffs_1d
WHERE gap IS NOT NULL
    AND gap <= 2
UNION ALL
-- 1d loss metrics (based on 1s cadence)
SELECT '1d Loss events' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                SELECT SUM(
                        CASE
                            WHEN gap > 2 THEN 1
                            ELSE 0
                        END
                    )
                FROM diffs_1d
                WHERE gap IS NOT NULL
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '1d Observed samples',
    printf(
        '%d',
        (
            SELECT COUNT(*)
            FROM recent_1d
        )
    ) AS result
UNION ALL
SELECT '1d Loss percent',
    printf(
        '%.3f %%',
        CASE
            WHEN (
                SELECT COUNT(*)
                FROM recent_1d
            ) + COALESCE(
                (
                    SELECT SUM(
                            CASE
                                WHEN gap > 2 THEN 1
                                ELSE 0
                            END
                        )
                    FROM diffs_1d
                    WHERE gap IS NOT NULL
                ),
                0
            ) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(
                (
                    SELECT SUM(
                            CASE
                                WHEN gap > 2 THEN 1
                                ELSE 0
                            END
                        )
                    FROM diffs_1d
                    WHERE gap IS NOT NULL
                ),
                0
            ) / (
                (
                    SELECT COUNT(*)
                    FROM recent_1d
                ) + COALESCE(
                    (
                        SELECT SUM(
                                CASE
                                    WHEN gap > 2 THEN 1
                                    ELSE 0
                                END
                            )
                        FROM diffs_1d
                        WHERE gap IS NOT NULL
                    ),
                    0
                )
            )
        END
    ) AS result
UNION ALL
SELECT '1d Loss event clusters (heal=5s)' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                SELECT COUNT(*)
                FROM agg_1d
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '1d Median cluster lost seconds' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_lost_sec AS v
                    FROM agg_1d
                    ORDER BY v
                ),
                n AS (
                    SELECT COUNT(*) AS c
                    FROM s
                )
                SELECT v
                FROM s
                LIMIT 1 OFFSET (
                        (
                            SELECT c
                            FROM n
                        ) -1
                    ) / 2
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '1d Median cluster span seconds' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_span_sec AS v
                    FROM agg_1d
                    ORDER BY v
                ),
                n AS (
                    SELECT COUNT(*) AS c
                    FROM s
                )
                SELECT v
                FROM s
                LIMIT 1 OFFSET (
                        (
                            SELECT c
                            FROM n
                        ) -1
                    ) / 2
            ),
            0
        )
    ) AS result
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
    printf('%.3f ms', AVG(diff)) AS result
FROM diffs_7d
WHERE gap IS NOT NULL
    AND gap <= 2
UNION ALL
-- 7d loss metrics (based on 1s cadence)
SELECT '7d Loss events' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                SELECT SUM(
                        CASE
                            WHEN gap > 2 THEN 1
                            ELSE 0
                        END
                    )
                FROM diffs_7d
                WHERE gap IS NOT NULL
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '7d Observed samples',
    printf(
        '%d',
        (
            SELECT COUNT(*)
            FROM recent_7d
        )
    ) AS result
UNION ALL
SELECT '7d Loss percent',
    printf(
        '%.3f %%',
        CASE
            WHEN (
                SELECT COUNT(*)
                FROM recent_7d
            ) + COALESCE(
                (
                    SELECT SUM(
                            CASE
                                WHEN gap > 2 THEN 1
                                ELSE 0
                            END
                        )
                    FROM diffs_7d
                    WHERE gap IS NOT NULL
                ),
                0
            ) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(
                (
                    SELECT SUM(
                            CASE
                                WHEN gap > 2 THEN 1
                                ELSE 0
                            END
                        )
                    FROM diffs_7d
                    WHERE gap IS NOT NULL
                ),
                0
            ) / (
                (
                    SELECT COUNT(*)
                    FROM recent_7d
                ) + COALESCE(
                    (
                        SELECT SUM(
                                CASE
                                    WHEN gap > 2 THEN 1
                                    ELSE 0
                                END
                            )
                        FROM diffs_7d
                        WHERE gap IS NOT NULL
                    ),
                    0
                )
            )
        END
    ) AS result
UNION ALL
SELECT '7d Loss event clusters (heal=5s)' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                SELECT COUNT(*)
                FROM agg_7d
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '7d Median cluster lost seconds' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_lost_sec AS v
                    FROM agg_7d
                    ORDER BY v
                ),
                n AS (
                    SELECT COUNT(*) AS c
                    FROM s
                )
                SELECT v
                FROM s
                LIMIT 1 OFFSET (
                        (
                            SELECT c
                            FROM n
                        ) -1
                    ) / 2
            ),
            0
        )
    ) AS result
UNION ALL
SELECT '7d Median cluster span seconds' AS metric,
    printf(
        '%d',
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_span_sec AS v
                    FROM agg_7d
                    ORDER BY v
                ),
                n AS (
                    SELECT COUNT(*) AS c
                    FROM s
                )
                SELECT v
                FROM s
                LIMIT 1 OFFSET (
                        (
                            SELECT c
                            FROM n
                        ) -1
                    ) / 2
            ),
            0
        )
    ) AS result;
