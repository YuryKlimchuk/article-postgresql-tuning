# Your PostgreSQL Is an F1 Car. Stop Driving in First Gear
## Part 2: EXPLAIN ANALYZE and Seq Scan — Learning to Read Query Plans

In [Part 1](https://medium.com/@hydro.yura/your-postgresql-is-an-f1-car-stop-driving-in-first-gear-a901055d00c3), we spun up two PostgreSQL instances — a small DB (`payment_small`, ~50K transactions) and a large one (`payment_large`, ~5M transactions). Now it's time to fire up our first queries and see how PostgreSQL fetches data.

**In this part:** we'll learn to read `EXPLAIN ANALYZE` and break down the simplest (but not always fastest) access method — sequential scanning. We'll see with our own eyes how the same query behaves completely differently on 50 thousand rows vs 5 million.

---

## 1. EXPLAIN ANALYZE — Your New Best Friend

Before we dive into scan types, we need to learn how to look under PostgreSQL's hood. That's what `EXPLAIN` is for.

### EXPLAIN vs EXPLAIN ANALYZE

There's an important distinction:

- **`EXPLAIN`** — shows the *plan* the PostgreSQL planner built for a query. The query is **not executed**; you only see cost estimates.
- **`EXPLAIN (ANALYZE)`** — **executes** the query and shows real metrics: how long it took, how many rows were read, how much memory was used.

**Always use `EXPLAIN (ANALYZE, BUFFERS)`** when debugging `SELECT` queries. For `UPDATE`/`DELETE`, wrap in a transaction with `ROLLBACK` so you don't modify data. Even a `SELECT` without `LIMIT` in production can hammer the disk — be careful.

### Key Metrics in the Output

Run this query on **both** databases (update statistics first):

```sql
-- Disable JIT to keep output clean (JIT is a topic for another day)
SET jit = OFF;

-- Disable parallel workers so the output matches the article examples
SET max_parallel_workers_per_gather = 0;

-- Refresh statistics (the init scripts already ran ANALYZE, just to be safe)
ANALYZE transactions;

-- Test query
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

You'll see something like:

### Small DB (50K transactions)

```
 Seq Scan on transactions  (cost=0.00..1845.00 rows=25224 width=155)
                           (actual time=0.007..5.138 rows=25175 loops=1)
   Filter: (amount > '5000'::numeric)
   Rows Removed by Filter: 24825
   Buffers: shared hit=1220
 Planning Time: 0.056 ms
 Execution Time: 5.808 ms
```

### Large DB (5M transactions)

```
 Seq Scan on transactions  (cost=0.00..218750.00 rows=2533332 width=214)
                           (actual time=0.024..675.241 rows=2503844 loops=1)
   Filter: (amount > '5000'::numeric)
   Rows Removed by Filter: 2496156
   Buffers: shared hit=2702 read=153548
 Planning Time: 0.057 ms
 Execution Time: 735.447 ms
```

Let's break down the metrics with real numbers from both databases:

| Metric | Small DB (`payment_small`) | Large DB (`payment_large`) | What it means |
|--------|---------------------------|------------------------------|---------------|
| **cost** | `0.00..1845.00` | `0.00..218750.00` | Cost estimate in abstract units. The 118× growth (218750 / 1845) reflects the data volume increase. Cost is the planner's estimate, not real time. |
| **actual time** | `0.007..5.138 ms` | `0.024..675.241 ms` | Real time: first number is time to the first row, second is total. |
| **rows** | `25,175` | `2,503,844` | Rows returned by this node. Exactly ×100 — more data, proportionally more results. |
| **width** | `155` bytes | `214` bytes | Average row size. Width is larger on the large DB because `description` is longer (`repeat(..., 5)` vs `repeat(..., 3)`). TOAST hasn't kicked in at this size yet — we'll cover that in Part 5. |
| **Buffers** | `hit=1220` | `hit=2702, read=153,548` | 8 KB pages. Small DB: everything in cache (1220 × 8 KB ≈ 10 MB). Large DB: 2,702 in cache + 153,548 from disk (~1.2 GB). The default `shared_buffers = 128 MB` can't fit the 5M-row table — hence `read`. |
| **Rows Removed by Filter** | `24,825` | `2,496,156` | Rows read and discarded. Seq Scan checked every row — half didn't match. |
| **Planning Time** | `0.056 ms` | `0.057 ms` | Plan construction time. Nearly identical! PostgreSQL doesn't "think slower" on big data — the problem is execution, not planning. |
| **Execution Time** | `5.8 ms` | `735.4 ms` | Pure execution time. ×127 with ×100 data — nearly linear scaling. |

Four takeaways from this table:

1. **Execution Time is ×127 higher** with ×100 the data — Seq Scan reads everything, so time scales linearly with volume.
2. **`Rows Removed by Filter: 2,496,156`** — PostgreSQL read 5 million rows and threw half of them away. Seq Scan can't skip — it checks every single one.
3. **`Buffers: read=153,548`** (~1.2 GB from disk). The default `shared_buffers = 128 MB` simply can't hold the table — hence the disk reads. Verify: `SHOW shared_buffers;`. On the small DB, everything fits in cache.
4. **`Planning Time` is nearly identical** — 0.056 vs 0.057 ms. PostgreSQL doesn't "get slower at planning" on big data. The problem is always execution (`Execution Time` grows 127×), not planning.

---

## 2. Sequential Scanning (Seq Scan)

### What Happens

PostgreSQL reads **the entire table** page by page, checking every row against the `WHERE` clause. It's the simplest method, but not always the fastest.

### Example: No Index

Here's the familiar query from Part 1:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

There's no index on `amount` → PostgreSQL has no choice but to read the whole table. On the small DB, this takes milliseconds; on the large DB, seconds.

### Seq Scan Even With an Index — Important Nuance

Now a query with an index:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric = 643;
```

There **is an index** on `currency_numeric` (we created it in `schema.sql`). But the planner picks different strategies depending on data volume:

**Small DB (50K rows, 1 currency = 10,000 rows / 20%):** the planner picks **Bitmap Heap Scan** — a middle ground between Index Scan and Seq Scan (we'll cover it in detail in Part 4).

**Large DB (5M rows, 1 currency = 1,000,000 rows / 20%):** the planner picks **Seq Scan**. Same query, same percentage — but at this scale, even 20% is a million rows, and the planner decides: "easier to read it all sequentially."

The reason comes down to the cost ratio of sequential vs random reads (covered in detail in the next section):

**Rule of thumb:** if the planner estimates it needs to fetch **> 5–15% of rows**, it may pick Seq Scan. The exact threshold depends on `random_page_cost` (default 4.0) and `effective_cache_size`. On SSD, `random_page_cost` is often lowered to 1.5 — raising the threshold, so Seq Scan kicks in **later** (the planner sticks with indexes longer).

**Verify on the small DB:** you'll get Bitmap Heap Scan, not Index Scan (more on that in Part 4). It'll be instant — an "inefficient" plan is no problem at small scale.

### The Threshold: Bitmap → Seq Scan

On the small DB, you can watch the planner change its mind. Run three queries with an increasing number of currencies:

```sql
-- 1 currency = 10,000 rows (20% of table)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric = 643;

-- 2 currencies = 20,000 rows (40% of table)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840);

-- 3 currencies = 30,000 rows (60% of table)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840, 978);
```

Results on the small DB:

| Currencies | Rows | % of table | Plan | Execution Time |
|------------|------|-----------|------|---------------|
| 1 | 10,000 | 20% | **Bitmap Heap Scan** | 2.050 ms |
| 2 | 20,000 | 40% | **Bitmap Heap Scan** | 3.380 ms |
| 3 | 30,000 | 60% | **Seq Scan** | 4.876 ms |

The threshold sits between 40% and 60% — add one more currency, and the planner flips. Seq Scan at 60% is only 1.5 ms slower than Bitmap at 40% — 1.5× more data, but time barely grows (thanks to sequential I/O).

### On the Large DB, Even One Currency Is a Million Rows

```
Seq Scan on transactions  (cost=0.00..218750.00 rows=998833 width=214)
                          (actual time=0.023..466.996 rows=1000000 loops=1)
  Filter: (currency_numeric = 643)
  Rows Removed by Filter: 4000000
  Buffers: shared hit=2800 read=153450
  Execution Time: 492.563 ms
```

Seq Scan right away — 20% of 5 million rows is too much for index access.

### Sequential vs Random Access — What's the Difference

To understand why the planner makes these decisions, you need to grasp two ways of reading from disk:

**Sequential access (sequential read)** — pages are read in order, one after another. Disks (especially HDDs) do this very fast: the head positions once, then data streams continuously. This is exactly how **Seq Scan** works.

**Random access (random read)** — jumping between pages scattered across different locations on disk. Each jump means a head seek (HDD) or a lookup in the page mapping table (SSD). This is how **Index Scan** works: the index points to rows spread across many different table pages.

PostgreSQL models this difference with two parameters:

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `seq_page_cost` | 1.0 | Cost of reading one page sequentially |
| `random_page_cost` | 4.0 | Cost of reading one page in random order |

The 1:4 ratio means: *"one random jump costs as much as 4 sequential reads."* This holds for HDDs. For SSDs, the ratio is closer to 1:1 or 1:1.5.

Now the ~40-60% threshold makes sense: if reading half the table with random jumps costs more than reading the whole thing sequentially, the planner picks the cheaper option.

**Real-world analogy:** imagine a library. Sequential access is walking along a shelf and grabbing books in order. Random access is finding 10 books scattered across different floors. Even if each book is light, running between floors takes longer than just reading the whole shelf.

### Experiment: Changing random_page_cost and Watching the Plan Flip

The most vivid way to understand `random_page_cost` is to change it on the fly and watch PostgreSQL change its mind:

```sql
-- Step 1. Three currencies: 60% of table. Check plan at random_page_cost = 4
SELECT current_setting('random_page_cost');  -- 4

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840, 978);

-- Step 2. Make random reads "cheap" (like on SSD)
SET random_page_cost = 1.0;

-- Step 3. Same query — the planner flips!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840, 978);

-- Step 4. Restore
SET random_page_cost = 4.0;
```

### Results on the Small DB (50K rows, 3 currencies = 30,000 rows)

```
random_page_cost = 4.0:
  Seq Scan  (cost=0.00..1907.50) (actual time=0.009..4.110 rows=30000)
  Rows Removed by Filter: 20000
  Buffers: shared hit=1220
  Execution Time: 4.876 ms

random_page_cost = 1.0:
  Index Scan  (cost=0.29..1746.67) (actual time=0.037..3.421 rows=30000)
  Index Cond: (currency_numeric = ANY ('{643,840,978}'::integer[]))
  Buffers: shared hit=3687
  Execution Time: 4.159 ms
```

Changed one parameter — the plan flipped from Seq Scan to Index Scan.

### Results on the Large DB (5M rows, 3 currencies = 3,000,000 rows)

```
random_page_cost = 4.0:
  Seq Scan  (cost=0.00..225000.00) (actual time=0.022..581.101 rows=3000000)
  Rows Removed by Filter: 2000000
  Buffers: shared hit=2864 read=153386
  Execution Time: 653.590 ms

random_page_cost = 1.0:
  Index Scan  (cost=0.43..208274.96) (actual time=0.099..978.244 rows=3000000)
  Index Cond: (currency_numeric = ANY ('{643,840,978}'::integer[]))
  Buffers: shared hit=6 read=471105 written=6
  Execution Time: 1054.237 ms
```

And here's the **surprise**. Index Scan turned out **slower** than Seq Scan (1054 ms vs 653 ms)! Why?

- `Buffers: read=471,105` — Index Scan read **3× more pages** than Seq Scan (153,386)
- Why so many? Index Scan goes to the heap for each row. With 3 million rows, that's 3 million random trips to different pages. Rows matching `currency_numeric IN (643, 840, 978)` are scattered across the table, so many pages are read multiple times — for different currencies on the same page.
- Seq Scan reads each page **exactly once** — hence 3× less I/O.
- `written=6` — pages "dirtied" on first read (hint-bit updates: PostgreSQL sets visibility flags). Normal for `SELECT`, negligible volume.
- The planner at `random_page_cost = 1.0` thinks random reads are cheap — and gets it wrong at this volume

**The takeaway:** `random_page_cost` influences the plan choice, but it doesn't override physics. Three million random heap fetches are always expensive, even on SSD.

**Important SSD nuance:** `random_page_cost = 1.0–1.5` is the right setting for SSDs, but it doesn't make random access free. If you're fetching >20–30% of the table, Seq Scan will still be faster — because sequential I/O beats jumping around, even when jumps are cheap.

### Parallel Seq Scan

If you enable parallel workers (`max_parallel_workers_per_gather = 2` — the default), PostgreSQL can spawn multiple processes to scan the table in parallel. You'd see something like `Workers Planned: 2` with `Parallel Seq Scan` — the query speeds up, but uses more CPU.

> **Note:** in our init scripts, parallel workers are disabled (`SET max_parallel_workers_per_gather = 0`), which is why the output above shows a plain `Seq Scan`, not `Parallel Seq Scan`. If you enable them (`max_parallel_workers_per_gather = 2`), PostgreSQL may parallelize — though in Docker with limited CPU, parallelism might not activate.

---

## What's Next

Seq Scan is the simplest method. In **Part 3**, we move on to indexes: how B-tree works, why Index Scan is hundreds and thousands of times faster than Seq Scan at scale, and how covering indexes let you skip the table entirely.

**In short:** Seq Scan reads everything, time scales linearly, default `shared_buffers` won't save you. Indexes are the next step.

In the meantime, experiment with `EXPLAIN (ANALYZE, BUFFERS)` on both databases.

---

**To be continued...**

*Questions and feedback — in the comments. Source files — in the [repository](https://github.com/YuryKlimchuk/article-postgresql-tuning).*
