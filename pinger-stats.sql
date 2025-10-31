.mode column --
-- pinger-stats.sql
-- Usage:
--   sqlite3 /var/db/pinger/pings.db < pinger-stats.sql
--
-- This script produces a daily (last 7 days) columnar summary with a final W7 column
-- for the combined last 7 days. It uses a single metric pipeline for all periods.
-- ----------------------------
-- Parameters
-- ----------------------------
WITH RECURSIVE params AS (
    -- consider a gap > 2s as a loss
    SELECT 2 AS loss_gap_s,
        600 AS heal_s -- cluster healing interval seconds
),
label AS (
    SELECT 'Event clusters (' || heal_s || 's)' AS clusters_label
    FROM params
),
-- ----------------------------
-- Periods (idx = 1..7 per-day, idx = 8 weekly)
-- ----------------------------
days AS (
    SELECT 0 AS d
    UNION ALL
    SELECT d + 1
    FROM days
    WHERE d < 6
),
periods AS (
    -- Per-day windows: idx = 1..7 (today=1, yesterday=2, ...)
    SELECT (d + 1) AS idx,
        CAST(
            strftime(
                '%s',
                datetime('now', 'start of day', printf('-%d days', d))
            ) AS INTEGER
        ) AS start_sec,
        CAST(
            strftime(
                '%s',
                datetime(
                    'now',
                    'start of day',
                    printf('-%d days', d),
                    '+1 day'
                )
            ) AS INTEGER
        ) AS end_sec
    FROM days
    UNION ALL
    -- Weekly window: idx = 8 (last 7 calendar days, midnight-aligned)
    SELECT 8 AS idx,
        CAST(
            strftime('%s', datetime('now', 'start of day', '-6 days')) AS INTEGER
        ) AS start_sec,
        CAST(
            strftime('%s', datetime('now', 'start of day', '+1 day')) AS INTEGER
        ) AS end_sec
),
-- ----------------------------
-- Raw samples per period
-- ----------------------------
samples AS (
    SELECT p.idx,
        s.ts,
        CAST(strftime('%s', s.ts) AS INTEGER) AS tsec,
        CAST(s.latency_ms AS REAL) AS rtt
    FROM periods p
        JOIN pings s ON CAST(strftime('%s', s.ts) AS INTEGER) >= p.start_sec
        AND CAST(strftime('%s', s.ts) AS INTEGER) < p.end_sec
),
-- ----------------------------
-- Basic stats & percentiles (per idx)
-- ----------------------------
basic AS (
    SELECT idx,
        MIN(rtt) AS min_rtt,
        MAX(rtt) AS max_rtt,
        AVG(rtt) AS avg_rtt
    FROM samples
    GROUP BY idx
),
ordered AS (
    SELECT idx,
        rtt,
        ROW_NUMBER() OVER (
            PARTITION BY idx
            ORDER BY rtt
        ) AS rn,
        COUNT(*) OVER (PARTITION BY idx) AS n
    FROM samples
),
percentiles AS (
    -- Median index = (n+1)/2 ; P01 = floor((n-1)*0.01)+1 ; P99 = floor((n-1)*0.99)+1
    SELECT o.idx,
        MAX(
            CASE
                WHEN rn = ((n + 1) / 2) THEN rtt
            END
        ) AS p50,
        MAX(
            CASE
                WHEN rn = (CAST((n - 1) * 0.01 AS INTEGER) + 1) THEN rtt
            END
        ) AS p01,
        MAX(
            CASE
                WHEN rn = (CAST((n - 1) * 0.99 AS INTEGER) + 1) THEN rtt
            END
        ) AS p99
    FROM ordered o
    GROUP BY o.idx
),
-- ----------------------------
-- Diffs, jitter, loss, outages, clusters (per idx)
-- ----------------------------
diffs AS (
    SELECT idx,
        ts,
        tsec,
        ABS(
            rtt - LAG(rtt) OVER (
                PARTITION BY idx
                ORDER BY ts
            )
        ) AS diff,
        (
            tsec - LAG(tsec) OVER (
                PARTITION BY idx
                ORDER BY ts
            )
        ) AS gap
    FROM samples
),
jitter AS (
    SELECT idx,
        AVG(diff) AS jitter_ms
    FROM diffs,
        params
    WHERE gap IS NOT NULL
        AND gap <= loss_gap_s
    GROUP BY idx
),
loss_events AS (
    SELECT idx,
        SUM(
            CASE
                WHEN gap > loss_gap_s THEN 1
                ELSE 0
            END
        ) AS loss_events
    FROM diffs,
        params
    WHERE gap IS NOT NULL
    GROUP BY idx
),
observed AS (
    SELECT idx,
        COUNT(*) AS observed_samples
    FROM samples
    GROUP BY idx
),
loss_percent AS (
    -- Event-based percent: events / (observed + events)
    SELECT o.idx,
        CASE
            WHEN (o.observed_samples + COALESCE(e.loss_events, 0)) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(e.loss_events, 0) / (o.observed_samples + COALESCE(e.loss_events, 0))
        END AS loss_percent
    FROM observed o
        LEFT JOIN loss_events e USING (idx)
),
outages AS (
    SELECT idx,
        ts,
        gap,
        (tsec - gap) AS start_sec,
        tsec AS end_sec,
        (gap - 1) AS lost_sec
    FROM diffs,
        params
    WHERE gap IS NOT NULL
        AND gap > loss_gap_s
),
clusters AS (
    SELECT *,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    PARTITION BY idx
                    ORDER BY start_sec
                )
            ) + heal_s THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM outages,
        params
),
clustered AS (
    SELECT *,
        SUM(new_cluster_flag) OVER (
            PARTITION BY idx
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM clusters
),
agg AS (
    SELECT idx,
        cluster_id,
        MIN(start_sec) AS cluster_start,
        MAX(end_sec) AS cluster_end,
        SUM(lost_sec) AS cluster_lost_sec,
        (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
    FROM clustered
    GROUP BY idx,
        cluster_id
),
cluster_counts AS (
    SELECT idx,
        COUNT(*) AS cluster_events
    FROM agg
    GROUP BY idx
),
cluster_medians AS (
    SELECT idx,
        -- median cluster lost seconds
        (
            SELECT v
            FROM (
                    SELECT cluster_lost_sec AS v,
                        ROW_NUMBER() OVER (
                            PARTITION BY idx
                            ORDER BY cluster_lost_sec
                        ) AS rn,
                        COUNT(*) OVER (PARTITION BY idx) AS n
                    FROM agg a2
                    WHERE a2.idx = a.idx
                ) s
            WHERE rn = ((n + 1) / 2)
        ) AS med_cluster_lost_sec,
        -- median cluster span seconds
        (
            SELECT v
            FROM (
                    SELECT cluster_span_sec AS v,
                        ROW_NUMBER() OVER (
                            PARTITION BY idx
                            ORDER BY cluster_span_sec
                        ) AS rn,
                        COUNT(*) OVER (PARTITION BY idx) AS n
                    FROM agg a3
                    WHERE a3.idx = a.idx
                ) s
            WHERE rn = ((n + 1) / 2)
        ) AS med_cluster_span_sec
    FROM (
            SELECT DISTINCT idx
            FROM agg
        ) a
),
-- ----------------------------
-- Key/Value assembly for pivot
-- ----------------------------
kv AS (
    SELECT 'Minimum (ms)' AS metric,
        idx,
        min_rtt AS val
    FROM basic
    UNION ALL
    SELECT 'Maximum (ms)',
        idx,
        max_rtt
    FROM basic
    UNION ALL
    SELECT 'Average (ms)',
        idx,
        avg_rtt
    FROM basic
    UNION ALL
    SELECT 'Median (ms)',
        idx,
        p50
    FROM percentiles
    UNION ALL
    SELECT '1st percentile (ms)',
        idx,
        p01
    FROM percentiles
    UNION ALL
    SELECT '99th percentile (ms)',
        idx,
        p99
    FROM percentiles
    UNION ALL
    SELECT 'Jitter (ms)',
        idx,
        jitter_ms
    FROM jitter
    UNION ALL
    SELECT 'Loss events',
        idx,
        loss_events
    FROM loss_events
    UNION ALL
    SELECT 'Observed samples',
        idx,
        observed_samples
    FROM observed
    UNION ALL
    SELECT 'Loss percent (%)',
        idx,
        loss_percent
    FROM loss_percent
    UNION ALL
    SELECT clusters_label,
        idx,
        cluster_events
    FROM cluster_counts,
        label
    UNION ALL
    SELECT 'Median cluster loss (s)',
        idx,
        med_cluster_lost_sec
    FROM cluster_medians
    UNION ALL
    SELECT 'Median cluster span (s)',
        idx,
        med_cluster_span_sec
    FROM cluster_medians
) -- ----------------------------
-- Final pivot: D1..D7 (days), W7 (weekly)
-- Integers rendered without decimals; others with 3 decimals
-- ----------------------------
SELECT metric,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 1 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 1 THEN val
                END
            )
        )
    END AS D1,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 2 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 2 THEN val
                END
            )
        )
    END AS D2,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 3 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 3 THEN val
                END
            )
        )
    END AS D3,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 4 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 4 THEN val
                END
            )
        )
    END AS D4,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 5 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 5 THEN val
                END
            )
        )
    END AS D5,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 6 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 6 THEN val
                END
            )
        )
    END AS D6,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 7 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 7 THEN val
                END
            )
        )
    END AS D7,
    CASE
        WHEN metric IN (
            'Loss events',
            'Observed samples',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            MAX(
                CASE
                    WHEN idx = 8 THEN val
                END
            ) AS INTEGER
        )
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 8 THEN val
                END
            )
        )
    END AS W7
FROM kv,
    label
GROUP BY metric
ORDER BY CASE
        metric
        WHEN 'Minimum (ms)' THEN 1
        WHEN 'Maximum (ms)' THEN 2
        WHEN 'Average (ms)' THEN 3
        WHEN 'Median (ms)' THEN 4
        WHEN '1st percentile (ms)' THEN 5
        WHEN '99th percentile (ms)' THEN 6
        WHEN 'Jitter (ms)' THEN 7
        WHEN 'Loss events' THEN 8
        WHEN 'Observed samples' THEN 9
        WHEN 'Loss percent (%)' THEN 10
        WHEN clusters_label THEN 11
        WHEN 'Median cluster loss (s)' THEN 12
        WHEN 'Median cluster span (s)' THEN 13
        ELSE 99
    END;
