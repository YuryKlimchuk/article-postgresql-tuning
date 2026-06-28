# Твой PostgreSQL — это болид F1. Хватит ездить на первой передаче
## Часть 5: Когда индекс не работает и ширина строки — финальные штрихи

В [предыдущей части](ссылка-на-часть-4) мы освоили Bitmap Scan и познакомились с Hash, GIN и BRIN-индексами. Но бывают ситуации, когда даже правильный индекс не спасает.

**В этой части:** три антипаттерна — `LIKE '%...'`, функции в WHERE и JSONB-поиск — и как их исправить. А затем разберём `width` — скрытый фактор производительности, из-за которого `SELECT *` на таблице с TOAST-полями убивает любой Index Scan.

---

## 7. Когда обычный индекс не работает

B-tree индекс не всегда помогает. Вот три распространённых случая и их решения.

### Случай 1: LIKE с wildcard в начале

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email LIKE '%user1%';
```

B-tree индекс не поможет — `%` в начале означает, что индекс не может использовать сортировку.

**Большая БД (500K users, без GIN):**

```
Seq Scan on users
  (actual time=0.383..75.121 rows=111111 loops=1)
  Filter: ((email)::text ~~ '%user1%'::text)
  Rows Removed by Filter: 388889
  Buffers: read=11016
  Execution Time: 77.960 ms
```

**Решение:** GIN-индекс с расширением `pg_trgm` (триграммы — тройки символов):

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_users_email_trgm ON users USING gin(email gin_trgm_ops);
ANALYZE users;
```

**После GIN-индекса:**

```
Bitmap Heap Scan on users
  (actual time=10.313..26.843 rows=111111 loops=1)
  Heap Blocks: exact=2463
  Buffers: shared hit=10 read=2518
  ->  Bitmap Index Scan on idx_users_email_trgm
        (actual time=10.082..10.083 rows=111111 loops=1)
        Buffers: shared hit=10 read=55
  Execution Time: 29.622 ms
```

**Результат:** время с 78ms до 30ms (×2.6), буферов с 11 016 до 2 518 (×4.4).

Почему «всего» ×2.6, а не ×100 как в других случаях? Запрос `LIKE '%user1%'` возвращает 111 111 строк из 500 000 — это 22% таблицы. GIN-индекс ускорил поиск, но PostgreSQL всё равно читает 2 463 страницы таблицы (`Heap Blocks: exact=2463`). Для точечного поиска — где паттерн встречается в единичных строках — ускорение будет в сотни раз. Эффективность индекса всегда зависит от селективности запроса.

Тот же GIN-индекс работает и для `ILIKE` (регистронезависимый поиск), и для операторов нечёткого сравнения из `pg_trgm`:

```sql
-- Нечёткий поиск: насколько строки похожи
SELECT * FROM users WHERE similarity(email, 'user@test.com') > 0.5;

-- Оператор % — строки похожи?
SELECT * FROM users WHERE email % 'user@test.com';
```

pg_trgm + GIN — это не только для `LIKE`, а полноценный инструмент нечёткого поиска по тексту.

### Случай 2: Функция в WHERE

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1@test.com';
```

Обычный индекс на `email` **не используется** — PostgreSQL не знает, что `lower(email)` эквивалентно чему-то проиндексированному.

**Большая БД (500K users, без функционального индекса):**

```
Seq Scan on users
  (actual time=0.308..143.290 rows=1 loops=1)
  Filter: (lower((email)::text) = 'user1@test.com'::text)
  Rows Removed by Filter: 499999
  Buffers: shared hit=128 read=10888
  Execution Time: 143.311 ms
```

Прочитано 500K строк, найдена одна — почти полсекунды на пустом месте.

**Решение:** функциональный индекс:

```sql
CREATE INDEX idx_users_email_lower ON users(lower(email));
ANALYZE users;
```

**После:**

```
Index Scan using idx_users_email_lower on users
  (actual time=0.022..0.022 rows=1 loops=1)
  Index Cond: (lower((email)::text) = 'user1@test.com'::text)
  Buffers: read=4
  Execution Time: 0.038 ms
