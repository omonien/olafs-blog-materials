-- Creates the benchmark table in PostgreSQL and fills it with the same 2,000,000 rows as firebird/fill.sql.
-- Expected checksums: sum(id) = 2000001000000, sum(price) = 6900000.00.
CREATE TABLE bench_rows (
  id bigint NOT NULL PRIMARY KEY,
  parent_id integer NOT NULL,
  branch_no integer,
  kind char(1),
  status char(1),
  price numeric(18,2),
  old_price numeric(18,2),
  factor double precision,
  label_text varchar(200),
  created_at timestamp,
  big_amount numeric(38,0),
  created_tz timestamptz
);
INSERT INTO bench_rows
SELECT i, i / 3, i % 500, 'K', CASE WHEN i % 3 = 0 THEN 'W' ELSE 'L' END,
       1.5 + trunc((i % 400) / 100.0, 1), NULL, 1.0, 'Grüße aus Österreich, Zeile ' || i,
       timestamp '2025-01-01 00:00:00' + i * interval '1 second', i * 1000000000000::numeric, now()
FROM generate_series(1::bigint, 2000000::bigint) AS g(i);
ANALYZE bench_rows;
SELECT count(*), sum(id), sum(price) FROM bench_rows;
