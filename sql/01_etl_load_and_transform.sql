-- =====================================================================
-- Online Retail II — ETL: Load raw data & build the star schema
-- File: 01_etl_load_and_transform.sql
-- Run after 00_schema.sql. Run with psql (uses \copy, a psql meta-
-- command — cannot run inside a plain SQL client / DBeaver query tab).
--
--   psql -h localhost -U retail_admin -d online_retail_bi -f 01_etl_load_and_transform.sql
--
-- Business rules applied while moving staging -> star schema:
--   1. Invoices starting with 'C'  -> cancellations, kept, flagged.
--   2. Invoices starting with 'A'  -> bank/adjustment entries (bad debt
--      write-offs, not real sales) -> EXCLUDED from fact_sales.
--   3. Rows with unit_price <= 0 and NOT a cancellation are excluded
--      (test/sample postings with no commercial value).
--   4. Missing Customer ID -> mapped to the single "Guest" member
--      (customer_key = -1) instead of being dropped, so revenue totals
--      stay complete while customer-level analysis can still filter
--      them out explicitly.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. LOAD raw CSV into staging (bulk load, ~1.07M rows)
-- ---------------------------------------------------------------------
TRUNCATE TABLE stg_online_retail;

\copy stg_online_retail (invoice_no, stock_code, description, quantity, invoice_date, unit_price, customer_id, country, source_sheet) FROM '../raw_data/online_retail_II_raw.csv' WITH (FORMAT csv, HEADER true, NULL '');

-- Quick sanity check
SELECT count(*) AS rows_loaded FROM stg_online_retail;

-- Helper indexes on staging to speed up the joins/aggregations below
CREATE INDEX IF NOT EXISTS idx_stg_customer_id ON stg_online_retail(customer_id);
CREATE INDEX IF NOT EXISTS idx_stg_stock_code  ON stg_online_retail(stock_code);
CREATE INDEX IF NOT EXISTS idx_stg_country     ON stg_online_retail(country);
CREATE INDEX IF NOT EXISTS idx_stg_invoice_no  ON stg_online_retail(invoice_no);
ANALYZE stg_online_retail;

-- ---------------------------------------------------------------------
-- 2. dim_date — spine covering the full observed range + 1 buffer year
-- ---------------------------------------------------------------------
INSERT INTO dim_date (date_key, full_date, day, day_name, month, month_name,
                       quarter, year, iso_week, is_weekend)
SELECT
    CAST(to_char(d, 'YYYYMMDD') AS INTEGER)          AS date_key,
    d::date                                          AS full_date,
    EXTRACT(DAY FROM d)::INT                         AS day,
    to_char(d, 'Day')                                AS day_name,
    EXTRACT(MONTH FROM d)::INT                        AS month,
    to_char(d, 'Month')                              AS month_name,
    EXTRACT(QUARTER FROM d)::INT                      AS quarter,
    EXTRACT(YEAR FROM d)::INT                         AS year,
    EXTRACT(WEEK FROM d)::INT                         AS iso_week,
    (EXTRACT(ISODOW FROM d) IN (6, 7))                AS is_weekend
FROM generate_series(
        (SELECT date_trunc('day', min(invoice_date)) FROM stg_online_retail),
        (SELECT date_trunc('day', max(invoice_date)) FROM stg_online_retail) + INTERVAL '1 day',
        INTERVAL '1 day'
     ) AS d;

-- ---------------------------------------------------------------------
-- 3. dim_country — distinct countries + a coarse region grouping
--    (region is only used for a couple of "roll-up" BI queries later)
-- ---------------------------------------------------------------------
INSERT INTO dim_country (country, region)
SELECT DISTINCT
    country,
    CASE
        WHEN country = 'United Kingdom' THEN 'UK (Home Market)'
        WHEN country IN ('Ireland','Germany','France','Netherlands','Belgium',
                          'Spain','Portugal','Italy','Switzerland','Austria',
                          'Denmark','Sweden','Finland','Norway','Poland',
                          'Channel Islands','Iceland','Lithuania','Malta',
                          'Cyprus','Greece','Czech Republic','European Community')
            THEN 'Europe'
        WHEN country IN ('USA','Canada','Brazil') THEN 'Americas'
        WHEN country IN ('Australia','Japan','Singapore','Hong Kong',
                          'United Arab Emirates','Saudi Arabia','Israel',
                          'Bahrain','Lebanon','Korea','Thailand')
            THEN 'Asia-Pacific / Middle East'
        WHEN country IN ('RSA','Nigeria') THEN 'Africa'
        WHEN country = 'Unspecified' THEN 'Unknown'
        ELSE 'Other'
    END AS region
