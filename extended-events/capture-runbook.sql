/* =====================================================================
   Application query capture with a database-scoped Extended Events session
   Azure SQL Database (also works on SQL Server 2012+ with ON SERVER /
   server-level DMVs; see README).

   What it does: records every call from one application that reads at least
   1,000 pages, plus every API cursor opening, and saves the raw ring buffer
   to a permanent table so nothing is lost when the session stops.

   Edit once before the first run:
     - the client_app_name value (two places) to the application you are
       capturing. 'axOnline' is what Dynamics 365 Finance and Operations
       reports.
     - the logical_reads threshold if 1,000 pages is too noisy or too quiet.
   Nothing needs editing between runs.

   Times in the captured events are UTC.
   ===================================================================== */


/* ---------------------------------------------------------------------
   0. PERMISSION CHECK
   You need ALTER ANY DATABASE EVENT SESSION (or CONTROL) on the database.
   VIEW SERVER STATE is not needed: everything here is database-scoped.
   --------------------------------------------------------------------- */
SELECT
    HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'ALTER ANY DATABASE EVENT SESSION') AS can_create_xe,
    HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'CONTROL')                          AS has_control,
    HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE')              AS has_db_state,
    HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')                           AS has_server_state;
GO


/* ---------------------------------------------------------------------
   1. ONE-TIME SETUP
   --------------------------------------------------------------------- */

-- The session. rpc_completed catches calls made through RPC, which is how
-- applications using API cursors (sp_cursorprepexec / sp_cursorfetch) send
-- queries. The cursor-opening calls are captured regardless of their reads,
-- because a cursor that is cheap to open can be very expensive to fetch, and
-- only the opening call carries the SQL text.
IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'app_capture')
CREATE EVENT SESSION [app_capture] ON DATABASE
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.session_id, sqlserver.client_app_name)
    WHERE sqlserver.client_app_name = N'axOnline'
      AND (    logical_reads >= 1000
            OR object_name = N'sp_cursorprepexec'
            OR object_name = N'sp_cursorexecute' )
),
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (sqlserver.session_id, sqlserver.client_app_name)
    WHERE sqlserver.client_app_name = N'axOnline'
      AND logical_reads >= 1000
)
ADD TARGET package0.ring_buffer (SET max_memory = 51200)   -- 50 MB, in memory
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);
GO

-- One row per save, holding the entire raw ring buffer as XML. Storing the
-- raw document (instead of shredding it at save time) keeps every field of
-- every event, so you can extract fields later that you did not think of.
IF OBJECT_ID(N'dbo.app_capture_raw') IS NULL
CREATE TABLE dbo.app_capture_raw (
    save_id     int IDENTITY(1, 1) PRIMARY KEY,
    saved_utc   datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    target_xml  xml NOT NULL
);
GO


/* ---------------------------------------------------------------------
   2. EACH RUN
   Run 2a on its own, reproduce the problem, then run 2b and 2c together,
   check the result, and only then run 2d.
   --------------------------------------------------------------------- */

-- 2a. START
ALTER EVENT SESSION [app_capture] ON DATABASE STATE = START;
GO

-- (Reproduce the problem in the application now. Note the time of each
--  action so you can line the events up afterwards.)

-- 2b. SAVE the raw buffer while the session is still running.
INSERT INTO dbo.app_capture_raw (target_xml)
SELECT CAST(t.target_data AS xml)
FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
WHERE s.name = N'app_capture'
  AND t.target_name = N'ring_buffer';
GO

-- 2c. CONFIRM the save. saved_utc should be just now. truncated = 1 means the
--     buffer came back without its oldest events: make the next run shorter.
SELECT TOP (1)
    save_id,
    saved_utc,
    target_xml.value('(RingBufferTarget/@eventCount)[1]',           'int') AS event_count,
    target_xml.value('(RingBufferTarget/@totalEventsProcessed)[1]', 'int') AS events_seen,
    target_xml.value('(RingBufferTarget/@truncated)[1]',            'int') AS truncated,
    target_xml.value('(RingBufferTarget/@droppedCount)[1]',         'int') AS dropped,
    target_xml.value('(RingBufferTarget/@memoryUsed)[1]',           'int') AS memory_used_bytes
FROM dbo.app_capture_raw
ORDER BY save_id DESC;
GO

-- 2d. STOP. Stopping empties the ring buffer, which is why 2b comes first.
ALTER EVENT SESSION [app_capture] ON DATABASE STATE = STOP;
GO


/* ---------------------------------------------------------------------
   3. STATUS (when "nothing" comes back)
   No row: the session was dropped. state = stopped: anything it held is gone.
   running with events_seen = 0: nothing passed the filter yet.
   --------------------------------------------------------------------- */
SELECT
    es.name,
    CASE WHEN ds.name IS NULL THEN 'stopped' ELSE 'running' END                              AS state,
    CAST(t.target_data AS xml).value('(RingBufferTarget/@eventCount)[1]', 'int')           AS events_held,
    CAST(t.target_data AS xml).value('(RingBufferTarget/@totalEventsProcessed)[1]', 'int') AS events_seen
FROM sys.database_event_sessions AS es
LEFT JOIN sys.dm_xe_database_sessions        AS ds ON ds.name = es.name
LEFT JOIN sys.dm_xe_database_session_targets AS t  ON t.event_session_address = ds.address
WHERE es.name = N'app_capture';
GO


/* ---------------------------------------------------------------------
   4. CLEAN UP when the investigation is finished
   --------------------------------------------------------------------- */
-- DROP EVENT SESSION [app_capture] ON DATABASE;
-- DROP TABLE dbo.app_capture_raw;
