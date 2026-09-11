"""Builds report/Online_Retail_II_Business_Findings.pdf — a short, first-person,
business-decision-oriented findings report (design brief: what I did / what I
found / what I recommend)."""

from pathlib import Path
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Image, Table,
                                 TableStyle, HRFlowable, ListFlowable, ListItem)
from reportlab.lib.enums import TA_LEFT, TA_JUSTIFY

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ASSETS = PROJECT_ROOT / "report" / "assets"
OUT = PROJECT_ROOT / "report" / "Online_Retail_II_Business_Findings.pdf"

NAVY = colors.HexColor("#1B3A6B")
BLUE = colors.HexColor("#2E5EAA")
ACCENT = colors.HexColor("#E07A5F")
GREY = colors.HexColor("#5A5A5A")
LIGHTBG = colors.HexColor("#F4F6FA")

styles = getSampleStyleSheet()
styles.add(ParagraphStyle("ReportTitle", fontSize=20, leading=24, textColor=NAVY, fontName="Helvetica-Bold", spaceAfter=4))
styles.add(ParagraphStyle("SubTitle", fontSize=11, leading=14, textColor=GREY, fontName="Helvetica", spaceAfter=14))
styles.add(ParagraphStyle("H2", fontSize=13.5, leading=16, textColor=NAVY, fontName="Helvetica-Bold", spaceBefore=14, spaceAfter=6))
styles.add(ParagraphStyle("Body", fontSize=9.6, leading=14, textColor=colors.HexColor("#222222"), fontName="Helvetica", alignment=TA_JUSTIFY, spaceAfter=6))
styles.add(ParagraphStyle("BodyBold", parent=styles["Body"], fontName="Helvetica-Bold"))
styles.add(ParagraphStyle("ReportBullet", parent=styles["Body"], leftIndent=0, spaceAfter=4))
styles.add(ParagraphStyle("Caption", fontSize=8, leading=10, textColor=GREY, fontName="Helvetica-Oblique", alignment=TA_LEFT, spaceAfter=10))
styles.add(ParagraphStyle("KPI", fontSize=14, leading=16, textColor=NAVY, fontName="Helvetica-Bold", alignment=TA_LEFT))
styles.add(ParagraphStyle("KPILabel", fontSize=7.6, leading=9, textColor=GREY, fontName="Helvetica", alignment=TA_LEFT))

story = []

# ---------------------------------------------------------------------
story.append(Paragraph("Online Retail II — Business Findings &amp; Recommendations", styles["ReportTitle"]))
story.append(Paragraph("A business-intelligence &amp; predictive-analytics review of two years of transactional sales data, "
                        "prepared by Berfin  ·  Data Analyst Portfolio Project  ·  September 2026", styles["SubTitle"]))
story.append(HRFlowable(width="100%", thickness=1.1, color=NAVY, spaceAfter=10))

# --- KPI strip ---
kpi_data = [
    ["£20.96M", "1,061,163", "5,942", "£19.90", "0.816"],
    ["Net revenue\n(2 yrs, 43 countries)", "Invoice lines\nanalysed", "Customers\nprofiled", "Average\norder value", "Churn model\nROC-AUC"],
]
kpi_table = Table([[Paragraph(v, styles["KPI"]) for v in kpi_data[0]],
                    [Paragraph(v.replace("\n","<br/>"), styles["KPILabel"]) for v in kpi_data[1]]],
                   colWidths=[174*mm/5]*5)
kpi_table.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,-1), LIGHTBG),
    ("BOX", (0,0), (-1,-1), 0.6, colors.HexColor("#DDE3EE")),
    ("TOPPADDING", (0,0), (-1,-1), 8), ("BOTTOMPADDING", (0,0), (-1,-1), 8),
    ("LEFTPADDING", (0,0), (-1,-1), 8),
    ("LINEBELOW", (0,0), (-1,0), 0, colors.white),
]))
story.append(kpi_table)
story.append(Spacer(1, 10))

