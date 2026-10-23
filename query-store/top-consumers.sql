/* =====================================================================
   Query Store: find the queries doing the most total work
   SQL Server 2016+ and Azure SQL Database, Query Store enabled.

   Rank by total logical reads (average reads per execution x executions).
   A query reading 50,000 pages 10 times a month costs far less than one
   reading 18,000 pages 843,000 times a month, so neither frequency nor
   per-run cost alone is the right ranking.
   ===================================================================== */

DECLARE @days int = 30;   -- look-back window

WITH stats AS (
    SELECT
        p.query_id,
        rs.plan_id,
        SUM(rs.count_executions)                                AS executions,
        SUM(rs.avg_logical_io_reads * rs.count_executions)      AS total_reads,
        SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0     AS total_cpu_ms,
        SUM(rs.avg_duration * rs.count_executions) / 1000.0     AS total_duration_ms,
        MAX(rs.max_logical_io_reads)                            AS max_reads_one_run
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i
        ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    WHERE i.start_time >= DATEADD(DAY, -@days, SYSUTCDATETIME())
    GROUP BY p.query_id, rs.plan_id
)
SELECT TOP (25)
    s.query_id,
    s.plan_id,
    s.executions,
    CAST(s.total_reads AS bigint)                         AS total_reads,
    CAST(s.total_reads / NULLIF(s.executions, 0) AS int)  AS avg_reads,
    CAST(s.max_reads_one_run AS bigint)                   AS max_reads_one_run,
    CAST(s.total_cpu_ms AS bigint)                        AS total_cpu_ms,
    CAST(s.total_duration_ms AS bigint)                   AS total_duration_ms,
    LEFT(qt.query_sql_text, 300)                          AS query_text_start
FROM stats AS s
JOIN sys.query_store_query      AS q  ON q.query_id = s.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
ORDER BY s.total_reads DESC;
GO

/* Full text of one query. Save the result to a file: the grid truncates
   long text. */
DECLARE @plan_id bigint = 0;   -- set from the list above

SELECT p.plan_id, q.query_id, qt.query_sql_text
FROM sys.query_store_plan       AS p
JOIN sys.query_store_query      AS q  ON q.query_id = p.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE p.plan_id = @plan_id;
GO

/* Is Query Store actually recording? If actual_state_desc is READ_ONLY, new
   queries are not being captured, and a missing query proves nothing. */
SELECT actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb, query_capture_mode_desc
FROM sys.database_query_store_options;
GO
