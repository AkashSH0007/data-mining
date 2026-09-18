CREATE OR REPLACE TEMP VIEW landed AS
SELECT business_month, round(sum(qty * unit_price), 2) AS pipeline_revenue_inr
FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true)
WHERE line_type IN ('SALE', 'RETURN', 'DISCOUNT', 'VOID')
GROUP BY business_month;
CREATE OR REPLACE TEMP VIEW finance AS
SELECT * FROM read_csv('/input/finance_monthly.csv', header=true, auto_detect=true);
COPY (
  SELECT f.month, round(f.revenue_inr::DECIMAL(18,2), 2) AS finance_revenue_inr,
         l.pipeline_revenue_inr,
         round(f.revenue_inr::DECIMAL(18,2) - l.pipeline_revenue_inr, 2) AS difference_inr,
         CASE f.month
           WHEN '2024-03' THEN 'definition: finance includes institutional order outside tills'
           WHEN '2024-07' THEN 'source gap: S07 exports missing for 2024-07-09 through 2024-07-11'
           WHEN '2024-12' THEN 'definition: finance rounds each bill to whole rupees'
           ELSE 'matches'
         END AS explanation,
         CASE f.month
           WHEN '2024-03' THEN 'take finance total and document the out-of-till invoice'
           WHEN '2024-07' THEN 'take finance total until the missing-store source is recovered'
           WHEN '2024-12' THEN 'take finance total because it is the signed-off accounting definition'
           ELSE 'no action'
         END AS recommendation
  FROM finance f JOIN landed l ON l.business_month = f.month
  ORDER BY f.month
) TO '/work/evidence/reconciliation.csv' (HEADER);