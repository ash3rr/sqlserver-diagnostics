# Capturing an application's queries with Extended Events

This runbook records exactly what an application sends to the database while you reproduce a problem. You get every expensive call with its duration, CPU, reads and parameter values, then match it to what you clicked.

It exists for the case where polling the DMVs isn't enough. Polling `sys.dm_exec_requests` only sees queries that happen to be running at the moment you look, so fast but frequent calls slip through. Extended Events (XE) is SQL Server's built-in event tracing. It records each call as it completes, so nothing in the window is missed.

The scripts are written for Azure SQL Database with a database-scoped session. That is the setup you get on Microsoft-managed platforms such as a Dynamics 365 Finance and Operations sandbox reached with a just-in-time login.

## Files

- `capture-runbook.sql`: a permission check, a one-time setup, the per-run steps (start, save, confirm, stop), a status check and clean-up.
- `read-results.sql`: three ways to read saved captures, including matching API cursor fetches back to the SQL that opened them.

## How a run works

1. **Run the permission check.** You need `ALTER ANY DATABASE EVENT SESSION` or `CONTROL` on the database. `VIEW SERVER STATE` is not needed. This matters because tools such as `sp_BlitzWho` fail outright under logins without server-level state, while database-scoped sessions and DMVs work.
2. **Run the one-time setup.** It creates the session and the `dbo.app_capture_raw` table. Edit the application name filter once before you do.
3. **For each run:**
   1. Start the session (2a) on its own.
   2. Reproduce the problem in the application, noting the time of each action.
   3. Run the save (2b) and the confirm (2c) together. Check that `saved_utc` is just now and `event_count` looks plausible for what you did.
   4. Stop the session (2d) only after the confirm looks right.
4. **Read the results** with `read-results.sql` at any time afterwards.

Nothing needs editing between runs. Each save appends one row holding the whole raw ring buffer as XML, and the readers always pick the latest save.

## Design decisions

**Save before stopping.** The session uses a `ring_buffer` target, which keeps events in memory and needs no storage account. Stopping the session empties it. The save step copies the buffer into a table first. The order of 2b and 2d is the most important thing in the runbook. Get it wrong once and the capture is gone.

**Store the raw XML, shred later.** Saving the raw document is fast and keeps every field of every event. Shredding at save time is slow, and it forces you to decide in advance which fields matter. Query B in `read-results.sql` lists every field of every event when you need one that query A doesn't extract.

**A reads threshold, with an exception for cursor openings.** Applications send thousands of tiny calls. Without a threshold they fill the buffer and push out the events you care about, so the session keeps calls reading 1,000 pages or more. Cursor-opening calls are kept whatever they read, for the reason in the next section.

**Short runs.** The ring buffer's contents come back from `sys.dm_xe_database_session_targets` as a single XML document, and a very full buffer can come back with its oldest events missing. The `truncated` attribute shown by step 2c reports this. A larger `max_memory` does not prevent it, so the fix is to save and stop more often. The size limit on that read is not clearly documented, so rely on the `truncated` flag rather than a number.

## API cursors: where the SQL text actually is

Applications built on API cursors, such as the Dynamics 365 Finance and Operations application server, split each query across several calls:

- **Opening:** `sp_cursorprepexec` carries the full SQL text and the parameter values. The cursor number SQL Server assigns appears as `set @p2=NNN` in the captured statement.
- **Re-running:** `sp_cursorexecute <handle>` re-runs a prepared cursor and carries no text.
- **Fetching rows:** `sp_cursorfetch NNN,...` carries only the cursor number.

The expensive part is often the fetches, and they carry no SQL. At the statement level they also appear as `FETCH API_CURSOR...`, which names the cursor but never shows the SELECT.

To find out what a fetch was running, match its cursor number to the opening call with the same `@p2` value. Query C in `read-results.sql` does this. Where the opener was not captured, `opening_sql` is NULL, and anything said about that cursor's query is a guess.

This is also why the session captures every `sp_cursorprepexec` regardless of reads. The pattern that hurts most, `OPTION (FAST 1)` with a selective filter, is cheap to open and expensive to fetch. A reads-only filter drops exactly the opener you need. See `../patterns/fast-1-with-joined-filter.md`.

## Lining events up with what you did

Event timestamps are UTC. Note your own actions in local time and convert. Line up each action with the burst of events after it, and use the parameter values in the opening call (an order number, a company code) to confirm which screen produced which query. State which links are confirmed by the capture and which are your reading of the timing.

## On SQL Server (not Azure SQL Database)

The same approach works with a server-scoped session: `CREATE EVENT SESSION ... ON SERVER`, `sys.dm_xe_sessions` and `sys.dm_xe_session_targets` in place of the database-scoped views. On a server you control, an `event_file` target is usually the better choice, since it survives a stop.