# ---------------------------------------------------------------------
story.append(Paragraph("Why I built this", styles["H2"]))
story.append(Paragraph(
    "I wanted a portfolio project that goes beyond a single descriptive notebook and instead mirrors how a real "
    "data/analytics team works end to end: a proper SQL data warehouse, a live external data feed, exploratory and "
    "business-intelligence analysis in Python, a supervised machine-learning model tied to a concrete business "
    "decision, and — the part I'm writing right now — a short findings report that translates all of it into plain "
    "business language. The dataset is the UCI \"Online Retail II\" set: ~1.07 million invoice lines from a UK-based "
    "online retailer of gift and homeware items, December 2009 to December 2011.", styles["Body"]))

story.append(Paragraph("What I did", styles["H2"]))
story.append(ListFlowable([
    ListItem(Paragraph("<b>Built a PostgreSQL data warehouse</b> — a cleaned star schema (fact_sales + "
                        "dim_customer/product/date/country) from the raw source file, with explicit rules for "
                        "cancellations, guest checkouts, and bad-debt adjustment postings (sql/00–01).", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Wrote 15+ SQL analyses</b> directly against that warehouse — KPI summaries, monthly/quarterly "
                        "trends, country concentration, RFM customer segmentation, cohort retention, customer lifetime "
                        "value, and market-basket (cross-sell) analysis (sql/02–03).", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Integrated a live external API</b> — pulling historical and current GBP→USD/EUR/TRY exchange "
                        "rates to convert revenue into the currencies our non-UK stakeholders actually think in "
                        "(scripts/live_currency_api.py).", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Ran a Python EDA/BI notebook</b> with 8 charts, each followed by an explicit business "
                        "takeaway rather than a bare description of the data (notebooks/01).", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Trained and evaluated a churn-prediction model</b> (Logistic Regression + Random Forest) "
                        "on a leakage-safe 90-day holdout split, plus a secondary customer-value regression, and turned "
                        "the output into a ranked, actionable retention target list (notebooks/02).", styles["ReportBullet"])),
], bulletType="bullet", start="•", leftIndent=12))

# ---------------------------------------------------------------------
story.append(Paragraph("What I found", styles["H2"]))
story.append(Image(str(ASSETS/"chart_revenue_trend.png"), width=160*mm, height=68.9*mm))
story.append(Paragraph("Net revenue by month, with a 3-month rolling average. December 2011 is a partial month — the "
                        "extract stops on Dec 9 — not a real demand collapse.", styles["Caption"]))

story.append(Paragraph(
    "<b>1. Growth is real, but seasonal and increasingly retention-driven.</b> Revenue builds steadily into a "
    "September–November peak each year and troughs in Jan/Feb. The share of monthly revenue coming from returning "
    "(not new) customers climbs from roughly two-thirds early in the dataset to 85–95% later on — the business is "
    "leaning more and more on the customers it already has.", styles["Body"]))
story.append(Paragraph(
    "<b>2. The UK dominates, but the real opportunity is the next tier down.</b> A large majority of revenue comes "
    "from the UK alone; EIRE, Germany, France and the Netherlands are the markets with proven repeat demand, and are "
    "a better next-expansion bet than a blank-slate new country.", styles["Body"]))
story.append(Paragraph(
    "<b>3. Retention has a sharp month-1 cliff.</b> Cohort analysis shows most of the drop-off in repeat purchasing "
    "happens in the first 30 days after a customer's first order, in every monthly cohort I looked at — this is the "
    "single highest-leverage point for a lifecycle/onboarding campaign to target.", styles["Body"]))

story.append(Image(str(ASSETS/"chart_rfm_segments.png"), width=160*mm, height=68.9*mm))
story.append(Paragraph("RFM (Recency/Frequency/Monetary) segmentation, computed in SQL and validated against the "
                        "churn model in the notebook.", styles["Caption"]))

