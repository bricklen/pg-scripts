-- Some queries I've written or collected that I've found useful.

-- Datatype and added functionality
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- DBA extensions
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Used to speed up array searching
CREATE EXTENSION IF NOT EXISTS intarray;

-- Utility extensions to read external files/databases
CREATE EXTENSION IF NOT EXISTS file_fdw;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Utility function to be able to determine which server the client is connected to
CREATE EXTENSION IF NOT EXISTS hostname;


-- Create the "admin" schema, to hold any admin or utility objects
CREATE SCHEMA IF NOT EXISTS admin;



DROP VIEW IF EXISTS public.stat_activity_brief;

CREATE OR REPLACE VIEW public.stat_activity_brief AS
SELECT  psa.datname AS dbname,
        psa.pid,
        psa.usename AS "user", 
        psa.application_name,
        psa.client_addr, 
        psa.xact_start::timestamp(0) with time zone AS transaction_start, 
        psa.query_start::timestamp(0) with time zone AS query_start, 
        CASE WHEN psa.waiting IS TRUE THEN 'Yes'::text ELSE NULL::text END AS "Blocked?", 
        (now() - psa.query_start)::interval(2) AS "Time (h:m:s.ms)",
        psa.state, 
        psa.query
FROM pg_stat_activity psa
WHERE psa.pid <> pg_backend_pid()
AND psa.state <> 'idle'::text
ORDER BY "Time (h:m:s.ms)";



DROP VIEW IF EXISTS admin.object_sizes;

CREATE OR REPLACE VIEW admin.object_sizes as
select  case when obj = 'table' then 'table' else 'index' end as objtype,
        replace((case when obj = 'table' then tbl::regclass else idx::regclass end)::TEXT,'public.','') as objname,
        case when obj = 'table' then tblsize else idxsize end as objbytes,
        pg_size_pretty(case when obj = 'table' then tblsize else idxsize end) as objsize,
        pg_total_relation_size(case when obj = 'table' then tbl::regclass else idx::regclass end) as overall_bytes,
        pg_size_pretty(pg_total_relation_size(case when obj = 'table' then tbl::regclass else idx::regclass end))  as overall_size
from 
        (select obj,tbl,idx,tblsize,idxsize
        from 
                (select 'table'::text as obj,
                        ((p.schemaname::text || '.'::text)||quote_ident(p.tablename)::text)::regclass as tbl,
                        null::regclass as idx,
                        pg_relation_size(((p.schemaname::text || '.'::text) || quote_ident(p.tablename)::text)::regclass) AS tblsize,
                        0 as idxsize
                from pg_catalog.pg_indexes as p
                where p.schemaname <> ALL (ARRAY['information_schema'::name, 'pg_catalog'::name])) as t
                union
                (select 'index'::text as obj,
                        ((p.schemaname::text || '.'::text) || quote_ident(p.tablename)::text)::regclass as tbl,
                        ((p.schemaname::text || '.'::text) || quote_ident(p.indexname)::text)::regclass as idx,
                        0 as tblsize,
                        pg_relation_size(((p.schemaname::text || '.'::text) || quote_ident(p.indexname)::text)::regclass) AS idxsize
                from pg_catalog.pg_indexes as p
                )
        ) as y
order by overall_bytes desc;




CREATE OR REPLACE VIEW admin.changed_guc_settings AS
SELECT name, current_setting(name), source
FROM pg_settings
WHERE source NOT IN ('default', 'override')
UNION ALL
SELECT 'version' as name, version(), null;




DROP VIEW IF EXISTS admin.approximate_row_counts;

CREATE OR REPLACE VIEW admin.approximate_row_counts AS
SELECT  (case when n.nspname is not null then n.nspname||'.' else '' end)||c.relname as tablename,
        (case when reltuples > 0 then pg_relation_size( ((case when n.nspname is not null then n.nspname||'.' else '' end)||c.relname)) / (8192*relpages::bigint/reltuples::bigint) else 0 end)::bigint as estimated_row_count
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'::"char"
AND n.nspname not in ('pg_catalog','information_schema')
ORDER BY tablename;




DROP VIEW IF EXISTS admin.locked_tables;

CREATE OR REPLACE VIEW admin.locked_tables AS
SELECT  DISTINCT
        locked.pid as locked_pid,
        locker.pid as locker_pid,
        locked_act.usename as locked_user,
        locker_act.usename as locker_user,
        locked.virtualtransaction as locked_vtxid,
        locker.virtualtransaction as locker_vtxid,
        locked.transactionid as locked_txid,
        locker.transactionid as locker_txid,
        pg_class.relname,
        locked.locktype,
        locked.mode as locked_mode,
        locker.mode as locker_mode,
        substring(locked_act.query,1,120) as locked_query,
        substring(locker_act.query,1,120) as locker_query,
        px.transaction as prep_tx,
        px.gid as prep_tx_gid,
        px.prepared as prep,
        px.owner as prep_owner
FROM pg_catalog.pg_locks AS locked
INNER JOIN pg_catalog.pg_stat_activity AS locked_act ON locked.pid = locked_act.pid
INNER JOIN pg_catalog.pg_locks AS locker ON ((locker.transactionid = locked.transactionid or (locker.relation = locked.relation and locker.locktype = locked.locktype)) and locker.pid IS DISTINCT FROM locked.pid)
INNER JOIN pg_catalog.pg_stat_activity AS locker_act ON locker.pid = locker_act.pid
LEFT JOIN pg_catalog.pg_class ON (locked.relation = pg_class.oid)
LEFT JOIN pg_catalog.pg_prepared_xacts px ON locker.virtualtransaction = '-1/' || px.transaction::text
WHERE locker.granted IS TRUE
AND locked.granted IS FALSE;




