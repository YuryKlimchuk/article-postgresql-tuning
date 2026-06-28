# Твой PostgreSQL — это болид F1. Хватит ездить на первой передаче
## Часть 3: Index Scan и Index Only Scan — работаем с индексами

В [предыдущей части](ссылка-на-часть-2) мы научились читать `EXPLAIN ANALYZE` и увидели, как Seq Scan читает всю таблицу, выбрасывая миллионы ненужных строк. Теперь разберём, как индексы меняют правила игры.

**В этой части:** B-tree — основной индекс PostgreSQL, как он устроен и почему Index Scan в сотни раз быстрее Seq Scan. А затем — покрывающие индексы (Index Only Scan), которые вообще не ходят в таблицу.

---

## 3. Индексное сканирование (Index Scan)

### B-tree — основной индекс

Когда вы создаёте индекс без указания типа:

```sql
CREATE INDEX idx_transactions_card_id ON transactions(card_id);
```

PostgreSQL создаёт **B-tree** (сбалансированное дерево). Это универсальный индекс, который работает для равенства (`=`), диапазонов (`>`, `<`, `BETWEEN`) и сортировки (`ORDER BY`).

**Как работает B-tree:** представьте оглавление книги. Чтобы найти главу, вы не листаете всю книгу подряд — открываете оглавление, видите номер страницы и переходите сразу туда. B-tree устроен похоже:

```
        [50 | 100]           ← корень: значения-разделители
       /    |     \
  [10|20] [60|80] [150|200]  ← промежуточные узлы
  /  |  \   /  |  \   /  |  \
 ↓   ↓   ↓  ↓   ↓   ↓  ↓   ↓   ← листья → heap (строки в таблице)
```

Глубина дерева небольшая (3-4 уровня даже для миллионов записей), поэтому поиск очень быстрый: O(log n).

### Реальные ID для тестов

В наших данных `BIGSERIAL` генерирует ID начиная с 1, так что `card_id = 1` точно существует:

```sql
-- ID гарантированно начинаются с 1
SELECT * FROM transactions WHERE card_id = 1;
```

### Что происходит при Index Scan

1. PostgreSQL идёт по B-tree и находит записи с нужным `card_id`
2. Для каждой найденной записи идёт в **таблицу (heap)** за остальными колонками (всеми, кроме `card_id`)

### Пример: точечный запрос

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;
```

**Малая БД (50K строк, 25 транзакций для card_id=1):**

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.29..8.73 rows=25 width=155)
  (actual time=0.041..0.045 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3
  Execution Time: 0.068 ms
```

