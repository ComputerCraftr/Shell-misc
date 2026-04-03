.mode column --
-- pinger-stats.sql
-- Usage:
--   sqlite3 /var/db/pinger/pings.db < pinger-stats.sql
--
-- Notes:
--   * Samples are stored in UTC by the pinger service.
--   * D1..D7 / W1..W4 / M1 are aligned to the current system local timezone's
--     calendar-day boundaries.
--   * Profiling:
--       sqlite3 -cmd "PRAGMA temp_store=MEMORY;" \
--               -cmd "PRAGMA cache_size=-131072;" \
--               -cmd ".timer on" -cmd ".stats on" \
--               /var/db/pinger/pings.db < pinger-stats.sql
--   * Planner inspection:
--       sqlite3 -cmd ".eqp full" /var/db/pinger/pings.db < pinger-stats.sql
--
-- This script uses one staged temp table for the last-30-day bounded sample set
-- expanded into D1..D7 / W1..W4 / M1 buckets. The temporal and value pipelines
-- then build only the indexes they need.
DROP TABLE IF EXISTS temp.report_pinger_periods;
DROP TABLE IF EXISTS temp.report_pinger_params;
DROP TABLE IF EXISTS temp.report_pinger_stage;
DROP TABLE IF EXISTS temp.report_pinger_diffs;
DROP TABLE IF EXISTS temp.report_pinger_outages;
DROP TABLE IF EXISTS temp.report_pinger_agg;
DROP TABLE IF EXISTS temp.report_pinger_cluster_lost_ranked;
DROP TABLE IF EXISTS temp.report_pinger_cluster_span_ranked;
DROP TABLE IF EXISTS temp.report_pinger_basic;
DROP TABLE IF EXISTS temp.report_pinger_counts;
DROP TABLE IF EXISTS temp.report_pinger_ordered;
DROP TABLE IF EXISTS temp.report_pinger_percentiles;
DROP TABLE IF EXISTS temp.report_pinger_mode_calc;
DROP TABLE IF EXISTS temp.report_pinger_mode;
DROP TABLE IF EXISTS temp.report_pinger_value_counts;
CREATE TEMP TABLE report_pinger_params AS
SELECT 2 AS loss_gap_s,
    600 AS heal_s,
    'Event clusters (600s)' AS clusters_label;
CREATE TEMP TABLE report_pinger_periods AS WITH RECURSIVE days AS (
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
)
SELECT (d + 1) AS idx,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        printf('-%d days', d),
        'utc'
    ) AS start_ts,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        printf('-%d days', d),
        '+1 day',
        'utc'
    ) AS end_ts
FROM days
UNION ALL
SELECT (w + 8) AS idx,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        printf('-%d days', w * 7 + 6),
        'utc'
    ) AS start_ts,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        printf('%+d days', 1 - w * 7),
        'utc'
    ) AS end_ts
FROM weeks
UNION ALL
SELECT 12 AS idx,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        '-29 days',
        'utc'
    ) AS start_ts,
    strftime(
        '%Y-%m-%d %H:%M:%S+00:00',
        'now',
        'localtime',
        'start of day',
        '+1 day',
        'utc'
    ) AS end_ts;
CREATE TEMP TABLE report_pinger_stage (
    idx INTEGER NOT NULL,
    ts TEXT NOT NULL,
    tsec INTEGER NOT NULL,
    rtt REAL NOT NULL,
    rtt_ms INTEGER NOT NULL
);
INSERT INTO report_pinger_stage(idx, ts, tsec, rtt, rtt_ms)
SELECT p.idx,
    s.ts,
    unixepoch(s.ts) AS tsec,
    CAST(s.latency_ms AS REAL) AS rtt,
    CAST(ROUND(s.latency_ms) AS INTEGER) AS rtt_ms
FROM pings s
    JOIN report_pinger_periods p ON s.ts >= p.start_ts
    AND s.ts < p.end_ts
