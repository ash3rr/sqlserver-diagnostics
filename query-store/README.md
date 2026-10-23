# Query Store: finding and reading expensive plans

Query Store is SQL Server's built-in record of which queries ran, how often, what they cost, and which execution plans they used. On a platform where you can't run your own tracing in production, it is often the main source of evidence you have.

These scripts answer two questions:

1. Which queries cost the most in total? (`top-consumers.sql`)
2. What exactly is the plan for one of them doing, and how does it differ from a cheaper plan for the same query? (`plan-xpath.sql`)

## Ranking: total work, not frequency or per-run cost

`top-consumers.sql` ranks by total logical reads over the window. That is average reads per run multiplied by number of runs. A logical read is one 8 KB page read from memory or disk. It is the most stable measure of how much work a query does, because duration and CPU vary with load.

The product is what matters:

- A query reading 50,000 pages per run, run 10 times a month, totals 500,000 pages.
- A query reading 18,000 pages per run, run 843,000 times a month, totals about 15 billion pages.

The second query is the one to fix, and neither number alone tells you that.

`top-consumers.sql` also checks whether Query Store is in `READ_ONLY` mode. A read-only Query Store has stopped capturing, so a query being absent from it proves nothing.

## Reading plan XML with XPath

A plan is a tree of operators, the individual steps such as an index seek, a nested loop join or a filter. Each operator has a number, its `NodeId`, and data flows from the leaves up to the root. Query Store stores each plan as an XML document, and `plan-xpath.sql` pulls specific fields out of it.

Each expression picks a step, then reads a field from it:

```
//RelOp[@NodeId="21"]/IndexScan/@ScanDirection
```

- `//RelOp` finds any operator in the plan. `RelOp` is the showplan name for an operator.
- `[@NodeId="21"]` is a condition: only the operator whose NodeId is 21.
- `/IndexScan` steps into the section describing how that operator reads the index. Seeks are also described in an element called `IndexScan`.
- `/@ScanDirection` at the end is a request, not a condition. It returns the field's value, `FORWARD` or `BACKWARD`.

So an `@` inside square brackets filters, and an `@` after the final slash reads a value. In SQL these expressions go into `.nodes()` (one row per match) and `.value()` (one value from each row).

## What the four queries in plan-xpath.sql show

1. **Every operator.** For each one: its type, table and index, scan direction, and the optimizer's estimated rows and estimated rows read. Comparing the cheap and expensive plans of the same query side by side usually shows where they diverge.
2. **Seek versus residual predicate for one operator.** The seek predicate is what the index jumps to. The residual predicate is checked row by row after the jump. If a seek's predicate only narrows to a company or partition, and the selective condition sits in the residual, it is really a range scan.
3. **Compiled parameter values.** These are the values each parameter held when the plan was compiled. Use them for parameter sniffing questions, and to see what the application actually sends, such as the same value repeated in every branch of a generated `OR` chain.
4. **Plan-level settings and hints.** Optimization level, cardinality estimator version, and whether the statement carries `OPTION (FAST 1)`.

## Estimates are not actuals

Query Store plans are estimated plans. `EstimatedRowsRead` is what the optimizer expected, not what happened. When the estimate is around 20 rows and the runtime stats say 18,000 pages per execution, the gap is the finding. Confirming how far an operator really reads needs an actual execution plan. To get one, run the captured query text with its real parameter values in a non-production copy, with actual plans switched on, and read `ActualRowsRead` on the operator.

Keep three kinds of statement apart when reporting:

- **Read from the plan:** for example, "the seek jumps only to the company's block, the order number is a residual check".
- **Measured:** runtime stats, or an actual plan.
- **Inferred:** why the optimizer chose the plan. The optimizer doesn't record its reasons.
