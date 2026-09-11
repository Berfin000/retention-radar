-- =====================================================================
-- Online Retail II — Advanced Analytics Queries
-- File: 03_advanced_analytics_queries.sql
-- Run after 00_schema.sql + 01_etl_load_and_transform.sql.
-- Heavier, window-function / self-join driven analyses: RFM
-- segmentation, cohort retention, CLV, basket analysis, churn risk.
-- These outputs feed directly into the Python EDA/BI and ML notebooks.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A1. RFM (Recency, Frequency, Monetary) scoring & customer segments
--     Recency  = days since last purchase, measured from the day after
--                the last date present in the whole dataset (so the
--                dataset's own "today" is used, not the real today).
--     Frequency = number of distinct orders
--     Monetary  = total net revenue
--     Each dimension is scored 1 (worst) - 5 (best) with NTILE, then
--     combined into a human-readable segment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_customer_rfm AS
WITH snapshot AS (
    SELECT max(invoice_ts) + INTERVAL '1 day' AS snapshot_date FROM fact_sales
),
base AS (
    SELECT
        f.customer_key,
        extract(day FROM (SELECT snapshot_date FROM snapshot) - max(f.invoice_ts))::int AS recency_days,
        count(DISTINCT f.invoice_no)                                                     AS frequency,
        sum(f.line_revenue)                                                              AS monetary
    FROM fact_sales f
    WHERE f.customer_key <> -1 AND NOT f.is_cancelled
    GROUP BY f.customer_key
),
scored AS (
    SELECT
        *,
        ntile(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- lower recency_days = more recent = higher score
        ntile(5) OVER (ORDER BY frequency ASC)      AS f_score,
        ntile(5) OVER (ORDER BY monetary ASC)        AS m_score
    FROM base
)
SELECT
    customer_key, recency_days, frequency, round(monetary, 2) AS monetary,
    r_score, f_score, m_score,
    (r_score + f_score + m_score)                              AS rfm_total,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 4 AND f_score >= 3                  THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'New / Recent Customers'
        WHEN r_score = 3                                     THEN 'Needs Attention'
        WHEN r_score <= 2 AND m_score >= 4                  THEN 'At-Risk High Value'
        WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2 THEN 'Lost / Churned'
        ELSE 'Hibernating'
    END AS segment
FROM scored;

SELECT segment, count(*) AS customers, round(sum(monetary),2) AS segment_revenue,
       round(avg(monetary),2) AS avg_revenue_per_customer
FROM vw_customer_rfm
GROUP BY segment
ORDER BY segment_revenue DESC;

-- ---------------------------------------------------------------------
-- A2. Cohort retention analysis
--     Cohort = calendar month of a customer's first-ever order.
--     For each cohort, what % of its customers are still ordering
--     N months later? (classic retention triangle / heat-map matrix)
-- ---------------------------------------------------------------------
WITH first_order AS (
    SELECT customer_key, date_trunc('month', min(invoice_ts))::date AS cohort_month
    FROM fact_sales
    WHERE customer_key <> -1 AND NOT is_cancelled
    GROUP BY customer_key
),
orders_by_month AS (
    SELECT DISTINCT
        f.customer_key,
        date_trunc('month', f.invoice_ts)::date AS order_month
    FROM fact_sales f
    WHERE f.customer_key <> -1 AND NOT f.is_cancelled
),
cohort_activity AS (
    SELECT
        fo.cohort_month,
        obm.order_month,
        (extract(year FROM age(obm.order_month, fo.cohort_month)) * 12
         + extract(month FROM age(obm.order_month, fo.cohort_month)))::int AS month_offset,
        obm.customer_key
    FROM orders_by_month obm
    JOIN first_order fo ON fo.customer_key = obm.customer_key
),
cohort_size AS (
    SELECT cohort_month, count(DISTINCT customer_key) AS cohort_customers
    FROM first_order
    GROUP BY cohort_month
)
SELECT
    ca.cohort_month,
    cs.cohort_customers,
    ca.month_offset,
    count(DISTINCT ca.customer_key)                                            AS active_customers,
    round(100.0 * count(DISTINCT ca.customer_key) / cs.cohort_customers, 1)     AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
GROUP BY ca.cohort_month, cs.cohort_customers, ca.month_offset
ORDER BY ca.cohort_month, ca.month_offset;

-- ---------------------------------------------------------------------
-- A3. Historical Customer Lifetime Value (CLV) + purchase cadence
-- ---------------------------------------------------------------------
SELECT
    f.customer_key,
    dc.country,
    count(DISTINCT f.invoice_no)                                                AS orders,
    round(sum(f.line_revenue), 2)                                                AS lifetime_revenue,
    round(sum(f.line_revenue) / NULLIF(count(DISTINCT f.invoice_no), 0), 2)      AS avg_order_value,
    min(f.invoice_ts)::date                                                      AS first_order,
    max(f.invoice_ts)::date                                                      AS last_order,
    (max(f.invoice_ts)::date - min(f.invoice_ts)::date)                          AS customer_lifespan_days,
    round(
        (max(f.invoice_ts)::date - min(f.invoice_ts)::date)::numeric
        / NULLIF(count(DISTINCT f.invoice_no) - 1, 0), 1)                        AS avg_days_between_orders
FROM fact_sales f
JOIN dim_customer dc ON dc.customer_key = f.customer_key
WHERE f.customer_key <> -1 AND NOT f.is_cancelled
GROUP BY f.customer_key, dc.country
ORDER BY lifetime_revenue DESC
LIMIT 50;

-- ---------------------------------------------------------------------
-- A4. Market-basket analysis — top product pairs bought in the same
--     invoice (simple co-occurrence + lift-style ratio)
-- ---------------------------------------------------------------------
WITH invoice_products AS (
    SELECT DISTINCT f.invoice_no, f.product_key
    FROM fact_sales f
    WHERE NOT f.is_cancelled
),
pair_counts AS (
    SELECT
        a.product_key AS product_a,
        b.product_key AS product_b,
        count(*)       AS pair_count
    FROM invoice_products a
    JOIN invoice_products b
      ON a.invoice_no = b.invoice_no AND a.product_key < b.product_key
    GROUP BY a.product_key, b.product_key
    HAVING count(*) >= 50
),
product_freq AS (
    SELECT product_key, count(DISTINCT invoice_no) AS invoice_count
    FROM invoice_products
    GROUP BY product_key
),
total_invoices AS (SELECT count(DISTINCT invoice_no) AS n FROM invoice_products)
SELECT
    pa.stock_code AS product_a_code, pa.description AS product_a_name,
    pb.stock_code AS product_b_code, pb.description AS product_b_name,
    pc.pair_count,
    round(pc.pair_count::numeric / ti.n
          / ((fa.invoice_count::numeric / ti.n) * (fb.invoice_count::numeric / ti.n)), 2) AS lift
FROM pair_counts pc
JOIN dim_product pa ON pa.product_key = pc.product_a
JOIN dim_product pb ON pb.product_key = pc.product_b
JOIN product_freq fa ON fa.product_key = pc.product_a
JOIN product_freq fb ON fb.product_key = pc.product_b
CROSS JOIN total_invoices ti
ORDER BY lift DESC, pair_count DESC
LIMIT 25;

-- ---------------------------------------------------------------------
-- A5. Running (cumulative) net revenue total across the whole period
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT invoice_ts::date AS day, sum(line_revenue) AS revenue
    FROM fact_sales
    WHERE NOT is_cancelled
    GROUP BY 1
)
SELECT
    day,
    round(revenue, 2)                                       AS daily_revenue,
    round(sum(revenue) OVER (ORDER BY day), 2)               AS cumulative_revenue
FROM daily
ORDER BY day;

-- ---------------------------------------------------------------------
-- A6. Churn risk list — previously active, valuable customers who have
--     gone quiet for 90+ days (as of the dataset's last observed date)
-- ---------------------------------------------------------------------
SELECT
    customer_key, recency_days, frequency, monetary, segment
FROM vw_customer_rfm
WHERE recency_days > 90 AND frequency >= 3
ORDER BY monetary DESC
LIMIT 50;