DROP VIEW IF EXISTS admin.pct_dead;
CREATE OR REPLACE VIEW admin.pct_dead AS
SELECT *,
    n_dead_tup > av_threshold AS "av_needed",
    (CASE WHEN reltuples > 0 THEN round(100.0 * n_dead_tup / (reltuples)) ELSE 0 END) AS pct_dead
FROM
(SELECT N.nspname, C.relname,
    pg_stat_get_tuples_inserted(C.oid) AS n_tup_ins,
    pg_stat_get_tuples_updated(C.oid) AS n_tup_upd,
    pg_stat_get_tuples_deleted(C.oid) AS n_tup_del,
    pg_stat_get_tuples_hot_updated(C.oid)::real / NULLIF(pg_stat_get_tuples_updated(C.oid),0) AS HOT_update_ratio,
    pg_stat_get_live_tuples(C.oid) AS n_live_tup,
    pg_stat_get_dead_tuples(C.oid) AS n_dead_tup,
    C.reltuples AS reltuples,round(current_setting('autovacuum_vacuum_threshold')::integer+current_setting('autovacuum_vacuum_scale_factor')::numeric * C.reltuples) AS av_threshold,
    date_trunc('minute',greatest(pg_stat_get_last_vacuum_time(C.oid),pg_stat_get_last_autovacuum_time(C.oid))) AS last_vacuum,
    date_trunc('minute',greatest(pg_stat_get_last_analyze_time(C.oid),pg_stat_get_last_analyze_time(C.oid))) AS last_analyze
    FROM pg_catalog.pg_class C
    LEFT JOIN pg_catalog.pg_index I ON C.oid = I.indrelid
    LEFT JOIN pg_catalog.pg_namespace N ON (N.oid = C.relnamespace)
    WHERE C.relkind IN ('r', 't')
    AND N.nspname NOT IN ('pg_catalog', 'information_schema')
    AND N.nspname !~ '^pg_toast'
    ) AS av
ORDER BY (case when (n_dead_tup > av_threshold) IS TRUE then 1 else 0 end), n_dead_tup DESC;






DROP FUNCTION IF EXISTS admin.pg_sequences();
CREATE OR REPLACE FUNCTION admin.pg_sequences() RETURNS TABLE
(
    schema          TEXT,
    sequencename    TEXT,
    owner           TEXT,
    last_value      BIGINT,
    start_value     BIGINT,
    increment_by    BIGINT,
    max_value       BIGINT,
    min_value       BIGINT,
    cache_value     BIGINT,
    log_cnt         BIGINT,
    is_cycled       BOOLEAN,
    is_called       BOOLEAN
) AS
$func$
DECLARE
    rec     RECORD;
BEGIN

FOR rec IN 
    SELECT  quote_ident(n.nspname) as schemaname,
            quote_ident(c.relname) as sequence,
            r.rolname as owner
    FROM pg_catalog.pg_class c
    INNER JOIN pg_catalog.pg_roles r ON r.oid = c.relowner
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('S','')
    AND n.nspname NOT IN ('pg_catalog', 'pg_toast')
    ORDER BY 1,2,3
LOOP
    schema := rec.schemaname;
    sequencename := rec.sequence;
    owner := rec.owner;

    EXECUTE FORMAT('SELECT last_value::BIGINT, start_value::BIGINT, increment_by::BIGINT, max_value::BIGINT, min_value::BIGINT, cache_value::BIGINT, log_cnt::BIGINT, is_cycled::BOOLEAN, is_called::BOOLEAN FROM %I.%I', rec.schemaname, rec.sequence)
    INTO last_value, start_value, increment_by, max_value, min_value, cache_value, log_cnt, is_cycled, is_called;

    RETURN NEXT;
END LOOP;

END;
$func$ LANGUAGE plpgsql STRICT IMMUTABLE;





CREATE OR REPLACE VIEW admin.table_stats AS
SELECT  stat.schemaname,
        stat.relname as relname,
        seq_scan,
        seq_tup_read,
        idx_scan,
        idx_tup_fetch,
        heap_blks_read,
        heap_blks_hit,
        idx_blks_read,
        idx_blks_hit
FROM pg_catalog.pg_stat_user_tables AS stat
RIGHT JOIN pg_catalog.pg_statio_user_tables AS statio ON (stat.relid = statio.relid)
ORDER BY seq_tup_read DESC;




CREATE OR REPLACE VIEW admin.table_storage_parameters as
SELECT  t.schemaname,
        t.relname,
        c.reloptions, 
        t.n_tup_upd,
        t.n_tup_hot_upd, 
        case when n_tup_upd > 0 then ((n_tup_hot_upd::numeric/n_tup_upd::numeric)*100.0)::numeric(5,2) else NULL end AS hot_ratio
FROM pg_stat_all_tables t 
INNER JOIN (pg_catalog.pg_class c INNER JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid) ON n.nspname = t.schemaname AND c.relname = t.relname
ORDER BY t.schemaname,t.relname;




