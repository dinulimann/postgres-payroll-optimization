# PostgreSQL Payroll Optimization: 28 s → 0.2 s

A reproducible case study of speeding up a monthly payroll stored procedure in PostgreSQL, **without changing a single number in the output**.

It is based on work I did on a production payroll system for roughly 5,000 employees, where the monthly run took more than 10 minutes and ended up under 1 minute. That code and data belong to a client, so this repository rebuilds the same problem from scratch with a simplified schema and **fully synthetic data**. Every name, rate and amount here is generated.

## Results

5,000 employees, one month (6,035 assignment segments, 147,024 attendance rows), PostgreSQL 16 in Docker on an Apple Silicon laptop:

| Version | What changed | Time | Speed-up |
|---|---|---:|---:|
| **v1** | Row-by-row loop, a helper function per salary component, no indexes | 28.01 s | 1x |
| **v1 + indexes** | Same code, three indexes that match the access pattern | 0.82 s | 34x |
| **v2** | Loop kept; parameters, rates, attendance and deductions computed once up front | 0.30 s | 93x |
| **v3** | Fully set-based: two `INSERT ... SELECT` statements, no loops | 0.20 s | 140x |

Every optimized run is checked row by row against v1 (`sql/07_verify.sql`): **0 differing rows** in both the detail and summary tables, same total net pay to the cent. Full output: [docs/results.md](docs/results.md).

## The problem

The payroll rules are simplified but keep the parts that make real payroll code slow:

- **Mid-month changes.** About 20% of employees change grade or position during the month, so their pay is split into segments and each segment is prorated by days.
- **Daily attendance.** Present and paid-leave days count for base salary and fixed allowance. Only present days count for the performance incentive.
- **Joiners and leavers** in the middle of the month.
- **Ordered deductions with a floor.** Health insurance (capped basis), pension, cooperative (mandatory, voluntary) and loan installments are taken in order. Take-home pay may never drop below a minimum, so each deduction is reduced if needed.

## What was slow in v1

[`sql/03_v1_naive.sql`](sql/03_v1_naive.sql) is written the way these procedures usually grow: loop over employees, loop over segments, call a small function for each component. Each piece is fine on its own. Together they add up:

1. **Lookups without a matching index.** Attendance, assignments and loans are all read per employee, but no index started with `employee_id`. Every lookup scanned far more rows than it returned.
2. **The same parameter read thousands of times.** `v1_param('min_take_home')` runs inside the deduction guard: 5 times per employee, 25,000 queries for one value.
3. **The same rows read twice.** Attendance is counted once for paid days and again for present days. Cooperative data is fetched once for each column.
4. **One statement per row.** Every detail and summary row is its own `INSERT`.

## How it was fixed

**Step 1: indexes** ([`sql/04_indexes.sql`](sql/04_indexes.sql)). Three indexes that match how the procedure actually reads data, including a covering index on attendance and a partial index on active loans. No code changes, **34x faster**. Always check this first: `EXPLAIN (ANALYZE, BUFFERS)` on the queries inside the loop.

**Step 2: take repeated work out of the loop** ([`sql/05_v2_cached.sql`](sql/05_v2_cached.sql)). This keeps the step-by-step structure, which matters when the business rules are complicated and the team is used to reading them that way:
- parameters loaded once into variables
- every segment's day counts and rates built in **one** query into a temp table
- cooperative and loan totals pre-aggregated per employee

**Step 3: set-based** ([`sql/06_v3_set_based.sql`](sql/06_v3_set_based.sql)). The deduction floor looks inherently sequential, but each step only depends on the running balance from the previous step. That makes it a chain of `LATERAL` subqueries. The whole run becomes two statements.

### Which one to ship?

v3 is fastest, but v2 is often the better production choice. The gap between them is 0.1 s, while v2 is much easier for the next developer to extend with a new allowance or a special case. On the real system I shipped the v2 approach (temp tables, caching, pre-fetched parameters), and checked every change against the previous version's output for all employees before deploying.

## Run it yourself

Requires Docker.

```bash
./scripts/bench.sh          # 5,000 employees
./scripts/bench.sh 20000    # or any size
```

The script starts PostgreSQL 16, creates the schema, generates the data, times all four versions, verifies them against v1 and writes `docs/results.md`.

## Layout

```
sql/01_schema.sql        tables (primary keys only)
sql/02_seed.sql          synthetic data generator (deterministic seed)
sql/03_v1_naive.sql      the "before" procedure
sql/04_indexes.sql       step 1
sql/05_v2_cached.sql     step 2
sql/06_v3_set_based.sql  step 3
sql/07_verify.sql        row-by-row comparison against v1
scripts/bench.sh         runs everything and writes docs/results.md
```

## Tech

PostgreSQL 16 · PL/pgSQL · Docker · Bash
