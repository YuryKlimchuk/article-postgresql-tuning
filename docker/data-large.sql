\timing on

-- ============================================
-- CARD TEMPLATES (30 records)
-- ============================================
INSERT INTO card_templates (name, bank_name, payment_system, currency_numeric, currency_alpha)
SELECT
    'Card ' || i,
    'Bank ' || (i % 5 + 1),
    ps.name,
    curr.code_num,
    curr.code_alpha
FROM generate_series(1, 30) AS i
CROSS JOIN LATERAL (
    SELECT name FROM (VALUES
        ('VISA'), ('MASTERCARD'), ('MIR'), ('UNIONPAY'), ('JCB')
    ) AS v(name)
    ORDER BY random()
    LIMIT 1
) AS ps
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        (643, 'RUB'),  -- Russian Ruble
        (840, 'USD'),  -- US Dollar
        (978, 'EUR'),  -- Euro
        (826, 'GBP'),  -- British Pound
        (156, 'CNY')   -- Chinese Yuan
    ) AS v(code_num, code_alpha)
    ORDER BY random()
    LIMIT 1
) AS curr;

-- ============================================
-- USERS (500,000 records)
-- ============================================
INSERT INTO users (email, localized_names)
SELECT
    'user' || i || '@test.com',
    jsonb_build_object(
        'en', 'Customer ' || i,
        'ru', 'Пользователь ' || i,
        'zh', '用户 ' || i
    )
FROM generate_series(1, 500000) AS i;

-- ============================================
-- MERCHANTS (100 records)
-- ============================================
INSERT INTO merchants (id, name_en, name_ru, name_zh, category, country_code)
SELECT
    i,
    'Merchant ' || i,
    'Мерчант ' || i,
    '商户 ' || i,
    CASE
        WHEN i % 4 = 0 THEN 'Food & Restaurants'
        WHEN i % 4 = 1 THEN 'Transport'
        WHEN i % 4 = 2 THEN 'Entertainment'
        ELSE 'Retail'
    END,
    CASE
        WHEN i % 3 = 0 THEN 'RU'
        WHEN i % 3 = 1 THEN 'US'
        ELSE 'CN'
    END
FROM generate_series(1, 100) AS i;

-- ============================================
-- USER CARDS (1,000,000 records)
-- ============================================
INSERT INTO user_cards (user_id, user_uuid, template_id, card_number, expiry_date, status)
SELECT
    u.id,
    u.uuid,
    (random() * 29 + 1)::INT,
    lpad((random() * 1000000000000000)::TEXT, 16, '0'),
    (NOW() + (random() * 365 + 365) * INTERVAL '1 day')::DATE,
    CASE
        WHEN random() > 0.1 THEN 'ACTIVE'
        WHEN random() > 0.05 THEN 'BLOCKED'
        ELSE 'EXPIRED'
    END
FROM users u
CROSS JOIN generate_series(1, 2) AS s;

-- ============================================
-- TRANSACTIONS (~5,000,000 records)
--
-- Generates 5 transactions per card (vs 25 in small dataset).
-- Fewer tx/card to keep the large dataset manageable while still
-- reaching ~5M rows to clearly show query plan differences.
-- description uses repeat(..., 5) to produce larger TOAST entries,
-- making TOAST overhead more visible in EXPLAIN ANALYZE.
-- ============================================
INSERT INTO transactions (card_id, merchant_id, amount, currency_numeric, currency_alpha, transaction_time, description)
SELECT
    uc.id,
    m.id,
    (random() * 10000 + 10)::NUMERIC(12,2),
    curr.code_num,
    curr.code_alpha,
    NOW() - (random() * 365 * INTERVAL '1 day'),
    'Transaction details for ID ' || i || '. ' || repeat('Lorem ipsum dolor sit amet. ', 5)
FROM user_cards uc
CROSS JOIN generate_series(1, 5) AS i
CROSS JOIN LATERAL (SELECT id FROM merchants ORDER BY random() LIMIT 1) m
CROSS JOIN LATERAL (
    SELECT (ARRAY[643, 840, 978, 826, 156])[1 + (i % 5)] AS code_num,
           (ARRAY['RUB', 'USD', 'EUR', 'GBP', 'CNY'])[1 + (i % 5)] AS code_alpha
) AS curr;

-- ============================================
-- UPDATE STATISTICS
-- ============================================
ANALYZE users;
ANALYZE card_templates;
ANALYZE user_cards;
ANALYZE merchants;
ANALYZE transactions;

-- Update visibility map (required for Index Only Scan to skip heap fetches)
VACUUM;

-- ============================================
-- SUMMARY: table sizes and row counts
-- ============================================
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    (SELECT COUNT(*) FROM users) AS user_count,
    (SELECT COUNT(*) FROM user_cards) AS card_count,
    (SELECT COUNT(*) FROM transactions) AS transaction_count
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