WHERE s.ts >= (
        SELECT MIN(start_ts)
        FROM report_pinger_periods
    )
    AND s.ts < (
        SELECT MAX(end_ts)
        FROM report_pinger_periods
    )
ORDER BY p.idx,
    s.ts;
CREATE INDEX report_pinger_stage_idx_ts ON report_pinger_stage(idx, ts);
CREATE TEMP TABLE report_pinger_diffs AS WITH diff_inputs AS (
    SELECT idx,
        ts,
        tsec,
        rtt,
        LAG(rtt) OVER (
            PARTITION BY idx
            ORDER BY ts
        ) AS prev_rtt,
        LAG(tsec) OVER (
            PARTITION BY idx
            ORDER BY ts
        ) AS prev_tsec
    FROM report_pinger_stage
)
SELECT idx,
    ts,
    tsec,
    ABS(rtt - prev_rtt) AS diff,
    (tsec - prev_tsec) AS gap
FROM diff_inputs;
CREATE INDEX report_pinger_diffs_idx ON report_pinger_diffs(idx, ts);
CREATE TEMP TABLE report_pinger_outages AS
SELECT idx,
    ts,
    gap,
    (tsec - gap) AS start_sec,
    tsec AS end_sec,
    (gap - 1) AS lost_sec
FROM report_pinger_diffs
WHERE gap IS NOT NULL
    AND gap > (
        SELECT loss_gap_s
        FROM report_pinger_params
    );
CREATE INDEX report_pinger_outages_idx ON report_pinger_outages(idx, start_sec);
CREATE TEMP TABLE report_pinger_agg AS WITH clusters AS (
    SELECT idx,
        start_sec,
        end_sec,
        lost_sec,
        CASE
            WHEN start_sec > (
                LAG(end_sec) OVER (
                    PARTITION BY idx
                    ORDER BY start_sec
                )
            ) + (
                SELECT heal_s
                FROM report_pinger_params
            ) THEN 1
            ELSE 0
        END AS new_cluster_flag
    FROM report_pinger_outages
),
clustered AS (
    SELECT idx,
        start_sec,
        end_sec,
        lost_sec,
        SUM(new_cluster_flag) OVER (
            PARTITION BY idx
            ORDER BY start_sec ROWS UNBOUNDED PRECEDING
        ) AS cluster_id
    FROM clusters
)
SELECT idx,
    cluster_id,
    MIN(start_sec) AS cluster_start,
    MAX(end_sec) AS cluster_end,
    SUM(lost_sec) AS cluster_lost_sec,
    (MAX(end_sec) - MIN(start_sec)) AS cluster_span_sec
FROM clustered
GROUP BY idx,
    cluster_id;
CREATE INDEX report_pinger_agg_idx ON report_pinger_agg(idx, cluster_id);
CREATE TEMP TABLE report_pinger_cluster_lost_ranked AS WITH agg_counts AS (
    SELECT idx,
        COUNT(*) AS n
    FROM report_pinger_agg
    GROUP BY idx
)
SELECT a.idx,
    a.cluster_lost_sec,
    ROW_NUMBER() OVER (
        PARTITION BY a.idx
        ORDER BY a.cluster_lost_sec
    ) AS rn,
    c.n
FROM report_pinger_agg a
    JOIN agg_counts c USING (idx);
CREATE INDEX report_pinger_cluster_lost_ranked_idx ON report_pinger_cluster_lost_ranked(idx, rn);
CREATE TEMP TABLE report_pinger_cluster_span_ranked AS WITH agg_counts AS (
    SELECT idx,
        COUNT(*) AS n
    FROM report_pinger_agg
    GROUP BY idx
)
SELECT a.idx,
    a.cluster_span_sec,
    ROW_NUMBER() OVER (
        PARTITION BY a.idx
        ORDER BY a.cluster_span_sec
    ) AS rn,
    c.n
FROM report_pinger_agg a
    JOIN agg_counts c USING (idx);
