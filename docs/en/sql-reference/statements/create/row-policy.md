---
description: 'Documentation for Row Policy'
sidebar_label: 'ROW POLICY'
sidebar_position: 41
slug: /sql-reference/statements/create/row-policy
title: 'CREATE ROW POLICY'
doc_type: 'reference'
---

Creates a [row policy](../../../guides/sre/user-management/index.md#row-policy-management), i.e. a filter used to determine which rows a user can read from a table.

:::tip
Row policies make sense only for users with readonly access. If a user can modify a table or copy partitions between tables, it defeats the restrictions of row policies.
:::

Syntax:

```sql
CREATE [ROW] POLICY [IF NOT EXISTS | OR REPLACE] policy_name1 [ON CLUSTER cluster_name1] ON [db1.]table1|db1.*
        [, policy_name2 [ON CLUSTER cluster_name2] ON [db2.]table2|db2.* ...]
    [IN access_storage_type]
    [FOR SELECT] USING condition
    [AS {PERMISSIVE | RESTRICTIVE}]
    [TO {role1 [, role2 ...] | ALL | ALL EXCEPT role1 [, role2 ...]}]
```

## USING Clause {#using-clause}

Allows specifying a condition to filter rows. A user will see a row if the condition is calculated to non-zero for the row.

## TO Clause {#to-clause}

In the `TO` section you can provide a list of users and roles this policy should work for. For example, `CREATE ROW POLICY ... TO accountant, john@localhost`.

Keyword `ALL` means all the ClickHouse users, including current user. Keyword `ALL EXCEPT` allows excluding some users from the all users list, for example, `CREATE ROW POLICY ... TO ALL EXCEPT accountant, john@localhost`

## AS Clause {#as-clause}

It's allowed to have more than one policy enabled on the same table for the same user at one time. So we need a way to combine the conditions from multiple policies.

By default, policies are combined using the boolean `OR` operator. For example, the following policies:

```sql
CREATE ROW POLICY pol1 ON mydb.table1 USING b=1 TO mira, peter
CREATE ROW POLICY pol2 ON mydb.table1 USING c=2 TO peter, antonio
```

enable the user `peter` to see rows with either `b=1` or `c=2`.

The `AS` clause specifies how policies should be combined with other policies. Policies can be either permissive or restrictive. By default, policies are permissive, which means they are combined using the boolean `OR` operator.

A policy can be defined as restrictive as an alternative. Restrictive policies are combined using the boolean `AND` operator.

Here is the general formula:

```text
row_is_visible = (one or more of the permissive policies' conditions are non-zero) AND
                 (all of the restrictive policies's conditions are non-zero)
```

For example, the following policies:

```sql
CREATE ROW POLICY pol1 ON mydb.table1 USING b=1 TO mira, peter
CREATE ROW POLICY pol2 ON mydb.table1 USING c=2 AS RESTRICTIVE TO peter, antonio
```

enable the user `peter` to see rows only if both `b=1` AND `c=2`.

Database policies are combined with table policies.

For example, the following policies:

```sql
CREATE ROW POLICY pol1 ON mydb.* USING b=1 TO mira, peter
CREATE ROW POLICY pol2 ON mydb.table1 USING c=2 AS RESTRICTIVE TO peter, antonio
```

enable the user `peter` to see table1 rows only if both `b=1` AND `c=2`, although
any other table in mydb would have only `b=1` policy applied for the user.

## Engines which merge rows {#blending-table-engines}

`SummingMergeTree`, `AggregatingMergeTree`, `CoalescingMergeTree` and `GraphiteMergeTree` produce one
row out of all the rows with the same sorting key, and the values of that row come from all of them —
summed, aggregated, or taken from whichever row had a non-`NULL` value. A row policy cannot hide a row
from that merge, only from its result, and by then the values of the hidden rows are already in it.

```sql
CREATE TABLE test (key String, data1 Nullable(String), data2 Nullable(String))
ENGINE = CoalescingMergeTree ORDER BY key;

INSERT INTO test VALUES ('key', 'sensitive_data', 'top_secret');
INSERT INTO test VALUES ('key', 'not sensitive data', NULL);

CREATE ROW POLICY sensitive_filter ON test USING data1 != 'sensitive_data' TO accountant;
```

Once the two parts are merged, the table holds a single row `('key', 'not sensitive data', 'top_secret')`,
which passes the filter and shows `top_secret` to `accountant`.

A row policy on such a table is therefore rejected:

```text
Received exception:
Code: 36. DB::Exception: Table `default`.`test` has the CoalescingMergeTree engine, which merges rows with
the same sorting key into one row taking the values of all of them, so a row policy on this table does not
hide the values of the rows it filters out ...
```

Keep the raw rows in a plain `MergeTree` table and define the policy there, letting the users read a
pre-aggregated table which contains nothing they are not allowed to see.

If you still want the policy on the merging table, enable
[`allow_suspicious_row_policies_with_blending_engines`](/operations/settings/settings#allow_suspicious_row_policies_with_blending_engines):

```sql
SET allow_suspicious_row_policies_with_blending_engines = 1;
```

In that case filter by the sorting key columns — rows with the same sorting key are always hidden or shown
together, so nothing of a hidden row survives in a visible one:

```sql
CREATE ROW POLICY sensitive_filter ON test USING key != 'secret_key' TO accountant;
```

:::note
The check runs for `CREATE ROW POLICY` and `ALTER ROW POLICY` on an existing table; policies which were
created earlier keep working. On these engines the policy is always applied before `FINAL`, regardless of
[`apply_row_policy_after_final`](/operations/settings/settings#apply_row_policy_after_final), so at least
`FINAL` does not merge hidden rows into the result of a query.
:::

## ON CLUSTER Clause {#on-cluster-clause}

Allows creating row policies on a cluster, see [Distributed DDL](../../../sql-reference/distributed-ddl.md).

## Examples {#examples}

`CREATE ROW POLICY filter1 ON mydb.mytable USING a<1000 TO accountant, john@localhost`

`CREATE ROW POLICY filter2 ON mydb.mytable USING a<1000 AND b=5 TO ALL EXCEPT mira`

`CREATE ROW POLICY filter3 ON mydb.mytable USING 1 TO admin`

`CREATE ROW POLICY filter4 ON mydb.* USING 1 TO admin`
