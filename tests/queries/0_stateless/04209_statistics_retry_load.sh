#!/usr/bin/env bash
# Tags: no-parallel
# Tag no-parallel: toggles server-global failpoints.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

set -e

CLICKHOUSE_CLIENT="${CLICKHOUSE_CLIENT} --allow_statistics=1 --materialize_statistics_on_insert=1 --allow_experimental_statistics=1 --allow_statistics_optimize=1"

cleanup()
{
    ${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw" >/dev/null 2>&1 ||:
    ${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_unfiltered_throw" >/dev/null 2>&1 ||:
    ${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t" >/dev/null 2>&1 ||:
    ${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_set" >/dev/null 2>&1 ||:
}

expect_error()
{
    local expected_error="$1"
    local query="$2"
    local output
    if output=$(${CLICKHOUSE_CLIENT} --multiquery --query "$query" 2>&1); then
        echo "Expected ${expected_error}, but query succeeded" >&2
        return 1
    fi

    if ! printf '%s\n' "$output" | grep -qF "$expected_error"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

trap cleanup EXIT
cleanup

${CLICKHOUSE_CLIENT} --multiquery --query "
    CREATE TABLE t
    (
        a UInt64 STATISTICS(basic),
        b UInt64 STATISTICS(basic),
        n Nullable(UInt64) STATISTICS(basic)
    )
    ENGINE = MergeTree ORDER BY tuple()
    SETTINGS min_bytes_for_wide_part = 0;

    INSERT INTO t SELECT number, number, if(number % 2 = 0, NULL, number) FROM numbers(1000);
    INSERT INTO t SELECT number + 1000000, number, if(number % 2 = 0, NULL, number) FROM numbers(1000);

    -- Recreate the part objects so pruning must load estimates from statistics files.
    DETACH TABLE t;
    ATTACH TABLE t;
"

${CLICKHOUSE_CLIENT} --query "SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw"

# Statistics-load failures must abort every path that actually needs the files.
expect_error "CANNOT_READ_ALL_DATA" "
    SELECT count() FROM t WHERE a > 500000
    SETTINGS use_statistics_for_part_pruning = 1
"
expect_error "CANNOT_READ_ALL_DATA" "
    CREATE HYPOTHETICAL INDEX idx_a ON t (a) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t WHERE a > 500000;
"
expect_error "CANNOT_READ_ALL_DATA" "OPTIMIZE TABLE t FINAL"

${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw"

# A filter without table inputs must not turn an empty filtered request into a
# full statistics load. Check both PREWHERE entry points.
${CLICKHOUSE_CLIENT} --query "SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE rand() % 2 = 0 AND rand() % 3 = 0
    SETTINGS use_statistics = 1, optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 0
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE rand() % 2 = 0 AND rand() % 3 = 0
    SETTINGS use_statistics = 1, optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw"

# Predicate analysis is best-effort. An unusable IN subquery must disable
# statistics pruning before any statistics file is loaded.
${CLICKHOUSE_CLIENT} --multiquery --query "
    CREATE TABLE t_set
    (
        a String,
        b String,
        c String STATISTICS(basic),
        INDEX idx_c c TYPE bloom_filter GRANULARITY 1
    )
    ENGINE = MergeTree
    ORDER BY (a, b);

    INSERT INTO t_set VALUES ('a', 'b', 'c');
    DETACH TABLE t_set;
    ATTACH TABLE t_set;
"

${CLICKHOUSE_CLIENT} --query "SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw"
${CLICKHOUSE_CLIENT} --query "
    EXPLAIN SELECT count() FROM t_set WHERE c IN (SELECT throwIf(1))
    SETTINGS use_skip_indexes = 0, use_statistics = 0
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw"

expect_error "FUNCTION_THROW_IF_VALUE_IS_NON_ZERO" "
    EXPLAIN SELECT count() FROM t_set WHERE c IN (SELECT throwIf(1))
    SETTINGS use_skip_indexes = 1, use_statistics = 0
"

# Planning paths must pass their non-empty filter columns to the loader instead
# of requesting every statistic. Exercise both PREWHERE implementations and
# WHATIF while the unfiltered overload is forbidden.
${CLICKHOUSE_CLIENT} --query "SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_unfiltered_throw"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE a > 500000 AND b < 500
    SETTINGS use_statistics = 1, use_statistics_cache = 0,
             optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 0
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE a > 500000 AND b < 500
    SETTINGS use_statistics = 1, use_statistics_cache = 0,
             optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE isNull(n) AND a > 500000
    SETTINGS use_statistics = 1, use_statistics_cache = 0,
             optimize_functions_to_subcolumns = 1,
             optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 0
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --query "
    SELECT sum(a) FROM t WHERE isNull(n) AND a > 500000
    SETTINGS use_statistics = 1, use_statistics_cache = 0,
             optimize_functions_to_subcolumns = 1,
             optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1
    FORMAT Null
"
${CLICKHOUSE_CLIENT} --multiquery --query "
    CREATE HYPOTHETICAL INDEX idx_a ON t (a) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0
    SELECT * FROM t WHERE a > 500000 AND a < 1000001;
" >/dev/null
${CLICKHOUSE_CLIENT} --multiquery --query "
    CREATE HYPOTHETICAL INDEX idx_n ON t (n) TYPE set(100) GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0
    SELECT * FROM t WHERE isNull(n)
    SETTINGS optimize_functions_to_subcolumns = 1;
" >/dev/null

# Part pruning only needs a. It must not call the unfiltered overload, and it
# must cache the filtered estimate so the same query does not reload it.
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM t WHERE a > 500000
    SETTINGS use_statistics_for_part_pruning = 1
"
${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_unfiltered_throw"

${CLICKHOUSE_CLIENT} --query "SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw"
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM t WHERE a > 500000
    SETTINGS use_statistics_for_part_pruning = 1
"
${CLICKHOUSE_CLIENT} --query "SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw"

# Before the fix, the poisoned empty cache would be hit (0 parts pruned).
# After the fix both parts participate in correct pruning.
${CLICKHOUSE_CLIENT} --query "
    SELECT count() FROM t WHERE a > 2000000
    SETTINGS use_statistics_for_part_pruning = 1
"

${CLICKHOUSE_CLIENT} --query "SYSTEM FLUSH LOGS query_log"

# No part should be selected for the impossible predicate.
${CLICKHOUSE_CLIENT} --query "
    SELECT ProfileEvents['SelectedParts']
    FROM system.query_log
    WHERE current_database = currentDatabase()
      AND query LIKE '%FROM t WHERE a > 2000000%'
      AND type = 'QueryFinish'
    ORDER BY event_time DESC
    LIMIT 1
"
