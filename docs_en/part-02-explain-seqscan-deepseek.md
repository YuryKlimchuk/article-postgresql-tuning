# Your PostgreSQL Is an F1 Car. Stop Driving in First Gear
## Part 2: EXPLAIN ANALYZE and Seq Scan — Learning to Read Query Plans

In [Part 1](https://medium.com/@hydro.yura/your-postgresql-is-an-f1-car-stop-driving-in-first-gear-a901055d00c3) we spun up two PostgreSQL instances — a small DB (`payment_small`, ~50K transactions) and a large one (`payment_large`, ~5M transactions). Now it's time to run our first queries and see how PostgreSQL finds data.

**In this part:** you'll learn to read `EXPLAIN ANALYZE` and we'll break down the simplest (but not always fastest) access method — sequential scan. You'll see firsthand how the same query behaves completely differently on 50 thousand rows versus 5 million.

---

## 1. EXPLAIN ANALYZE — Your New Best Friend

Before diving into scan types, you need to learn how to look "under the hood" of PostgreSQL. That's what the `EXPLAIN` command is for.

### EXPLAIN vs EXPLAIN ANALYZE

There's an important distinction:

- **`EXPLAIN`** — shows the *execution plan* that PostgreSQL's planner built. The query is **not executed**; you only see cost estimates.
- **`EXPLAIN (ANALYZE)`** — **executes** the query and shows real metrics: how long it took, how many rows were read, how much memory was used.

**Always use `EXPLAIN (ANALYZE, BUFFERS)`** when debugging `SELECT` queries. For `UPDATE`/`DELETE` — wrap them in a transaction with `ROLLBACK` so you don't modify data. On production, even a `SELECT` without `LIMIT` can hammer the disk — proceed with caution.

### Key Metrics in the Output

Run the first test query on **both** databases (make sure to update statistics first):

```sql
-- Turn off JIT compilation to keep the output clean (JIT is a separate topic)
SET jit = OFF;

-- Disable parallel workers so the output matches the examples in this article
SET max_parallel_workers_per_gather = 0;

-- Update statistics (init scripts already ran ANALYZE, but just in case)
ANALYZE transactions;

-- Test query
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

You'll see something like this:

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

Let's break down the metrics using real numbers from both databases:

| Metric | Small DB (`payment_small`) | Large DB (`payment_large`) | What it means |
|--------|---------------------------|----------------------------|---------------|
| **cost** | `0.00..1845.00` | `0.00..218750.00` | Cost estimate in arbitrary units. The 118× increase (218750 / 1845) reflects the data volume growth. Cost is a planner estimate, not real time. |
| **actual time** | `0.007..5.138 ms` | `0.024..675.241 ms` | Real time: the first number is time to the first row, the second is total time. |
| **rows** | `25,175` | `2,503,844` | How many rows the node returned. Exactly ×100 — more data yields proportionally more results. |
| **width** | `155` bytes | `214` bytes | Average row width. It's larger on the big DB because `description` is longer (`repeat(..., 5)` instead of `repeat(..., 3)`). TOAST hasn't kicked in at these sizes yet — we'll cover that in Part 5. |
| **Buffers** | `hit=1220` | `hit=2702, read=153,548` | Pages of 8 KB each. Small DB: everything is cached (1220 × 8 KB ≈ 10 MB). Large DB: 2,702 cached + 153,548 from disk (~1.2 GB). The default `shared_buffers = 128 MB` can't fit a 5M-row table — hence the `read`. |
| **Rows Removed by Filter** | `24,825` | `2,496,156` | How many rows were read and discarded. Seq Scan checked every row — half didn't match. |
| **Planning Time** | `0.056 ms` | `0.057 ms` | Time to build the plan. Virtually identical! PostgreSQL doesn't "slow down" on large data — the problem is in execution, not planning. |
| **Execution Time** | `5.8 ms` | `735.4 ms` | Pure execution time. ×127 for ×100 data — nearly linear growth. |

Four takeaways from this table:

1. **×127 time difference** for ×100 data — Seq Scan reads everything sequentially, so time scales linearly with volume.
2. **`Rows Removed by Filter: 2,496,156`** — PostgreSQL read 5 million rows and threw half away. Seq Scan can't skip — it checks every single one.
3. **`Buffers: read=153,548`** (~1.2 GB from disk). The default `shared_buffers = 128 MB` simply doesn't fit the table — hence disk reads. Check yours: `SHOW shared_buffers;`. On the small DB, everything fits in cache.
4. **`Planning Time` is nearly identical** — 0.056 vs 0.057 ms. PostgreSQL doesn't "lag" or "think longer" on large data. The problem is always in execution (`Execution Time` grows 127×), not planning.

---

## 2. Sequential Scan (Seq Scan)

### What Happens

PostgreSQL reads the **entire table** page by page, checking every row against the `WHERE` condition. It's the simplest — but not always the fastest — access method.

### Example: No Index

Take another look at the query we already know from Part 1:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

There's no index on `amount` → PostgreSQL is forced to read the whole table. On the small DB it takes milliseconds; on the large one — seconds.

### Seq Scan With an Index Present — An Important Nuance

Now a query that does have an index:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric = 643;
```

There **is an index** on `currency_numeric` (we created it in `schema.sql`). But the planner picks a different plan depending on data volume:

**Small DB (50K rows, 1 currency = 10,000 rows / 20%):** the planner chooses **Bitmap Heap Scan** — a middle ground between Index Scan and Seq Scan (we'll cover this in detail in Part 4).

**Large DB (5M rows, 1 currency = 1,000,000 rows / 20%):** the planner chooses **Seq Scan**. Same query, same percentage — but at scale, even 20% is a million rows, and the planner decides "let's just read everything sequentially."

The reason lies in the cost ratio of random vs. sequential reads (more on this in the next section):

**Rule:** If the planner estimates it needs to fetch **>5–15% of rows**, it may opt for Seq Scan. The exact threshold depends on `random_page_cost` (default 4.0) and `effective_cache_size`. On SSD, `random_page_cost` is often lowered to 1.5 — this raises the threshold, and Seq Scan kicks in later (the planner sticks with the index longer).

**Check the small DB:** You won't see an Index Scan there — you'll see a Bitmap Heap Scan (covered in Part 4). It runs instantly — even a "suboptimal" plan is no problem at small scale.

### The Tipping Point: Bitmap → Seq Scan

On the small DB you can see the exact moment the planner changes its mind. Run three queries with an increasing number of currencies:

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

Result on the small DB:

| Currencies | Rows | % of table | Plan | Execution Time |
|------------|------|-----------|------|---------------|
| 1 | 10,000 | 20% | **Bitmap Heap Scan** | 2.050 ms |
| 2 | 20,000 | 40% | **Bitmap Heap Scan** | 3.380 ms |
| 3 | 30,000 | 60% | **Seq Scan** | 4.876 ms |

The threshold is crossed between 40% and 60% — add one more currency and the planner flips. Seq Scan at 60% is only 1.5 ms slower than Bitmap at 40% — the result set is 1.5× larger, but time barely increased (sequential reads for the win).

### On the Large DB, Even One Currency Means a Million Rows

```
Seq Scan on transactions  (cost=0.00..218750.00 rows=998833 width=214)
                          (actual time=0.023..466.996 rows=1000000 loops=1)
  Filter: (currency_numeric = 643)
  Rows Removed by Filter: 4000000
  Buffers: shared hit=2800 read=153450
  Execution Time: 492.563 ms
```

Straight to Seq Scan — you can't tackle 20% of 5 million rows with an index.

### Sequential vs. Random Access — What's the Difference

To understand why the planner makes these decisions, you need to grasp the two ways of reading from disk:

**Sequential access (sequential read)** — pages are read one after another, in order. Disks (especially HDDs) are very fast at this: the head positions once, then data streams in. This is exactly how **Seq Scan** works.

**Random access (random read)** — you jump between pages scattered across different disk locations. Every jump is a head seek (HDD) or a page table lookup (SSD). This is how **Index Scan** works: the index points to rows scattered across various table pages.

PostgreSQL models this difference through two parameters:

| Parameter | Default value | What it means |
|-----------|--------------|---------------|
| `seq_page_cost` | 1.0 | Cost of reading one page sequentially |
| `random_page_cost` | 4.0 | Cost of reading one page randomly |

The 1:4 ratio means *"one random jump costs as much as 4 sequential reads"*. This holds true for HDDs. For SSDs the ratio is closer to 1:1 or 1:1.5.

Now the ~40–60% threshold makes sense: reading half the table through random jumps can cost more than reading the whole thing sequentially. The planner estimates both options and picks the cheaper one.

**Real-life analogy:** Imagine a library. Sequential reading is walking along a shelf and grabbing books one after another. Random reading is finding 10 books scattered across different floors. Even if each book is lightweight, running between floors takes longer than simply reading the entire shelf.

### Experiment: Changing random_page_cost and Watching the Plan Flip

The most vivid way to understand `random_page_cost` is to change it on the fly and watch PostgreSQL change its mind:

```sql
-- Step 1. Three currencies: 60% of table. Check the plan at random_page_cost = 4
SELECT current_setting('random_page_cost');  -- 4

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840, 978);

-- Step 2. Make random reads "cheap" (like on SSD)
SET random_page_cost = 1.0;

-- Step 3. Same query — the planner changed its mind!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric IN (643, 840, 978);

-- Step 4. Set it back
SET random_page_cost = 4.0;
```

### Result on Small DB (50K rows, 3 currencies = 30,000 rows)

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

One parameter changed — the plan flipped from Seq Scan to Index Scan.

### Result on Large DB (5M rows, 3 currencies = 3,000,000 rows)

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
- Why so many? Index Scan goes to the table (heap) for every single row. With 3 million rows, that's 3 million random visits to different pages. Rows with `currency_numeric IN (643, 840, 978)` are scattered across the entire table, so many pages get read repeatedly — multiple currencies land on the same page.
- Seq Scan reads each page **exactly once** — hence 3× less I/O.
- `written=6` — pages "dirtied" during the first read (hint-bit updates: PostgreSQL sets visibility hint bits). This is normal for `SELECT` and the volume is negligible.
- With `random_page_cost = 1.0`, the planner thinks random reads are cheap — and gets it wrong at this scale.

**The moral:** `random_page_cost` influences plan choice, but it doesn't override physics. Three million random trips to the table is always expensive, even on SSD.

**Important SSD nuance:** `random_page_cost = 1.0–1.5` is the right setting for SSDs, but it doesn't make random access free. If the result set exceeds 20–30% of the table, Seq Scan will still be faster — because reading everything sequentially is more efficient than jumping around, even if jumps are cheap.

### Parallel Seq Scan

If you enable parallel workers (`max_parallel_workers_per_gather = 2` — the default), PostgreSQL can spin up multiple processes to read the table in parallel. You'd see something like `Workers Planned: 2` with `Parallel Seq Scan` — the query speeds up but consumes more CPU.

> **Note:** our init scripts have parallel workers disabled (`SET max_parallel_workers_per_gather = 0`), which is why the output above shows plain `Seq Scan`, not `Parallel Seq Scan`. If you enable it (`max_parallel_workers_per_gather = 2`), PostgreSQL may launch several workers to read the table in parallel — this speeds up the query but uses more CPU. On a CPU-constrained Docker setup, parallelism may not kick in at all.

---

## What's Next

Seq Scan is the simplest access method. In **Part 3** we'll move on to indexes: how B-tree works, why Index Scan is 800× faster than Seq Scan at scale, and how a covering index lets you avoid touching the table entirely.

**In short:** Seq Scan reads everything sequentially, time grows linearly, and the default `shared_buffers` won't save you. An index is the next level.

In the meantime, go experiment with `EXPLAIN (ANALYZE, BUFFERS)` on both databases.

---

**To be continued...**

*Questions and feedback — in the comments. Source files — in the [repository](https://github.com/YuryKlimchuk/article-postgresql-tuning).*
