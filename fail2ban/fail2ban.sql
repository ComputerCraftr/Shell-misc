.headers on
.mode column

SELECT jail,
    ip,
    CASE
        WHEN bantime = -1 THEN 'Permanent'
        ELSE (timeofban + bantime) - strftime ('%s', 'now')
    END AS remaining_time
FROM bans;