**Большая БД (5M строк, 5 транзакций для card_id=1):**

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.43..8.80 rows=21 width=214)
  (actual time=0.410..0.411 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3 read=4
  Execution Time: 0.444 ms
```

Обратите внимание: `cost` на обеих БД почти одинаков (`0.29..8.73` vs `0.43..8.80`). Планировщик знает: Index Scan не зависит от размера таблицы — он зависит только от глубины B-tree и количества найденных строк.

Сравните с cost Seq Scan из раздела 2: `cost=0.00..218750.00`. **Разница в 26 000 раз!** Планировщик смотрит на эти цифры и выбирает Index Scan.

### Прямое сравнение: Index Scan vs Seq Scan

Насколько Index Scan быстрее? Отключим Index Scan и Bitmap Scan принудительно — и посмотрим, что будет:

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
SET max_parallel_workers_per_gather = 2;
```

Результаты:

| Метрика | Малая БД (Index Scan) | Малая БД (Seq Scan) | Большая БД (Index Scan) | Большая БД (Seq Scan) |
|---------|----------------------|---------------------|------------------------|----------------------|
| **Execution Time** | 0.068 ms | 14.669 ms | 0.444 ms | 391.552 ms |
| **Разница** | — | **×216 медленнее** | — | **×882 медленнее** |
| **Buffers** | 3 hit | 65 hit + 1 155 read | 3 hit + 4 read | 129 hit + 156 121 read |
| **Rows Removed by Filter** | — | 49 975 | — | 4 999 995 |

Главный вывод: **Index Scan практически не зависит от размера таблицы**. 0.068 ms на 50K строк, 0.444 ms на 5M строк — разница всего в 6 раз, хотя данных в 100 раз больше. Это потому что глубина B-tree растёт логарифмически: для 50K строк нужно ~3 уровня дерева, для 5M — ~4 уровня. Seq Scan же читает всю таблицу, поэтому время растёт линейно.

Index Scan всегда делает заходы в таблицу (heap) за колонками, которых нет в индексе — это «плата» за универсальность. В следующем разделе мы увидим, как покрывающий индекс устраняет эту проблему.

### Когда Index Scan неэффективен

Index Scan хорош для **точечных запросов** (одна строка или несколько). Но если нужно выбрать больше ~5-15% таблицы, планировщик переключится на Bitmap Heap Scan или Seq Scan — как мы видели в разделе 2.

### Составной индекс

Индекс не обязан быть на одной колонке. Можно создать **составной индекс** на несколько полей:

```sql
-- Составной индекс для ускорения запросов по card_id + status
CREATE INDEX idx_tx_card_status ON transactions(card_id, status);

-- Обновляем статистику, чтобы планировщик знал о новом индексе
ANALYZE transactions;
```

Такой индекс ускоряет запросы с условиями по обеим колонкам:

```sql
SELECT * FROM transactions WHERE card_id = 1 AND status = 'ACTIVE';
```

И даже запрос только по первой колонке:

```sql
SELECT * FROM transactions WHERE card_id = 1;  -- тоже использует составной индекс
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

Порядок колонок важен: сначала колонки для `=`, потом для `ORDER BY`, потом для диапазонов.

**Итог:** Index Scan — основной рабочий инструмент PostgreSQL. Для точечных запросов он быстрее Seq Scan в сотни и тысячи раз. Но он всегда ходит в таблицу (heap) за данными — и когда нужно прочитать много строк или данных нет в индексе, это становится узким местом. Дальше мы увидим, как покрывающий индекс и битовая карта решают эти проблемы.

---

## 4. Покрывающий индекс (Index Only Scan)

### Проблема Index Scan

Index Scan всегда ходит в таблицу (heap) за колонками, которых нет в индексе. Даже если вам нужны только `card_id` и `amount`, а индекс только на `card_id` — PostgreSQL читает и индекс, и таблицу.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
```

**Малая БД:**

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.29..8.73 rows=25 width=14)
  (actual time=0.044..0.049 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3
  Execution Time: 0.077 ms
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

**Малая БД:**

```
Index Only Scan using idx_tx_card_amount on transactions
  (cost=0.29..4.73 rows=25 width=14)
  (actual time=0.022..0.024 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=1 read=2
  Execution Time: 0.039 ms
```

`Heap Fetches: 0` — ни одного захода в таблицу! PostgreSQL ответил, используя только индекс.

Сравним:

> **Пояснение про read=2:** индекс `idx_tx_card_amount` только что создан и ещё не в кэше (`shared_buffers`). При повторном запуске вы увидите только `hit`. Новый индекс всегда начинается с «холодного» кэша.

| Метрика | Index Scan | Index Only Scan | Разница |
|---------|-----------|----------------|---------|
| **Buffers** | 3 hit | 1 hit + 2 read* | ~одинаково (индекс маленький) |
| **Heap Fetches** | 25 (по 1 на строку) | **0** | Таблица не читается |
| **Execution Time** | 0.077 ms | 0.039 ms | **×2 быстрее** |
| **cost** | 0.29..8.73 | 0.29..4.73 | Общая стоимость вдвое ниже |

\* `read=2` — индекс ещё не в кэше, при повторе будет `hit`.

**На большой БД разница радикальна:**

| Метрика | Index Scan (большая БД) | Index Only Scan, INCLUDE (большая БД) |
|---------|------------------------|--------------------------------------|
| **Buffers** | 4 hit | 1 hit + 3 read |
| **Heap Fetches** | 5 (по 1 на строку) | 5* |
| **Execution Time** | 0.065 ms | 0.040 ms |

\* `Heap Fetches: 5` на Index Only Scan — индекс новый, страницы ещё не в Visibility Map. После `VACUUM` или повтора запроса станет 0.

Даже на «холодном» кэше Index Only Scan быстрее. А когда таблица в миллионы строк и heap не влезает в `shared_buffers`, Index Scan начнёт читать таблицу с диска — и разница станет не в проценты, а в разы.

### INCLUDE-индекс (PostgreSQL 11+)

Что если `amount` нужен только в `SELECT`, но не в `WHERE`? Добавлять его в составной индекс `(card_id, amount)` — значит раздувать B-tree и замедлять поиск по `card_id`.

Решение — **INCLUDE**: колонка хранится в листьях индекса, но не участвует в поиске:

```sql
CREATE INDEX idx_tx_card_amount_include ON transactions(card_id) INCLUDE (amount);
```

- Поиск идёт только по `card_id` — B-tree компактный
- `amount` лежит в листьях — Index Only Scan работает

**Малая БД:**

```
Index Only Scan using idx_tx_card_amount_include on transactions
  (cost=0.29..8.73 rows=25 width=14)
  (actual time=0.020..0.022 rows=25 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 0
  Buffers: shared hit=1 read=2
  Execution Time: 0.036 ms
```

**Большая БД:**

```
Index Only Scan using idx_tx_card_amount_include on transactions
  (cost=0.43..8.80 rows=21 width=14)
  (actual time=0.026..0.027 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Heap Fetches: 5
  Buffers: shared hit=1 read=3
  Execution Time: 0.040 ms
```

На большой БД `Heap Fetches: 5`. Почему на малой 0, а здесь 5? Когда создаётся новый индекс после загрузки данных, PostgreSQL не знает, какие страницы «чистые» для этого индекса. На малой БД индекс маленький и помещается в несколько страниц — после первого запроса они помечаются как чистые. На большой БД индекс больше, и первые запросы проверяют страницы в heap. После `VACUUM` или нескольких повторных запросов `Heap Fetches` станет 0.

**Когда INCLUDE, а когда составной индекс?** Если колонка используется и в `WHERE`, и в `SELECT` — делайте составной индекс `(col1, col2)`. Если колонка только в `SELECT` и не участвует в поиске — используйте `INCLUDE`. Так B-tree остаётся компактным, а Index Only Scan работает.

### Visibility Map: почему Index Only Scan не всегда «Only»

PostgreSQL использует **Visibility Map** — битовую карту, которая отмечает страницы, где все строки видны всем активным транзакциям (MVCC). Если страница «чистая» — Index Only Scan не идёт в таблицу. Если «грязная» — заглядывает в heap за каждой строкой.

**Эксперимент: создаём грязные страницы и чистим их:**

```sql
-- После INSERT все страницы чистые (благодаря VACUUM в init-скриптах)
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 0 ← всё чисто

-- Делаем UPDATE — страницы становятся «грязными»
UPDATE transactions SET amount = amount WHERE card_id = 1;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 70 ← полезли в таблицу!

-- VACUUM обновляет Visibility Map
VACUUM transactions;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;
-- Heap Fetches: 0 ← снова чисто
```

Реальные цифры (малая БД):

| Шаг | Heap Fetches | Buffers | Execution Time |
|-----|-------------|---------|---------------|
| После INSERT | 0 | 3 hit | 0.038 ms |
| После UPDATE | **70** | 73 hit | 0.116 ms |
| После VACUUM | **0** | 3 hit | 0.038 ms |

`UPDATE` → `Heap Fetches: 70` — `Heap Fetches` считает не строки, а **заходы в страницы таблицы** для проверки видимости. 25 строк разбросаны по нескольким страницам, и каждая «грязная» страница проверяется. PostgreSQL не доверяет Visibility Map для этих страниц после UPDATE, поэтому заглядывает в heap за каждой из них. `VACUUM` → `0` — страницы снова чистые.

Именно поэтому в наших init-скриптах есть `VACUUM` после загрузки данных. Без него даже покрывающий индекс будет читать таблицу.

**Практический совет:** если активно пишете в таблицу (много INSERT/UPDATE/DELETE), либо почаще делайте `VACUUM`, либо настройте автовакуум агрессивнее — иначе Index Only Scan будет постоянно проваливаться в heap, и смысл покрывающего индекса теряется.

**Итог:** Index Only Scan — самый быстрый способ доступа к данным, быстрее только кэш приложения. Но он требует покрывающего индекса и актуальной Visibility Map. Если индекс покрывает запрос, а автовакуум не отстаёт — вы читаете только индекс и не касаетесь таблицы. На больших объёмах это даёт выигрыш в разы по сравнению с Index Scan.

---


## Что дальше

Индексы ускоряют точечные запросы в сотни и тысячи раз. Но что делать, когда строк много, но недостаточно для Seq Scan? В **Части 4** — Bitmap Heap Scan: компромисс между индексом и полным сканированием. А также обзор Hash, GIN и BRIN-индексов.

А пока попробуйте Index Only Scan на своих данных. Исходные файлы доступен в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).

---

**Продолжение следует...**

*Вопросы и замечания — в комментариях. Исходные файлы — в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).*
