INSTALL postgres;
LOAD postgres;
ATTACH 'dbname=annapurna user=annapurna password=annapurna host=postgres' AS pg (TYPE POSTGRES, READ_ONLY);

CREATE OR REPLACE VIEW sales AS
SELECT * FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true);

-- Revenue excludes TAX and TENDER. VOID is retained, so cancelled bills net to zero.
CREATE OR REPLACE VIEW revenue_lines AS
SELECT *, qty * unit_price AS line_revenue
FROM sales
WHERE line_type IN ('SALE', 'RETURN', 'DISCOUNT', 'VOID');

COPY (
  SELECT business_month, round(sum(line_revenue), 2) AS revenue_inr
  FROM revenue_lines
  GROUP BY business_month
  ORDER BY business_month
) TO '/work/evidence/pipeline_monthly.csv' (HEADER);

-- One query supports any reporting month and uses the product and price revision
-- valid on that month. Change only the two date parameters to rerun it.
COPY (
  WITH params AS (SELECT DATE '2024-03-01' AS period_start, DATE '2024-04-01' AS period_end),
  dated_products AS (
    SELECT r.*, p.product_sk, p.product_name, p.category_id
    FROM revenue_lines r
    JOIN pg.products p ON p.product_code = r.product_code
      AND r.business_date >= p.valid_from AND r.business_date <= p.valid_to
    CROSS JOIN params
    WHERE r.business_date >= params.period_start AND r.business_date < params.period_end
  )
  SELECT dp.business_date, dp.store_id, pc.category_name, dp.product_name,
         pr.selling_price AS authoritative_price,
         sum(dp.qty) AS quantity, round(sum(dp.qty * pr.selling_price), 2) AS revenue_at_period_price
  FROM dated_products dp
  JOIN pg.product_categories pc ON pc.category_id = dp.category_id
  JOIN pg.price_revisions pr ON pr.product_sk = dp.product_sk
    AND dp.business_date >= pr.effective_from AND dp.business_date <= pr.effective_to
  GROUP BY ALL ORDER BY dp.business_date, dp.store_id, dp.product_name
) TO '/work/evidence/march_prices.csv' (HEADER);

COPY (
  WITH params AS (SELECT DATE '2024-10-01' AS period_start, DATE '2024-11-01' AS period_end)
  SELECT s.store_id, s.store_name, pc.category_name,
         strftime(r.business_date, '%A') AS day_of_week,
         r.business_month, round(sum(r.line_revenue), 2) AS revenue_inr
  FROM revenue_lines r
  JOIN pg.stores s ON s.store_id = r.store_id
  JOIN pg.products p ON p.product_code = r.product_code
    AND r.business_date BETWEEN p.valid_from AND p.valid_to
  JOIN pg.product_categories pc ON pc.category_id = p.category_id
  CROSS JOIN params
  WHERE r.business_date >= params.period_start AND r.business_date < params.period_end
  GROUP BY ALL ORDER BY s.store_id, pc.category_name, day_of_week
) TO '/work/evidence/october_slice.csv' (HEADER);

EXPLAIN SELECT s.region, pc.category_name, sum(r.line_revenue) AS revenue_inr
  FROM revenue_lines r
  JOIN pg.stores s ON s.store_id = r.store_id
  JOIN pg.products p ON p.product_code = r.product_code
    AND r.business_date BETWEEN p.valid_from AND p.valid_to
  JOIN pg.product_categories pc ON pc.category_id = p.category_id
  WHERE r.business_month = '2024-10'
  GROUP BY s.region, pc.category_name;