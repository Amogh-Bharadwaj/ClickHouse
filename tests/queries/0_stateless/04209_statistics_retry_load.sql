-- Tags: no-parallel

SET allow_statistics = 1;
SET materialize_statistics_on_insert = 1;

DROP TABLE IF EXISTS t;
CREATE TABLE t (a UInt64 STATISTICS(basic), b UInt64 STATISTICS(basic))
ENGINE = MergeTree ORDER BY tuple()
SETTINGS min_bytes_for_wide_part = 0;

INSERT INTO t SELECT number, number FROM numbers(1000);
INSERT INTO t SELECT number + 1000000, number FROM numbers(1000);

-- Recreate the part objects so pruning must load estimates from statistics files.
DETACH TABLE t;
ATTACH TABLE t;

-- Enable failpoint: loadStatistics throws an exception
SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw;

-- Query 1: a statistics-load failure must abort the query.
SELECT count() FROM t WHERE a > 500000
SETTINGS use_statistics_for_part_pruning = 1; -- { serverError CANNOT_READ_ALL_DATA }

-- The same failure must propagate through EXPLAIN WHATIF when its filter needs a.
SET allow_experimental_statistics = 1;
SET allow_statistics_optimize = 1;
CREATE HYPOTHETICAL INDEX idx_a ON t (a) TYPE minmax GRANULARITY 1;
EXPLAIN WHATIF empirical = 0 SELECT * FROM t WHERE a > 500000; -- { serverError CANNOT_READ_ALL_DATA }

-- Maintenance paths obey the same contract: a merge must abort if loading
-- statistics from a source part fails.
OPTIMIZE TABLE t FINAL; -- { serverError CANNOT_READ_ALL_DATA }

-- Disable failpoint
SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw;

-- Part pruning only needs a. It must not call the unfiltered overload, and it
-- must cache the filtered estimate so the same query does not reload it.
SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_unfiltered_throw;
SELECT count() FROM t WHERE a > 500000
SETTINGS use_statistics_for_part_pruning = 1;
SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_unfiltered_throw;

SYSTEM ENABLE FAILPOINT merge_tree_load_statistics_throw;
SELECT count() FROM t WHERE a > 500000
SETTINGS use_statistics_for_part_pruning = 1;
SYSTEM DISABLE FAILPOINT merge_tree_load_statistics_throw;

-- Query 2: before the fix, the poisoned empty cache would be hit (0 parts pruned),
-- after the fix both parts should participate in correct pruning.
SELECT count() FROM t WHERE a > 2000000
SETTINGS use_statistics_for_part_pruning = 1;

SYSTEM FLUSH LOGS query_log;

-- Key assertion: SelectedParts for query 2 should be 0
SELECT ProfileEvents['SelectedParts']
FROM system.query_log
WHERE current_database = currentDatabase()
  AND query LIKE '%FROM t WHERE a > 2000000%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC LIMIT 1;

DROP TABLE t;
