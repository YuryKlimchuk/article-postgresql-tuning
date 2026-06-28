-- ============================================
-- Performance monitoring extension
-- ============================================
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ============================================
-- 1. USERS (JSONB approach to localization)
-- ============================================
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    uuid UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
    email VARCHAR(100) NOT NULL,
    localized_names JSONB,  -- {"en": "John Doe", "ru": "Ivan Ivanov"}
    created_at TIMESTAMP DEFAULT NOW()
);

-- ============================================
-- 2. CARD TEMPLATES
-- ============================================
CREATE TABLE card_templates (
    id SMALLSERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    bank_name VARCHAR(50),
    payment_system VARCHAR(10),  -- VISA, MASTERCARD, MIR, UNIONPAY, JCB
    currency_numeric SMALLINT,   -- ISO 4217 numeric: 643, 840, 978, 826, 156
    currency_alpha CHAR(3)       -- ISO 4217 alpha: RUB, USD, EUR, GBP, CNY
);

-- ============================================
-- 3. USER CARDS
--
-- Has TWO foreign keys to users table:
--   user_id   → BIGINT   (numeric FK)
--   user_uuid → UUID     (UUID FK)
-- This allows comparing JOIN performance across different FK data types.
-- ============================================
CREATE TABLE user_cards (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT REFERENCES users(id),
    user_uuid UUID REFERENCES users(uuid),
    template_id SMALLINT REFERENCES card_templates(id),
    card_number VARCHAR(16),
    expiry_date DATE,
    status VARCHAR(20) DEFAULT 'ACTIVE'
);

-- ============================================
-- 4. MERCHANTS (Column-based approach to localization)
-- ============================================
CREATE TABLE merchants (
    id INT PRIMARY KEY,
    name_en VARCHAR(100),
    name_ru VARCHAR(100),
    name_zh VARCHAR(100),
    category VARCHAR(50),
    country_code CHAR(2)
);

-- ============================================
-- 5. TRANSACTIONS
-- ============================================
CREATE TABLE transactions (
    id BIGSERIAL PRIMARY KEY,
    card_id BIGINT REFERENCES user_cards(id),
    merchant_id INT REFERENCES merchants(id),
    amount NUMERIC(12, 2),
    currency_numeric SMALLINT,
    currency_alpha CHAR(3),
    transaction_time TIMESTAMP DEFAULT NOW(),
    description TEXT  -- Large field to demonstrate TOAST behavior
);

-- ============================================
-- INDEXES
-- ============================================

-- Users
CREATE INDEX idx_users_email ON users(email);

-- User cards
CREATE INDEX idx_user_cards_user_id ON user_cards(user_id);
CREATE INDEX idx_user_cards_user_uuid ON user_cards(user_uuid);
CREATE INDEX idx_user_cards_status ON user_cards(status);
CREATE INDEX idx_user_cards_template ON user_cards(template_id);

-- Transactions
CREATE INDEX idx_transactions_card_id ON transactions(card_id);
CREATE INDEX idx_transactions_merchant_id ON transactions(merchant_id);
CREATE INDEX idx_transactions_time ON transactions(transaction_time);
CREATE INDEX idx_transactions_currency_numeric ON transactions(currency_numeric);

-- Merchants
CREATE INDEX idx_merchants_name_en ON merchants(name_en);
CREATE INDEX idx_merchants_name_ru ON merchants(name_ru);
CREATE INDEX idx_merchants_category ON merchants(category);

-- ============================================
-- COMMENTS (documentation)
-- ============================================
COMMENT ON TABLE users IS 'System users';
COMMENT ON COLUMN users.localized_names IS 'Localized user names in JSONB format: {"en": "...", "ru": "..."}';
COMMENT ON TABLE card_templates IS 'Card templates (bank products)';
COMMENT ON TABLE user_cards IS 'User-issued cards. Has both BIGINT and UUID FKs to users to compare join performance';
COMMENT ON TABLE merchants IS 'Merchant points of sale';
COMMENT ON TABLE transactions IS 'Financial transactions. description column is intentionally large to demonstrate TOAST';
