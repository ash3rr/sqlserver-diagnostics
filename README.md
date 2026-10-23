# sqlserver-diagnostics

Runbooks and scripts for finding out why a SQL Server or Azure SQL Database workload is slow. They are aimed at the hard case: a database behind a packaged application, where you can't change the code, your access is limited, and the evidence has to be good enough to hand to the application's developers.

| Folder | What it is for |
|---|---|
| [`extended-events/`](extended-events/) | Capturing every expensive call an application makes while you reproduce a problem, saving it before it is lost, and matching API cursor fetches back to their SQL. |
| [`query-store/`](query-store/) | Ranking queries by total work, and reading Query Store plan XML with XPath to compare cheap and expensive plans of the same query. |
| [`patterns/`](patterns/) | Write-ups of specific performance mechanisms, starting with `OPTION (FAST 1)` combined with filters or sorts on joined tables. |
| [`d365-fo/`](d365-fo/) | What database access and tooling you actually get on Dynamics 365 Finance and Operations, and a method for a fixed-scope performance engagement. |

## Where to start

- **"This screen is slow"**: capture it with `extended-events/capture-runbook.sql` while you reproduce it, then read it with `extended-events/read-results.sql`.
- **"The database is busy and we don't know why"**: rank by total reads with `query-store/top-consumers.sql`, then compare plans with `query-store/plan-xpath.sql`.
- **A query that reads millions of pages to return one row, with `FAST 1` in its text**: read `patterns/fast-1-with-joined-filter.md`.

## Compatibility

The scripts target Azure SQL Database and SQL Server 2016 or later. The Extended Events scripts use database-scoped sessions (Azure SQL Database). The README in that folder notes the server-scoped equivalent.

## Conventions

- Every script reads by default. Anything that creates or drops objects is in a clearly labelled section.
- Findings are reported as one of three kinds: read from evidence (a plan, a capture), measured (runtime stats, an actual plan), or inferred. The write-ups keep those apart.

## License

MIT
