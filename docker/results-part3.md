## Реальные результаты прогона — Часть 3 (07.07.2026)

### Малая БД (50K transactions, 25 tx для card_id=1)

| Запрос | Execution Time | Buffers | Heap Fetches | Rows Removed | cost |
|--------|---------------|---------|-------------|-------------|------|
| Index Scan (card_id=1) | 0.027 ms | 3 hit | — | — | 0.29..8.73 |
| Seq Scan (принудительно) | 7.374 ms | 1 hit + 1219 read | — | 49 975 | 0.00..1845.00 |
| Index Only Scan (card_id, amount) | 0.030 ms | 3 hit | 0 | — | 0.29..4.73 |
| INCLUDE (card_id) INCLUDE (amount) | 0.045 ms | 3 hit | 0 | — | 0.29..4.73 |

**Visibility Map (малая БД):**
| Шаг | Heap Fetches | Buffers |
|-----|-------------|---------|
| После INSERT | 0 | 3 hit |
| После UPDATE | 50 | 6 hit |
| После VACUUM | 0 | 3 hit |

### Большая БД (5M transactions, 5 tx для card_id=1)

| Запрос | Execution Time | Buffers | Heap Fetches | Rows Removed | cost |
|--------|---------------|---------|-------------|-------------|------|
| Index Scan (card_id=1) | 0.022 ms | 4 hit | — | — | 0.43..8.80 |
| Seq Scan (принудительно) | 388.290 ms | 128 hit + 156 122 read | — | 4 999 995 | 0.00..218750.00 |
| Index Only Scan (card_id, amount) | 0.034 ms | 4 hit | 0 | — | 0.43..4.80 |
| INCLUDE (card_id) INCLUDE (amount) | 0.042 ms | 4 hit | 0 | — | 0.43..4.80 |

**Visibility Map (большая БД):**
| Шаг | Heap Fetches | Buffers |
|-----|-------------|---------|
| После INSERT | 0 | 4 hit |
| После UPDATE | 10 | 7 hit |
| После VACUUM | 0 | 4 hit |

### Сравнение Index Scan vs Seq Scan

| Метрика | Малая БД (Index) | Малая БД (Seq) | Большая БД (Index) | Большая БД (Seq) |
|---------|-----------------|----------------|-------------------|------------------|
| Execution Time | 0.027 ms | 7.374 ms | 0.022 ms | 388.290 ms |
| Разница | — | **×273** | — | **×17 650** |
| Buffers | 3 hit | 1 hit + 1 219 read | 4 hit | 128 hit + 156 122 read |
| Rows Removed | — | 49 975 | — | 4 999 995 |
| cost | 0.29..8.73 | 0.00..1 845 | 0.43..8.80 | 0.00..218 750 |

### Составной индекс user_cards(user_id, status)

| Метрика | Малая БД (без сост.) | Малая БД (с сост.) | Большая БД (без сост.) | Большая БД (с сост.) |
|---------|---------------------|--------------------|----------------------|---------------------|
| План | Bitmap Heap Scan | Bitmap Heap Scan | Index Scan | Index Scan |
| Rows Removed by Filter | — | — | 1 | 1 |
| Execution Time | 0.050 ms | 0.048 ms | 0.056 ms | 0.043 ms |

Примечание: на малой БД планировщик выбрал Bitmap Heap Scan вместо Index Scan из-за малого объёма данных. Роль составного индекса видна в Buffers.

### БАГИ В СТАТЬЕ

1. **Невалидный пример:** `CREATE INDEX idx_tx_card_status ON transactions(card_id, status)` — в таблице `transactions` **нет колонки `status`**. Этот пример нужно заменить на `user_cards(user_id, status)`.

2. **Показатели в статье расходятся с реальностью:**
   - Малая БД Index Scan: статья 0.068 ms → реально 0.027 ms
   - Большая БД Index Scan: статья 0.444 ms → реально 0.022 ms (в статье первый запуск с диска)
   - Малая БД Seq Scan: статья 14.669 ms → реально 7.374 ms  
   - Большая БД Heap Fetches после UPDATE: статья 70 → реально 50 (малая), 10 (большая)
