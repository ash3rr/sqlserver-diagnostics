# Dynamics 365 Finance and Operations: what you can see at the database layer

Dynamics 365 Finance and Operations (F&O) runs on Azure SQL Database managed by Microsoft. A database engineer's first question on an F&O performance engagement is which tools will actually work. The answer depends on the environment tier.

## Non-production (sandbox, test, UAT)

You can connect directly with SSMS or Azure Data Studio and run T-SQL. Access is just-in-time (JIT): you request it in Lifecycle Services (LCS) or the Power Platform admin center for the environment, receive a server name and a temporary login, and allow your IP address in the firewall.

A JIT login is database-scoped. In practice that means:

- **Database-level DMVs and Query Store work.** These need `VIEW DATABASE STATE`.
- **Database-scoped Extended Events sessions work**, if the login has `ALTER ANY DATABASE EVENT SESSION` or `CONTROL`. See `../extended-events/`.
- **Server-level views and tools that need them fail.** These need `VIEW SERVER STATE` / `VIEW SERVER PERFORMANCE STATE`, and `sp_BlitzWho` is a common example.

Check what you have before planning around a tool. The permission query at the top of `../extended-events/capture-runbook.sql` does this.

A sandbox refreshed from production gives you production's data, and its Query Store history up to the refresh. It does not give you production's concurrency. Blocking, lock escalation and number-sequence contention rarely reproduce in a quiet sandbox.

## Production

There is no direct SQL access to production. The evidence comes from:

- Microsoft's monitoring in LCS or the Power Platform admin center: SQL insights such as current blocking and expensive queries, and system CPU and memory over time. Microsoft has been moving this monitoring to Application Insights, so check which applies to your environment.
- Application Insights, if the customer has configured it: slow queries at the application server level, with call stacks. Its slow-query telemetry is usually enabled in sandboxes only, because of volume.
- Trace Parser traces of specific user actions.
- The Query Store history that comes across with a sandbox refresh.

You don't see host-level counters for the database server. Resource pressure has to be inferred from blocking, waits and query duration.

## Who fixes what

Indexes in F&O are defined on tables in the application metadata and deployed through the development pipeline, not created with `CREATE INDEX` against the database. Query shape (sorts, filters, `firstFast`, set-based versus row-by-row X++) also lives in application code. So the database engineer's deliverable is usually a precise, evidenced recommendation for the developers. It covers which query, which screen or batch, how much it costs, which mechanism causes it, and the proposed change with expected effect, tested in a sandbox where possible.

Changes on the platform side, made through supported tooling and change control, include statistics, plan forcing for regressions where available, batch job scheduling and parallelism, number sequence preallocation, and scheduling of the standard cleanup jobs.
