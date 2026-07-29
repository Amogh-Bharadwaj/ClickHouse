#!/usr/bin/env bash
# Tags: no-fasttest, no-replicated-database, no-random-merge-tree-settings
# no-fasttest: column statistics (tdigest/uniq) require the full build, fast_build can't materialize them, so the statistical path falls through to applicability_only
# no-replicated-database: hypothetical indexes are session-scoped and not replicated
# no-random-merge-tree-settings: test requires deterministic index_granularity

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    SET enable_json_type = 1;
    -- force on so the INSERT builds statistics files the statistical path reads
    SET materialize_statistics_on_insert = 1;

    DROP TABLE IF EXISTS t_hypo_stat;
    CREATE TABLE t_hypo_stat (a UInt64, b UInt64 STATISTICS(tdigest, uniq))
    ENGINE = MergeTree ORDER BY a
    SETTINGS index_granularity = 100, index_granularity_bytes = 0, min_bytes_for_wide_part = 0;

    -- 100 granules of 100 rows; b cycles 0..99
    INSERT INTO t_hypo_stat SELECT number, number % 100 FROM numbers(10000);

    DROP TABLE IF EXISTS t_hypo_unrelated_stat;
    CREATE TABLE t_hypo_unrelated_stat
    (
        a UInt64,
        b UInt64,
        c UInt64 STATISTICS(tdigest, uniq)
    )
    ENGINE = MergeTree ORDER BY a
    SETTINGS index_granularity = 100, index_granularity_bytes = 0,
             min_bytes_for_wide_part = 0, auto_statistics_types = '';
    INSERT INTO t_hypo_unrelated_stat
    SELECT number, number % 100, number % 50 FROM numbers(10000);

    DROP TABLE IF EXISTS t_hypo_insufficient_stat;
    CREATE TABLE t_hypo_insufficient_stat
    (
        a UInt64,
        b UInt64 STATISTICS(uniq)
    )
    ENGINE = MergeTree ORDER BY a
    SETTINGS index_granularity = 100, index_granularity_bytes = 0,
             min_bytes_for_wide_part = 0, auto_statistics_types = '';
    INSERT INTO t_hypo_insufficient_stat
    SELECT number, number % 100 FROM numbers(10000);

    DROP TABLE IF EXISTS t_hypo_nullable_stat;
    CREATE TABLE t_hypo_nullable_stat
    (
        a UInt64,
        n Nullable(UInt64) STATISTICS(basic)
    )
    ENGINE = MergeTree ORDER BY a
    SETTINGS index_granularity = 100, index_granularity_bytes = 0,
             min_bytes_for_wide_part = 0, auto_statistics_types = '';
    INSERT INTO t_hypo_nullable_stat
    SELECT number, if(number % 2, number, NULL) FROM numbers(10000);

    DROP TABLE IF EXISTS t_hypo_json_null_stat;
    CREATE TABLE t_hypo_json_null_stat
    (
        a UInt64,
        x Nullable(JSON) STATISTICS(basic)
    )
    ENGINE = MergeTree ORDER BY a
    SETTINGS index_granularity = 100, index_granularity_bytes = 0,
             min_bytes_for_wide_part = 0, auto_statistics_types = '';
    INSERT INTO t_hypo_json_null_stat
    SELECT number, if(number % 3 = 0, NULL, concat('{\"null\":', toString(number % 2), '}'))
    FROM numbers(10000);

    DROP TABLE IF EXISTS t_hypo_prewhere_stat;
    CREATE TABLE t_hypo_prewhere_stat
    (
        s String STATISTICS(uniq),
        k UInt64 STATISTICS(tdigest)
    )
    ENGINE = MergeTree ORDER BY tuple()
    SETTINGS min_bytes_for_wide_part = 0, auto_statistics_types = '',
             default_compression_codec = 'NONE';
    INSERT INTO t_hypo_prewhere_stat
    SELECT repeat('x', 100), number FROM numbers(10000);
"

# empirical disabled -> statistical: tdigest gives ~50% selectivity for b < 50
echo "--- statistical: range query on column with stats ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_b ON t_hypo_stat (b) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_stat WHERE b < 50;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# No column stats -> falls through to applicability_only.
echo "--- statistical: no stats, falls back to applicability_only ---"
$CLICKHOUSE_CLIENT -n -q "
    DROP TABLE IF EXISTS t_hypo_no_stat;
    CREATE TABLE t_hypo_no_stat (a UInt64, b UInt64)
    ENGINE = MergeTree ORDER BY a
    -- auto_statistics_types = '': this table must have no column statistics so the statistical
    -- path falls back to applicability_only. Without it the default auto-statistics (minmax, uniq),
    -- once materialized on INSERT (randomized in CI), would make the source 'statistical'.
    SETTINGS index_granularity = 100, index_granularity_bytes = 0, min_bytes_for_wide_part = 0, auto_statistics_types = '';
    INSERT INTO t_hypo_no_stat SELECT number, number % 100 FROM numbers(10000);

    CREATE HYPOTHETICAL INDEX idx_b ON t_hypo_no_stat (b) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_no_stat WHERE b < 50;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# Statistics for an unrelated column must not make the filter estimate statistical.
