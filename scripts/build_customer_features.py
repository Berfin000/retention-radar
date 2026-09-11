"""
build_customer_features.py
===========================
Builds the customer-level feature table used by the ML notebook
(02_ml_churn_clv_prediction.ipynb), using a leakage-safe train/holdout
split so the model genuinely predicts the future instead of describing
the past:

    - FEATURE WINDOW : first observed invoice  ->  cutoff_date
    - HOLDOUT WINDOW  : cutoff_date+1  ->  last observed invoice  (90 days)

cutoff_date = last observed invoice date minus 90 days.

Every feature is computed ONLY from the feature window. The two
prediction targets are computed ONLY from the holdout window:
    - churned        : 1 if the customer placed NO order in the holdout
                        window, else 0  (classification target)
    - holdout_revenue : net revenue in the holdout window, 0 if none
                        (regression / CLV target)

Only customers with >=1 real (non-cancelled) order strictly before the
cutoff are included — brand-new customers who first ordered inside the
holdout window aren't "at risk of churn" yet, they simply hadn't
arrived, so including them would corrupt the churn label.

Output: exports/customer_features_churn.csv
"""

from pathlib import Path
import pandas as pd
from sqlalchemy import create_engine, text

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_URL = "postgresql+psycopg2://retail_admin:retail_admin@localhost:5432/online_retail_bi"
OUT_PATH = PROJECT_ROOT / "exports" / "customer_features_churn.csv"

HOLDOUT_DAYS = 90


def main():
    engine = create_engine(DB_URL)

    with engine.connect() as conn:
        max_date = conn.execute(text("SELECT max(invoice_ts) FROM fact_sales")).scalar()
    cutoff_date = max_date - pd.Timedelta(days=HOLDOUT_DAYS)
    print(f"[build_customer_features] max_date={max_date}  cutoff_date={cutoff_date}  "
          f"(feature window ends here, {HOLDOUT_DAYS}-day holdout follows)")

    feature_sql = """
        WITH feat AS (
            SELECT
                f.customer_key,
                dc.country,
                min(f.invoice_ts)                                              AS first_order,
                max(f.invoice_ts)                                              AS last_order_in_window,
                count(DISTINCT f.invoice_no)                                   AS frequency,
                sum(f.line_revenue)                                            AS monetary,
                sum(f.line_revenue) / NULLIF(count(DISTINCT f.invoice_no), 0)  AS avg_order_value,
                count(DISTINCT f.product_key)                                  AS distinct_products,
                sum(f.quantity) FILTER (WHERE NOT f.is_cancelled)              AS total_units,
                count(*) FILTER (WHERE f.is_cancelled)                         AS cancelled_lines,
                extract(day FROM (:cutoff - min(f.invoice_ts)))::int           AS tenure_days,
                extract(day FROM (:cutoff - max(f.invoice_ts)))::int           AS recency_days
            FROM fact_sales f
            JOIN dim_customer dc ON dc.customer_key = f.customer_key
            WHERE f.customer_key <> -1
              AND f.invoice_ts <= :cutoff
              AND NOT f.is_cancelled
            GROUP BY f.customer_key, dc.country
        )
        SELECT *,
               CASE WHEN frequency > 1
                    THEN tenure_days::numeric / NULLIF(frequency - 1, 0)
                    ELSE NULL END AS avg_days_between_orders
        FROM feat;
    """

    holdout_sql = """
        SELECT
            customer_key,
            sum(line_revenue) AS holdout_revenue,
            count(DISTINCT invoice_no) AS holdout_orders
        FROM fact_sales
        WHERE customer_key <> -1
          AND invoice_ts > :cutoff
          AND NOT is_cancelled
        GROUP BY customer_key;
    """

    features = pd.read_sql(text(feature_sql), engine, params={"cutoff": cutoff_date})
    holdout = pd.read_sql(text(holdout_sql), engine, params={"cutoff": cutoff_date})

    df = features.merge(holdout, on="customer_key", how="left")
    df["holdout_revenue"] = df["holdout_revenue"].fillna(0.0)
    df["holdout_orders"] = df["holdout_orders"].fillna(0).astype(int)
    df["churned"] = (df["holdout_orders"] == 0).astype(int)

    # Top-10 country flag to keep the categorical feature space small & meaningful
    top_countries = df["country"].value_counts().nlargest(10).index.tolist()
    df["country_grouped"] = df["country"].where(df["country"].isin(top_countries), "Other")

    df["cutoff_date"] = cutoff_date
    df["max_date"] = max_date

    df.to_csv(OUT_PATH, index=False)
    print(f"[build_customer_features] wrote {OUT_PATH.relative_to(PROJECT_ROOT)} "
          f"with {len(df)} customers, churn rate = {df['churned'].mean():.1%}")


if __name__ == "__main__":
    main()
