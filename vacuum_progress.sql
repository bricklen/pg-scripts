-- Original query from http://blog.postgresql-consulting.com/2017/10/deep-dive-into-postgres-stats_31.html
-- NOTES:
--     pg_stat_progress_vacuum holds no information about which index is vacuumed and how many blocks have already been processed.
--     Also, pg_stat_progress_vacuum does not support VACUUM FULL operations.
-- Postgres 10+

CREATE OR REPLACE VIEW vacuum_progress AS
SELECT
    p.pid,
    clock_timestamp() - a.xact_start AS duration,
    coalesce(wait_event_type ||'.'|| wait_event, 'f') AS waiting,
    (CASE
        WHEN a.query ~ '^autovacuum.*to prevent wraparound' THEN 'wraparound' 
        WHEN a.query ~ '^vacuum' THEN 'user'
        ELSE 'regular'
    END) AS mode,
    p.datname AS database,
    p.relid::regclass AS table,
    p.phase,
    pg_size_pretty(p.heap_blks_total * 
        current_setting('block_size')::int) AS table_size,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(p.heap_blks_scanned * 
        current_setting('block_size')::int) AS scanned,
    pg_size_pretty(p.heap_blks_vacuumed * 
        current_setting('block_size')::int) AS vacuumed,
    (CASE WHEN p.heap_blks_total > 0 THEN 
        round(100.0 * p.heap_blks_scanned / 
            p.heap_blks_total, 1) else 0 end) AS scanned_pct,
    (CASE WHEN p.heap_blks_total > 0 THEN 
        round(100.0 * p.heap_blks_vacuumed / 
            p.heap_blks_total, 1) else 0 end) AS vacuumed_pct,
    p.index_vacuum_count,
    round(100.0 * p.num_dead_tuples / 
        p.max_dead_tuples,1) AS dead_pct
FROM pg_catalog.pg_stat_progress_vacuum AS p
JOIN pg_catalog.pg_stat_activity AS a USING (pid)
ORDER BY duration DESC;