```

**Результат:** время с 143ms до 0.038ms (**×3 770**), буферов с 11 016 до 4.

### Случай 3: JSONB-поиск

В нашей схеме `users.localized_names` — это JSONB:

```json
{"en": "Customer 42", "ru": "Пользователь 42", "zh": "用户 42"}
```

**Большая БД (500K users, без GIN):**

```
Seq Scan on users
  (actual time=0.020..75.689 rows=1 loops=1)
  Filter: ((localized_names ->> 'en'::text) = 'Customer 42'::text)
  Rows Removed by Filter: 499999
  Buffers: shared hit=257 read=10759
  Execution Time: 75.707 ms
```

**Решение:** GIN-индекс на JSONB. Важно: для поиска нужно использовать оператор `@>`, а не `->>`:

```sql
CREATE INDEX idx_users_names ON users USING gin(localized_names);
ANALYZE users;

-- Правильный оператор для JSONB с GIN-индексом
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE localized_names @> '{"en": "Customer 42"}';
```

**После:**

```
Bitmap Heap Scan on users
  (actual time=0.096..0.096 rows=1 loops=1)
  Recheck Cond: (localized_names @> '{"en": "Customer 42"}'::jsonb)
  Heap Blocks: exact=1
  Buffers: shared hit=5 read=5
  ->  Bitmap Index Scan on idx_users_names
        (actual time=0.090..0.090 rows=1 loops=1)
        Buffers: shared hit=4 read=5
  Execution Time: 0.132 ms
```

**Результат:** время с 75.7ms до 0.132ms (**×573**), буферов с 11 016 до 10.

### Когда НЕ использовать GIN и функциональные индексы

У специализированных индексов есть цена:

- **GIN-индексы** (pg_trgm, JSONB) могут быть в 2-5 раз больше B-tree — больше места на диске и в кэше
- Они замедляют `INSERT`, `UPDATE` и `DELETE` — PostgreSQL обновляет обратный индекс при каждом изменении
- **Функциональные индексы** тоже замедляют запись — функция вычисляется для каждой вставляемой/обновляемой строки

**Правило:** создавайте такие индексы только когда `pg_stat_statements` показал медленный запрос, и вы уверены, что выигрыш в чтении перевесит потерю в записи. Не создавайте их превентивно «на всякий случай».

---

Сводка по всем трём случаям:

| Случай | До (Seq Scan) | После (с индексом) | Ускорение |
|--------|---------------|-------------------|-----------|
| `LIKE '%user1%'` | 77.9 ms | 29.6 ms | **×2.6** |
| `lower(email) = ...` | 143.3 ms | 0.038 ms | **×3 770** |
| `JSONB @> ...` | 75.7 ms | 0.132 ms | **×573** |

**Итоговый чек-лист:**

- `LIKE '%pattern%'` или `ILIKE` → pg_trgm + GIN (×2-10 для больших выборок, ×100+ для точечных)
- Функция в `WHERE` → функциональный индекс (×1000+ для точечных запросов)
- Поиск внутри JSONB → GIN + оператор `@>` (×100-1000)

**Порядок действий:** сначала найдите медленный запрос через `pg_stat_statements` → затем создайте индекс под него. Не превентивно, а прицельно.

---

## 8. Width — скрытый фактор производительности

Обратите внимание на метрику `width` в выводе `EXPLAIN`:

```
Index Scan using idx_transactions_card_id on transactions
  (cost=0.28..8.30 rows=5 width=120)
