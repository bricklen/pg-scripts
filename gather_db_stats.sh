#!/bin/bash

## Usage: bash gather_db_stats.sh -h
##        Runs as postgres OS user.
##
## Requires: A directory to hold the stats.
##           If not supplied, creates directory ~postgres/postgresql_stats
##
## TODO: Add options to send the resulting tar.gz file to a remote destination.
##       This would likely require the dest IP, dest user, and dest location.
##
## Scheduled execution: run at end-of-day, daily, to gather stats.
##      55 23 * * * /bin/bash /path/to/gather_db_stats.sh -o /path/to/postgresql_stats -p 5432
##
## Changes:
##      Jan 5, 2014 - bricklen - Initial check-in, gathers index statistics.
##      Feb 4, 2014 - bricklen - Revised the query to determine whether indexes are unique or primary keys.
##
## Error codes:
##      100 = Missing tool
##      130 = Could not change to directory
##      142 = No database cluster found
##      150 = No tar.gz file found.

set -o errexit

## Pick up the Postgresql bin dir if set
#. $HOME/.bash_profile

OUTPUTDIR=
PGPORT=5432
DBUSER=postgres
ADMINDBNAME=postgres
DT=`date +'%Y-%m-%d'`
HN=`hostname`
TARFNAME="${HN}_${DT}_database_stats.tar"

function die
{
    local exit_status=$1
    shift
    echo "$@" >&2
    exit $exit_status
}

usage()
{
cat <<-EOF
        Usage: ${0##*/} options

        This script will tar + gzip the database stats csv files for all non-template databases in a cluster.
        Should be run as the postgres OS user.

        Sample usage:
                bash gather_db_stats.sh -o $HOME/postgresql_stats/

        OPTIONS:
        -h      Show this message
        -o      Output directory
        -p      PostgreSQL database port. If omitted, defaults to 5432.

EOF
}

while getopts "o:p:h" OPTION
do
    case $OPTION in
    h)
        usage
        exit 0
        ;;
    o)
        OUTPUTDIR=$OPTARG
        ;;
    p)
        PGPORT=$OPTARG
        ;;
    ?)
        usage
        exit 1
        ;;
    esac
done

## Check for tool existence
ZIP=$(which pigz 2>/dev/null || which gzip 2>/dev/null || die 100 "gzip tool not available")
PSQL=$(which psql 2>/dev/null || die 100 "psql client not available")

## Check that there is a running cluster at the specified port
CLUSTERSTATUS=`$PSQL -d $ADMINDBNAME -U $DBUSER -p $PGPORT -qtAXc "select 42" 2> /dev/null || echo 1`
[[ "$CLUSTERSTATUS" == "42" ]] || die 142 "Cluster at port $PGPORT is not available."

if [[ "X$OUTPUTDIR" == "X" ]]; then
    OUTPUTDIR=~postgres/postgresql_stats && mkdir -p $OUTPUTDIR
fi

cd $OUTPUTDIR || die 130 "ERROR: Could not cd to $OUTPUTDIR"

## Query to list all relevant databases in the cluster
SQL="SELECT datname FROM pg_catalog.pg_database WHERE datistemplate IS FALSE AND datallowconn IS TRUE ORDER BY datname"

## Loop the list of databases
for db in `$PSQL -d $ADMINDBNAME -U $DBUSER -p $PGPORT -qtAX -c "$SQL"`; do

## Custom filename for each csv
FNAME="${HN}_${DT}_idx_stats_${db}"
FNAME=$(echo "$FNAME" | tr ' ' '_')

## Emit the csv of db stats
$PSQL -d $db -U $DBUSER -p $PGPORT -qtAXc "
COPY (
SELECT  now()::TIMESTAMPTZ(0) as time_of_execution,
        current_database() as dbname,
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
    INNER JOIN pg_catalog.pg_class c ON c.oid = x.indrelid
    INNER JOIN pg_catalog.pg_class i ON i.oid = x.indexrelid
    ORDER BY idx_size DESC
    ) y
) TO '$OUTPUTDIR/$FNAME.csv' CSV HEADER FORCE QUOTE *"

## Append this log file to the tar archive
tar --update --file="${TARFNAME}" --remove-files "${FNAME}.csv"

done

## gzip the tar archive, force overwrite any existing file of the same name
$ZIP --force ${TARFNAME}

## Check that the compressed tar archive exists
[[ -f "$TARFNAME.gz" ]] || die 150 "ERROR: tgz archive $TARFNAME.gz does not appear to exist."

echo
echo ".....Results output to $OUTPUTDIR/$TARFNAME.gz"
echo

## TODO: Optionally rsync to a valid location?

## Steps to load the csv data at a centralized location
## CREATE SCHEMA IF NOT EXISTS admin;
## CREATE TABLE IF NOT EXISTS admin.index_statistics (
##     time_of_execution       TIMESTAMPTZ,
##     dbname                  TEXT,
##     schemaname              TEXT,
##     tablename               TEXT,
##     indexname               TEXT,
##     idx_scan                BIGINT,
##     idx_tup_read            BIGINT,
##     idx_tup_fetch           BIGINT,
##     is_used                 BOOLEAN,
##     idx_size_bytes          BIGINT,
##     is_unique               BOOLEAN,
##     is_primary_key          BOOLEAN
## ) WITH (fillfactor = 100);
## 
## COPY admin.index_statistics FROM '/path/to/your/file.csv' CSV HEADER;
##
## Sample query:
## SELECT  rank,
##         indexname,
##         idx_usage,
##         size_in_all_dbs
## FROM
##     (SELECT ROW_NUMBER() OVER (ORDER BY SUM(COALESCE(idx_scan,0) + COALESCE(idx_tup_read,0) + COALESCE(idx_tup_fetch,0)), sum(idx_size_bytes) DESC) as rank,
##             indexname,
##             SUM(COALESCE(idx_scan,0) + COALESCE(idx_tup_read,0) + COALESCE(idx_tup_fetch,0)) as idx_usage,
##             pg_size_pretty(sum(idx_size_bytes)::BIGINT) as size_in_all_dbs,
##             sum(idx_size_bytes) as bytes_in_all_dbs
##     FROM admin.index_statistics
##     WHERE is_unique IS FALSE
##     AND is_primary_key IS FALSE
##     GROUP BY indexname) y
## ORDER BY rank;

exit 0
