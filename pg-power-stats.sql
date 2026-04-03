-- power summary (PostgreSQL)
--
-- Usage (with psql):
--   psql -d power_logger_db -v ON_ERROR_STOP=1 -X \
--        --pset=border=2 --pset=null='—' \
--        -f pg-power-stats.sql
--
-- Notes:
--   * Assumes database "power_logger_db", schema "power_logger", table "watts"
--     with columns: ts (timestamp[tz]), power_w (real/double precision/numeric).
--   * This script sets search_path to the "power_logger" schema; adjust if needed.
--   * Samples are stored in UTC by the power-logger service.
--   * D1..D7 / W1..W4 / M1 are aligned to the current PostgreSQL session
--     timezone's calendar-day boundaries.
--   * Mirrors the SQLite report: D1..D7 are calendar days (today=1),
--     W1..W4 are rolling weeks, M1 is last 30 days.
SET search_path TO power_logger;
WITH RECURSIVE params AS (
    SELECT 600::bigint AS off_gap_s
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
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) - (d || ' days')::interval
        ) AT TIME ZONE current_setting('TIMEZONE') AS start_ts,
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) - (d || ' days')::interval + interval '1 day'
        ) AT TIME ZONE current_setting('TIMEZONE') AS end_ts
    FROM days
    UNION ALL
    -- Weekly windows: idx = 8..11 (W1..W4, midnight-aligned)
    SELECT (w + 8) AS idx,
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) - ((w * 7 + 6) * interval '1 day')
        ) AT TIME ZONE current_setting('TIMEZONE') AS start_ts,
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) + ((1 - w * 7) * interval '1 day')
        ) AT TIME ZONE current_setting('TIMEZONE') AS end_ts
    FROM weeks
    UNION ALL
    -- Monthly window: idx = 12 (last 30 days, midnight-aligned)
    SELECT 12 AS idx,
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) - interval '29 days'
        ) AT TIME ZONE current_setting('TIMEZONE') AS start_ts,
        (
            date_trunc(
                'day',
                now() AT TIME ZONE current_setting('TIMEZONE')
            ) + interval '1 day'
        ) AT TIME ZONE current_setting('TIMEZONE') AS end_ts
),
global_bounds AS (
    SELECT MIN(start_ts) AS min_start_ts,
        MAX(end_ts) AS max_end_ts
    FROM periods
),
-- ----------------------------
-- Raw samples per period
-- ----------------------------
base_samples AS MATERIALIZED (
    SELECT s.ts,
        extract(
            epoch
            FROM s.ts
        )::bigint AS tsec,
        s.power_w::double precision AS watts
    FROM power_logger.watts s
        CROSS JOIN global_bounds g
    WHERE s.ts >= g.min_start_ts
        AND s.ts < g.max_end_ts
),
samples AS MATERIALIZED (
    SELECT p.idx,
        s.ts,
        s.tsec,
        s.watts
    FROM periods p
        JOIN base_samples s ON s.ts >= p.start_ts
        AND s.ts < p.end_ts
),
interval_inputs AS MATERIALIZED (
    SELECT idx,
        watts,
        tsec,
        LEAD(tsec) OVER (
            PARTITION BY idx
            ORDER BY tsec
        ) AS next_tsec
    FROM samples
),
intervals AS MATERIALIZED (
    SELECT idx,
        watts,
        tsec,
        next_tsec,
        (next_tsec - tsec) AS gap_s
    FROM interval_inputs
),
energy_stats AS (
    SELECT i.idx,
        SUM(
            CASE
                WHEN i.gap_s IS NOT NULL
                AND i.gap_s <= p.off_gap_s THEN i.watts * i.gap_s
                ELSE 0
            END
        ) AS watt_seconds,
        SUM(
            CASE
                WHEN i.gap_s IS NOT NULL
                AND i.gap_s <= p.off_gap_s THEN i.gap_s
                ELSE 0
            END
        ) AS total_seconds,
        CASE
            WHEN SUM(
                CASE
                    WHEN i.gap_s IS NOT NULL
                    AND i.gap_s <= p.off_gap_s THEN i.gap_s
                    ELSE 0
                END
            ) > 0 THEN SUM(
                CASE
                    WHEN i.gap_s IS NOT NULL
                    AND i.gap_s <= p.off_gap_s THEN i.watts * i.gap_s
                    ELSE 0
                END
            ) / SUM(
                CASE
                    WHEN i.gap_s IS NOT NULL
                    AND i.gap_s <= p.off_gap_s THEN i.gap_s
                    ELSE 0
                END
            )
            ELSE 0.0
        END AS mean_watts
    FROM intervals i
        CROSS JOIN params p
    GROUP BY i.idx
),
-- ----------------------------
-- Basic stats & percentiles (per idx)
-- ----------------------------
basic AS (
    SELECT idx,
        MIN(watts) AS min_watts,
        MAX(watts) AS max_watts
    FROM samples
    GROUP BY idx
),
ordered AS MATERIALIZED (
    SELECT idx,
        watts,
        ROW_NUMBER() OVER (
            PARTITION BY idx
            ORDER BY watts
        ) AS rn,
        COUNT(*) OVER (PARTITION BY idx) AS n
    FROM samples
),
percentiles AS (
    -- Median index = (n+1)/2 ; P01 = floor((n-1)*0.01)+1 ; P99 = floor((n-1)*0.99)+1
    SELECT o.idx,
        MAX(
            CASE
                WHEN rn = ((n + 1) / 2) THEN watts
            END
        ) AS p50,
        MAX(
            CASE
                WHEN rn = ((n - 1) * 0.01)::bigint + 1 THEN watts
            END
        ) AS p01,
        MAX(
            CASE
                WHEN rn = ((n - 1) * 0.99)::bigint + 1 THEN watts
            END
        ) AS p99
    FROM ordered o
    GROUP BY o.idx
),
rounded AS MATERIALIZED (
    SELECT idx,
        watts,
        round(watts)::integer AS watts_whole
    FROM samples
),
mode_calc AS (
    SELECT idx,
        watts_whole,
        COUNT(*) AS cnt,
        ROW_NUMBER() OVER (
            PARTITION BY idx
            ORDER BY COUNT(*) DESC,
                watts_whole DESC
        ) AS rn
    FROM rounded
    GROUP BY idx,
        watts_whole
),
mode AS (
    SELECT idx,
        watts_whole AS mode_watts,
        cnt AS mode_count
    FROM mode_calc
    WHERE rn = 1
),
value_counts AS (
    SELECT e.idx,
        (
            SELECT COUNT(*)
            FROM rounded r
            WHERE r.idx = e.idx
                AND r.watts_whole = round(e.mean_watts)::integer
        ) AS mean_count,
        CASE
            WHEN p.p50 IS NULL THEN 0
            ELSE (
                SELECT COUNT(*)
                FROM rounded r
                WHERE r.idx = e.idx
                    AND r.watts_whole = round(p.p50)::integer
            )
        END AS median_count,
        COALESCE(m.mode_count, 0) AS mode_count
    FROM energy_stats e
        LEFT JOIN percentiles p USING (idx)
        LEFT JOIN mode m USING (idx)
),
observed AS (
    SELECT idx,
        COUNT(*) AS sample_count
    FROM samples
    GROUP BY idx
),
-- ----------------------------
-- Key/Value assembly for pivot
-- ----------------------------
kv AS (
    SELECT 'Minimum (W)' AS metric,
        idx,
        min_watts AS val
    FROM basic
    UNION ALL
    SELECT 'Maximum (W)',
        idx,
        max_watts
    FROM basic
    UNION ALL
    SELECT 'Mean (W)',
        idx,
        mean_watts
    FROM energy_stats
    UNION ALL
    SELECT 'Median (W)',
        idx,
        p50
    FROM percentiles
    UNION ALL
    SELECT 'Mode (W)',
        idx,
        mode_watts
    FROM mode
    UNION ALL
    SELECT '1st percentile (W)',
        idx,
        p01
    FROM percentiles
    UNION ALL
    SELECT '99th percentile (W)',
        idx,
        p99
    FROM percentiles
    UNION ALL
    SELECT 'Total energy (kWh)',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE watt_seconds / 3600000.0
        END
    FROM energy_stats
    UNION ALL
    SELECT 'Cost @ $0.10/kWh',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE (watt_seconds / 3600000.0) * 0.10
        END
    FROM energy_stats
    UNION ALL
    SELECT 'Cost @ $0.15/kWh',
        idx,
        CASE
            WHEN watt_seconds IS NULL THEN 0.0
            ELSE (watt_seconds / 3600000.0) * 0.15
        END
    FROM energy_stats
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
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 1 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 1 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 2 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 2 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 3 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 3 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 4 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 4 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 5 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 5 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D5,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 6 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 6 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D6,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 7 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 7 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS D7,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 8 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 8 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS W1,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 9 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 9 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS W2,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 10 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 10 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS W3,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 11 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 11 THEN val
                    END
                ),
                0
            )::numeric,
            3
        )
    END AS W4,
    CASE
        WHEN metric IN (
            'Mean count',
            'Median count',
            'Mode count',
            'Sample count'
        ) THEN COALESCE(
            MAX(
                CASE
                    WHEN idx = 12 THEN val
                END
            ),
            0
        )::numeric
        ELSE ROUND(
            COALESCE(
                MAX(
                    CASE
                        WHEN idx = 12 THEN val
                    END
                ),
                0
            )::numeric,
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
        ELSE 99
    END;