CREATE OR REPLACE VIEW admin.view_buffers AS
SELECT  relname,
        buffers,
        ROUND((buffers*8192::NUMERIC)/1024/1024,1) as MB,
        ROUND(buffers / 
            (SELECT count(*) FROM pg_buffercache b INNER JOIN pg_catalog.pg_class c ON b.relfilenode = c.relfilenode AND b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database())))::numeric
            * 100,2) AS pct_of_total
FROM    (SELECT c.relname, count(*) AS buffers
        FROM pg_buffercache b
        INNER JOIN pg_catalog.pg_class c ON b.relfilenode = c.relfilenode AND b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
        GROUP BY c.relname) as y
ORDER BY buffers DESC;



CREATE OR REPLACE VIEW admin.find_invalid_indexes AS
SELECT n.nspname, c.relname
FROM pg_catalog.pg_class c
INNER JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
INNER JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
WHERE (i.indisvalid = false OR i.indisready = false)
AND n.nspname != 'pg_catalog' 
AND n.nspname != 'information_schema' 
AND n.nspname != 'pg_toast';

COMMENT ON VIEW admin.find_invalid_indexes IS 'To find invalid indexes. Specifically if you attempted to create an index CONCURRENTLY and it failed. This can cause pg_upgrade to fail.';



CREATE OR REPLACE VIEW admin.show_foreign_keys AS
SELECT quote_ident(fk.table_schema)||'.'||quote_ident(fk.table_name)||
            ' ( '||quote_ident(cu.column_name)||'::'||coalesce(UPPER(colf.data_type),'')||
            ' ) REFERENCES '||quote_ident(pk.table_schema)||'.'||quote_ident(pk.table_name)||
            ' ( '||quote_ident(pt.column_name)||'::'||coalesce(UPPER(colp.data_type),'')||
            ' ) AS '|| quote_ident(c.constraint_name) as "Foreign Key Constraints"
FROM information_schema.referential_constraints c
INNER JOIN information_schema.table_constraints fk ON c.constraint_name = fk.constraint_name
INNER JOIN information_schema.table_constraints pk ON c.unique_constraint_name = pk.constraint_name
INNER JOIN information_schema.key_column_usage cu ON c.constraint_name = cu.constraint_name
INNER JOIN
       (SELECT i1.table_name, i2.column_name
       FROM information_schema.table_constraints i1
       INNER JOIN information_schema.key_column_usage i2 ON i1.constraint_name = i2.constraint_name
       WHERE i1.constraint_type = 'PRIMARY KEY') pt ON pt.table_name = pk.table_name
LEFT JOIN information_schema.columns colp ON (colp.table_schema, colp.table_name, colp.column_name) = (pk.table_schema,pk.table_name,pt.column_name)
LEFT JOIN information_schema.columns colf ON (colf.table_schema, colf.table_name, colf.column_name) = (fk.table_schema,fk.table_name,cu.column_name)
GROUP BY "Foreign Key Constraints"
ORDER BY "Foreign Key Constraints";




DROP VIEW IF EXISTS admin.unindexed_foreign_keys;
CREATE OR REPLACE VIEW admin.unindexed_foreign_keys as
SELECT  referencing_tbl,
        referencing_column,
        existing_fk_on_referencing_tbl,
        referenced_tbl,
        referenced_column,
        pg_size_pretty(referencing_tbl_bytes) as referencing_tbl_size,
        pg_size_pretty(referenced_tbl_bytes) as referenced_tbl_size,
        suggestion
FROM    (
        select  (case when n1.nspname is not null then quote_ident(n1.nspname) else 'public' end) || '.' || quote_ident(c1.relname)  as referencing_tbl,
                quote_ident(a1.attname) as referencing_column,
                t.conname as existing_fk_on_referencing_tbl,
                (case when n2.nspname is not null then quote_ident(n2.nspname) else 'public' end) || '.' || quote_ident(c2.relname) || '.' || quote_ident(a2.attname) as referenced_tbl,
                quote_ident(a2.attname) as referenced_column,
                pg_relation_size( ((case when n1.nspname is not null then quote_ident(n1.nspname) else 'public' end) || '.' || quote_ident(c1.relname)) ) as referencing_tbl_bytes,
                pg_relation_size( ((case when n2.nspname is not null then quote_ident(n2.nspname) else 'public' end) || '.' || quote_ident(c2.relname)) ) as referenced_tbl_bytes,
                'Create an index on column ' || quote_ident(a1.attname) || ' in table ' ||
                    (case when n1.nspname is not null then quote_ident(n1.nspname) else 'public' end) || '.' || quote_ident(c1.relname) as suggestion
        from pg_constraint t
        join pg_attribute  a1 on a1.attrelid = t.conrelid and a1.attnum = t.conkey[1]
        join pg_catalog.pg_class      c1 on c1.oid = t.conrelid
        join pg_catalog.pg_namespace  n1 on n1.oid = c1.relnamespace
        join pg_catalog.pg_class      c2 on c2.oid = t.confrelid
        join pg_catalog.pg_namespace  n2 on n2.oid = c2.relnamespace
        join pg_attribute  a2 on a2.attrelid = t.confrelid and a2.attnum = t.confkey[1]
        where t.contype = 'f'
        and not exists
            (select 1
            from pg_catalog.pg_index i
            where i.indrelid = t.conrelid
            and i.indkey[0] = t.conkey[1])
        ) as y
ORDER BY referencing_tbl_bytes desc, referenced_tbl_bytes desc, referencing_tbl,
         referenced_tbl, referencing_column, referenced_column;






