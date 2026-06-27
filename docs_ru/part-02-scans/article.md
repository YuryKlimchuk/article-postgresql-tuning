# Твой PostgreSQL — это болид F1. Хватит ездить на первой передаче
## Часть 2: Способы доступа к данным — от Seq Scan до Index Only Scan

В [первой части](ссылка) мы подняли два экземпляра PostgreSQL — малую БД (`payment_small`, ~50K транзакций) и большую (`payment_large`, ~5M транзакций). Теперь пришло время запустить первые запросы и посмотреть, как PostgreSQL ищет данные.

**Цель этой части:** научиться читать `EXPLAIN ANALYZE` и понять, почему PostgreSQL выбирает тот или иной способ доступа к данным. Мы увидим, как один и тот же запрос на 50 тысячах строк и на 5 миллионах строк выполняется совершенно по-разному.

---

## 1. EXPLAIN ANALYZE — ваш новый лучший друг

Прежде чем разбираться с типами сканирования, нужно научиться смотреть «под капот» PostgreSQL. Для этого используется команда `EXPLAIN`.

### EXPLAIN vs EXPLAIN ANALYZE

Есть важное различие:

- **`EXPLAIN`** — показывает *план* выполнения запроса, который построил планировщик PostgreSQL. Запрос **не выполняется**, вы видите только оценку стоимости.
- **`EXPLAIN (ANALYZE)`** — **выполняет** запрос и показывает реальные метрики: сколько времени заняло, сколько строк было прочитано, сколько памяти использовано.

**Всегда используйте `EXPLAIN (ANALYZE, BUFFERS)`** для отладки производительности.

### Ключевые метрики в выводе

Запустите первый тестовый запрос на **обеих** базах (не забудьте сначала обновить статистику):

```sql
-- Обновляем статистику перед тестами
ANALYZE transactions;

-- Тестовый запрос
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

Вы увидите что-то вроде:

```
Seq Scan on transactions  (cost=0.00..123456.78 rows=500000 width=120) 
                          (actual time=0.123..456.789 rows=450000 loops=1)
  Filter: (amount > 5000)
  Rows Removed by Filter: 50000
  Buffers: shared hit=1000 read=5000
```

Разберём по частям:

| Метрика | Что означает |
|---------|--------------|
| **cost=0.00..123456.78** | Оценка стоимости: первое число — стоимость старта, второе — общая стоимость. Это *условные единицы*, которые PostgreSQL использует для сравнения разных путей. Планировщик выбирает путь с наименьшей cost. |
| **actual time=0.123..456.789** | Реальное время в миллисекундах: первое — время до возврата первой строки, второе — общее время выполнения. |
| **rows=450000** | Сколько строк фактически вернул узел. |
| **loops=1** | Сколько раз выполнился этот узел. |
| **Buffers: shared hit/read** | `hit` — данные были в кэше (RAM), `read` — пришлось читать с диска. Чем больше `read`, тем медленнее. |

**Ключевой момент:** Сравнивайте вывод на малой и большой БД. На малой запрос выполнится за миллисекунды, на большой — за секунды. Это и есть разница между «тестом» и «продом».

---

## 2. Последовательное сканирование (Seq Scan)

### Что происходит

PostgreSQL читает **всю таблицу** страницу за страницей, проверяя каждую строку на соответствие условию `WHERE`. Это самый простой, но не всегда самый быстрый способ.

### Пример: нет индекса

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE amount > 5000;
```

На поле `amount` нет индекса → PostgreSQL вынужден читать всю таблицу. На малой БД это займёт миллисекунды, на большой — секунды.

### Seq Scan при наличии индекса — важный нюанс

Теперь запрос с индексом:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE currency_numeric = 643;
```

На поле `currency_numeric` **есть индекс** (мы создали его в `schema.sql`), но на **большой БД** вы, скорее всего, увидите **Seq Scan**, а не Index Scan!

**Почему?** Потому что в нашей генерации данных ~20% транзакций в рублях (currency_numeric = 643). Когда нужно выбрать большой процент строк, PostgreSQL говорит: *«Проще прочитать всю таблицу подряд, чем прыгать по индексу и потом лезть в таблицу за каждой строкой»*.

Это происходит из-за соотношения стоимости случайных и последовательных чтений:
- `seq_page_cost` (по умолчанию 1.0) — стоимость последовательного чтения страницы
- `random_page_cost` (по умолчанию 4.0) — стоимость случайного чтения страницы

**Правило:** Если планировщик estime, что нужно выбрать **> 5-15% строк**, он может выбрать Seq Scan. Точный порог зависит от `random_page_cost`, размера таблицы и распределения данных.

**Проверьте на малой БД:** Там тоже будет Seq Scan, но выполнится он мгновенно. Это показывает, почему проблемы производительности не видны на тестовом окружении.

### Parallel Seq Scan

На **большой БД** вы можете увидеть `Parallel Seq Scan`:

```
Gather  (cost=0.00..123456.78 rows=1000000 width=120)
  Workers Planned: 2
  ->  Parallel Seq Scan on transactions