CREATE INDEX report_pinger_cluster_span_ranked_idx ON report_pinger_cluster_span_ranked(idx, rn);
CREATE INDEX report_pinger_stage_idx_rtt ON report_pinger_stage(idx, rtt, ts);
CREATE INDEX report_pinger_stage_idx_rtt_ms ON report_pinger_stage(idx, rtt_ms);
CREATE TEMP TABLE report_pinger_basic AS
SELECT idx,
    MIN(rtt) AS min_rtt,
    MAX(rtt) AS max_rtt,
    AVG(rtt) AS avg_rtt
FROM report_pinger_stage
GROUP BY idx;
CREATE TEMP TABLE report_pinger_counts AS
SELECT idx,
    COUNT(*) AS n
FROM report_pinger_stage
GROUP BY idx;
CREATE UNIQUE INDEX report_pinger_counts_idx ON report_pinger_counts(idx);
CREATE TEMP TABLE report_pinger_ordered AS
SELECT idx,
    ROW_NUMBER() OVER (
        PARTITION BY idx
        ORDER BY rtt
    ) AS rn,
    rtt
FROM report_pinger_stage;
CREATE INDEX report_pinger_ordered_idx ON report_pinger_ordered(idx, rn);
CREATE TEMP TABLE report_pinger_percentiles AS
SELECT c.idx,
    o50.rtt AS p50,
    o01.rtt AS p01,
    o99.rtt AS p99
FROM report_pinger_counts c
    LEFT JOIN report_pinger_ordered o50 ON o50.idx = c.idx
    AND o50.rn = ((c.n + 1) / 2)
    LEFT JOIN report_pinger_ordered o01 ON o01.idx = c.idx
    AND o01.rn = (CAST((c.n - 1) * 0.01 AS INTEGER) + 1)
    LEFT JOIN report_pinger_ordered o99 ON o99.idx = c.idx
    AND o99.rn = (CAST((c.n - 1) * 0.99 AS INTEGER) + 1);
CREATE TEMP TABLE report_pinger_mode_calc AS WITH grouped AS (
    SELECT idx,
        rtt_ms,
        COUNT(*) AS cnt
    FROM report_pinger_stage
    GROUP BY idx,
        rtt_ms
)
SELECT idx,
    rtt_ms,
    cnt,
    ROW_NUMBER() OVER (
        PARTITION BY idx
        ORDER BY cnt DESC,
            rtt_ms DESC
    ) AS rn
FROM grouped;
CREATE INDEX report_pinger_mode_calc_idx ON report_pinger_mode_calc(idx, rn);
CREATE TEMP TABLE report_pinger_mode AS
SELECT idx,
    rtt_ms AS mode_ms,
    cnt AS mode_count
FROM report_pinger_mode_calc
WHERE rn = 1;
CREATE TEMP TABLE report_pinger_value_counts AS
SELECT b.idx,
    (
        SELECT COUNT(*)
        FROM report_pinger_stage s
        WHERE s.idx = b.idx
            AND s.rtt_ms = CAST(ROUND(b.avg_rtt) AS INTEGER)
    ) AS mean_count,
    CASE
        WHEN p.p50 IS NULL THEN 0
        ELSE (
            SELECT COUNT(*)
            FROM report_pinger_stage s
            WHERE s.idx = b.idx
                AND s.rtt_ms = CAST(ROUND(p.p50) AS INTEGER)
        )
    END AS median_count,
    COALESCE(m.mode_count, 0) AS mode_count
FROM report_pinger_basic b
    LEFT JOIN report_pinger_percentiles p USING (idx)
    LEFT JOIN report_pinger_mode m USING (idx);
