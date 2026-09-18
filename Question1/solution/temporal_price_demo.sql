INSTALL postgres;
LOAD postgres;
ATTACH 'dbname=annapurna user=annapurna password=annapurna host=postgres' AS pg (TYPE POSTGRES, READ_ONLY);

CREATE OR REPLACE TEMP VIEW sales AS
SELECT * FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true);

COPY (
  WITH periods AS (
    SELECT '2024-03' AS reporting_period, DATE '2024-03-01' AS period_start, DATE '2024-04-01' AS period_end
    UNION ALL
    SELECT '2024-11', DATE '2024-11-01', DATE '2024-12-01'
  ), priced_lines AS (
    SELECT periods.reporting_period, s.business_date, s.store_id, p.product_name,
           pr.selling_price, s.qty
    FROM sales s
    JOIN periods ON s.business_date >= periods.period_start AND s.business_date < periods.period_end
    JOIN pg.products p ON p.product_code = s.product_code
      AND s.business_date BETWEEN p.valid_from AND p.valid_to
    JOIN pg.price_revisions pr ON pr.product_sk = p.product_sk
      AND s.business_date BETWEEN pr.effective_from AND pr.effective_to
    WHERE s.line_type IN ('SALE', 'RETURN', 'DISCOUNT', 'VOID')
  )
  SELECT reporting_period, product_name, round(sum(qty * selling_price), 2) AS revenue_at_historical_price
  FROM priced_lines
  GROUP BY reporting_period, product_name
  ORDER BY reporting_period, product_name
) TO '/work/evidence/temporal_price_demo.csv' (HEADER);