FROM stg_online_retail
WHERE country IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. dim_customer — one row per real customer + the -1 "Guest" member
-- ---------------------------------------------------------------------
INSERT INTO dim_customer (customer_key, customer_id, country,
                           first_invoice_date, last_invoice_date)
VALUES (-1, 'GUEST', NULL, NULL, NULL);

INSERT INTO dim_customer (customer_key, customer_id, country,
                           first_invoice_date, last_invoice_date)
SELECT
    row_number() OVER (ORDER BY customer_id)::INT AS customer_key,
    customer_id,
    -- a customer can appear against >1 country if they moved / typo'd it;
    -- mode() picks the most frequently used country for that customer
    -- in a single aggregation pass (avoids an expensive correlated subquery)
    mode() WITHIN GROUP (ORDER BY country)          AS country,
    min(invoice_date)                               AS first_invoice_date,
    max(invoice_date)                               AS last_invoice_date
FROM stg_online_retail s1
WHERE customer_id IS NOT NULL AND customer_id <> ''
GROUP BY customer_id;

-- ---------------------------------------------------------------------
-- 5. dim_product — one row per stock_code, most common description wins
-- ---------------------------------------------------------------------
INSERT INTO dim_product (stock_code, description)
SELECT stock_code, description
FROM (
    SELECT
        stock_code,
        description,
        row_number() OVER (PARTITION BY stock_code
                            ORDER BY count(*) DESC) AS rn
    FROM stg_online_retail
    WHERE stock_code IS NOT NULL
    GROUP BY stock_code, description
) ranked
WHERE rn = 1;

-- ---------------------------------------------------------------------
-- 6. fact_sales — cleaned invoice lines, joined to every dimension
-- ---------------------------------------------------------------------
INSERT INTO fact_sales (invoice_no, date_key, customer_key, product_key,
                         country_key, invoice_ts, quantity, unit_price,
                         line_revenue, is_cancelled)
SELECT
    s.invoice_no,
    CAST(to_char(s.invoice_date, 'YYYYMMDD') AS INTEGER)   AS date_key,
    COALESCE(dc.customer_key, -1)                          AS customer_key,
    dp.product_key,
    dco.country_key,
    s.invoice_date                                         AS invoice_ts,
    s.quantity,
    s.unit_price,
    (s.quantity * s.unit_price)::NUMERIC(14,4)              AS line_revenue,
    (left(s.invoice_no, 1) = 'C')                           AS is_cancelled
FROM stg_online_retail s
LEFT JOIN dim_customer dc  ON dc.customer_id = s.customer_id
LEFT JOIN dim_product  dp  ON dp.stock_code  = s.stock_code
LEFT JOIN dim_country  dco ON dco.country    = s.country
WHERE
    left(s.invoice_no, 1) <> 'A'                 -- drop bad-debt/adjustment postings
    AND (left(s.invoice_no, 1) = 'C' OR s.unit_price > 0)  -- drop zero/negative-price non-cancellations
    AND dp.product_key IS NOT NULL;

-- ---------------------------------------------------------------------
-- 7. Post-load validation
-- ---------------------------------------------------------------------
SELECT 'stg_online_retail' AS table_name, count(*) FROM stg_online_retail
UNION ALL SELECT 'dim_date',     count(*) FROM dim_date
UNION ALL SELECT 'dim_customer', count(*) FROM dim_customer
UNION ALL SELECT 'dim_product',  count(*) FROM dim_product
UNION ALL SELECT 'dim_country',  count(*) FROM dim_country
UNION ALL SELECT 'fact_sales',   count(*) FROM fact_sales;
