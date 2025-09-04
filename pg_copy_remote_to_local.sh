#!/usr/bin/env bash
set -euo pipefail
# pg_copy_remote_to_local.sh
# Automated script to copy a PostgreSQL database from a remote server to local
# Uses: pg_dump -Fd (directory format) with parallel jobs, pg_dumpall for globals,
# and pg_restore for parallel restore. Does NOT store passwords; use ~/.pgpass or
# set REMOTE_PGPASS/LOCAL_PGPASS in environment when calling the script.

usage() {
  cat <<EOF
Usage: $0 [options]

Required:
  -H remote_host        Remote PostgreSQL host (or IP)
  -U remote_db_user     Remote PostgreSQL user
  -d remote_dbname      Remote database name to copy

Optional:
  -P remote_port        Remote PostgreSQL port (default: 5432)
  -L local_dbname       Local target database name (default: same as remote)
  -u local_db_user      Local PostgreSQL user (default: current user)
  -p local_port         Local PostgreSQL port (default: 5432)
  -j jobs               Number of parallel jobs for dump/restore (default: nproc or 4)
  -D dump_dir           Directory to store dump (default: ./pg_dumps/<dbname>-YYYYMMDD)
  --apply-globals       After dumping, apply globals.sql to local postgres (CAUTION)
  --verify              After restore, run row-count verification for all public tables (may be slow)
  --overwrite-dir       If dump_dir already exists, remove it before dumping (DANGEROUS)
  -h                    Show this help

Environment:
  REMOTE_PGPASS         Optional password for remote pg (exported as PGPASSWORD for remote commands)
  LOCAL_PGPASS          Optional password for local pg commands

Examples:
  REMOTE_PGPASS=secret LOCAL_PGPASS=localpass \
    $0 -H 192.168.10.41 -U dbuser -d mydb -u localuser -L mydb_copy -j 8

EOF
}

if [[ ${#@} -eq 0 ]]; then
  usage
  exit 1
fi

# defaults
REMOTE_PORT=5432
LOCAL_PORT=5432
JOBS=$(nproc 2>/dev/null || echo 4)
LOCAL_DB_USER=$(whoami)
APPLY_GLOBALS=0
VERIFY=0
OVERWRITE_DIR=0

# parse args
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) REMOTE_HOST="$2"; shift 2;;
    -U) REMOTE_DB_USER="$2"; shift 2;;
    -d) REMOTE_DBNAME="$2"; shift 2;;
    -P) REMOTE_PORT="$2"; shift 2;;
    -L) LOCAL_DBNAME="$2"; shift 2;;
    -u) LOCAL_DB_USER="$2"; shift 2;;
    -p) LOCAL_PORT="$2"; shift 2;;
    -j) JOBS="$2"; shift 2;;
    -D) DUMP_DIR="$2"; shift 2;;
    --apply-globals) APPLY_GLOBALS=1; shift ;;
    --verify) VERIFY=1; shift ;;
  --overwrite-dir) OVERWRITE_DIR=1; shift ;;
    -h) usage; exit 0;;
    --) shift; break;;
    -*) echo "Unknown option: $1"; usage; exit 1;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done

if [[ -z ${REMOTE_HOST:-} || -z ${REMOTE_DB_USER:-} || -z ${REMOTE_DBNAME:-} ]]; then
  echo "Missing required parameters." >&2
  usage
  exit 2
fi

LOCAL_DBNAME=${LOCAL_DBNAME:-$REMOTE_DBNAME}
DUMP_DIR=${DUMP_DIR:-"./pg_dumps/${REMOTE_DBNAME}_$(date +%F)"}

echo "Remote: ${REMOTE_HOST}:${REMOTE_PORT} db=${REMOTE_DBNAME} user=${REMOTE_DB_USER}"
echo "Local:  port=${LOCAL_PORT} db=${LOCAL_DBNAME} user=${LOCAL_DB_USER}"
echo "Requested dump dir: ${DUMP_DIR}  jobs=${JOBS}  apply-globals=${APPLY_GLOBALS} verify=${VERIFY} overwrite-dir=${OVERWRITE_DIR}"

