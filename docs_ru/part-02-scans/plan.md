# Часть 2: Способы доступа к данным — план

## 1. Введение в EXPLAIN ANALYZE

- Что такое план запроса и зачем его читать
- `EXPLAIN` vs `EXPLAIN ANALYZE` — разница
- Ключевые метрики в выводе: cost, actual time, rows, loops, buffers
- `Buffers: shared hit/read` — кэш vs диск
- Как запустить на малой и большой БД и сравнить

## 2. Последовательное сканирование (Seq Scan)

- Что происходит: PostgreSQL читает **всю** таблицу страницу за страницей
- `SELECT * FROM transactions WHERE amount > 5000;` — нет индекса на amount → Seq Scan
- Сравнить малую (50K) и большую (5M) БД — на большой разница драматична
- **Ключевой момент: Seq Scan при наличии индекса.** Даже если индекс есть, планировщик может выбрать Seq Scan, если:
  - Выборка > 5-10% таблицы (дешевле прочитать всё подряд, чем прыгать по индексу)
  - Таблица маленькая (помещается в пару страниц)
  - Пример: `SELECT * FROM transactions WHERE currency_numeric = 643` — на большой БД ~20% строк в RUB, планировщик говорит «проще Seq Scan»

## 3. Индексное сканирование (Index Scan)

- B-tree — основной индекс, как он устроен (сбалансированное дерево)
- `CREATE INDEX idx_xxx ON table(column);`
- Что происходит: идём по B-tree → находим нужные записи → идём в таблицу (heap) за остальными колонками
- `SELECT * FROM transactions WHERE card_id = 12345;` — Index Scan по `idx_transactions_card_id`
- Сравнить время Seq Scan vs Index Scan на одном и том же запросе

## 4. Покрывающий индекс (Index Only Scan)

- Что такое покрывающий индекс: все нужные колонки есть в индексе → в таблицу не ходим
- `SELECT card_id, amount FROM transactions WHERE card_id = 12345;` — если индекс только на `card_id`, всё равно Index Scan (amount не в индексе)
- `CREATE INDEX idx_tx_card_amount ON transactions(card_id, amount);` — теперь Index Only Scan!
- Сравнение Buffers: Index Scan (ходит в heap) vs Index Only Scan (читает только индекс)
- Ограничение: Visibility Map — почему Index Only Scan всё равно иногда ходит в таблицу

## 5. Битовая карта (Bitmap Heap Scan)

- Двухфазный подход:
  1. **Bitmap Index Scan** — проходим по индексу, строим битовую карту страниц
  2. **Bitmap Heap Scan** — идём в таблицу, читаем страницы в физическом порядке
- Когда планировщик выбирает Bitmap Scan:
  - Много строк, но недостаточно для Seq Scan
  - Несколько индексов на одну таблицу → битовые карты можно OR/AND-ить
- Пример: `SELECT * FROM transactions WHERE card_id BETWEEN 100 AND 500;` — много строк, индекс есть, но прыгать по таблице для каждой — дорого
- Пример с двумя условиями: `WHERE card_id = 123 OR merchant_id = 5` → две битовые карты → OR

## 6. Типы индексов: краткий обзор

- **B-tree** — 99% случаев, сортировка, диапазоны, равенство
- **Hash** — только равенство `=`, быстрее B-tree на очень больших ключах (UUID!)
- **GIN** — полнотекстовый поиск, JSONB, массивы
- **GiST** — геометрия, полнотекстовый поиск
- **BRIN** — очень большие таблицы с коррелированными данными (временные ряды)

## 7. Когда обычный индекс не работает

- **`LIKE '%pattern%'`** — B-tree не помогает (префиксный wildcard)
  - Решение: GIN + `pg_trgm` → `CREATE INDEX idx_trgm ON users USING gin(email gin_trgm_ops);`
- **Функция в WHERE**: `WHERE lower(email) = 'user1@test.com'`
  - Решение: функциональный индекс → `CREATE INDEX idx_email_lower ON users(lower(email));`
- **JSONB-поиск**: `WHERE localized_names->>'en' = 'Customer 1'` — обычный индекс не работает
  - Решение: GIN-индекс на JSONB → `CREATE INDEX idx_names ON users USING gin(localized_names);`

---

## Запросы для ручного тестирования

### Seq Scan (нет индекса)
```sql
-- amount без индекса = Seq Scan на обеих БД
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

### Seq Scan при наличии индекса (большая выборка)
```sql
-- На большой БД RUB ~1M строк = 20% → Seq Scan даже с индексом
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric = 643;
```

### Index Scan
```sql
-- Точечный запрос = Index Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 42;
```

### Index Only Scan (покрывающий индекс)
```sql
-- Без покрывающего: Index Scan (amount не в индексе)
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 42;

-- Создаём покрывающий
CREATE INDEX idx_tx_card_amount ON transactions(card_id, amount);

-- Теперь Index Only Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 42;
```

### Bitmap Heap Scan (диапазон)
```sql
-- Много строк, но не вся таблица = Bitmap
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id BETWEEN 100 AND 500;
```

### Bitmap + два условия
```sql
-- Два индекса → две битовые карты
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions
WHERE card_id = 123 OR merchant_id = 5;
```

### Индекс не работает — LIKE
```sql
-- B-tree не поможет
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email LIKE '%user1%';

-- Включаем pg_trgm и создаём GIN
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_users_email_trgm ON users USING gin(email gin_trgm_ops);

-- Теперь Bitmap Index Scan по GIN!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email LIKE '%user1%';
```

### Индекс не работает — функция
```sql
-- Не используется индекс idx_users_email
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1@test.com';

-- Функциональный индекс
CREATE INDEX idx_users_email_lower ON users(lower(email));

-- Теперь Index Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1@test.com';
```

### Индекс не работает — JSONB
```sql
-- Обычный индекс не используется
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE localized_names->>'en' = 'Customer 42';

-- GIN на JSONB
CREATE INDEX idx_users_names ON users USING gin(localized_names);

-- Bitmap по GIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE localized_names->>'en' = 'Customer 42';
```