story.append(Paragraph(
    "<b>4. Revenue is heavily concentrated in a small \"Champions\" segment</b> (1,294 of 5,942 customers, ~69% of "
    "total revenue). The <b>396-customer \"At-Risk High Value\" segment</b> — proven high spenders who have gone "
    "quiet — is the clearest, highest-ROI retention target.", styles["Body"]))
story.append(Paragraph(
    "<b>5. The churn model works, and it agrees with the segmentation.</b> A Random Forest classifier trained on a "
    "leakage-safe 90-day holdout (features from before the cutoff, label from after it) reaches ROC-AUC = 0.816 — "
    "recency and order frequency are the strongest signals. Predicted risk rises monotonically from Champions to "
    "Lost/Churned, cross-validating the SQL-based segmentation and the ML model against each other. Ranking "
    "customers by <i>probability × historical value</i> (not probability alone) produced a 25-name target list "
    "exported for a retention campaign (exports/churn_risk_list.csv).", styles["Body"]))
story.append(Paragraph(
    "<b>6. Clear, low-risk cross-sell pairs exist</b> and are not currently merchandised together — mostly colour/"
    "pattern variants of the same product (matching cutlery sets, egg cups, cake stands) with purchase-lift scores "
    "of 200–400×, i.e. customers who buy one are 200–400 times more likely than chance to also buy its pair in the "
    "same order.", styles["Body"]))

story.append(Paragraph("What I recommend", styles["H2"]))
story.append(ListFlowable([
    ListItem(Paragraph("<b>Launch a first-30-days lifecycle campaign</b> (welcome flow + a modest second-order "
                        "incentive) — this is where the retention curve is steepest, so it's the highest-leverage "
                        "fix available.", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Run a proactive win-back campaign on the 25-name churn-risk list</b> before those "
                        "customers fully lapse, prioritised by expected revenue at risk rather than by churn "
                        "probability alone.", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Feature the identified product pairs together</b> on product pages and at cart/checkout — "
                        "a low-effort, high-confidence conversion lever versus speculative new bundling.", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Prioritise EIRE, Germany, France and the Netherlands</b> for international investment "
                        "over new-market entry, since they already show repeat (not one-off) demand.", styles["ReportBullet"])),
    ListItem(Paragraph("<b>Report exec revenue in period-correct multi-currency terms</b> (each month converted at "
                        "that month's own rate, not one static rate) — the live-API pipeline built for this project "
                        "already produces that table.", styles["ReportBullet"])),
], bulletType="bullet", start="•", leftIndent=12))

story.append(Paragraph("Limitations &amp; next steps", styles["H2"]))
story.append(Paragraph(
    "This is historical data (through Dec 2011) from a single UK retailer, so absolute figures are illustrative "
    "rather than current — the methodology, not the specific numbers, is the deliverable. The churn model's 90-day "
    "definition is a reasonable default but should be tuned against the business's actual reorder cycle; the "
    "secondary revenue-regression model is noisy enough that I'd trust it only for relative ranking, not as a "
    "financial forecast. A natural next step is a live Power BI dashboard on top of the star schema built here, "
    "which I built together with a Power BI Desktop session — see the README for that walkthrough and screenshot.",
    styles["Body"]))

story.append(Spacer(1, 8))
story.append(HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#CCCCCC")))
story.append(Paragraph("Full SQL, Python notebooks, the live-API script and the data warehouse build scripts are in "
                        "the accompanying GitHub repository. — Berfin", styles["Caption"]))

doc = SimpleDocTemplate(str(OUT), pagesize=A4,
                         leftMargin=18*mm, rightMargin=18*mm, topMargin=16*mm, bottomMargin=16*mm,
                         title="Online Retail II — Business Findings & Recommendations", author="Berfin")
doc.build(story)
print("Wrote", OUT)