# Ensure parent directory exists and decide final dump directory without creating it (pg_dump will create it)
PARENT_DIR=$(dirname -- "$DUMP_DIR")
BASE_NAME=$(basename -- "$DUMP_DIR")
mkdir -p "$PARENT_DIR"

if [[ -e "$DUMP_DIR" ]]; then
  if [[ "$OVERWRITE_DIR" -eq 1 ]]; then
    echo "Removing existing dump directory: $DUMP_DIR"
    rm -rf -- "$DUMP_DIR"
  else
    # choose a unique directory name by appending _1, _2, ...
    i=1
    CANDIDATE="$DUMP_DIR"
    while [[ -e "$CANDIDATE" ]]; do
      CANDIDATE="${DUMP_DIR}_$i"
      i=$((i+1))
    done
    DUMP_DIR="$CANDIDATE"
    BASE_NAME=$(basename -- "$DUMP_DIR")
    echo "Dump directory exists; using new directory: $DUMP_DIR"
  fi
fi

# logs are stored outside dump dir to avoid creating it before pg_dump runs
TIME_TAG=$(date +%F_%H%M%S)
LOG_DIR="$PARENT_DIR/_logs"
mkdir -p "$LOG_DIR"
DUMP_LOG="$LOG_DIR/${BASE_NAME}_${TIME_TAG}_pg_dump.log"
RESTORE_LOG="$LOG_DIR/${BASE_NAME}_${TIME_TAG}_pg_restore.log"

echo "Final dump dir: ${DUMP_DIR}"

# check required binaries
for cmd in pg_dump pg_restore psql createdb; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 3
  fi
done

echo "1/7 - Dumping remote database (directory format)"
# Use remote password if provided via REMOTE_PGPASS environment variable
if [[ -n "${REMOTE_PGPASS:-}" ]]; then
  export PGPASSWORD="$REMOTE_PGPASS"
fi

pg_dump -h "$REMOTE_HOST" -p "$REMOTE_PORT" -U "$REMOTE_DB_USER" -Fd -j "$JOBS" -f "$DUMP_DIR" -v "$REMOTE_DBNAME" 2> >(tee "$DUMP_LOG" >&2)

# fail if pg_dump logged errors
if grep -qi "^error:" "$DUMP_LOG" 2>/dev/null; then
  echo "pg_dump reported errors. See $DUMP_LOG" >&2
  exit 10
fi

echo "2/7 - Dumping globals (roles, tablespaces) to ${DUMP_DIR}/globals.sql"
PGPASSWORD="${REMOTE_PGPASS:-}" pg_dumpall -h "$REMOTE_HOST" -p "$REMOTE_PORT" -U "$REMOTE_DB_USER" --globals-only > "$DUMP_DIR/globals.sql"

echo "3/7 - (Optional) Apply globals to local Postgres? apply-globals=${APPLY_GLOBALS}"
if [[ "$APPLY_GLOBALS" -eq 1 ]]; then
  echo "Applying globals.sql to local postgres (you should review this file before running)"
  if [[ -n "${LOCAL_PGPASS:-}" ]]; then
    export PGPASSWORD="$LOCAL_PGPASS"
  fi
  psql -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -f "$DUMP_DIR/globals.sql" postgres
else
  echo "Skipping automatic globals apply. File available at: $DUMP_DIR/globals.sql"
fi