CREATE OR REPLACE VIEW admin.bloat AS
SELECT  current_database() AS db,
        schemaname,
        tablename,
        reltuples::bigint AS tups,
        relpages::bigint AS pages,
        otta,
        ROUND(CASE WHEN otta=0 OR sml.relpages=0 OR sml.relpages=otta THEN 0.0 ELSE sml.relpages/otta::numeric END,1) AS tbloat,
        CASE WHEN relpages < otta THEN 0 ELSE relpages::bigint - otta END AS wastedpages,
        CASE WHEN relpages < otta THEN 0 ELSE bs*(sml.relpages-otta)::bigint END AS wastedbytes,
        CASE WHEN relpages < otta THEN '0 bytes'::text ELSE (bs*(relpages-otta))::bigint || ' bytes' END AS wastedsize,
        iname,
        ituples::bigint AS itups,
        ipages::bigint AS ipages,
        iotta,
        ROUND(CASE WHEN iotta=0 OR ipages=0 OR ipages=iotta THEN 0.0 ELSE ipages/iotta::numeric END,1) AS ibloat,
        CASE WHEN ipages < iotta THEN 0 ELSE ipages::bigint - iotta END AS wastedipages,
        CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta) END AS wastedibytes,
        CASE WHEN ipages < iotta THEN '0 bytes' ELSE (bs*(ipages-iotta))::bigint || ' bytes' END AS wastedisize,
        (CASE WHEN relpages < otta THEN
            CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta::bigint) END
            ELSE    CASE WHEN ipages < iotta THEN bs*(relpages-otta::bigint)
                    ELSE bs*(relpages-otta::bigint + ipages-iotta::bigint) END
        END) AS totalwastedbytes
