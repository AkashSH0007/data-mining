INSTALL postgres;
LOAD postgres;
ATTACH 'dbname=annapurna user=annapurna password=annapurna host=postgres' AS pg (TYPE POSTGRES, READ_ONLY);

CREATE OR REPLACE TEMP VIEW sales AS
SELECT * FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true);

WITH priced_lines AS (
  SELECT s.business_date, s.store_id, p.product_name,
         pr.selling_price, s.qty
  FROM sales s
  JOIN pg.products p ON p.product_code = s.product_code
    AND s.business_date BETWEEN p.valid_from AND p.valid_to
  JOIN pg.price_revisions pr ON pr.product_sk = p.product_sk
    AND s.business_date BETWEEN pr.effective_from AND pr.effective_to
  WHERE s.business_date >= getvariable('period_start')
    AND s.business_date < getvariable('period_end')
    AND s.line_type IN ('SALE', 'RETURN', 'DISCOUNT', 'VOID')
)
SELECT getvariable('period_start')::DATE AS reporting_period_start,
       getvariable('period_end')::DATE AS reporting_period_end,
       product_name,
       round(sum(qty * selling_price), 2) AS revenue_at_historical_price
FROM priced_lines
GROUP BY product_name
ORDER BY product_name;