echo "--- statistical: unrelated stats fall back to applicability_only ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_b ON t_hypo_unrelated_stat (b) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_unrelated_stat WHERE b < 50;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# A function-expression index can be applicable even though the statistics
# estimator cannot describe that expression. Do not label its heuristic as statistical.
echo "--- statistical: unsupported expression falls back to applicability_only ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_mod ON t_hypo_stat (b % 10) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_stat WHERE b % 10 = 1;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# Uniq can estimate equality but not a numeric range. Do not call the range fallback statistical.
echo "--- statistical: insufficient statistic type falls back to applicability_only ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_b ON t_hypo_insufficient_stat (b) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_insufficient_stat WHERE b < 50;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# The analyzer rewrites isNull(n) to the n.null carrier. Its statistics belong to n.
echo "--- statistical: nullable subcolumn rewrite uses parent statistics ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_n ON t_hypo_nullable_stat (n) TYPE set(100) GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0
        SELECT * FROM t_hypo_nullable_stat WHERE isNull(n)
        SETTINGS optimize_functions_to_subcolumns = 1;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# Explicit predicates on the binary null carrier are equivalent to IS [NOT] NULL.
echo "--- statistical: explicit nullable carrier uses parent statistics ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_n ON t_hypo_nullable_stat (n.null) TYPE set(100) GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_nullable_stat WHERE n.null = 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_nullable_stat WHERE n.null = 0;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_nullable_stat WHERE n.null != 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_nullable_stat WHERE n.null != 0;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# JSON owns a real `null` subcolumn.
# Do not reinterpret that subcolumn as the outer Nullable null-map.
echo "--- statistical: real nested null subcolumn does not use parent statistics ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_x_null ON t_hypo_json_null_stat (x.null) TYPE set(100) GRANULARITY 1;
    EXPLAIN WHATIF empirical = 0 SELECT * FROM t_hypo_json_null_stat WHERE x.null = 1;
" | grep -E '^\s+status:|^\s+source:|^\s+empirical_status:'

# LIKE cannot be estimated from uniq statistics. Its default heuristic must not
# be treated as a statistics estimate when PREWHERE conditions are reordered.
echo "--- prewhere: unsupported predicate keeps non-statistical ordering ---"
with_statistics=$($CLICKHOUSE_CLIENT -q "
    SELECT extractAll(explain, 'Prewhere filter column: ([^\n]+)')[1]
    FROM
    (
        EXPLAIN actions = 1
        SELECT count() FROM t_hypo_prewhere_stat
        WHERE like(s, '%z%') AND k < 9000
        SETTINGS allow_experimental_statistics = 1, use_statistics = 1,
                 optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1,
                 allow_reorder_prewhere_conditions = 1, move_all_conditions_to_prewhere = 1,
                 move_primary_key_columns_to_end_of_prewhere = 1
    )
    WHERE explain LIKE '%Prewhere filter column%'
")
without_statistics=$($CLICKHOUSE_CLIENT -q "
    SELECT extractAll(explain, 'Prewhere filter column: ([^\n]+)')[1]
    FROM
    (
        EXPLAIN actions = 1
        SELECT count() FROM t_hypo_prewhere_stat
        WHERE like(s, '%z%') AND k < 9000
        SETTINGS allow_experimental_statistics = 1, use_statistics = 0,
                 optimize_move_to_prewhere = 1, query_plan_optimize_prewhere = 1,
                 allow_reorder_prewhere_conditions = 1, move_all_conditions_to_prewhere = 1,
                 move_primary_key_columns_to_end_of_prewhere = 1
    )
    WHERE explain LIKE '%Prewhere filter column%'
")
[[ -n "$with_statistics"
    && "$with_statistics" == *s*
    && "$with_statistics" == *k*
    && "$with_statistics" == "$without_statistics" ]] && echo 1 || echo 0

# With empirical = 1 (default), empirical is preferred when both are available.
echo "--- default: empirical preferred over statistical when both available ---"
$CLICKHOUSE_CLIENT -n -q "
    SET allow_experimental_statistics = 1;
    SET allow_statistics_optimize = 1;
    CREATE HYPOTHETICAL INDEX idx_b ON t_hypo_stat (b) TYPE minmax GRANULARITY 1;
    EXPLAIN WHATIF SELECT * FROM t_hypo_stat WHERE b < 50;
" | grep -E '^\s+source:|^\s+empirical_status:'

# Settings validation: unknown setting and invalid value are rejected.
echo "--- unknown setting is rejected ---"
$CLICKHOUSE_CLIENT -q "EXPLAIN WHATIF empircal = 0 SELECT * FROM t_hypo_stat WHERE b < 50" 2>&1 | grep -m1 -o 'UNKNOWN_SETTING'

echo "--- invalid value for empirical is rejected ---"
$CLICKHOUSE_CLIENT -q "EXPLAIN WHATIF empirical = 2 SELECT * FROM t_hypo_stat WHERE b < 50" 2>&1 | grep -m1 -o 'INVALID_SETTING_VALUE'

$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_no_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_unrelated_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_insufficient_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_nullable_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_json_null_stat"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS t_hypo_prewhere_stat"