FROM (
  SELECT
        nn.nspname AS schemaname,
        cc.relname AS tablename,
        COALESCE(cc.reltuples,0) AS reltuples,
        COALESCE(cc.relpages,0) AS relpages,
        COALESCE(bs,0) AS bs,
        COALESCE(CEIL((cc.reltuples*((datahdr + ma - (CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::float)),0) AS otta,
        NULLIF(c2.relname,'') AS iname,
        COALESCE(c2.reltuples,0) AS ituples,
        COALESCE(c2.relpages,0) AS ipages,
        COALESCE(CEIL((c2.reltuples*(datahdr-12))/(bs-20::float)),0) AS iotta -- very rough approximation, assumes all cols
    FROM pg_catalog.pg_class cc
    JOIN pg_catalog.pg_namespace nn ON (cc.relnamespace = nn.oid AND nn.nspname <> 'information_schema')
    LEFT JOIN
    (
        SELECT  ma,bs,foo.nspname,foo.relname,
                (datawidth+(hdr+ma-(case when hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr,
                (maxfracsum*(nullhdr+ma-(case when nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
        FROM (
            SELECT  ns.nspname, tbl.relname, hdr, ma, bs,
                    SUM((1-coalesce(null_frac,0))*coalesce(avg_width, 2048)) AS datawidth,
                    MAX(coalesce(null_frac,0)) AS maxfracsum,
                    hdr + ( SELECT 1+count(*)/8 FROM pg_stats s2 WHERE null_frac<>0 AND s2.schemaname = ns.nspname AND s2.tablename = tbl.relname ) AS nullhdr
            FROM pg_attribute att 
            JOIN pg_catalog.pg_class tbl ON att.attrelid = tbl.oid
            JOIN pg_catalog.pg_namespace ns ON ns.oid = tbl.relnamespace 
            LEFT JOIN pg_stats s ON s.schemaname=ns.nspname
            AND s.tablename = tbl.relname
            AND s.inherited=false
            AND s.attname=att.attname,
            (SELECT current_setting('block_size')::numeric AS bs,
                    CASE WHEN SUBSTRING(SPLIT_PART(v, ' ', 2) FROM '#"[0-9]+.[0-9]+#"%' for '#') IN ('8.0','8.1','8.2') THEN 27 ELSE 23 END AS hdr,
                    CASE WHEN v ~ 'mingw32' OR v ~ '64-bit' THEN 8 ELSE 4 END AS ma
            FROM (SELECT version() AS v) AS foo
            ) AS constants
            WHERE att.attnum > 0
            AND tbl.relkind='r'
            GROUP BY 1,2,3,4,5
        ) AS foo
    ) AS rs ON (cc.relname = rs.relname AND nn.nspname = rs.nspname)
    LEFT JOIN pg_catalog.pg_index i ON indrelid = cc.oid
    LEFT JOIN pg_catalog.pg_class c2 ON c2.oid = i.indexrelid
) AS sml
WHERE (sml.relpages::double precision - sml.otta) > 100::double precision
    OR (sml.ipages::double precision - sml.iotta) > 100::double precision
ORDER BY sml.bs * (sml.relpages::double precision - sml.otta)::bigint::numeric DESC;



DROP VIEW IF EXISTS indexes_requiring_maintenance;
DROP VIEW IF EXISTS admin.indexes_requiring_maintenance;
CREATE OR REPLACE VIEW admin.indexes_requiring_maintenance AS
SELECT  db,
        schemaname||'.'||tablename as tbl,
        tups as rows,
        tbloat::TEXT||'%' as table_bloat_pct,
        pg_size_pretty(wastedbytes::BIGINT) as wasted_table_space,
        schemaname||'.'||iname as index_name,
        ibloat::TEXT||'%' as index_bloat_pct,
        pg_size_pretty(wastedibytes::BIGINT) as wasted_index_space,
        ROUND( 100 * (wastedibytes / pg_relation_size(schemaname||'.'||iname::TEXT)::NUMERIC)::NUMERIC,2) as pct_idx_wasted
FROM    (
        select *
        from admin.bloat
        order by wastedibytes desc limit 40) b
ORDER BY wastedibytes DESC;





DROP VIEW IF EXISTS admin.table_stats_rows;
CREATE OR REPLACE VIEW admin.table_stats_rows as
SELECT  schemaname,
        tablename,
        rowcnt,
        inserted,
        updated,
        deleted,
        updated+deleted as upd_and_del,
        (CASE WHEN inserted > 0 THEN round(100 * ((updated+deleted) / inserted::float))::TEXT||'%' ELSE 'No inserts recorded' END) as pct_churn_vs_inserts
FROM    (SELECT n.nspname as schemaname,
                c.relname as tablename,
                c.reltuples::bigint as rowcnt,
                pg_stat_get_tuples_inserted(c.oid) AS inserted,
                pg_stat_get_tuples_updated(c.oid) AS updated,
                pg_stat_get_tuples_deleted(c.oid) AS deleted
        FROM pg_catalog.pg_class c
        INNER JOIN pg_catalog.pg_namespace n on c.relnamespace=n.oid
        WHERE c.relkind = 'r'::"char"
        GROUP BY n.nspname,c.oid, c.relname, c.reltuples
        HAVING (pg_stat_get_tuples_updated(c.oid) + pg_stat_get_tuples_deleted(c.oid)) > 1000
        ) as y
ORDER BY pct_churn_vs_inserts desc;

COMMENT ON VIEW admin.table_stats_rows IS 'The pct of churn is the ratio of updates & deletes vs inserts. High churn requires more aggressive autovacuum settings.';




DROP VIEW IF EXISTS admin.show_columns;
CREATE OR REPLACE VIEW admin.show_columns AS
SELECT  n.nspname AS schemaname,
        c.relname as tablename,
        a.attnum as column_position,
        a.attname as columnname,
        pg_catalog.format_type(a.atttypid, a.atttypmod) as datatype,
        (case when a.attnotnull is true then 'NOT NULL' else null end) AS null_status,
        (SELECT substring(pg_catalog.pg_get_expr(d.adbin, d.adrelid) for 128) FROM pg_catalog.pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef) as column_default,
        pg_get_userbyid(c.relowner) AS tableowner,
        ts.spcname AS tablespace,
        (case UPPER(a.attstorage::VARCHAR) when 'X'::VARCHAR then 'Extended' when 'P'::VARCHAR then 'Plain' when 'M'::VARCHAR then 'Main' else a.attstorage::VARCHAR end)::VARCHAR as column_storage,
        CASE WHEN a.attstattarget=-1 THEN NULL ELSE a.attstattarget END AS non_default_stats_target,
        pg_catalog.col_description(a.attrelid, a.attnum) as column_description
FROM pg_catalog.pg_class as c
INNER JOIN pg_catalog.pg_attribute as a ON (a.attrelid = c.oid)
INNER JOIN pg_catalog.pg_type as t ON (t.oid = a.atttypid)
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
WHERE a.attnum > 0
AND c.relkind = 'r'
ORDER BY schemaname,tablename,column_position;




CREATE OR REPLACE VIEW admin.function_def as
/* This view can be used to search the func_def for matching terms in the body of the function */
SELECT n.nspname AS schema_name,
       p.proname AS function_name,
       pg_get_function_arguments(p.oid) AS args,
       pg_get_functiondef(p.oid) AS func_def
FROM   (SELECT oid, * FROM pg_proc p WHERE NOT p.proisagg) p
JOIN   pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname !~~ 'pg_%'
AND    n.nspname <> 'information_schema';

COMMENT ON VIEW admin.function_def IS 'This view can be used to search the func_def for matching terms in the body of the function.';







DROP VIEW IF EXISTS admin.unused_indexes;
CREATE OR REPLACE VIEW admin.unused_indexes as
SELECT  current_database() as dbname,
        schemaname,
        tablename,
        indexname,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch,
        is_used,
        idx_size as idx_size_bytes,
        is_unique,
        is_primary_key
FROM (
    SELECT  quote_ident(ui.schemaname) as schemaname,
            quote_ident(ui.relname) as tablename,
            quote_ident(ui.indexrelname) as indexname,
            ui.idx_scan,
            ui.idx_tup_read,
            ui.idx_tup_fetch,
            (ui.idx_scan + ui.idx_tup_read + ui.idx_tup_fetch) > 0 as is_used,
            pg_relation_size(quote_ident(ui.schemaname)||'.'||quote_ident(ui.indexrelname)) as idx_size,
            x.indisunique IS TRUE as is_unique,
            x.indisprimary IS TRUE as is_primary_key
    FROM pg_catalog.pg_stat_user_indexes ui
    INNER JOIN pg_catalog.pg_index x ON x.indexrelid = ui.indexrelid
    JOIN pg_catalog.pg_class c ON c.oid = x.indrelid
    JOIN pg_catalog.pg_class i ON i.oid = x.indexrelid
    ORDER BY idx_size DESC
    ) y;





DROP VIEW IF EXISTS admin.age_of_tables;
CREATE OR REPLACE VIEW admin.age_of_tables AS
SELECT  nsp.nspname||'.'||c.relname as tablename,
        age(c.relfrozenxid) as xid_age,
        to_timestamp(extract(epoch from now()) - age(c.relfrozenxid))::DATE as date_of_last_freeze,
        pg_size_pretty(pg_table_size(c.oid)) as table_size,
        pg_table_size(c.oid) as table_bytes,
        pg_table_size(c.oid) > 1073741824 as greater_than_1_gb
FROM pg_catalog.pg_class as c
LEFT JOIN pg_catalog.pg_namespace as nsp on c.relnamespace=nsp.oid
WHERE c.relkind = 'r'
ORDER BY greater_than_1_gb desc, age(c.relfrozenxid) DESC;

COMMENT ON VIEW admin.age_of_tables IS 'This view shows the age of tables, ordered by age descending. If over about 1GB, the DBA should run "VACUUM FREEZE <tablename>" at an opportune time rather than waiting for autovacuum to hit the autovacuum_freeze_max_age threshold.';





CREATE OR REPLACE FUNCTION array_intersect(ANYARRAY, ANYARRAY)
RETURNS ANYARRAY
LANGUAGE SQL
AS $$
SELECT ARRAY(
    SELECT $1[i] AS "the_intersection"
    FROM generate_series(array_lower($1,1), array_upper($1,1) ) AS i
    INTERSECT
    SELECT $2[j] AS "the_intersection"
    FROM generate_series( array_lower($2,1), array_upper($2,1) ) AS j
);
$$;

GRANT EXECUTE ON FUNCTION array_intersect(anyarray,anyarray) TO public;






CREATE OR REPLACE FUNCTION arrxor(anyarray,anyarray) RETURNS ANYARRAY AS $$
SELECT ARRAY(
        (
        select r.elements
        from    (
                (select 1,unnest($1))
                union all
                (select 2,unnest($2))
                ) as r (arr, elements)
        group by 1
        having min(arr) = max(arr)
        )
)
$$ LANGUAGE SQL STRICT IMMUTABLE;

GRANT EXECUTE ON FUNCTION arrxor(anyarray,anyarray) TO public;






CREATE OR REPLACE VIEW admin.checkpoint_details as
SELECT
    (100 * checkpoints_req) /
        (checkpoints_timed + checkpoints_req) AS checkpoints_req_pct,
    pg_size_pretty(buffers_checkpoint * block_size /
        (checkpoints_timed + checkpoints_req)) AS avg_checkpoint_write,
    pg_size_pretty(block_size *
        (buffers_checkpoint + buffers_clean + buffers_backend)) AS total_written,
    100 * buffers_checkpoint /
        (buffers_checkpoint + buffers_clean + buffers_backend) AS checkpoint_write_pct,
    100 * buffers_backend /
        (buffers_checkpoint + buffers_clean + buffers_backend) AS backend_write_pct,
    *
FROM pg_catalog.pg_stat_bgwriter,
(SELECT cast(current_setting('block_size') AS integer) AS block_size) AS bs;





CREATE OR REPLACE VIEW admin.table_dependencies AS (
WITH RECURSIVE t AS (
    SELECT
        c.oid AS origin_id,
        c.oid::regclass::text AS origin_table,
        c.oid AS referencing_id,
        c.oid::regclass::text AS referencing_table,
        c2.oid AS referenced_id,
        c2.oid::regclass::text AS referenced_table,
        ARRAY[c.oid::regclass,c2.oid::regclass] AS chain
    FROM pg_catalog.pg_constraint AS co
    INNER JOIN pg_catalog.pg_class AS c ON c.oid = co.conrelid
    INNER JOIN pg_catalog.pg_class AS c2 ON c2.oid = co.confrelid
--     Add this line as an input parameter if you want to make a one-off query
--     WHERE c.oid::regclass::text = 'YOUR TABLE'
    UNION ALL
    SELECT
        t.origin_id,
        t.origin_table,
        t.referenced_id AS referencing_id,
        t.referenced_table AS referencing_table,
        c3.oid AS referenced_id,
        c3.oid::regclass::text AS referenced_table,
        t.chain || c3.oid::regclass AS chain
    FROM pg_catalog.pg_constraint AS co
    INNER JOIN pg_catalog.pg_class AS c3 ON c3.oid = co.confrelid
    INNER JOIN t ON t.referenced_id = co.conrelid
    WHERE
        -- prevent infinite recursion by pruning paths where the last entry in
        -- the path already appears somewhere else in the path
        NOT (
            ARRAY[ t.chain[array_upper(t.chain, 1)] ] -- an array containing the last element
            <@                                        -- "is contained by"
            t.chain[1:array_upper(t.chain, 1) - 1]    -- a slice of the chain,
                                                      -- from element 1 to n-1
        )
)
SELECT  origin_table,
        referenced_table,
        array_upper(chain,1) AS "depth",
        array_to_string(chain,',') as chain
FROM t
);






CREATE OR REPLACE FUNCTION public.array_sort (ANYARRAY)
RETURNS ANYARRAY LANGUAGE SQL
AS $$
SELECT array_agg(x ORDER BY x) FROM unnest($1) x;
$$;

GRANT EXECUTE ON FUNCTION public.array_sort(anyarray) TO public;



DROP VIEW IF EXISTS admin.pending_wraparound;
CREATE OR REPLACE VIEW admin.pending_wraparound as
SELECT  nspname as schemaname,
        relname as tablename,
        pg_size_pretty(pg_relation_size(oid)) as table_size,
        pg_size_pretty(pg_total_relation_size(oid)) as total_size,
        age(relfrozenxid),
        last_vacuum
FROM
(SELECT c.oid,
        N.nspname,
        C.relname,
        C.relfrozenxid,
        pg_stat_get_tuples_inserted(C.oid) AS n_tup_ins,
        pg_stat_get_tuples_updated(C.oid) AS n_tup_upd,
        pg_stat_get_tuples_deleted(C.oid) AS n_tup_del,
        pg_stat_get_live_tuples(C.oid) AS n_live_tup,
        pg_stat_get_dead_tuples(C.oid) AS n_dead_tup,
        C.reltuples AS reltuples,
        round(current_setting('autovacuum_vacuum_threshold')::integer
            + current_setting('autovacuum_vacuum_scale_factor')::numeric
            * C.reltuples)
        AS av_threshold,
        date_trunc('day',greatest(pg_stat_get_last_vacuum_time(C.oid),pg_stat_get_last_autovacuum_time(C.oid)))::date AS last_vacuum,
        date_trunc('day',greatest(pg_stat_get_last_analyze_time(C.oid),pg_stat_get_last_analyze_time(C.oid)))::date AS last_analyze,
        setting::integer as freeze_max_age
    FROM pg_catalog.pg_class C
    LEFT JOIN pg_catalog.pg_namespace N ON (N.oid = C.relnamespace),
    pg_settings pgs
    WHERE C.relkind IN ('r', 't')
    AND N.nspname NOT IN ('pg_catalog', 'information_schema')
    AND N.nspname !~ '^pg_toast'
    AND pgs.name='autovacuum_freeze_max_age'
) AS av
WHERE age(relfrozenxid) > (0.9 * freeze_max_age)
ORDER BY age(relfrozenxid) DESC;



DROP VIEW IF EXISTS admin.indexes_on_high_write_relations;
CREATE OR REPLACE VIEW admin.indexes_on_high_write_relations AS
SELECT
  TS.spcname tbl_space,
  i.schemaname as schemaname,
  i.relname as tablename,
  i.indexrelname as indexname,
  i.idx_scan,
  pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
  pg_stat_get_tuples_returned(indrelid) AS n_tup_read,
  pg_stat_get_tuples_inserted(indrelid) + pg_stat_get_tuples_updated(indrelid) +
    pg_stat_get_tuples_deleted(indrelid) AS n_tup_write,
  CASE WHEN (pg_stat_get_tuples_returned(indrelid) + pg_stat_get_tuples_inserted(indrelid) +
    pg_stat_get_tuples_updated(indrelid) +
    pg_stat_get_tuples_deleted(indrelid)) > 0 then
        100 * pg_stat_get_tuples_returned(indrelid)  /
            (pg_stat_get_tuples_returned(indrelid) +
            pg_stat_get_tuples_inserted(indrelid) + pg_stat_get_tuples_updated(indrelid) +
            pg_stat_get_tuples_deleted(indrelid))
  ELSE 0 END AS read_pct
FROM
  pg_stat_user_indexes i
  JOIN pg_catalog.pg_index USING (indexrelid)
  JOIN pg_catalog.pg_class C ON (C.oid = indexrelid)
  LEFT JOIN pg_catalog.pg_tablespace TS ON (C.reltablespace = TS.oid)
ORDER BY 
  pg_stat_get_tuples_inserted(indrelid) + pg_stat_get_tuples_updated(indrelid) +
  pg_stat_get_tuples_deleted(indrelid) DESC;



DROP VIEW IF EXISTS admin.indexes_on_high_read_relations;
CREATE OR REPLACE VIEW admin.indexes_on_high_read_relations as
SELECT
  TS.spcname tbl_space,
  i.schemaname,
  i.relname as tablename,
  i.indexrelname as indexname,
  i.idx_scan,
  pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
  pg_stat_get_tuples_returned(indrelid) AS n_tup_read,
  pg_stat_get_tuples_inserted(indrelid) + pg_stat_get_tuples_updated(indrelid) +
    pg_stat_get_tuples_deleted(indrelid) AS n_tup_write
FROM pg_catalog.pg_stat_user_indexes i
JOIN pg_catalog.pg_index USING (indexrelid)
JOIN pg_catalog.pg_class C ON (C.oid = indexrelid)
LEFT JOIN pg_catalog.pg_tablespace TS ON (C.reltablespace = TS.oid)
ORDER BY pg_stat_get_tuples_returned(indrelid) DESC
LIMIT 50;


DROP VIEW IF EXISTS admin.top_users_of_disk_space;
CREATE OR REPLACE VIEW admin.top_users_of_disk_space as
SELECT
  TS.spcname tbl_space,
  N.nspname as schemaname,
  C.relname AS relation,
  CASE WHEN C.relkind='r' THEN 'Table' WHEN C.relkind='v' THEN 'View'
    WHEN C.relkind='i' THEN 'Index' WHEN C.relkind='S' THEN 'Sequence'
    WHEN C.relkind='s' THEN 'Special'
    WHEN C.relkind='t' THEN 'Toast'
    ELSE lower(C.relkind) END AS "type",
  pg_size_pretty(pg_relation_size(C.oid)) AS size,
  pg_relation_size(C.oid) AS bytes,
  pg_stat_get_tuples_returned(C.oid) AS n_tup_read,
  pg_stat_get_tuples_inserted(C.oid) AS n_tup_ins,
  pg_stat_get_tuples_updated(C.oid) AS n_tup_upd,
  pg_stat_get_tuples_deleted(C.oid) AS n_tup_del
FROM pg_catalog.pg_class C
LEFT JOIN pg_catalog.pg_tablespace TS ON (C.reltablespace = TS.oid)
LEFT JOIN pg_catalog.pg_namespace N ON (N.oid = C.relnamespace)
ORDER BY bytes DESC;





CREATE OR REPLACE VIEW admin.last_analyzed AS
SELECT  nspname as schemaname,
        relname as tablename,
        last_vacuum,
        last_analyze,
        to_timestamp(extract(epoch from now()) - age(relfrozenxid)) as last_frozen
FROM
    (SELECT c.oid,
            N.nspname,
            C.relname,
            date_trunc('day',greatest(pg_stat_get_last_vacuum_time(C.oid),pg_stat_get_last_autovacuum_time(C.oid)))::date AS last_vacuum,
            date_trunc('day',greatest(pg_stat_get_last_analyze_time(C.oid),pg_stat_get_last_analyze_time(C.oid)))::date AS last_analyze,
            C.relfrozenxid
    FROM pg_catalog.pg_class C
    LEFT JOIN pg_catalog.pg_namespace N ON (N.oid = C.relnamespace)
    WHERE C.relkind IN ('r', 't')
    AND N.nspname NOT IN ('pg_catalog', 'information_schema')
    AND N.nspname !~ '^pg_toast'
    ) AS av
WHERE (last_analyze IS NULL) OR (last_analyze < (now() - '1 day'::interval))
ORDER BY last_analyze NULLS FIRST;





CREATE OR REPLACE FUNCTION public.extract_interval(TSTZRANGE) RETURNS interval AS
$func$
select upper($1) - lower($1);
$func$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION public.extract_interval(TSTZRANGE) TO public;

CREATE OR REPLACE FUNCTION public.extract_interval(TSRANGE) RETURNS interval AS
$func$
select upper($1) - lower($1);
$func$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION public.extract_interval(TSRANGE) TO public;


CREATE OR REPLACE FUNCTION public.extract_days(TSTZRANGE) RETURNS integer AS
$func$
select (date_trunc('day',upper($1))::DATE - date_trunc('day',lower($1))::DATE) + 1;
$func$ LANGUAGE sql;

GRANT EXECUTE ON FUNCTION public.extract_days(TSTZRANGE) TO public;


CREATE OR REPLACE FUNCTION public.extract_days(TSRANGE) RETURNS integer AS
$func$
select (date_trunc('day',upper($1))::DATE - date_trunc('day',lower($1))::DATE) + 1;
$func$ LANGUAGE sql;

GRANT EXECUTE ON FUNCTION public.extract_days(TSRANGE) TO public;



CREATE OR REPLACE FUNCTION last_day(DATE)
RETURNS DATE AS
$$
SELECT (date_trunc('MONTH', $1) + INTERVAL '1 MONTH - 1 day')::DATE;
$$ LANGUAGE SQL IMMUTABLE STRICT;

GRANT EXECUTE ON FUNCTION last_day(date) TO PUBLIC;





DROP FUNCTION IF EXISTS extract_dy(timestamptz);
CREATE OR REPLACE FUNCTION extract_dy (timestamptz) RETURNS TEXT AS
$$
select  (case extract(dow from $1)
            when 0 then 'SU'
            when 1 then 'MO'
            when 2 then 'TU'
            when 3 then 'WE'
            when 4 then 'TH'
            when 5 then 'FR'
            when 6 then 'SA'
        end) as dy;
$$ LANGUAGE SQL STRICT IMMUTABLE;

GRANT EXECUTE ON FUNCTION extract_dy(timestamptz) TO public;


DROP FUNCTION IF EXISTS extract_dy(timestamp);
CREATE OR REPLACE FUNCTION EXTRACT_DY (timestamp) RETURNS TEXT AS
$$
select  (case extract(dow from $1)
            when 0 then 'SU'
            when 1 then 'MO'
            when 2 then 'TU'
            when 3 then 'WE'
            when 4 then 'TH'
            when 5 then 'FR'
            when 6 then 'SA'
        end) as dy;
$$ LANGUAGE SQL STRICT IMMUTABLE;

GRANT EXECUTE ON FUNCTION extract_dy(timestamp) TO public;



CREATE OR REPLACE FUNCTION convert_dy_to_d (text) RETURNS INTEGER AS
$$
select  (case $1
            when 'SU' then 0
            when 'MO' then 1
            when 'TU' then 2
            when 'WE' then 3
            when 'TH' then 4
            when 'FR' then 5
            when 'SA' then 6
        end) as dy;
$$ LANGUAGE SQL STRICT IMMUTABLE ;
GRANT EXECUTE ON FUNCTION convert_dy_to_d(text) TO public;





CREATE OR REPLACE FUNCTION public.day_conversions() RETURNS TABLE (day TEXT, dy TEXT, dow INTEGER) AS
$func$
select  unnest( ARRAY['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday']::TEXT[] ) as "day",
        unnest( ARRAY['SU','MO','TU','WE','TH','FR','SA']::TEXT[] ) as "dy",
        unnest( ARRAY[0,1,2,3,4,5,6]::INTEGER[] ) as "dow";
$func$ LANGUAGE sql STRICT IMMUTABLE;

GRANT EXECUTE ON FUNCTION public.day_conversions() TO public;

