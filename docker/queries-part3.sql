-- ============================================
-- ЧАСТЬ 3: Index Scan и Index Only Scan
-- Чистый прогон всех запросов
-- ============================================

\set QUIET 1
\timing on

SET jit = OFF;
SET max_parallel_workers_per_gather = 0;

\echo '========================================================='
\echo 'БАЗОВАЯ ИНФОРМАЦИЯ О БД'
\echo '========================================================='
SELECT COUNT(*) AS transactions_count FROM transactions;
SELECT COUNT(*) AS user_cards_count FROM user_cards;
SELECT card_id, COUNT(*) AS cnt FROM transactions WHERE card_id = 1 GROUP BY card_id;

\echo ''
\echo '========================================================='
\echo '1. INDEX SCAN — точечный запрос card_id = 1'
\echo '========================================================='

-- Прогрев: первый запрос всегда медленнее
\echo '>>> Прогрев (первый запуск):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;

\echo ''
\echo '>>> Второй запуск (данные в кэше):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;

\echo ''
\echo '========================================================='
\echo '2. INDEX SCAN vs SEQ SCAN — прямое сравнение'
\echo '========================================================='

\echo '>>> С индексами (Index Scan):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;

-- Отключаем индексы
SET enable_indexscan = OFF;
SET enable_bitmapscan = OFF;

\echo ''
\echo '>>> Без индексов (Seq Scan) — принудительно:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE card_id = 1;

-- Возвращаем
SET enable_indexscan = ON;
SET enable_bitmapscan = ON;

\echo ''
\echo '========================================================='
\echo '3. СОСТАВНОЙ ИНДЕКС на user_cards(user_id, status)'
\echo '========================================================='

\echo '>>> Без составного индекса (фильтр status в heap):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_cards WHERE user_id = 1 AND status = 'ACTIVE';

-- Создаём составной индекс
CREATE INDEX idx_uc_user_status ON user_cards(user_id, status);
ANALYZE user_cards;

\echo ''
\echo '>>> С составным индексом (user_id, status):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_cards WHERE user_id = 1 AND status = 'ACTIVE';

\echo ''
\echo '>>> Leftmost prefix — запрос только по user_id:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_cards WHERE user_id = 1;

\echo ''
\echo '>>> Запрос только по status — НЕ использует индекс:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM user_cards WHERE status = 'ACTIVE';

\echo ''
\echo '========================================================='
\echo '4. INDEX ONLY SCAN — покрывающий индекс'
\echo '========================================================='

-- Сначала Index Scan (amount нет в индексе)
\echo '>>> Index Scan — amount не в индексе, ходим в heap:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

-- Создаём покрывающий индекс
CREATE INDEX idx_tx_card_amount ON transactions(card_id, amount);
ANALYZE transactions;

\echo ''
\echo '>>> Index Only Scan — покрывающий индекс (card_id, amount):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '>>> Повторный запуск (индекс в кэше):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '========================================================='
\echo '5. INCLUDE-индекс (amount только в листьях)'
\echo '========================================================='

DROP INDEX IF EXISTS idx_tx_card_amount;
CREATE INDEX idx_tx_card_inc ON transactions(card_id) INCLUDE (amount);
ANALYZE transactions;

\echo '>>> Index Only Scan с INCLUDE-индексом:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '>>> Повторный запрос (индекс в кэше):'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '========================================================='
\echo '6. VISIBILITY MAP — эксперимент с UPDATE и VACUUM'
\echo '========================================================='

\echo '>>> Шаг 1: после INSERT — всё чисто:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '>>> Шаг 2: UPDATE — страницы становятся грязными:'
UPDATE transactions SET amount = amount WHERE card_id = 1;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '>>> Шаг 3: VACUUM — чистим Visibility Map:'
VACUUM transactions;

EXPLAIN (ANALYZE, BUFFERS)
SELECT card_id, amount FROM transactions WHERE card_id = 1;

\echo ''
\echo '========================================================='
\echo 'ГОТОВО'
\echo '========================================================='
