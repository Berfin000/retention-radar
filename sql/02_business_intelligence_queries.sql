-- =====================================================================
-- Online Retail II — Core Business Intelligence Queries
-- File: 02_business_intelligence_queries.sql
-- Run after 00_schema.sql + 01_etl_load_and_transform.sql.
-- Each query answers one concrete business question a retail
-- manager / analyst would actually ask.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. Headline KPI summary (gross vs. net revenue, orders, customers, AOV)
-- ---------------------------------------------------------------------
SELECT
    round(sum(line_revenue) FILTER (WHERE NOT is_cancelled), 2)                 AS gross_revenue,
    round(sum(line_revenue) FILTER (WHERE is_cancelled), 2)                     AS cancelled_revenue,
    round(sum(line_revenue), 2)                                                 AS net_revenue,
    count(DISTINCT invoice_no) FILTER (WHERE NOT is_cancelled)                  AS orders,
    count(DISTINCT customer_key) FILTER (WHERE customer_key <> -1)              AS paying_customers,
    round(sum(line_revenue) FILTER (WHERE NOT is_cancelled)
          / NULLIF(count(DISTINCT invoice_no) FILTER (WHERE NOT is_cancelled), 0), 2) AS avg_order_value
FROM fact_sales;

-- ---------------------------------------------------------------------
-- Q2. Monthly revenue trend with month-over-month growth %
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT
        date_trunc('month', invoice_ts)::date          AS month,
        sum(line_revenue)                               AS revenue
    FROM fact_sales
    WHERE NOT is_cancelled
    GROUP BY 1
)
SELECT
    month,
    round(revenue, 2)                                                        AS revenue,
    round(lag(revenue) OVER (ORDER BY month), 2)                             AS prev_month_revenue,
    round(100.0 * (revenue - lag(revenue) OVER (ORDER BY month))
          / NULLIF(lag(revenue) OVER (ORDER BY month), 0), 1)                 AS mom_growth_pct
FROM monthly
ORDER BY month;

-- ---------------------------------------------------------------------
-- Q3. Revenue by country — top 15, with share of total net revenue
-- ---------------------------------------------------------------------
SELECT
    co.country,
    co.region,
    round(sum(f.line_revenue), 2)                                            AS net_revenue,
    round(100.0 * sum(f.line_revenue) / sum(sum(f.line_revenue)) OVER (), 1) AS pct_of_total,
    count(DISTINCT f.customer_key) FILTER (WHERE f.customer_key <> -1)       AS customers
FROM fact_sales f
JOIN dim_country co ON co.country_key = f.country_key
GROUP BY co.country, co.region
ORDER BY net_revenue DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- Q4. Top 20 products by net revenue
-- ---------------------------------------------------------------------
SELECT
    p.stock_code,
    p.description,
    sum(f.quantity) FILTER (WHERE NOT f.is_cancelled)                        AS units_sold,
    round(sum(f.line_revenue), 2)                                            AS net_revenue,
    count(DISTINCT f.invoice_no)                                             AS orders_containing_product
FROM fact_sales f
JOIN dim_product p ON p.product_key = f.product_key
GROUP BY p.stock_code, p.description
ORDER BY net_revenue DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- Q5. Weekday vs weekend performance (does the business run 7 days/week?)
-- ---------------------------------------------------------------------
SELECT
    d.day_name,
    d.is_weekend,
    round(sum(f.line_revenue), 2)                                            AS net_revenue,
    count(DISTINCT f.invoice_no)                                             AS orders,
    round(sum(f.line_revenue) / NULLIF(count(DISTINCT f.invoice_no), 0), 2)  AS avg_order_value
FROM fact_sales f
JOIN dim_date d ON d.date_key = f.date_key
WHERE NOT f.is_cancelled
GROUP BY d.day_name, d.is_weekend
ORDER BY net_revenue DESC;

-- ---------------------------------------------------------------------
-- Q6. Order cancellation rate by month (operational health metric)
-- ---------------------------------------------------------------------
SELECT
    date_trunc('month', f.invoice_ts)::date                                  AS month,
    count(DISTINCT f.invoice_no) FILTER (WHERE f.is_cancelled)               AS cancelled_invoices,
    count(DISTINCT f.invoice_no)                                             AS total_invoices,
    round(100.0 * count(DISTINCT f.invoice_no) FILTER (WHERE f.is_cancelled)
          / NULLIF(count(DISTINCT f.invoice_no), 0), 1)                       AS cancellation_rate_pct
