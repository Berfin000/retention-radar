"""
live_currency_api.py
=====================
Live-data component of the Online Retail II BI project.

WHY THIS EXISTS (business case)
--------------------------------
The Online Retail II dataset records every sale in GBP only. But the
company sells into 40+ countries and any executive report worth showing
to a non-UK stakeholder (or a US/EU investor) needs revenue in a
currency they actually think in. Re-running historical conversions by
hand every time is not scalable — so this script pulls exchange rates
live from a public FX-rate API (Frankfurter, backed by the European
Central Bank's daily reference rates: https://api.frankfurter.dev) and:

  1. Fetches the historical monthly-average GBP -> USD / EUR / TRY rate
     for the exact period the dataset covers (Dec-2009 .. Dec-2011), so
     each month's revenue is converted at the rate that actually applied
     that month (not today's rate applied retroactively, which would be
     misleading).
  2. Fetches TODAY's live rate and shows what the company's total
     historical GBP revenue would be worth if received today — a small
     but genuinely "live" number that changes every time this script is
     run, which is the point of the exercise.
  3. Joins both to the monthly net-revenue figures pulled straight out
     of the `fact_sales` table in Postgres (see sql/02_business_intelligence_queries.sql
     Q2 for the equivalent pure-SQL version of the GBP figures) and
     writes a ready-to-use multi-currency CSV for the BI notebook and
     for Power BI.

USAGE
-----
    python live_currency_api.py                       # live API + live Postgres
    python live_currency_api.py --offline              # use bundled FX cache only
    python live_currency_api.py --db-url postgresql://retail_admin:retail_admin@localhost/online_retail_bi

Requires: requests, pandas, sqlalchemy, psycopg2-binary (only for --db-url mode)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from datetime import date

import pandas as pd
import requests

FRANKFURTER_BASE = "https://api.frankfurter.dev/v1"
BASE_CURRENCY = "GBP"
TARGET_CURRENCIES = ["USD", "EUR", "TRY"]  # TRY included for a Turkey-based stakeholder view

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = PROJECT_ROOT / "exports" / "fx_rates_monthly_cache.json"
OUTPUT_PATH = PROJECT_ROOT / "exports" / "monthly_revenue_multi_currency.csv"

DEFAULT_DB_URL = "postgresql+psycopg2://retail_admin:retail_admin@localhost:5432/online_retail_bi"


# ---------------------------------------------------------------------
# 1. Live API calls
# ---------------------------------------------------------------------
def fetch_latest_rates(base: str = BASE_CURRENCY, symbols: list[str] = TARGET_CURRENCIES,
                        timeout: int = 10) -> dict:
    """Today's live GBP -> {USD, EUR, TRY} rates."""
    url = f"{FRANKFURTER_BASE}/latest"
    resp = requests.get(url, params={"base": base, "symbols": ",".join(symbols)}, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def fetch_historical_daily_rates(start: str, end: str, base: str = BASE_CURRENCY,
                                  symbols: list[str] = TARGET_CURRENCIES, timeout: int = 30) -> dict:
    """Daily GBP -> {USD, EUR, TRY} rates for every day in [start, end] (YYYY-MM-DD)."""
    url = f"{FRANKFURTER_BASE}/{start}..{end}"
    resp = requests.get(url, params={"base": base, "symbols": ",".join(symbols)}, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def monthly_average_from_daily(daily_json: dict) -> dict:
    """Collapse a Frankfurter time-series payload into calendar-month averages."""
    rates = daily_json["rates"]  # {"2010-01-04": {"USD": 1.61, ...}, ...}
    df = pd.DataFrame.from_dict(rates, orient="index")
    df.index = pd.to_datetime(df.index)
    monthly = df.resample("MS").mean().round(4)
    monthly.index = monthly.index.strftime("%Y-%m")
    return monthly.to_dict(orient="index")


# ---------------------------------------------------------------------
# 2. Fallback for offline / restricted-network environments
# ---------------------------------------------------------------------
def load_cache() -> dict:
    with open(CACHE_PATH) as f:
        return json.load(f)


def get_monthly_rates(start: str, end: str, offline: bool = False) -> dict:
    if not offline:
        try:
            daily = fetch_historical_daily_rates(start, end)
            print(f"[live_currency_api] Pulled LIVE historical daily rates "
                  f"{start}..{end} from {FRANKFURTER_BASE}")
            return monthly_average_from_daily(daily)
        except Exception as exc:  # network blocked, rate limited, etc.
            print(f"[live_currency_api] Live fetch failed ({exc}); "
                  f"falling back to cached rates in {CACHE_PATH.name}", file=sys.stderr)
    cache = load_cache()
    return cache["monthly_avg_rates"]


def get_latest_snapshot(offline: bool = False) -> dict:
    if not offline:
        try:
            live = fetch_latest_rates()
            print(f"[live_currency_api] Pulled LIVE latest rates as of {live['date']}")
            return {"as_of": live["date"], "rates": live["rates"]}
        except Exception as exc:
            print(f"[live_currency_api] Live fetch failed ({exc}); "
                  f"falling back to cached snapshot", file=sys.stderr)
    cache = load_cache()
    return cache["latest_snapshot"]


# ---------------------------------------------------------------------
# 3. Pull monthly GBP revenue straight from the warehouse
# ---------------------------------------------------------------------
def get_monthly_gbp_revenue(db_url: str | None) -> pd.DataFrame:
    query = """
        SELECT date_trunc('month', invoice_ts)::date AS month,
               sum(line_revenue) AS revenue_gbp
        FROM fact_sales
        WHERE NOT is_cancelled
        GROUP BY 1
        ORDER BY 1;
    """
    if db_url:
        try:
            from sqlalchemy import create_engine
            engine = create_engine(db_url)
            df = pd.read_sql(query, engine)
            print(f"[live_currency_api] Pulled {len(df)} monthly revenue rows from Postgres")
            return df
        except Exception as exc:
            print(f"[live_currency_api] Could not read from Postgres ({exc}); "
                  f"falling back to raw CSV aggregation", file=sys.stderr)

    # Fallback: aggregate straight from the raw CSV so this script never hard-fails
    raw_path = PROJECT_ROOT / "raw_data" / "online_retail_II_raw.csv"
    df = pd.read_csv(raw_path, parse_dates=["invoice_date"])
    df = df[~df["invoice_no"].astype(str).str.startswith(("C", "A"))]
    df = df[df["unit_price"] > 0]
    df["revenue_gbp"] = df["quantity"] * df["unit_price"]
    monthly = (df.set_index("invoice_date")["revenue_gbp"]
                 .resample("MS").sum().reset_index()
                 .rename(columns={"invoice_date": "month"}))
    print(f"[live_currency_api] Pulled {len(monthly)} monthly revenue rows from raw CSV fallback")
    return monthly


# ---------------------------------------------------------------------
# 4. Main
# ---------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Live multi-currency revenue reporting")
    parser.add_argument("--db-url", default=DEFAULT_DB_URL,
                         help="SQLAlchemy Postgres URL (or empty string to force the CSV fallback)")
    parser.add_argument("--offline", action="store_true",
                         help="Skip live API calls entirely and use the bundled FX cache")
    args = parser.parse_args()

    revenue_df = get_monthly_gbp_revenue(args.db_url or None)
    start = revenue_df["month"].min().strftime("%Y-%m-%d")
    end = revenue_df["month"].max().strftime("%Y-%m-%d")

    monthly_rates = get_monthly_rates(start, end, offline=args.offline)
    rates_df = pd.DataFrame.from_dict(monthly_rates, orient="index").reset_index()
    rates_df.columns = ["month_str", "usd_rate", "eur_rate", "try_rate"]

    revenue_df["month_str"] = pd.to_datetime(revenue_df["month"]).dt.strftime("%Y-%m")
    merged = revenue_df.merge(rates_df, on="month_str", how="left")
    merged["revenue_usd"] = (merged["revenue_gbp"] * merged["usd_rate"]).round(2)
    merged["revenue_eur"] = (merged["revenue_gbp"] * merged["eur_rate"]).round(2)
    merged["revenue_try"] = (merged["revenue_gbp"] * merged["try_rate"]).round(2)
    merged["revenue_gbp"] = merged["revenue_gbp"].round(2)

    out_cols = ["month", "revenue_gbp", "usd_rate", "revenue_usd",
                "eur_rate", "revenue_eur", "try_rate", "revenue_try"]
    merged[out_cols].to_csv(OUTPUT_PATH, index=False)
    print(f"[live_currency_api] Wrote {OUTPUT_PATH.relative_to(PROJECT_ROOT)} "
          f"({len(merged)} months)")

    # Live "what is our total historical revenue worth today" headline number
    total_gbp = revenue_df.merge(rates_df, on="month_str")["revenue_gbp"].sum() if False else revenue_df["revenue_gbp"].sum()
    snapshot = get_latest_snapshot(offline=args.offline)
    print("\n=== Live snapshot ===")
    print(f"As of {snapshot['as_of']}: 1 GBP = "
          f"{snapshot['rates']['USD']} USD, {snapshot['rates']['EUR']} EUR, {snapshot['rates']['TRY']} TRY")
    print(f"Total historical net revenue: £{total_gbp:,.2f} GBP  ->  "
          f"${total_gbp * snapshot['rates']['USD']:,.2f} USD  |  "
          f"€{total_gbp * snapshot['rates']['EUR']:,.2f} EUR  |  "
          f"₺{total_gbp * snapshot['rates']['TRY']:,.2f} TRY  (at today's rate)")


if __name__ == "__main__":
    main()
