-- =====================================================================
-- Online Retail II — Business Intelligence Data Warehouse
-- File: 00_schema.sql
-- Purpose: Creates the raw staging table and the dimensional (star)
--          schema used for all downstream BI / analytics queries.
-- Engine:  PostgreSQL 14+
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Clean slate (safe to re-run)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fact_sales CASCADE;
DROP TABLE IF EXISTS dim_customer CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;
DROP TABLE IF EXISTS dim_country CASCADE;
DROP TABLE IF EXISTS stg_online_retail CASCADE;

-- ---------------------------------------------------------------------
-- 1. STAGING LAYER — raw data, one row per invoice line, no cleaning.
--    Loaded directly from the UCI "Online Retail II" source file
--    (raw_data/online_retail_II_raw.csv), sheets "Year 2009-2010" and
--    "Year 2010-2011" appended together.
-- ---------------------------------------------------------------------
CREATE TABLE stg_online_retail (
    invoice_no      TEXT,
    stock_code      TEXT,
    description     TEXT,
    quantity        INTEGER,
    invoice_date    TIMESTAMP,
    unit_price      NUMERIC(12,4),
    customer_id     TEXT,          -- kept as TEXT in staging (raw has floats/blank)
    country         TEXT,
    source_sheet    TEXT
);

COMMENT ON TABLE stg_online_retail IS
  'Raw, unaltered invoice-line data as delivered by the source file. '
  'No business rules applied yet — used only as ETL input for the star schema below.';

-- ---------------------------------------------------------------------
-- 2. DIMENSION: dim_date
--    Pre-built date spine covering the full data range plus a small
--    buffer, so every fact row always finds a matching date_key.
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INTEGER PRIMARY KEY,      -- YYYYMMDD
    full_date       DATE NOT NULL,
    day             INTEGER NOT NULL,
    day_name        TEXT NOT NULL,
    month           INTEGER NOT NULL,
    month_name      TEXT NOT NULL,
    quarter         INTEGER NOT NULL,
    year            INTEGER NOT NULL,
    iso_week        INTEGER NOT NULL,
    is_weekend      BOOLEAN NOT NULL
);

-- ---------------------------------------------------------------------
-- 3. DIMENSION: dim_customer
--    One row per customer. customer_key = -1 is the explicit
--    "Guest / Unknown customer" member for invoice lines with no
--    Customer ID in the source data (~25% of rows — common in retail
--    POS/web exports and must be handled, not silently dropped).
-- ---------------------------------------------------------------------
CREATE TABLE dim_customer (
    customer_key    INTEGER PRIMARY KEY,      -- -1 = Unknown/Guest
    customer_id     TEXT,
    country         TEXT,
    first_invoice_date TIMESTAMP,
    last_invoice_date  TIMESTAMP
);
CREATE UNIQUE INDEX idx_dim_customer_customer_id ON dim_customer(customer_id);

-- ---------------------------------------------------------------------
-- 4. DIMENSION: dim_country
-- ---------------------------------------------------------------------
CREATE TABLE dim_country (
    country_key     SERIAL PRIMARY KEY,
    country         TEXT UNIQUE NOT NULL,
    region          TEXT      -- coarse grouping added during ETL
);

-- ---------------------------------------------------------------------
-- 5. DIMENSION: dim_product
--    One row per stock_code. A stock_code can have more than one
--    description in the raw data (typos/re-labelling over 2 years);
--    we keep the most frequently used description.
-- ---------------------------------------------------------------------
CREATE TABLE dim_product (
    product_key     SERIAL PRIMARY KEY,
    stock_code      TEXT UNIQUE NOT NULL,
    description     TEXT
);

-- ---------------------------------------------------------------------
-- 6. FACT: fact_sales
--    Grain: one row per original invoice line (post-cleaning).
--    Includes cancellations (is_cancelled = TRUE, negative quantity)
--    so that net revenue and gross revenue can both be computed.
-- ---------------------------------------------------------------------
CREATE TABLE fact_sales (
    sales_key       BIGSERIAL PRIMARY KEY,
    invoice_no      TEXT NOT NULL,
    date_key        INTEGER NOT NULL REFERENCES dim_date(date_key),
    customer_key    INTEGER NOT NULL REFERENCES dim_customer(customer_key),
    product_key     INTEGER NOT NULL REFERENCES dim_product(product_key),
    country_key     INTEGER NOT NULL REFERENCES dim_country(country_key),
    invoice_ts      TIMESTAMP NOT NULL,
    quantity        INTEGER NOT NULL,
    unit_price      NUMERIC(12,4) NOT NULL,
    line_revenue    NUMERIC(14,4) NOT NULL,   -- quantity * unit_price
    is_cancelled    BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_fact_sales_date        ON fact_sales(date_key);
CREATE INDEX idx_fact_sales_customer    ON fact_sales(customer_key);
CREATE INDEX idx_fact_sales_product     ON fact_sales(product_key);
CREATE INDEX idx_fact_sales_country     ON fact_sales(country_key);
CREATE INDEX idx_fact_sales_invoice     ON fact_sales(invoice_no);

COMMENT ON TABLE fact_sales IS
  'Cleaned, dimensionalised invoice-line facts. One row per line item. '
  'Grain: invoice_no + stock_code (+ occurrence). Cancellations are kept '
  '(is_cancelled = TRUE) so gross vs. net revenue can both be derived.';