```

PostgreSQL запускает несколько воркеров для параллельного чтения таблицы. Это ускоряет запрос, но потребляет больше CPU. Количество воркеров зависит от параметра `max_parallel_workers_per_gather` (по умолчанию 2).

---

## 3. Индексное сканирование (Index Scan)

### B-tree — основной индекс

Когда вы создаёте индекс без указания типа:

```sql
CREATE INDEX idx_transactions_card_id ON transactions(card_id);
```

PostgreSQL создаёт **B-tree** (сбалансированное дерево). Это универсальный индекс, который работает для:
- Равенства (`=`)
- Диапазонов (`>`, `<`, `BETWEEN`)
- Сортировки (`ORDER BY`)

### Что происходит при Index Scan

1. PostgreSQL идёт по B-tree, находя нужные записи
2. Для каждой найденной записи идёт в **таблицу (heap)** за остальными колонками

### Пример: точечный запрос

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 42;
```

Вы увидите:

```
Index Scan using idx_transactions_card_id on transactions
  Index Cond: (card_id = 42)
  Buffers: shared hit=10 read=5
```

**Сравните время** с Seq Scan на том же запросе (если бы индекса не было). Разница будет в разы, особенно на большой БД.

### Реальные ID для тестов

В наших данных ID начинаются не с 1, а с случайных значений. Чтобы получить реальный ID для теста:

```sql
-- Получаем существующий card_id
SELECT card_id FROM transactions LIMIT 1;

-- Используем его в запросе
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions 
WHERE card_id = (SELECT card_id FROM transactions LIMIT 1);
```

---

## 4. Покрывающий индекс (Index Only Scan)

### Проблема Index Scan

Index Scan всё равно ходит в таблицу за колонками, которых нет в индексе. Это дополнительные I/O операции.

### Решение: покрывающий индекс

Если все нужные колонки есть в индексе, PostgreSQL может ответить, **не заглядывая в таблицу**. Это называется **Index Only Scan**.

#### Пример

```sql
-- Запрос выбирает только card_id и amount
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 42;
```

Если индекс только на `card_id`:

```
Index Scan using idx_transactions_card_id on transactions
  Index Cond: (card_id = 42)
```

PostgreSQL всё равно идёт в таблицу за `amount` (его нет в индексе).

Создаём покрывающий индекс:

```sql
CREATE INDEX idx_tx_card_amount ON transactions(card_id, amount);
```

Теперь тот же запрос:

```
Index Only Scan using idx_tx_card_amount on transactions
  Index Cond: (card_id = 42)
```

**Index Only Scan!** PostgreSQL ответил, используя только индекс.

### Сравнение Buffers

Запустите оба варианта с `BUFFERS` и сравните:
- Index Scan: больше `shared hit/read` (читает и индекс, и таблицу)
- Index Only Scan: меньше `shared hit/read` (читает только индекс)

### Ограничение: Visibility Map

Index Only Scan не всегда работает идеально. PostgreSQL должен проверить, видна ли строка текущей транзакции (MVCC). Для этого используется **Visibility Map**. Если данные «старые» и уже vacuumed, Index Only Scan сработает. Если нет — PostgreSQL всё равно заглянет в таблицу.

В выводе вы увидите строку `Heap Fetches: N` — сколько раз пришлось идти в таблицу. В идеале `Heap Fetches: 0`.

---

## 5. Битовая карта (Bitmap Heap Scan)

### Двухфазный подход

Иногда строк много, но недостаточно для Seq Scan. PostgreSQL использует хитрый трюк:

1. **Bitmap Index Scan** — проходит по индексу, строит битовую карту страниц, которые содержат нужные строки
2. **Bitmap Heap Scan** — идёт в таблицу и читает страницы **в физическом порядке** (а не в логическом порядке индекса)

Это эффективнее, чем Index Scan, когда нужно выбрать много строк: вместо случайных чтений для каждой строки, PostgreSQL читает страницы пачками.

### Пример: диапазон

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id BETWEEN 100 AND 500;
```

Если диапазон возвращает тысячи строк, вы увидите:

```
Bitmap Heap Scan on transactions
  ->  Bitmap Index Scan using idx_transactions_card_id
        Index Cond: ((card_id >= 100) AND (card_id <= 500))
