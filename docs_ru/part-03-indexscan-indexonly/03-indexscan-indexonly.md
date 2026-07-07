# Твой PostgreSQL — это болид F1. Хватит ездить на первой передаче
## Часть 3: Index Scan и Index Only Scan — работаем с индексами

В [предыдущей части](https://medium.com/@hydro.yura/your-postgresql-is-an-f1-car-stop-driving-in-first-gear-31024877b89e) мы научились читать `EXPLAIN ANALYZE` и увидели, как Seq Scan читает всю таблицу, выбрасывая миллионы ненужных строк. Если вы пропустили — начните с [части 1](https://medium.com/@hydro.yura/your-postgresql-is-an-f1-car-stop-driving-in-first-gear-a901055d00c3) (настройка окружения). Теперь разберём, как индексы меняют правила игры.

**В этой части:** B-tree — основной индекс PostgreSQL, как он устроен и почему Index Scan в сотни раз быстрее Seq Scan. А затем — покрывающие индексы (Index Only Scan), которые вообще не ходят в таблицу.

```sql
-- Отключаем JIT и параллельные воркеры, обновляем статистику (как в части 2)
SET jit = OFF;
SET max_parallel_workers_per_gather = 0;
ANALYZE transactions;
```

---

### B-tree — основной индекс

Когда вы создаёте индекс без указания типа:

```sql
CREATE INDEX idx_transactions_card_id ON transactions(card_id);
```

PostgreSQL создаёт **B-tree** (сбалансированное дерево). Это универсальный индекс, который работает для равенства (`=`), диапазонов (`>`, `<`, `BETWEEN`) и сортировки (`ORDER BY`).

**Аналогия из жизни:** представьте оглавление книги. Чтобы найти главу, вы не листаете всю книгу подряд — открываете оглавление, видите номер страницы и переходите сразу туда. B-tree устроен похоже:

```
        [50 | 100]           ← корень: значения-разделители
       /    |     \
  [10|20] [60|80] [150|200]  ← промежуточные узлы
  /  |  \   /  |  \   /  |  \
 ↓   ↓   ↓  ↓   ↓   ↓  ↓   ↓   ← листья → heap (строки в таблице)
```

Глубина дерева небольшая (3-4 уровня даже для миллионов записей), поэтому поиск очень быстрый: O(log n).

### Что происходит при Index Scan

1. PostgreSQL идёт по B-tree и находит записи с нужным `card_id`
2. Для каждой найденной записи идёт в **таблицу (heap)** за остальными колонками (всеми, кроме `card_id`)

### Пример: точечный запрос

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;
```

> **Примечание:** в наших данных `BIGSERIAL` генерирует ID начиная с 1, так что `card_id = 1` гарантированно существует.

### Малая БД (50K строк, 25 транзакций для card_id=1)

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.29..8.73 rows=25 width=155)
  (actual time=0.014..0.017 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3
 Planning Time: 0.083 ms
 Execution Time: 0.034 ms
```

### Большая БД (5M строк, 5 транзакций для card_id=1)

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.43..8.80 rows=21 width=214)
  (actual time=0.014..0.015 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=4
 Planning Time: 0.032 ms
 Execution Time: 0.028 ms
```

Обратите внимание: `cost` на обеих БД почти одинаков (`0.29..8.73` vs `0.43..8.80`). Планировщик знает: Index Scan не зависит от размера таблицы — он зависит только от глубины B-tree и количества найденных строк.

Сравните с cost Seq Scan из части 2: `cost=0.00..218750.00`. **Разница в 25 000 раз по оценке стоимости!** Планировщик смотрит на эти цифры и выбирает Index Scan.

### Прямое сравнение: Index Scan vs Seq Scan

Насколько Index Scan быстрее по реальному времени? Отключим Index Scan и Bitmap Scan принудительно — и посмотрим, что будет:

```sql
-- Отключаем все индексные доступы и параллельные воркеры
-- (Parallel Seq Scan может активироваться на большой БД, отключаем для чистоты сравнения)
SET enable_indexscan = OFF;
SET enable_bitmapscan = OFF;
SET max_parallel_workers_per_gather = 0;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;

SET enable_indexscan = ON;
SET enable_bitmapscan = ON;
SET max_parallel_workers_per_gather = 0;
```

Результаты:

| Метрика | Малая БД (Index Scan) | Малая БД (Seq Scan) | Большая БД (Index Scan) | Большая БД (Seq Scan) |
|---------|----------------------|---------------------|------------------------|----------------------|
| **Execution Time** | 0.034 ms | 7.374 ms | 0.028 ms | 388.290 ms |
| **Разница** | — | **×217 медленнее** | — | **×13 867 медленнее** |
| **Buffers** | 3 hit | 1 hit + 1 219 read | 4 hit | 128 hit + 156 122 read |
| **Rows Removed by Filter** | — | 49 975 | — | 4 999 995 |

Главный вывод: **Index Scan практически не зависит от размера таблицы**. 0.034 ms на 50K строк, 0.028 ms на 5M строк — время одинаковое, хотя данных в 100 раз больше. Это потому что глубина B-tree растёт логарифмически: для 50K строк нужно ~3 уровня дерева, для 5M — ~4 уровня. Seq Scan же читает всю таблицу, поэтому время растёт линейно.

Index Scan всегда делает заходы в таблицу (heap) за колонками, которых нет в индексе — это «плата» за универсальность. В следующем разделе мы увидим, как покрывающий индекс устраняет эту проблему.

### Когда Index Scan неэффективен

Index Scan хорош для **точечных запросов** (одна строка или несколько). Но если нужно выбрать больше ~5-15% таблицы, планировщик переключится на Bitmap Heap Scan или Seq Scan — как мы видели в части 2.

### Составной индекс

Индекс не обязан быть на одной колонке. Можно создать **составной индекс** на несколько полей:

```sql
-- Составной индекс для ускорения запросов по user_id + status
CREATE INDEX idx_uc_user_status ON user_cards(user_id, status);

-- Обновляем статистику, чтобы планировщик знал о новом индексе
ANALYZE user_cards;
```

Такой индекс ускоряет запросы с условиями по обеим колонкам:

```sql
SELECT * FROM user_cards WHERE user_id = 1 AND status = 'ACTIVE';
```

И даже запрос только по первой колонке:

```sql
SELECT * FROM user_cards WHERE user_id = 1;  -- тоже использует составной индекс
```

Но **не** ускоряет запрос только по второй колонке — это правило **leftmost prefix**:

```sql
-- Эти запросы используют индекс (A, B, C):
-- WHERE A = ...              ✅
-- WHERE A = ... AND B = ...  ✅
-- WHERE A = ... AND B = ... AND C = ...  ✅

-- А эти — нет:
-- WHERE B = ...              ❌ пропущена A
-- WHERE C = ...              ❌ пропущены A и B
```

**Пример из нашей схемы:** частый кейс — «активные карты пользователя»:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_cards WHERE user_id = 1 AND status = 'ACTIVE';
```

Без составного индекса PostgreSQL использует `idx_user_cards_user_id`, но затем фильтрует по `status` — `Rows Removed by Filter` покажет лишнюю работу. С составным индексом `(user_id, status)` фильтрация происходит прямо в индексе.

Реальные цифры (на обеих БД планировщик выбрал существующий индекс `idx_user_cards_user_id` — оба индекса начинаются с `user_id`, для 2 строк разницы нет):

```
-- Малая БД
Bitmap Heap Scan on user_cards
  (cost=4.29..10.55 rows=2 width=62) (actual time=0.033..0.038 rows=2 loops=1)
  Recheck Cond: (user_id = 1)
  Filter: ((status)::text = 'ACTIVE'::text)
  Heap Blocks: exact=2
  Buffers: shared hit=7
  ->  Bitmap Index Scan on idx_user_cards_user_id
        Index Cond: (user_id = 1)
        Buffers: shared hit=5
 Planning Time: 0.952 ms
 Execution Time: 0.089 ms

-- Большая БД (видно Rows Removed by Filter)
Index Scan using idx_user_cards_user_id on user_cards
  (cost=0.42..11.49 rows=2 width=62) (actual time=0.031..0.031 rows=1 loops=1)
  Index Cond: (user_id = 1)
  Filter: ((status)::text = 'ACTIVE'::text)
  Rows Removed by Filter: 1
  Buffers: shared hit=8
 Planning Time: 0.255 ms
 Execution Time: 0.058 ms
```

На большой БД заметна лишняя работа: `Rows Removed by Filter: 1` — фильтрация по `status` происходит в heap, а не в индексе. Для 2 строк на пользователя это копейки, но когда у пользователя сотни карт — разница становится значительной.

Порядок колонок важен: сначала колонки для `=`, потом для `ORDER BY`, потом для диапазонов.

**Подведём итог по Index Scan:** это основной рабочий инструмент PostgreSQL. Для точечных запросов он быстрее Seq Scan в сотни и тысячи раз. Но он всегда ходит в таблицу (heap) за данными — и когда нужно прочитать много строк или данных нет в индексе, это становится узким местом. Дальше мы увидим, как покрывающий индекс решает проблему заходов в таблицу (а в части 4 — как битовая карта помогает для промежуточных объёмов).

---

### Проблема Index Scan

Index Scan всегда ходит в таблицу (heap) за колонками, которых нет в индексе. Даже если вам нужны только `card_id` и `amount`, а индекс только на `card_id` — PostgreSQL читает и индекс, и таблицу.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
```

### Малая БД (Index Scan, amount не в индексе)

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.29..8.73 rows=25 width=14)
  (actual time=0.020..0.024 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3
 Planning Time: 0.039 ms
 Execution Time: 0.037 ms
```

`width=14` (только card_id + amount, без description), но всё равно Index Scan — потому что `amount` нет в индексе. Index Scan особенно дорог, если в таблице есть TOAST-поля (TEXT, JSONB, BYTEA) — даже когда они не нужны, PostgreSQL читает TOAST-указатели из таблицы.

### Решение: покрывающий индекс

Если **все** колонки из `SELECT` и `WHERE` есть в индексе, PostgreSQL может ответить, не заглядывая в таблицу. Это **Index Only Scan**.

```sql
CREATE INDEX idx_tx_card_amount ON transactions(card_id, amount);
ANALYZE transactions;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
```

### Малая БД (покрывающий индекс, card_id + amount)

```
Index Only Scan using idx_tx_card_amount on transactions
  (cost=0.29..4.73 rows=25 width=14)
  (actual time=0.022..0.025 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=1 read=2
 Planning Time: 0.235 ms
 Execution Time: 0.044 ms
```

`Heap Fetches: 0` — ни одного захода в таблицу! PostgreSQL ответил, используя только индекс.

Сравним:

> **Пояснение про read=2:** индекс `idx_tx_card_amount` только что создан и ещё не в кэше (`shared_buffers`). При повторном запуске вы увидите только `hit`. Новый индекс всегда начинается с «холодного» кэша.

| Метрика | Index Scan | Index Only Scan | Разница |
|---------|-----------|----------------|---------|
| **Buffers** | 3 hit | 1 hit + 2 read* | ~одинаково (индекс маленький) |
| **Heap Fetches** | 25 (по 1 на строку) | **0** | Таблица не читается |
| **Execution Time** | 0.037 ms | 0.044 ms (холодный) / 0.030 ms (горячий) | Index Only Scan быстрее в кэше |
| **cost** | 0.29..8.73 | 0.29..4.73 | Общая стоимость вдвое ниже |

\* `read=2` — индекс ещё не в кэше, при повторе будет `hit`.

Повторный запуск (индекс уже в кэше):

```
Index Only Scan using idx_tx_card_amount on transactions
  (cost=0.29..4.73 rows=25 width=14) (actual time=0.015..0.016 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=3
 Planning Time: 0.031 ms
 Execution Time: 0.030 ms
```

### Большая БД (покрывающий индекс)

Сначала — Index Scan на большом объёме (для сравнения):

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.43..8.80 rows=21 width=14) (actual time=0.027..0.029 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=4
 Planning Time: 0.047 ms
 Execution Time: 0.046 ms
```

Теперь — с покрывающим индексом:

| Метрика | Index Scan (большая БД) | Index Only Scan (большая БД) |
|---------|------------------------|-----------------------------|
| **Buffers** | 4 hit | 4 hit |
| **Heap Fetches** | 5 (по 1 на строку) | **0** |
| **Execution Time** | 0.046 ms | 0.034 ms |
| **cost** | 0.43..8.80 | 0.43..4.80 |

Даже на «холодном» кэше Index Only Scan быстрее. А когда таблица в миллионы строк и heap не влезает в `shared_buffers`, Index Scan начнёт читать таблицу с диска — и разница станет не в проценты, а в разы.

**Мораль:** покрывающий индекс — это самый эффективный способ ускорить точечные запросы. Цена — дополнительное место на диске и замедление INSERT/UPDATE. Если запрос выполняется часто, а данные меняются редко — покрывающий индекс почти всегда оправдан.

### INCLUDE-индекс (PostgreSQL 11+)

Что если `amount` нужен только в `SELECT`, но не в `WHERE`? Добавлять его в составной индекс `(card_id, amount)` — значит раздувать B-tree и замедлять поиск по `card_id`.

Решение — **INCLUDE**: колонка хранится в листьях индекса, но не участвует в поиске:

```sql
DROP INDEX IF EXISTS idx_tx_card_amount;
CREATE INDEX idx_tx_card_inc ON transactions(card_id) INCLUDE (amount);
```

- Поиск идёт только по `card_id` — B-tree компактный
- `amount` лежит в листьях — Index Only Scan работает

### Малая БД (INCLUDE-индекс)

```
Index Only Scan using idx_tx_card_inc on transactions
  (cost=0.29..4.73 rows=25 width=14)
  (actual time=0.023..0.026 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=3
 Planning Time: 0.259 ms
 Execution Time: 0.045 ms
```

### Большая БД (INCLUDE-индекс)

```
Index Only Scan using idx_tx_card_inc on transactions
  (cost=0.43..4.80 rows=21 width=14)
  (actual time=0.022..0.023 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=4
 Planning Time: 0.140 ms
 Execution Time: 0.042 ms
```

`Heap Fetches: 0` на обеих БД — таблица только что создана, VACUUM отработал в init-скриптах, Visibility Map чистая.

**Когда INCLUDE, а когда составной индекс?** Если колонка используется и в `WHERE`, и в `SELECT` — делайте составной индекс `(col1, col2)`. Если колонка только в `SELECT` и не участвует в поиске — используйте `INCLUDE`. Так B-tree остаётся компактным, а Index Only Scan работает.

### Visibility Map: почему Index Only Scan не всегда «Only»

PostgreSQL использует **Visibility Map** — битовую карту, которая отмечает страницы, где все строки видны всем активным транзакциям (MVCC). Если страница «чистая» — Index Only Scan не идёт в таблицу. Если «грязная» — заглядывает в heap за каждой строкой.

### Эксперимент: создаём грязные страницы и чистим их

```sql
-- После INSERT все страницы чистые (благодаря VACUUM в init-скриптах)
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 0 ← всё чисто

-- Делаем UPDATE — страницы становятся «грязными»
UPDATE transactions SET amount = amount WHERE card_id = 1;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 50 (малая) / 10 (большая) ← полезли в таблицу!

-- VACUUM обновляет Visibility Map
VACUUM transactions;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 0 ← снова чисто
```

Реальные цифры:

**Малая БД (Visibility Map):**

| Шаг | Heap Fetches | Buffers | Execution Time |
|-----|-------------|---------|---------------|
| После INSERT | 0 | 3 hit | 0.051 ms |
| После UPDATE | **50** | 6 hit | 0.071 ms |
| После VACUUM | **0** | 3 hit | 0.054 ms |

**Большая БД (Visibility Map):**

| Шаг | Heap Fetches | Buffers | Execution Time |
|-----|-------------|---------|---------------|
| После INSERT | 0 | 4 hit | 0.030 ms |
| После UPDATE | **10** | 7 hit | 0.058 ms |
| После VACUUM | **0** | 4 hit | 0.031 ms |

`Heap Fetches` считает не строки, а **заходы в страницы таблицы** для проверки видимости. Почему 50 заходов для 25 строк? `UPDATE` создаёт новые версии кортежей (MVCC). Index Only Scan идёт по индексу к старому TID, видит обновлённую строку и проверяет видимость в heap — как для старой, так и для новой страницы. Отсюда ~2 захода на строку: 25×2≈50 на малой БД, 5×2≈10 на большой. `VACUUM` помечает старые версии как неактуальные и обновляет Visibility Map → `Heap Fetches: 0`.

Именно поэтому в наших init-скриптах есть `VACUUM` после загрузки данных. Без него даже покрывающий индекс будет читать таблицу.

**Практический совет:** если активно пишете в таблицу (много INSERT/UPDATE/DELETE), либо почаще делайте `VACUUM`, либо настройте автовакуум агрессивнее — иначе Index Only Scan будет постоянно проваливаться в heap, и смысл покрывающего индекса теряется.

**Итог:** Index Only Scan — самый быстрый способ доступа к данным, быстрее только кэш приложения. Но он требует покрывающего индекса и актуальной Visibility Map. Если индекс покрывает запрос, а автовакуум не отстаёт — вы читаете только индекс и не касаетесь таблицы. На больших объёмах это даёт выигрыш в разы по сравнению с Index Scan.

---


## Что дальше

Индексы ускоряют точечные запросы в сотни и тысячи раз. Но что делать, когда строк много, но недостаточно для Seq Scan? В **Части 4** — Bitmap Heap Scan: компромисс между индексом и полным сканированием. А также обзор Hash, GIN и BRIN-индексов.

---

**Продолжение следует...**

*Вопросы и замечания — в комментариях. Исходные файлы — в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).*
