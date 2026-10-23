/* =====================================================================
   Reading saved captures from dbo.app_capture_raw
   These only read the table, never the live session, so they work after the
   session is stopped and can be run as often as you like.
   Each query reads the latest save. Change the TOP (1) ... ORDER BY save_id
   subquery to pick another one.
   ===================================================================== */


/* A. One row per event, most useful fields */
SELECT
    r.save_id,
    x.value('(@name)[1]',                                     'varchar(50)')   AS event_name,
    x.value('(@timestamp)[1]',                                'datetime2(7)')  AS utc_time,
    x.value('(data[@name="duration"]/value)[1]',              'bigint') / 1000 AS duration_ms,
    x.value('(data[@name="cpu_time"]/value)[1]',              'bigint') / 1000 AS cpu_ms,
    x.value('(data[@name="logical_reads"]/value)[1]',         'bigint')        AS logical_reads,
    x.value('(data[@name="physical_reads"]/value)[1]',        'bigint')        AS physical_reads,
    x.value('(data[@name="writes"]/value)[1]',                'bigint')        AS writes,
    x.value('(data[@name="row_count"]/value)[1]',             'bigint')        AS row_count,
    x.value('(data[@name="result"]/text)[1]',                 'varchar(20)')   AS result,
    x.value('(data[@name="object_name"]/value)[1]',           'nvarchar(128)') AS rpc_name,
    x.value('(action[@name="session_id"]/value)[1]',          'int')           AS session_id,
    x.value('(data[@name="statement"]/value)[1]',             'nvarchar(max)') AS statement_text
FROM (SELECT TOP (1) * FROM dbo.app_capture_raw ORDER BY save_id DESC) AS r
CROSS APPLY r.target_xml.nodes('RingBufferTarget/event') AS e(x)
ORDER BY utc_time;
GO


/* B. Every field of every event, one row per field. Use this when you need
      something query A does not extract. */
SELECT
    r.save_id,
    x.value('(@timestamp)[1]', 'datetime2(7)')  AS utc_time,
    x.value('(@name)[1]',      'varchar(50)')   AS event_name,
    f.value('local-name(.)',   'varchar(10)')   AS kind,        -- data or action
    f.value('(@name)[1]',      'varchar(60)')   AS field,
    f.value('(value)[1]',      'nvarchar(max)') AS value,
    f.value('(text)[1]',       'nvarchar(200)') AS value_text   -- e.g. result = OK
FROM (SELECT TOP (1) * FROM dbo.app_capture_raw ORDER BY save_id DESC) AS r
CROSS APPLY r.target_xml.nodes('RingBufferTarget/event') AS e(x)
CROSS APPLY x.nodes('data, action') AS d(f)
ORDER BY utc_time, kind, field;
GO


/* C. Match API cursor fetches to the SQL that opened them.

   Applications that use API cursors run each query in two kinds of call:
     - the opening call, sp_cursorprepexec (or sp_cursorexecute on re-run),
       carries the full SQL text and shows the cursor number in "set @p2=NNN"
     - every fetch, "exec sp_cursorfetch NNN,...", carries only that number
   So the expensive part (the fetches) has no SQL text of its own. This query
   pairs each cursor's fetches with its opening call by cursor number.
   A NULL opening_sql means the opener was not captured, and anything said
   about that cursor's query would be a guess. */
WITH ev AS (
    SELECT
        x.value('(@timestamp)[1]', 'datetime2(7)')                       AS utc_time,
        x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')      AS logical_reads,
        x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000    AS duration_ms,
        x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')   AS txt
    FROM (SELECT TOP (1) * FROM dbo.app_capture_raw ORDER BY save_id DESC) AS r
    CROSS APPLY r.target_xml.nodes('RingBufferTarget/event') AS e(x)
),
openers AS (
    SELECT
        utc_time,
        txt,
        SUBSTRING(txt, CHARINDEX('set @p2=', txt) + 8,
                  CHARINDEX(' ', txt + ' ', CHARINDEX('set @p2=', txt) + 8)
                  - (CHARINDEX('set @p2=', txt) + 8)) AS cursor_id
    FROM ev
    WHERE (txt LIKE '%sp_cursorprepexec%' OR txt LIKE '%sp_cursorexecute%')
      AND CHARINDEX('set @p2=', txt) > 0
),
fetches AS (
    SELECT
        utc_time,
        logical_reads,
        duration_ms,
        SUBSTRING(txt, CHARINDEX('sp_cursorfetch ', txt) + 15,
                  CHARINDEX(',', txt + ',', CHARINDEX('sp_cursorfetch ', txt) + 15)
                  - (CHARINDEX('sp_cursorfetch ', txt) + 15)) AS cursor_id
    FROM ev
    WHERE txt LIKE 'exec sp_cursorfetch %'
),
fetch_totals AS (
    SELECT
        cursor_id,
        COUNT(*)           AS fetches,
        SUM(logical_reads) AS fetch_reads,
        SUM(duration_ms)   AS fetch_ms
    FROM fetches
    GROUP BY cursor_id
),
first_opener AS (   -- one row per cursor, so a re-executed cursor does not double the totals
    SELECT cursor_id, utc_time, txt,
           ROW_NUMBER() OVER (PARTITION BY cursor_id ORDER BY utc_time) AS rn
    FROM openers
)
SELECT
    t.cursor_id,
    t.fetches,
    t.fetch_reads,
    t.fetch_ms,
    o.utc_time AS opened_utc,
    o.txt      AS opening_sql
FROM fetch_totals AS t
LEFT JOIN first_opener AS o ON o.cursor_id = t.cursor_id AND o.rn = 1
ORDER BY t.fetch_reads DESC;
GO