```

### Несколько условий

Битовые карты можно комбинировать через `OR` и `AND`:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions
WHERE card_id = 123 OR merchant_id = 5;
```

Вы увидите:

```
Bitmap Heap Scan on transactions
  ->  BitmapOr
        ->  Bitmap Index Scan using idx_transactions_card_id
              Index Cond: (card_id = 123)
        ->  Bitmap Index Scan using idx_transactions_merchant_id
              Index Cond: (merchant_id = 5)
```

PostgreSQL построил две битовые карты и объединил их через `OR`.

---

## 6. Типы индексов — краткий обзор

PostgreSQL поддерживает несколько типов индексов. Вот основные:

| Тип | Когда использовать |
|-----|-------------------|
| **B-tree** | 99% случаев. Равенство, диапазоны, сортировка. |
| **Hash** | Только равенство (`=`). Может быть быстрее B-tree для очень больших ключей (UUID). |
| **GIN** | Полнотекстовый поиск, JSONB, массивы. |
| **GiST** | Геометрия, полнотекстовый поиск. |
| **BRIN** | Очень большие таблицы с коррелированными данными (временные ряды, логи). |

В этой статье мы фокусируемся на **B-tree** и **GIN** (для JSONB).

---

## 7. Когда обычный индекс не работает

B-tree индекс не всегда помогает. Вот три распространённых случая и их решения.

### Случай 1: LIKE с wildcard в начале

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email LIKE '%user1%';
```

B-tree индекс **не поможет**, потому что `%` в начале строки означает, что индекс не может использовать сортировку.

**Решение:** GIN-индекс с расширением `pg_trgm` (триграммы):

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_users_email_trgm ON users USING gin(email gin_trgm_ops);

-- Теперь используется Bitmap Index Scan по GIN!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE email LIKE '%user1%';
```

### Случай 2: Функция в WHERE

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1@test.com';
```

Обычный индекс на `email` **не используется**, потому что PostgreSQL не знает, что `lower(email)` можно индексировать.

**Решение:** Функциональный индекс:

```sql
CREATE INDEX idx_users_email_lower ON users(lower(email));

-- Теперь Index Scan!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1@test.com';
```

### Случай 3: JSONB-поиск

В нашей схеме `users.localized_names` — это JSONB:

```json
{"en": "Customer 42", "ru": "Пользователь 42", "zh": "用户 42"}
```

Обычный запрос:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE localized_names->>'en' = 'Customer 42';
```

B-tree индекс **не поможет** для поиска внутри JSON.

**Решение:** GIN-индекс на JSONB:

```sql
CREATE INDEX idx_users_names ON users USING gin(localized_names);

-- Теперь Bitmap Index Scan по GIN!
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE localized_names->>'en' = 'Customer 42';
```

GIN-индекс позволяет быстро искать по ключам и значениям внутри JSONB.

---

## Сводная таблица типов сканирования

| Тип | Когда используется | Плюсы | Минусы |
|-----|-------------------|-------|--------|
| **Seq Scan** | Маленькая таблица ИЛИ большая выборка (>5-15%) | Простой, последовательное чтение | Медленный на больших таблицах |
| **Index Scan** | Точечный запрос или малая выборка | Быстрый для малых выборок | Случайные чтения в таблицу |
| **Index Only Scan** | Все колонки в индексе | Не ходит в таблицу | Требует покрывающего индекса |
| **Bitmap Scan** | Средняя выборка, несколько условий | Эффективен для множества строк | Дополнительная память для битовой карты |

---

## Что дальше

В этой части мы разобрали основные способы доступа к данным. В **Части 3** мы перейдём к **JOIN** — как PostgreSQL соединяет таблицы и почему типы данных (INT vs UUID vs VARCHAR) критически влияют на производительность.

Мы увидим:
- **Nested Loop Join** — когда он эффективен
- **Hash Join** — почему `work_mem` важен
- **Merge Join** — когда данные уже отсортированы
- Как JOIN по `INT` работает в 10 раз быстрее, чем JOIN по `UUID` или `VARCHAR`

А пока поэкспериментируйте с запросами на обеих базах и посмотрите, как меняются планы выполнения. Весь код доступен в [репозитории](https://github.com/YuryKlimchuk/article-postgresql-tuning).

---

**Продолжение следует...**

*Если статья была полезной — ставьте 👏, подписывайтесь на серию и делитесь с коллегами. Вопросы и замечания — в комментариях.*