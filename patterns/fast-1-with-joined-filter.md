# OPTION (FAST 1) with a filter or sort on a joined table

## Symptom

A list screen in a line-of-business application is usually fast. It becomes extremely slow when a user filters on a column from a related table (a location, a customer group, a route), or opens a record and the application looks up the next and previous record.

In Extended Events or Query Store this shows up as:

- an API cursor that is cheap to open and very expensive to fetch, with millions of logical reads per fetch
- `OPTION (FAST 1)` in the query text
- an estimated rows read of a few dozen in the plan, against runtime reads many orders of magnitude higher

## What FAST 1 does

`OPTION (FAST 1)` changes what the optimizer aims for. Normally it picks the plan that finishes the whole query most cheaply. With `FAST 1`, it picks the plan that returns the first row soonest, even if the full query then costs far more. Applications that show results in a scrolling grid add it so the first screen of rows appears quickly. Dynamics 365 Finance and Operations does this through the `firstFast` setting on a form's query data source (`QueryBuildDataSource.firstFast`).

## Why it goes wrong

Take a list sorted by order number and filtered on a location stored on a joined address table. There are two ways to run it:

1. **Collect then sort.** Find all orders at that location through the join, then sort them by order number. This is cheap overall, but nothing comes out until the sort is done, so under `FAST 1` it looks expensive.
2. **Walk then check.** Walk the order-number index in sort order. For each order, look up its location through the joins, and return it if it matches. Rows can stream out immediately, so under `FAST 1` this plan looks cheap.

`FAST 1` picks the second plan. That plan bets a match will turn up within the first few rows. For a selective filter, such as a location with few orders, the bet loses. Each fetch walks through huge numbers of orders, with a set of join lookups for each one, before finding the next match.

The plan's own estimate shows the bet. It expects to read a handful of rows, because it assumes matches are spread evenly through the index.

## The same mechanism with paging

Grids page through results with a "rows after the last one shown" condition. When the sort uses several columns in mixed directions, for example order number descending plus several tie-breaker columns ascending, the application has to expand that condition into an `OR` chain with one branch per sort column:

```sql
WHERE (T1.ORDERID < @p1)
   OR (T1.ORDERID = @p1 AND T2.NAME > @p2)
   OR (T1.ORDERID = @p1 AND T2.NAME = @p2 AND T3.CITY > @p3)
   ...
```

An `OR` chain like this can't be used as a single seek range. The index seek narrows only to the leading columns, such as the company code, and the order-number condition becomes a residual check on every row. With `FAST 1` and a descending walk, finding the rows before an old record means reading through almost the whole company's block of orders. Finding the rows after it is cheap, because the match is adjacent. That asymmetry, one direction cheap and the other expensive, is a useful fingerprint of this pattern.

## Fix candidates

All of these are application-side changes, delivered by the application's developers. Test each in a non-production copy by comparing actual reads before and after.

- **Sort on a unique key only, where the screen allows it.** Then the paging condition collapses to `ORDERID < @last`, which seeks directly.
- **Turn off `FAST 1` for the data source**, so the optimizer can choose collect-then-sort for selective filters. Confirm the hint is actually gone from the captured query text afterwards, because some frameworks add it regardless.
- **Index the linking column for commonly used joined filters.** For a filter on an address's location, the index belongs on the work order table's address foreign key, not on the location itself. Choose which filters get indexes from Query Store or from asking users, because indexing every column is not an option.
- **Restrict filtering on unindexed joined columns** in the UI. This is effective but usually the harder conversation with users.

Database-side workarounds are limited here. Query Store hints add hints to a query. They don't remove one already in the query text, and the documented hints include none that cancels `FAST n`. Plan forcing only chooses among plans compiled for the same query text, which already carries the hint. On a Microsoft-managed production database you can't apply either yourself anyway. That leaves the application change as the real fix.
