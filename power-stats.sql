.mode column --
-- power-stats.sql
-- Usage:
--   sqlite3 /var/db/apc-watts/apc-watts.db < power-stats.sql
--
-- This script produces a daily (last 7 days) columnar summary with W1..W4 weekly
-- columns and an M1 last-30-days column. It uses a single metric pipeline for all periods.
-- ----------------------------
-- Periods (idx = 1..7 per-day, idx = 8..11 weekly, idx = 12 monthly)
-- ----------------------------
WITH RECURSIVE params AS (
    SELECT 600 AS off_gap_s
),
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
    -- Weekly windows: idx = 8..11 (W1..W4, midnight-aligned)
    SELECT (w + 8) AS idx,
        CAST(
            strftime(
                '%s',
                datetime(
                    'now',
                    'start of day',
                    printf('-%d days', w * 7 + 6)
                )
            ) AS INTEGER
        ) AS start_sec,
        CAST(
            strftime(
                '%s',
                datetime(
                    'now',
                    'start of day',
                    printf('%+d days', 1 - w * 7)
                )
            ) AS INTEGER
        ) AS end_sec
    FROM weeks
    UNION ALL
    -- Monthly window: idx = 12 (last 30 days, midnight-aligned)
    SELECT 12 AS idx,
        CAST(
            strftime(
                '%s',
                datetime('now', 'start of day', '-29 days')
            ) AS INTEGER
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
        CAST(s.watts AS REAL) AS watts
    FROM periods p
        JOIN watts s ON CAST(strftime('%s', s.ts) AS INTEGER) >= p.start_sec
        AND CAST(strftime('%s', s.ts) AS INTEGER) < p.end_sec
),
intervals AS (
    SELECT idx,
        watts,
        tsec,
        LEAD(tsec) OVER (
            PARTITION BY idx
            ORDER BY tsec
        ) AS next_tsec,
        (
            LEAD(tsec) OVER (
                PARTITION BY idx
                ORDER BY tsec
            ) - tsec
        ) AS gap_s
    FROM samples
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
ordered AS (
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
                WHEN rn = (CAST((n - 1) * 0.01 AS INTEGER) + 1) THEN watts
            END
        ) AS p01,
        MAX(
            CASE
                WHEN rn = (CAST((n - 1) * 0.99 AS INTEGER) + 1) THEN watts
            END
        ) AS p99
    FROM ordered o
    GROUP BY o.idx
),
rounded AS (
    SELECT idx,
        watts,
        CAST(ROUND(watts) AS INTEGER) AS watts_whole
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
    SELECT r.idx,
        SUM(
            CASE
                WHEN r.watts_whole = CAST(ROUND(e.mean_watts) AS INTEGER) THEN 1
                ELSE 0
            END
        ) AS mean_count,
        SUM(
            CASE
                WHEN r.watts_whole = CAST(ROUND(p.p50) AS INTEGER) THEN 1
                ELSE 0
            END
        ) AS median_count,
        MAX(m.mode_count) AS mode_count
    FROM rounded r
        JOIN energy_stats e USING (idx)
        JOIN percentiles p USING (idx)
        LEFT JOIN mode m USING (idx)
    GROUP BY r.idx
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
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 8 THEN val
                END
            )
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
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 9 THEN val
                END
            )
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
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 10 THEN val
                END
            )
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
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 11 THEN val
                END
            )
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
        ELSE printf(
            '%.3f',
            MAX(
                CASE
                    WHEN idx = 12 THEN val
                END
            )
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
