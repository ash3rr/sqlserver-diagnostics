/* =====================================================================
   Reading Query Store plans with XPath
   Query Store keeps each plan as showplan XML. These queries pull specific
   fields out of it, so you can compare plans without opening each one in a
   graphical viewer, and see fields the viewer hides.

   See README.md for how to read the XPath expressions.
   ===================================================================== */

-- The plans to compare: for example one cheap and one expensive variant of
-- the same query.
DECLARE @plans TABLE (plan_id bigint PRIMARY KEY);
INSERT INTO @plans (plan_id) VALUES (0), (0);   -- replace with real plan_ids


/* 1. Every operator in each plan: what it is, what it reads, how it reads it,
      and what the optimizer expected. */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
plans AS (
    SELECT p.plan_id, TRY_CAST(p.query_plan AS xml) AS x
    FROM sys.query_store_plan AS p
    JOIN @plans AS f ON f.plan_id = p.plan_id
)
SELECT
    pl.plan_id,
    r.value('@NodeId',              'int')            AS node_id,
    r.value('@PhysicalOp',          'varchar(60)')    AS physical_op,
    r.value('@LogicalOp',           'varchar(60)')    AS logical_op,
    r.value('@EstimateRows',        'float')          AS est_rows,
    r.value('@EstimatedRowsRead',   'float')          AS est_rows_read,
    r.value('@EstimatedTotalSubtreeCost', 'float')    AS est_subtree_cost,
    -- */Object looks only at this operator's own child element (IndexScan,
    -- TableScan, ...), not at operators further down the tree.
    r.value('(*/Object/@Table)[1]', 'nvarchar(260)')  AS table_name,
    r.value('(*/Object/@Index)[1]', 'nvarchar(260)')  AS index_name,
    r.value('(IndexScan/@ScanDirection)[1]', 'varchar(20)') AS scan_direction,
    r.value('(IndexScan/@Ordered)[1]',       'varchar(5)')  AS ordered
FROM plans AS pl
CROSS APPLY pl.x.nodes('//RelOp') AS n(r)
ORDER BY pl.plan_id, node_id;
GO


/* 2. Seek predicate versus residual predicate on one operator.
      The seek predicate is what the index jumps to. The residual predicate
      is checked row by row after the jump. A selective condition that only
      appears in the residual is the usual sign of a seek that is really a
      scan of a range. */
DECLARE @plan_id bigint = 0;   -- replace
DECLARE @node    int    = 0;   -- the NodeId of the operator reading the big table

WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
    p.plan_id,
    r.value('@PhysicalOp', 'varchar(60)')                                 AS physical_op,
    r.query('IndexScan/SeekPredicates')                                   AS seek_predicates,
    r.query('IndexScan/Predicate')                                        AS residual_predicate
FROM sys.query_store_plan AS p
CROSS APPLY (SELECT TRY_CAST(p.query_plan AS xml) AS x) AS c
CROSS APPLY c.x.nodes('//RelOp[@NodeId=sql:variable("@node")]') AS n(r)
WHERE p.plan_id = @plan_id;
GO


/* 3. Compiled parameter values: what each parameter held when the plan was
      built. Useful for parameter sniffing, and for seeing what an
      application actually sends (for example the same value repeated in
      every branch of an OR chain). */
DECLARE @plan_id bigint = 0;   -- replace

WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
    p.plan_id,
    pr.value('@Column',                 'varchar(30)')    AS parameter,
    pr.value('@ParameterDataType',      'varchar(60)')    AS data_type,
    pr.value('@ParameterCompiledValue', 'nvarchar(400)')  AS compiled_value
FROM sys.query_store_plan AS p
CROSS APPLY (SELECT TRY_CAST(p.query_plan AS xml) AS x) AS c
CROSS APPLY c.x.nodes('//ParameterList/ColumnReference') AS n(pr)
WHERE p.plan_id = @plan_id
ORDER BY p.plan_id, parameter;
GO


/* 4. Hints and plan-level settings: OPTION (FAST n), optimizer goal,
      and the cardinality estimator version. */
DECLARE @plan_id bigint = 0;   -- replace

WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
    p.plan_id,
    s.value('@StatementOptmLevel',      'varchar(20)')  AS optimization_level,
    s.value('@CardinalityEstimationModelVersion', 'int') AS ce_version,
    s.value('@StatementOptmEarlyAbortReason', 'varchar(40)') AS early_abort_reason,
    CASE WHEN qt.query_sql_text LIKE '%FAST 1%' THEN 1 ELSE 0 END AS has_fast_1
FROM sys.query_store_plan AS p
JOIN sys.query_store_query      AS q  ON q.query_id = p.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
CROSS APPLY (SELECT TRY_CAST(p.query_plan AS xml) AS x) AS c
CROSS APPLY c.x.nodes('//StmtSimple') AS n(s)
WHERE p.plan_id = @plan_id;
GO