WITH observed AS (
    SELECT idx,
        COUNT(*) AS sample_count
    FROM report_pinger_stage
    GROUP BY idx
),
jitter AS (
    SELECT idx,
        AVG(diff) AS jitter_ms
    FROM report_pinger_diffs
    WHERE gap IS NOT NULL
        AND gap <= (
            SELECT loss_gap_s
            FROM report_pinger_params
        )
    GROUP BY idx
),
loss_events AS (
    SELECT idx,
        SUM(
            CASE
                WHEN gap > (
                    SELECT loss_gap_s
                    FROM report_pinger_params
                ) THEN 1
                ELSE 0
            END
        ) AS loss_events
    FROM report_pinger_diffs
    WHERE gap IS NOT NULL
    GROUP BY idx
),
loss_percent AS (
    SELECT o.idx,
        CASE
            WHEN (o.sample_count + COALESCE(e.loss_events, 0)) = 0 THEN 0.0
            ELSE 100.0 * COALESCE(e.loss_events, 0) / (o.sample_count + COALESCE(e.loss_events, 0))
        END AS loss_percent
    FROM observed o
        LEFT JOIN loss_events e USING (idx)
),
cluster_events AS (
    SELECT idx,
        COUNT(*) AS cluster_events
    FROM report_pinger_agg
    GROUP BY idx
),
cluster_lost_medians AS (
    SELECT idx,
        MAX(cluster_lost_sec) AS med_cluster_lost_sec
    FROM report_pinger_cluster_lost_ranked
    WHERE rn = ((n + 1) / 2)
    GROUP BY idx
),
cluster_span_medians AS (
    SELECT idx,
        MAX(cluster_span_sec) AS med_cluster_span_sec
    FROM report_pinger_cluster_span_ranked
    WHERE rn = ((n + 1) / 2)
    GROUP BY idx
),
cluster_medians AS (
    SELECT i.idx,
        l.med_cluster_lost_sec,
        s.med_cluster_span_sec
    FROM (
            SELECT DISTINCT idx
            FROM report_pinger_agg
        ) i
        LEFT JOIN cluster_lost_medians l USING (idx)
        LEFT JOIN cluster_span_medians s USING (idx)
),
kv AS (
    SELECT 'Minimum (ms)' AS metric,
        idx,
        min_rtt AS val
    FROM report_pinger_basic
    UNION ALL
    SELECT 'Maximum (ms)',
        idx,
        max_rtt
    FROM report_pinger_basic
    UNION ALL
    SELECT 'Mean (ms)',
        idx,
        avg_rtt
    FROM report_pinger_basic
    UNION ALL
    SELECT 'Median (ms)',
        idx,
        p50
    FROM report_pinger_percentiles
    UNION ALL
    SELECT 'Mode (ms)',
        idx,
        mode_ms
    FROM report_pinger_mode
    UNION ALL
    SELECT '1st percentile (ms)',
        idx,
        p01
    FROM report_pinger_percentiles
    UNION ALL
    SELECT '99th percentile (ms)',
        idx,
        p99
    FROM report_pinger_percentiles
    UNION ALL
    SELECT 'Jitter (ms)',
        idx,
        jitter_ms
    FROM jitter
    UNION ALL
    SELECT 'Mean count',
        idx,
        mean_count
    FROM report_pinger_value_counts
    UNION ALL
    SELECT 'Median count',
        idx,
        median_count
    FROM report_pinger_value_counts
    UNION ALL
    SELECT 'Mode count',
        idx,
        mode_count
    FROM report_pinger_value_counts
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
    SELECT (
            SELECT clusters_label
            FROM report_pinger_params
        ),
        idx,
        cluster_events
    FROM cluster_events
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
)
SELECT metric,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 1 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 2 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 3 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 4 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 5 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D5,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 6 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D6,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 7 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS D7,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 8 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS W1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 9 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS W2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 10 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS W3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 11 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS W4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count',
            'Loss events',
            (
                SELECT clusters_label
                FROM report_pinger_params
            ),
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
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 12 THEN val
                    END
                ),
                0
            ),
            3
        )
    END AS M1
FROM kv
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
        WHEN (
            SELECT clusters_label
            FROM report_pinger_params
        ) THEN 15
        WHEN 'Median cluster loss (s)' THEN 16
        WHEN 'Median cluster span (s)' THEN 17
        ELSE 999
    END;