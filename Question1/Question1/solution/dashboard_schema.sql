INSTALL postgres;
LOAD postgres;
ATTACH 'dbname=annapurna user=annapurna password=annapurna host=postgres' AS pg (TYPE POSTGRES, READ_ONLY);

CREATE OR REPLACE TABLE dim_store AS
SELECT store_id, store_name, address_line, city, state, region, floor_area_sqft, opened_on
FROM pg.stores;

CREATE OR REPLACE TABLE dim_category AS
SELECT category_id, category_name, department, gst_rate
FROM pg.product_categories;

CREATE OR REPLACE TABLE dim_product AS
SELECT product_sk, product_code, product_name, category_id, brand, pack_size, uom,
       valid_from, valid_to, is_current
FROM pg.products;

CREATE OR REPLACE TABLE dim_date AS
SELECT DISTINCT business_date AS date_key,
       strftime(business_date, '%Y-%m') AS month_key,
       strftime(business_date, '%A') AS day_of_week,
       extract('dow' FROM business_date)::INTEGER AS day_of_week_number
FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true);

CREATE OR REPLACE TABLE fact_sales AS
SELECT r.business_date AS date_key, r.store_id, p.product_sk, p.category_id,
       r.bill_no, r.line_no, r.line_type, r.qty, r.unit_price,
       r.qty * r.unit_price AS line_revenue
FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true) r
JOIN pg.products p ON p.product_code = r.product_code
  AND r.business_date BETWEEN p.valid_from AND p.valid_to;

COPY (
  SELECT table_name, estimated_size AS rows
  FROM duckdb_tables()
  WHERE table_name IN ('dim_store', 'dim_category', 'dim_product', 'dim_date', 'fact_sales')
  ORDER BY table_name
) TO '/work/evidence/dashboard_table_sizes.csv' (HEADER);