-- pinger latency summary (PostgreSQL)
--
-- Usage (with psql):
--   psql -d pinger_db -v ON_ERROR_STOP=1 -X \
--        --pset=border=2 --pset=null='—' \
--        -f pg-pinger-stats.sql
--
-- Notes:
--   * Assumes database "pinger_db", schema "pinger", table "pings" with columns:
--       ts (timestamp[tz]) and latency_ms (real/double precision/numeric).
--   * This script sets search_path to the "pinger" schema; adjust if needed.
--   * Mirrors the SQLite report: D1..D7 are calendar days (today=1),
--     W1..W4 are rolling weeks, M1 is last 30 days.
SET search_path TO pinger;
WITH RECURSIVE params AS (
    -- consider a gap > 2s as a loss
    SELECT 2::bigint AS loss_gap_s,
        600::bigint AS heal_s -- cluster healing interval seconds
),
label AS (
    SELECT 'Event clusters (' || heal_s || 's)' AS clusters_label
    FROM params
),
-- ----------------------------
-- Periods (idx = 1..7 per-day, idx = 8..11 weekly, idx = 12 monthly)
-- ----------------------------
days AS (
    SELECT 0 AS d
    UNION ALL
    SELECT d + 1
    FROM days
    WHERE d < 6
),
weeks AS (
    SELECT 0 AS w
    UNION ALL
    SELECT w + 1
    FROM weeks
    WHERE w < 3
),
periods AS (
    -- Per-day windows: idx = 1..7 (today=1, yesterday=2, ...)
    SELECT (d + 1) AS idx,
        date_trunc('day', now()) - (d || ' days')::interval AS start_ts,
        date_trunc('day', now()) - (d || ' days')::interval + interval '1 day' AS end_ts
    FROM days
    UNION ALL
    -- Weekly windows: idx = 8..11 (W1..W4, midnight-aligned)
    SELECT (w + 8) AS idx,
        date_trunc('day', now()) - ((w * 7 + 6) * interval '1 day') AS start_ts,
        date_trunc('day', now()) + ((1 - w * 7) * interval '1 day') AS end_ts
    FROM weeks
    UNION ALL
    -- Monthly window: idx = 12 (last 30 days, midnight-aligned)
    SELECT 12 AS idx,
        date_trunc('day', now()) - interval '29 days' AS start_ts,
        date_trunc('day', now()) + interval '1 day' AS end_ts
),
-- ----------------------------
-- Raw samples per period
-- ----------------------------
samples AS (
    SELECT p.idx,
        s.ts,
        extract(
            epoch
            FROM s.ts
        )::bigint AS tsec,
        s.latency_ms::double precision AS rtt
    FROM periods p
        JOIN pings s ON s.ts >= p.start_ts
        AND s.ts < p.end_ts
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
                WHEN rn = ((n - 1) * 0.01)::bigint + 1 THEN rtt
            END
        ) AS p01,
        MAX(
            CASE
                WHEN rn = ((n - 1) * 0.99)::bigint + 1 THEN rtt
            END
        ) AS p99
    FROM ordered o
    GROUP BY o.idx
),
rounded AS (
    SELECT idx,
        rtt,
        round(rtt)::integer AS rtt_ms
    FROM samples
),
mode_calc AS (
    SELECT idx,
        rtt_ms,
        COUNT(*) AS cnt,
        ROW_NUMBER() OVER (
            PARTITION BY idx
            ORDER BY COUNT(*) DESC,
                rtt_ms DESC
        ) AS rn
    FROM rounded
    GROUP BY idx,
        rtt_ms
),
mode AS (
    SELECT idx,
        rtt_ms AS mode_ms,
        cnt AS mode_count
    FROM mode_calc
    WHERE rn = 1
),
value_counts AS (
    SELECT r.idx,
        SUM(
            CASE
                WHEN r.rtt_ms = round(b.avg_rtt)::integer THEN 1
                ELSE 0
            END
        ) AS mean_count,
        SUM(
            CASE
                WHEN r.rtt_ms = round(p.p50)::integer THEN 1
                ELSE 0
            END
        ) AS median_count,
        MAX(m.mode_count) AS mode_count
    FROM rounded r
        JOIN basic b USING (idx)
        JOIN percentiles p USING (idx)
        LEFT JOIN mode m USING (idx)
    GROUP BY r.idx
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
        COUNT(*) AS sample_count
    FROM samples
    GROUP BY idx
),
loss_percent AS (
    -- Event-based percent: events / (observed + events)
    SELECT o.idx,
        CASE
            WHEN (o.sample_count + COALESCE(e.loss_events, 0)) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(e.loss_events, 0) / (o.sample_count + COALESCE(e.loss_events, 0))
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
    SELECT 'Mean (ms)',
        idx,
        avg_rtt
    FROM basic
    UNION ALL
    SELECT 'Median (ms)',
        idx,
        p50
    FROM percentiles
    UNION ALL
    SELECT 'Mode (ms)',
        idx,
        mode_ms
    FROM mode
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
    SELECT 'Mean count',
        idx,
        mean_count
    FROM value_counts
    UNION ALL
    SELECT 'Median count',
        idx,
        median_count
    FROM value_counts
    UNION ALL
    SELECT 'Mode count',
        idx,
        mode_count
    FROM value_counts
    UNION ALL
    SELECT 'Sample count',
        idx,
        sample_count
    FROM observed
    UNION ALL
    SELECT 'Loss events',
        idx,
        loss_events
    FROM loss_events
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
-- Final pivot: D1..D7 (days), W1..W4 (weeks), M1 (month)
-- Integers rendered without decimals; others with 3 decimals
-- ----------------------------
SELECT metric,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 1 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 1 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 2 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 2 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 3 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 3 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 4 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 4 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 5 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 5 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D5,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 6 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 6 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D6,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 7 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 7 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS D7,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 8 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 8 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS W1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 9 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 9 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS W2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 10 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 10 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS W3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 11 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 11 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS W4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            clusters_label,
            'Median cluster loss (s)',
            'Median cluster span (s)'
        ) THEN CAST(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 12 THEN val
                    END
                ),
                0
            ) AS INTEGER
        )
        ELSE to_char(
            MAX(
                CASE
                    WHEN idx = 12 THEN val
                END
            )::numeric,
            'FM999999990.000'
        )
    END AS M1
FROM kv,
    label
GROUP BY metric
ORDER BY CASE
        metric
        WHEN 'Minimum (ms)' THEN 1
        WHEN 'Maximum (ms)' THEN 2
        WHEN 'Mean (ms)' THEN 3
        WHEN 'Median (ms)' THEN 4
        WHEN 'Mode (ms)' THEN 5
        WHEN '1st percentile (ms)' THEN 6
        WHEN '99th percentile (ms)' THEN 7
        WHEN 'Jitter (ms)' THEN 8
        WHEN 'Mean count' THEN 9
        WHEN 'Median count' THEN 10
        WHEN 'Mode count' THEN 11
        WHEN 'Sample count' THEN 12
        WHEN 'Loss events' THEN 13
        WHEN 'Loss percent (%)' THEN 14
        WHEN clusters_label THEN 15
        WHEN 'Median cluster loss (s)' THEN 16
        WHEN 'Median cluster span (s)' THEN 17
        ELSE 99
    END;