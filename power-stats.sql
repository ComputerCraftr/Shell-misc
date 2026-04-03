.mode column --
-- power-stats.sql
-- Usage:
--   sqlite3 /var/db/power-logger/power-logger.db < power-stats.sql
--
-- Notes:
--   * Samples are stored in UTC by the power-logger service.
--   * D1..D7 / W1..W4 / M1 are aligned to the current system local timezone's
--     calendar-day boundaries.
--   * Assumes table "watts" with columns:
--       ts (datetime/timestamp), power_w (real/numeric).
--   * Profiling:
--       sqlite3 -cmd "PRAGMA temp_store=MEMORY;" \
--               -cmd "PRAGMA cache_size=-131072;" \
--               -cmd ".timer on" -cmd ".stats on" \
--               /var/db/power-logger/power-logger.db < power-stats.sql
--   * Planner inspection:
--       sqlite3 -cmd ".eqp full" /var/db/power-logger/power-logger.db < power-stats.sql
DROP TABLE IF EXISTS temp.report_power_periods;
DROP TABLE IF EXISTS temp.report_power_params;
DROP TABLE IF EXISTS temp.report_power_stage;
DROP TABLE IF EXISTS temp.report_power_intervals;
DROP TABLE IF EXISTS temp.report_power_energy_stats;
DROP TABLE IF EXISTS temp.report_power_basic;
DROP TABLE IF EXISTS temp.report_power_counts;
DROP TABLE IF EXISTS temp.report_power_ordered;
DROP TABLE IF EXISTS temp.report_power_percentiles;
DROP TABLE IF EXISTS temp.report_power_mode_calc;
DROP TABLE IF EXISTS temp.report_power_mode;
DROP TABLE IF EXISTS temp.report_power_value_counts;
CREATE TEMP TABLE report_power_params AS
SELECT 600 AS off_gap_s;
CREATE TEMP TABLE report_power_periods AS WITH RECURSIVE days AS (
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
CREATE TEMP TABLE report_power_stage (
    idx INTEGER NOT NULL,
    ts TEXT NOT NULL,
    tsec INTEGER NOT NULL,
    watts REAL NOT NULL,
    watts_whole INTEGER NOT NULL
);
INSERT INTO report_power_stage(idx, ts, tsec, watts, watts_whole)
SELECT p.idx,
    s.ts,
    unixepoch(s.ts) AS tsec,
    CAST(s.power_w AS REAL) AS watts,
    CAST(ROUND(s.power_w) AS INTEGER) AS watts_whole
FROM watts s
    JOIN report_power_periods p ON s.ts >= p.start_ts
    AND s.ts < p.end_ts
WHERE s.ts >= (
        SELECT MIN(start_ts)
        FROM report_power_periods
    )
    AND s.ts < (
        SELECT MAX(end_ts)
        FROM report_power_periods
    )
ORDER BY p.idx,
    s.ts;
CREATE INDEX report_power_stage_idx_ts ON report_power_stage(idx, ts);
CREATE TEMP TABLE report_power_intervals AS WITH interval_inputs AS (
    SELECT idx,
        watts,
        tsec,
        LEAD(tsec) OVER (
            PARTITION BY idx
            ORDER BY tsec
        ) AS next_tsec
    FROM report_power_stage
)
SELECT idx,
    watts,
    tsec,
    next_tsec,
    (next_tsec - tsec) AS gap_s
FROM interval_inputs;
CREATE INDEX report_power_intervals_idx ON report_power_intervals(idx, tsec);
CREATE TEMP TABLE report_power_energy_stats AS
SELECT idx,
    SUM(
        CASE
            WHEN gap_s IS NOT NULL
            AND gap_s <= (
                SELECT off_gap_s
                FROM report_power_params
            ) THEN watts * gap_s
            ELSE 0
        END
    ) AS watt_seconds,
    SUM(
        CASE
            WHEN gap_s IS NOT NULL
            AND gap_s <= (
                SELECT off_gap_s
                FROM report_power_params
            ) THEN gap_s
            ELSE 0
        END
    ) AS total_seconds,
    CASE
        WHEN SUM(
            CASE
                WHEN gap_s IS NOT NULL
                AND gap_s <= (
                    SELECT off_gap_s
                    FROM report_power_params
                ) THEN gap_s
                ELSE 0
            END
        ) > 0 THEN SUM(
            CASE
                WHEN gap_s IS NOT NULL
                AND gap_s <= (
                    SELECT off_gap_s
                    FROM report_power_params
                ) THEN watts * gap_s
                ELSE 0
            END
        ) / SUM(
            CASE
                WHEN gap_s IS NOT NULL
                AND gap_s <= (
                    SELECT off_gap_s
                    FROM report_power_params
                ) THEN gap_s
                ELSE 0
            END
        )
        ELSE 0.0
    END AS mean_watts
FROM report_power_intervals
GROUP BY idx;
CREATE INDEX report_power_stage_idx_watts ON report_power_stage(idx, watts, ts);
CREATE INDEX report_power_stage_idx_whole ON report_power_stage(idx, watts_whole);
CREATE TEMP TABLE report_power_basic AS
SELECT idx,
    MIN(watts) AS min_watts,
    MAX(watts) AS max_watts
FROM report_power_stage
GROUP BY idx;
CREATE TEMP TABLE report_power_counts AS
SELECT idx,
    COUNT(*) AS n
FROM report_power_stage
GROUP BY idx;
CREATE UNIQUE INDEX report_power_counts_idx ON report_power_counts(idx);
CREATE TEMP TABLE report_power_ordered AS
SELECT idx,
    ROW_NUMBER() OVER (
        PARTITION BY idx
        ORDER BY watts
    ) AS rn,
    watts
FROM report_power_stage;
CREATE INDEX report_power_ordered_idx ON report_power_ordered(idx, rn);
CREATE TEMP TABLE report_power_percentiles AS
SELECT c.idx,
    o50.watts AS p50,
    o01.watts AS p01,
    o99.watts AS p99
FROM report_power_counts c
    LEFT JOIN report_power_ordered o50 ON o50.idx = c.idx
    AND o50.rn = ((c.n + 1) / 2)
    LEFT JOIN report_power_ordered o01 ON o01.idx = c.idx
    AND o01.rn = (CAST((c.n - 1) * 0.01 AS INTEGER) + 1)
    LEFT JOIN report_power_ordered o99 ON o99.idx = c.idx
    AND o99.rn = (CAST((c.n - 1) * 0.99 AS INTEGER) + 1);
CREATE TEMP TABLE report_power_mode_calc AS WITH grouped AS (
    SELECT idx,
        watts_whole,
        COUNT(*) AS cnt
    FROM report_power_stage
    GROUP BY idx,
        watts_whole
)
SELECT idx,
    watts_whole,
    cnt,
    ROW_NUMBER() OVER (
        PARTITION BY idx
        ORDER BY cnt DESC,
            watts_whole DESC
    ) AS rn
FROM grouped;
CREATE INDEX report_power_mode_calc_idx ON report_power_mode_calc(idx, rn);
CREATE TEMP TABLE report_power_mode AS
SELECT idx,
    watts_whole AS mode_watts,
    cnt AS mode_count
FROM report_power_mode_calc
WHERE rn = 1;
CREATE TEMP TABLE report_power_value_counts AS
SELECT e.idx,
    (
        SELECT COUNT(*)
        FROM report_power_stage s
        WHERE s.idx = e.idx
            AND s.watts_whole = CAST(ROUND(e.mean_watts) AS INTEGER)
    ) AS mean_count,
    CASE
        WHEN p.p50 IS NULL THEN 0
        ELSE (
            SELECT COUNT(*)
            FROM report_power_stage s
            WHERE s.idx = e.idx
                AND s.watts_whole = CAST(ROUND(p.p50) AS INTEGER)
        )
    END AS median_count,
    COALESCE(m.mode_count, 0) AS mode_count
FROM report_power_energy_stats e
    LEFT JOIN report_power_percentiles p USING (idx)
    LEFT JOIN report_power_mode m USING (idx);
WITH observed AS (
    SELECT idx,
        COUNT(*) AS sample_count
    FROM report_power_stage
    GROUP BY idx
),
kv AS (
    SELECT 'Minimum (W)' AS metric,
        idx,
        min_watts AS val
    FROM report_power_basic
    UNION ALL
    SELECT 'Maximum (W)',
        idx,
        max_watts
    FROM report_power_basic
    UNION ALL
    SELECT 'Mean (W)',
        idx,
        mean_watts
    FROM report_power_energy_stats
    UNION ALL
    SELECT 'Median (W)',
        idx,
        p50
    FROM report_power_percentiles
    UNION ALL
    SELECT 'Mode (W)',
        idx,
        mode_watts
    FROM report_power_mode
    UNION ALL
    SELECT '1st percentile (W)',
        idx,
        p01
    FROM report_power_percentiles
    UNION ALL
    SELECT '99th percentile (W)',
        idx,
        p99
    FROM report_power_percentiles
    UNION ALL
    SELECT 'Total energy (kWh)',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE watt_seconds / 3600000.0
        END
    FROM report_power_energy_stats
    UNION ALL
    SELECT 'Cost @ $0.10/kWh',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE (watt_seconds / 3600000.0) * 0.10
        END
    FROM report_power_energy_stats
    UNION ALL
    SELECT 'Cost @ $0.15/kWh',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE (watt_seconds / 3600000.0) * 0.15
        END
    FROM report_power_energy_stats
    UNION ALL
    SELECT 'Mean count',
        idx,
        mean_count
    FROM report_power_value_counts
    UNION ALL
    SELECT 'Median count',
        idx,
        median_count
    FROM report_power_value_counts
    UNION ALL
    SELECT 'Mode count',
        idx,
        mode_count
    FROM report_power_value_counts
    UNION ALL
    SELECT 'Sample count',
        idx,
        sample_count
    FROM observed
)
SELECT metric,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
            'Sample count'
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
        WHEN 'Minimum (W)' THEN 1
        WHEN 'Maximum (W)' THEN 2
        WHEN 'Mean (W)' THEN 3
        WHEN 'Median (W)' THEN 4
        WHEN 'Mode (W)' THEN 5
        WHEN '1st percentile (W)' THEN 6
        WHEN '99th percentile (W)' THEN 7
        WHEN 'Total energy (kWh)' THEN 8
        WHEN 'Cost @ $0.10/kWh' THEN 9
        WHEN 'Cost @ $0.15/kWh' THEN 10
        WHEN 'Mean count' THEN 11
        WHEN 'Median count' THEN 12
        WHEN 'Mode count' THEN 13
        WHEN 'Sample count' THEN 14
        ELSE 999
    END;