echo "4/7 - Creating local target database (with same encoding as remote)"
REMOTE_ENCODING=$(PGPASSWORD="${REMOTE_PGPASS:-}" psql -h "$REMOTE_HOST" -p "$REMOTE_PORT" -U "$REMOTE_DB_USER" -At -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = '$REMOTE_DBNAME';" postgres || true)
REMOTE_ENCODING=${REMOTE_ENCODING:-UTF8}
echo "Detected remote encoding: $REMOTE_ENCODING"

if [[ -n "${LOCAL_PGPASS:-}" ]]; then
  export PGPASSWORD="$LOCAL_PGPASS"
fi

if psql -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -lqt | cut -d \| -f 1 | tr -d ' ' | grep -qw "${LOCAL_DBNAME}"; then
  echo "Local database ${LOCAL_DBNAME} already exists. Skipping createdb.";
else
  createdb -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -T template0 -E "$REMOTE_ENCODING" "$LOCAL_DBNAME"
fi

echo "5/7 - Restoring dump into local database"
pg_restore -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -d "$LOCAL_DBNAME" -j "$JOBS" -e -v "$DUMP_DIR" 2> >(tee "$RESTORE_LOG" >&2)

# fail if pg_restore logged errors
if grep -qi "^error:" "$RESTORE_LOG" 2>/dev/null; then
  echo "pg_restore reported errors. See $RESTORE_LOG" >&2
  exit 11
fi

echo "6/7 - Vacuum analyze local database"
psql -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -d "$LOCAL_DBNAME" -c "VACUUM VERBOSE ANALYZE;"

echo "7/7 - Optional verification of table and row counts across all user schemas"
if [[ "$VERIFY" -eq 1 ]]; then
  echo "Verification: comparing table list and row counts (remote vs local). This may be slow."
  TMP_VERIFY="$DUMP_DIR/verify_counts.csv"
  TMP_TABLES="$DUMP_DIR/verify_tables.csv"
  echo "schema.table,remote_count,local_count" > "$TMP_VERIFY"

  # list all base tables (exclude system schemas, toast, temp)
  TABLES=$(psql -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -d "$LOCAL_DBNAME" -At -c "
    SELECT table_schema||'.'||table_name
    FROM information_schema.tables
    WHERE table_type='BASE TABLE'
      AND table_schema NOT IN ('pg_catalog','information_schema')
      AND table_schema NOT LIKE 'pg_toast%'
      AND table_schema NOT LIKE 'pg_temp%'
    ORDER BY 1;")

  echo "$TABLES" | sed '/^$/d' > "$TMP_TABLES"

  TOTAL_REMOTE=0
  TOTAL_LOCAL=0
  MISMATCH=0
  while IFS= read -r t; do
    schema=${t%%.*}
    tbl=${t#*.}
    remote_count=$(PGPASSWORD="${REMOTE_PGPASS:-}" psql -h "$REMOTE_HOST" -p "$REMOTE_PORT" -U "$REMOTE_DB_USER" -d "$REMOTE_DBNAME" -At -c "SELECT count(*) FROM \"$schema\".\"$tbl\";" || echo "-1")
    local_count=$(psql -h localhost -p "$LOCAL_PORT" -U "$LOCAL_DB_USER" -d "$LOCAL_DBNAME" -At -c "SELECT count(*) FROM \"$schema\".\"$tbl\";" || echo "-1")
    echo "${t},${remote_count},${local_count}" >> "$TMP_VERIFY"
    # accumulate totals if numeric
    [[ $remote_count =~ ^[0-9]+$ ]] && TOTAL_REMOTE=$((TOTAL_REMOTE + remote_count))
    [[ $local_count =~ ^[0-9]+$ ]] && TOTAL_LOCAL=$((TOTAL_LOCAL + local_count))
    if [[ "$remote_count" != "$local_count" ]]; then MISMATCH=$((MISMATCH + 1)); fi
  done < "$TMP_TABLES"

  echo "Verification results saved to: $TMP_VERIFY"
  echo "Summary: tables checked=$(wc -l < "$TMP_TABLES") mismatched=$MISMATCH total_rows_remote=$TOTAL_REMOTE total_rows_local=$TOTAL_LOCAL"
  if [[ $MISMATCH -gt 0 || $TOTAL_REMOTE -ne $TOTAL_LOCAL ]]; then
    echo "WARNING: Differences detected. See $TMP_VERIFY for details." >&2
  fi
fi

echo "Done. Dump directory: $DUMP_DIR"
echo "Recommended next steps: review $DUMP_DIR/globals.sql and any extension requirements. Run integrity checks as needed."