FROM fact_sales f
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Q7. New vs. returning customer revenue split, per month
--     ("new" = this is the calendar month of that customer's very
--     first invoice in the whole dataset)
-- ---------------------------------------------------------------------
WITH customer_first_month AS (
    SELECT customer_key, date_trunc('month', min(invoice_ts))::date AS first_month
    FROM fact_sales
    WHERE customer_key <> -1
    GROUP BY customer_key
),
sales_labelled AS (
    SELECT
        f.*,
        date_trunc('month', f.invoice_ts)::date AS order_month,
        cfm.first_month
    FROM fact_sales f
    JOIN customer_first_month cfm ON cfm.customer_key = f.customer_key
    WHERE NOT f.is_cancelled
)
SELECT
    order_month,
    round(sum(line_revenue) FILTER (WHERE order_month = first_month), 2)     AS new_customer_revenue,
    round(sum(line_revenue) FILTER (WHERE order_month <> first_month), 2)    AS returning_customer_revenue,
    round(100.0 * sum(line_revenue) FILTER (WHERE order_month <> first_month)
          / NULLIF(sum(line_revenue), 0), 1)                                  AS pct_from_returning
FROM sales_labelled
GROUP BY order_month
ORDER BY order_month;

-- ---------------------------------------------------------------------
-- Q8. Customer revenue quartiles ("who are our whales?")
-- ---------------------------------------------------------------------
WITH customer_revenue AS (
    SELECT customer_key, sum(line_revenue) AS revenue
    FROM fact_sales
    WHERE customer_key <> -1 AND NOT is_cancelled
    GROUP BY customer_key
),
quartiled AS (
    SELECT *, ntile(4) OVER (ORDER BY revenue DESC) AS revenue_quartile
    FROM customer_revenue
)
SELECT
    revenue_quartile,
    count(*)                                                                 AS customers,
    round(sum(revenue), 2)                                                   AS total_revenue,
    round(100.0 * sum(revenue) / sum(sum(revenue)) OVER (), 1)               AS pct_of_total_revenue,
    round(avg(revenue), 2)                                                   AS avg_revenue_per_customer
FROM quartiled
GROUP BY revenue_quartile
ORDER BY revenue_quartile;

-- ---------------------------------------------------------------------
-- Q9. Quarter-over-quarter and year-over-year revenue comparison
-- ---------------------------------------------------------------------
WITH quarterly AS (
    SELECT
        extract(year FROM invoice_ts)::int    AS yr,
        extract(quarter FROM invoice_ts)::int AS qtr,
        sum(line_revenue)                     AS revenue
    FROM fact_sales
    WHERE NOT is_cancelled
    GROUP BY 1, 2
)
SELECT
    yr, qtr, round(revenue, 2) AS revenue,
    round(lag(revenue) OVER (ORDER BY yr, qtr), 2)                            AS prev_quarter_revenue,
    round(100.0 * (revenue - lag(revenue) OVER (ORDER BY yr, qtr))
          / NULLIF(lag(revenue) OVER (ORDER BY yr, qtr), 0), 1)                AS qoq_growth_pct,
    round(lag(revenue, 4) OVER (ORDER BY yr, qtr), 2)                          AS same_quarter_last_year,
    round(100.0 * (revenue - lag(revenue, 4) OVER (ORDER BY yr, qtr))
          / NULLIF(lag(revenue, 4) OVER (ORDER BY yr, qtr), 0), 1)             AS yoy_growth_pct
FROM quarterly
ORDER BY yr, qtr;

-- ---------------------------------------------------------------------
-- Q10. Product return/cancellation hot-list (quality or listing issues?)
-- ---------------------------------------------------------------------
SELECT
    p.stock_code,
    p.description,
    count(*) FILTER (WHERE f.is_cancelled)                                   AS cancelled_lines,
    count(*)                                                                 AS total_lines,
    round(100.0 * count(*) FILTER (WHERE f.is_cancelled) / count(*), 1)      AS cancellation_rate_pct
FROM fact_sales f
JOIN dim_product p ON p.product_key = f.product_key
GROUP BY p.stock_code, p.description
HAVING count(*) >= 30
ORDER BY cancellation_rate_pct DESC
LIMIT 20;