```

`width=120` — это **средний размер строки в байтах** на этом шаге плана. Почему это важно?

### Как считается width

Каждая строка в PostgreSQL состоит из:

```
| tuple header (23 байта) | значения полей | padding | TOAST pointer (опционально) |
```

- **Tuple header** — 23 байта: служебная информация (xmin, xmax, указатели и т.д.)
- **Значения полей** — сумма размеров всех колонок
- **Padding** — выравнивание до границы 8 байт (процессор быстрее читает выровненные данные)
- **TOAST pointer** — если поле не влезает в страницу, хранится только указатель (18 байт)

**Пример расчёта для нашей таблицы `transactions`:**

| Поле | Тип | Размер |
|------|-----|--------|
| `id` | BIGSERIAL | 8 байт |
| `card_id` | BIGINT | 8 байт |
| `merchant_id` | INT | 4 байта |
| `amount` | NUMERIC(12,2) | ~10-12 байт |
| `currency_numeric` | SMALLINT | 2 байта |
| `currency_alpha` | CHAR(3) | ~4 байта (CHAR + padding) |
| `transaction_time` | TIMESTAMP | 8 байт |
| `description` | TEXT | 4-18 байт (короткий текст / TOAST pointer) |

Сумма значений полей: ~48 байт. Tuple header: 23 байта. Padding: ~5 байт. **Итого: ~76 байт** без учёта TOAST.

Если `description` короткий (~70 байт, как в малой БД с `repeat(..., 3)`) → width ≈ 48 + 23 + 5 + 70 = **~146 байт**. Реальный EXPLAIN показал `width=155` — близко!

Если `description` длиннее (~140 байт, как в большой БД с `repeat(..., 5)`) → width ≈ 48 + 23 + 5 + 140 = **~216 байт**. Реальный EXPLAIN: `width=214`. Совпадение почти идеальное.

Так рождается разница 155 vs 214, которую мы видели в разделе 1. +60 байт на строку × 5 миллионов строк = **300 МБ лишнего I/O** — просто потому что TOAST-поле длиннее.

### Как PostgreSQL хранит данные

PostgreSQL хранит данные на **страницах по 8 КБ** (8192 байта). Таблица — это набор страниц. Когда PostgreSQL читает таблицу, он читает страницы целиком, даже если нужна одна строка.

Простая арифметика:
- Строка 100 байт → на страницу помещается **~80 строк**
- Строка 400 байт → на страницу помещается **~20 строк**

**Меньше размер строки → больше строк на странице → меньше страниц читать → меньше I/O.**

### Практический пример: BIGINT vs SMALLINT

Создадим две тестовые таблицы с одинаковыми данными, но разными типами:

```sql
-- Таблица с «тяжёлыми» типами
CREATE TABLE test_heavy (
    id BIGINT PRIMARY KEY,
    amount BIGINT,
    status BIGINT,
    created_at TIMESTAMP
);

-- Таблица с минимально достаточными типами
CREATE TABLE test_light (
    id INT PRIMARY KEY,
    amount INT,
    status SMALLINT,
    created_at DATE
);

-- Наполняем одинаковыми данными
INSERT INTO test_heavy
SELECT i, (random() * 10000)::BIGINT, (random() * 3)::BIGINT, NOW() - (random() * 365)::INT * INTERVAL '1 day'
FROM generate_series(1, 100000) AS i;

INSERT INTO test_light
SELECT i, (random() * 10000)::INT, (random() * 3)::SMALLINT, (NOW() - (random() * 365)::INT * INTERVAL '1 day')::DATE
FROM generate_series(1, 100000) AS i;

-- Сравниваем размер таблиц
SELECT
    relname,
    pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
    pg_size_pretty(pg_relation_size(oid)) AS table_size
FROM pg_class
WHERE relname IN ('test_heavy', 'test_light');
```

Пример результата:

```
  relname   | total_size | table_size
------------+------------+------------
 test_heavy | 6240 kB    | 5120 kB
 test_light | 4200 kB    | 3640 kB
```

Разница в **1.5 раза** на 100K строк — только за счёт правильного выбора типов. На миллионах строк это гигабайты.

Теперь `EXPLAIN` подтверждает:

```sql
EXPLAIN SELECT * FROM test_heavy;
-- width=48

