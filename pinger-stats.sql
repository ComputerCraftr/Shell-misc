.mode column
-- pinger_stats.sql
-- Usage:
--   sqlite3 /var/db/pinger/pings.db < pinger_stats.sql
--   or use -header -column flags instead of directives in file
--
-- ============================================
-- Daily (last 7 days) columnar summary of latency stats and loss events (D1=Today ... D7=6 days ago)
-- ============================================
WITH RECURSIVE day_map(idx, d) AS (
    SELECT 1,
        date('now')
    UNION ALL
    SELECT idx + 1,
        date('now', '-' || idx || ' days')
    FROM day_map
    WHERE idx < 7
),
day_samples AS (
    SELECT dm.idx,
        p.ts,
        CAST(strftime('%s', p.ts) AS INTEGER) AS tsec,
        CAST(p.latency_ms AS REAL) AS rtt
    FROM pings p
        JOIN day_map dm ON date(p.ts) = dm.d
),
day_ordered AS (
    SELECT idx,
        rtt,
        ROW_NUMBER() OVER (
            PARTITION BY idx
            ORDER BY rtt
        ) AS rn,
        COUNT(*) OVER (PARTITION BY idx) AS n
    FROM day_samples
),
day_percentiles AS (
    -- Median index = (n+1)/2 (integer); P01 = floor((n-1)*0.01)+1; P99 = floor((n-1)*0.99)+1
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
    FROM day_ordered o
    GROUP BY o.idx
),
day_basic AS (
    SELECT idx,
        MIN(rtt) AS min_rtt,
        MAX(rtt) AS max_rtt,
        AVG(rtt) AS avg_rtt
    FROM day_samples
    GROUP BY idx
),
day_diffs AS (
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
    FROM day_samples
),
day_jitter AS (
    SELECT idx,
        AVG(diff) AS jitter_ms
    FROM day_diffs
    WHERE gap IS NOT NULL
        AND gap <= 2
    GROUP BY idx
),
day_loss_events AS (
    SELECT idx,
        SUM(
            CASE
                WHEN gap > 2 THEN 1
                ELSE 0
            END
        ) AS loss_events
    FROM day_diffs
    WHERE gap IS NOT NULL
    GROUP BY idx
),
day_observed AS (
    SELECT idx,
        COUNT(*) AS observed_samples
    FROM day_samples
    GROUP BY idx
),
day_loss_percent AS (
    -- Event-based percent: events / (observed + events)
    SELECT o.idx,
        CASE
            WHEN (o.observed_samples + COALESCE(e.loss_events, 0)) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(e.loss_events, 0) / (o.observed_samples + COALESCE(e.loss_events, 0))
        END AS loss_percent
    FROM day_observed o
        LEFT JOIN day_loss_events e USING (idx)
),
-- Build outages and clusters per day with 5s healing interval
outages_day AS (
    SELECT idx,
        ts,
        gap,
        (tsec - gap) AS start_sec,
        tsec AS end_sec,
        (gap - 1) AS lost_sec
    FROM day_diffs
    WHERE gap IS NOT NULL
        AND gap > 2
),
clusters_day AS (
    SELECT *,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    PARTITION BY idx
                    ORDER BY start_sec
                )
            ) + 5 THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM outages_day
),
clustered_day AS (
    SELECT *,
        SUM(new_cluster_flag) OVER (
            PARTITION BY idx
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM clusters_day
),
agg_day AS (
    SELECT idx,
        cluster_id,
        MIN(start_sec) AS cluster_start,
        MAX(end_sec) AS cluster_end,
        SUM(lost_sec) AS cluster_lost_sec,
        (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
    FROM clustered_day
    GROUP BY idx,
        cluster_id
),
day_cluster_counts AS (
    SELECT idx,
        COUNT(*) AS cluster_events
    FROM agg_day
    GROUP BY idx
),
day_cluster_medians AS (
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
                    FROM agg_day a2
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
                    FROM agg_day a3
                    WHERE a3.idx = a.idx
                ) s
            WHERE rn = ((n + 1) / 2)
        ) AS med_cluster_span_sec
    FROM (
            SELECT DISTINCT idx
            FROM agg_day
        ) a
),
-- Weekly (last 7 days) aggregates for a final column
weekly_samples AS (
    SELECT p.ts,
        CAST(strftime('%s', p.ts) AS INTEGER) AS tsec,
        CAST(p.latency_ms AS REAL) AS rtt
    FROM pings p
    WHERE p.ts >= datetime('now', '-7 days')
),
weekly_basic AS (
    SELECT MIN(rtt) AS min_rtt,
        MAX(rtt) AS max_rtt,
        AVG(rtt) AS avg_rtt
    FROM weekly_samples
),
weekly_ordered AS (
    SELECT rtt,
        ROW_NUMBER() OVER (
            ORDER BY rtt
        ) AS rn,
        COUNT(*) OVER () AS n
    FROM weekly_samples
),
weekly_percentiles AS (
    SELECT MAX(
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
    FROM weekly_ordered
),
weekly_diffs AS (
    SELECT ts,
        tsec,
        ABS(
            rtt - LAG(rtt) OVER (
                ORDER BY ts
            )
        ) AS diff,
        (
            tsec - LAG(tsec) OVER (
                ORDER BY ts
            )
        ) AS gap
    FROM weekly_samples
),
weekly_jitter AS (
    SELECT AVG(diff) AS jitter_ms
    FROM weekly_diffs
    WHERE gap IS NOT NULL
        AND gap <= 2
),
weekly_loss_events AS (
    SELECT SUM(
            CASE
                WHEN gap > 2 THEN 1
                ELSE 0
            END
        ) AS loss_events
    FROM weekly_diffs
    WHERE gap IS NOT NULL
),
weekly_observed AS (
    SELECT COUNT(*) AS observed_samples
    FROM weekly_samples
),
weekly_loss_percent AS (
    -- Event-based percent to match daily table: events / (observed + events)
    SELECT CASE
            WHEN (
                SELECT observed_samples
                FROM weekly_observed
            ) + COALESCE(
                (
                    SELECT loss_events
                    FROM weekly_loss_events
                ),
                0
            ) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(
                (
                    SELECT loss_events
                    FROM weekly_loss_events
                ),
                0
            ) / (
                (
                    SELECT observed_samples
                    FROM weekly_observed
                ) + COALESCE(
                    (
                        SELECT loss_events
                        FROM weekly_loss_events
                    ),
                    0
                )
            )
        END AS loss_percent
),
weekly_outages AS (
    SELECT ts,
        gap,
        (tsec - gap) AS start_sec,
        tsec AS end_sec,
        (gap - 1) AS lost_sec
    FROM weekly_diffs
    WHERE gap IS NOT NULL
        AND gap > 2
),
weekly_clusters AS (
    SELECT *,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    ORDER BY start_sec
                )
            ) + 5 THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM weekly_outages
),
weekly_clustered AS (
    SELECT *,
        SUM(new_cluster_flag) OVER (
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM weekly_clusters
),
weekly_agg AS (
    SELECT MIN(start_sec) AS cluster_start,
        MAX(end_sec) AS cluster_end,
        SUM(lost_sec) AS cluster_lost_sec,
        (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
    FROM weekly_clustered
    GROUP BY cluster_id
),
weekly_kv AS (
    SELECT 'Minimum (ms)' AS metric,
        8 AS idx,
        (
            SELECT min_rtt
            FROM weekly_basic
        ) AS val
    UNION ALL
    SELECT 'Maximum (ms)',
        8,
        (
            SELECT max_rtt
            FROM weekly_basic
        )
    UNION ALL
    SELECT 'Average (ms)',
        8,
        (
            SELECT avg_rtt
            FROM weekly_basic
        )
    UNION ALL
    SELECT 'Median (ms)',
        8,
        (
            SELECT p50
            FROM weekly_percentiles
        )
    UNION ALL
    SELECT '1st percentile (ms)',
        8,
        (
            SELECT p01
            FROM weekly_percentiles
        )
    UNION ALL
    SELECT '99th percentile (ms)',
        8,
        (
            SELECT p99
            FROM weekly_percentiles
        )
    UNION ALL
    SELECT 'Jitter (ms)',
        8,
        (
            SELECT jitter_ms
            FROM weekly_jitter
        )
    UNION ALL
    SELECT 'Loss events',
        8,
        (
            SELECT loss_events
            FROM weekly_loss_events
        )
    UNION ALL
    SELECT 'Observed samples',
        8,
        (
            SELECT observed_samples
            FROM weekly_observed
        )
    UNION ALL
    SELECT 'Loss percent (%)',
        8,
        (
            SELECT loss_percent
            FROM weekly_loss_percent
        )
    UNION ALL
    SELECT 'Loss event clusters (heal=5s)',
        8,
        (
            SELECT COUNT(*)
            FROM weekly_agg
        )
    UNION ALL
    SELECT 'Median cluster lost seconds',
        8,
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_lost_sec AS v
                    FROM weekly_agg
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
    UNION ALL
    SELECT 'Median cluster span seconds',
        8,
        COALESCE(
            (
                WITH s AS (
                    SELECT cluster_span_sec AS v
                    FROM weekly_agg
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
),
-- Assemble per-day key/value rows and append weekly (idx=8) for pivot
kv AS (
    SELECT 'Minimum (ms)' AS metric,
        idx,
        min_rtt AS val
    FROM day_basic
    UNION ALL
    SELECT 'Maximum (ms)',
        idx,
        max_rtt
    FROM day_basic
    UNION ALL
    SELECT 'Average (ms)',
        idx,
        avg_rtt
    FROM day_basic
    UNION ALL
    SELECT 'Median (ms)',
        idx,
        p50
    FROM day_percentiles
    UNION ALL
    SELECT '1st percentile (ms)',
        idx,
        p01
    FROM day_percentiles
    UNION ALL
    SELECT '99th percentile (ms)',
        idx,
        p99
    FROM day_percentiles
    UNION ALL
    SELECT 'Jitter (ms)',
        idx,
        jitter_ms
    FROM day_jitter
    UNION ALL
    SELECT 'Loss events',
        idx,
        loss_events
    FROM day_loss_events
    UNION ALL
    SELECT 'Observed samples',
        idx,
        observed_samples
    FROM day_observed
    UNION ALL
    SELECT 'Loss percent (%)',
        idx,
        loss_percent
    FROM day_loss_percent
    UNION ALL
    SELECT 'Loss event clusters (heal=5s)',
        idx,
        cluster_events
    FROM day_cluster_counts
    UNION ALL
    SELECT 'Median cluster lost seconds',
        idx,
        med_cluster_lost_sec
    FROM day_cluster_medians
    UNION ALL
    SELECT 'Median cluster span seconds',
        idx,
        med_cluster_span_sec
    FROM day_cluster_medians
    UNION ALL
    SELECT metric,
        idx,
        val
    FROM weekly_kv
)
SELECT metric,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 1 THEN val
            END
        )
    ) AS D1,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 2 THEN val
            END
        )
    ) AS D2,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 3 THEN val
            END
        )
    ) AS D3,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 4 THEN val
            END
        )
    ) AS D4,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 5 THEN val
            END
        )
    ) AS D5,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 6 THEN val
            END
        )
    ) AS D6,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 7 THEN val
            END
        )
    ) AS D7,
    printf(
        '%.3f',
        MAX(
            CASE
                WHEN idx = 8 THEN val
            END
        )
    ) AS W7
FROM kv
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
        WHEN 'Loss event clusters (heal=5s)' THEN 11
        WHEN 'Median cluster lost seconds' THEN 12
        WHEN 'Median cluster span seconds' THEN 13
        ELSE 99
    END;
