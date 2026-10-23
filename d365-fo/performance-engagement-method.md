# Running a database performance engagement on a managed ERP

This is a method for a fixed-scope performance diagnostic, typically one to three months, on an application database you don't fully control. Dynamics 365 Finance and Operations is the worked case, but the shape applies to any packaged application.

The deliverable is a root-cause report with prioritised, evidenced fixes, split between what the platform team can apply and what goes to the application developers.

## 1. Baseline: find out what is measured (week 1)

- **Get access sorted on day one.** That means the sandbox database (JIT login), whichever monitoring portal the environment uses, Application Insights if it exists, and a sandbox refreshed from production for invasive testing.
- **Check that the telemetry is actually working.** Is Query Store capturing, or read-only? Is Application Insights wired up? The first finding on these engagements is often that nothing is being read.
- **Turn "it's slow" into specific symptoms.** Which screens or batch jobs, which users, at what times, how slow, and since when.
- **Define the measures you will report against.** For example: P95 response time for named screens, completion time for named batch jobs, and top queries by total reads, CPU and duration.

## 2. Triage on the evidence you have (weeks 1 to 2)

- Rank queries by total work in Query Store (`../query-store/top-consumers.sql`). Remember that total work is reads per run multiplied by runs.
- For the top few, pull the plans and compare cheap and expensive variants (`../query-store/plan-xpath.sql`).
- Classify each problem by mechanism: CPU, I/O, blocking, plan regression, or a query-shape problem such as `FAST 1` with a selective joined filter (`../patterns/fast-1-with-joined-filter.md`).

## 3. Reproduce in the sandbox (weeks 2 to 3)

- Capture the application's real calls while reproducing the user action (`../extended-events/`), so you have the exact query text and parameters for each step.
- Run the captured query with an actual execution plan. Then test each hypothesis, such as a different sort, removing the hint or adding an index, and compare actual reads.
- Record what reproduces and what doesn't. Concurrency problems usually won't reproduce here.

## 4. Split the fixes

- **Platform side:** statistics, plan forcing for genuine regressions, batch scheduling and parallelism, cleanup job scheduling, number sequence settings.
- **Application side, as recommendations:** index additions in the application metadata, query shape changes, set-based rewrites of row-by-row loops, trimming selected fields, caching settings.

## 5. Report

For each finding, give the user-visible symptom, the query and how it was identified, the cost measured as reads, runs and time, the mechanism, the proposed fix, and the expected and (where tested) measured effect. Mark each claim as read from evidence, measured, or inferred. Order the findings by impact against effort.

## Working notes

- Keep a log of every capture: the time of each user action in local time and UTC, what was clicked, and which save it went into. Matching events to actions is most of the work.
- When a finding changes, update the report draft immediately, and hold back recommendations to developers until the screen and query are confirmed. Developers will act on a recommendation as written, even if it names the wrong screen.