EXPLAIN SELECT * FROM test_light;
-- width=22
```

`width` меньше в 2 раза → на той же странице в 2 раза больше строк. Производительность растёт без единого индекса.

### Реальный пример из нашей схемы: SELECT * vs выбор колонок

В таблице `transactions` поле `description` типа `TEXT` заполнено «тяжёлыми» данными — `repeat('Lorem ipsum...', 5)`. Посмотрим, как это влияет на большой БД:

**SELECT \* (все колонки, включая description):**

```
Index Scan using idx_tx_card_amount_include on transactions
  (cost=0.43..8.80 rows=21 width=214)
  (actual time=0.176..0.177 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=3 read=4
  Execution Time: 0.192 ms
```

**SELECT колонок (без description):**

```
Index Scan using idx_tx_card_amount_include on transactions
  (cost=0.43..8.80 rows=21 width=34)
  (actual time=0.045..0.047 rows=5 loops=1)
  Index Cond: (card_id = 1)
  Buffers: shared hit=4
  Execution Time: 0.073 ms
```

Тот же Index Scan, тот же `card_id = 1`. Но `width` 34 вместо 214 (в 6 раз меньше), `Buffers` только hit (без read), время 0.073ms вместо 0.192ms (**×2.6 быстрее**). PostgreSQL читает меньше страниц, потому что не тащит TOAST-значения.

### Правила оптимизации width

**Выбирайте минимально достаточный тип:**

| Вместо | Используйте | Экономия |
|--------|-------------|----------|
| `BIGINT` (8 байт) | `INT` (4 байта) или `SMALLINT` (2 байта) | 2-4× |
| `TIMESTAMP` (8 байт) | `DATE` (4 байта) — если время не нужно | 2× |
| `VARCHAR(255)` | Реальный лимит: `VARCHAR(100)` для email | В PostgreSQL `VARCHAR(n)` хранит только реальные символы — `VARCHAR(255)` и `VARCHAR(100)` занимают одинаково для коротких строк. Но ограничение в 100 защищает от случайных ошибок и делает схему понятнее. |

**Сколько весят типы данных PostgreSQL:**

| Тип | Байт |
|-----|------|
| `BOOLEAN` | 1 |
| `SMALLINT` | 2 |
| `INT` / `INTEGER` / `DATE` | 4 |
| `BIGINT` / `TIMESTAMP` / `TIMESTAMPTZ` / `REAL` | 8 |
| `UUID` | 16 |
| `NUMERIC(p,s)` | переменный, ~5-12 байт в зависимости от точности |
| `CHAR(n)` | n + padding до 4 байт |
| `VARCHAR(n)` / `TEXT` | 4 байта заголовка + длина строки. Если > 2 КБ → TOAST pointer (18 байт) |

**Не используйте `SELECT *` в продакшене:**
- Забирайте только нужные колонки
- Особенно важно для таблиц с `TEXT` / `JSONB` / `BYTEA` — они могут быть в TOAST
- Даже Index Only Scan не спасёт, если выбираете колонки, не входящие в индекс

**Избавляйтесь от избыточных полей:**
- `VARCHAR(200)` для email? Достаточно `VARCHAR(100)`
- `BIGINT` для справочника из 100 записей? Достаточно `SMALLINT`
- Дублирующиеся данные в JSONB, которые можно вынести в отдельную таблицу

**Итог:** `width` — средний размер строки в байтах. Чем он меньше, тем больше строк на странице и тем меньше I/O. Ключевые правила:
- Выбирайте минимально достаточный тип (`SMALLINT` вместо `BIGINT`, `DATE` вместо `TIMESTAMP`)
- Не используйте `SELECT *` в продакшене, особенно для таблиц с `TEXT`/`JSONB`/`BYTEA`
- Помните про TOAST — длинные значения хранятся отдельно, но указатель (18 байт) остаётся в строке
- Разница в 60 байт на 5 миллионах строк = **300 МБ лишнего I/O**

---


## Советы пилота: что вынести из серии о сканировании

1. **Всегда `EXPLAIN (ANALYZE, BUFFERS)`** — без него вы гадаете, с ним вы знаете
2. **Забирайте только нужные колонки** — `SELECT *` тянет TOAST и убивает производительность
3. **Помните про селективность** — индекс по полю с 3-4 уникальными значениями часто бесполезен
4. **Создавайте покрывающие индексы** — Index Only Scan не ходит в таблицу
5. **Настройте `random_page_cost` под железо** — SSD → 1.0-1.5, иначе планировщик избегает индексов
6. **Не забывайте `ANALYZE` после массовых вставок** — устаревшая статистика = плохие планы
7. **Следите за `work_mem`** — если видите `lossy` в Bitmap Scan, увеличивайте
8. **Следите за `width`** — меньше размер строки = больше строк в кэше = меньше I/O

---


## Что дальше

В этой серии мы разобрали, как PostgreSQL ищет данные в одной таблице. Но реальные приложения почти всегда работают с несколькими таблицами через JOIN.

В следующей серии — **JOIN-ы**: как PostgreSQL соединяет таблицы и почему тип внешнего ключа (INT vs UUID vs VARCHAR) меняет скорость JOIN в 10 раз. Nested Loop, Hash Join, Merge Join — всё на реальных цифрах из нашей схемы.

Исходные файлы серии доступны в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).

---

**Конец серии о сканировании.**

*Вопросы и замечания — в комментариях. Исходные файлы — в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).*
