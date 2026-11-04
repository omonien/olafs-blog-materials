-- 200,000 primary key lookups and 200,000 single-row updates inside the server, without the client protocol.
-- Run after "oltp-setup scale=10" (pgbench tables). The difference to the oltp test is the cost of the round trips.
\timing on
DO $$
DECLARE b integer; checksum bigint := 0;
BEGIN
  FOR i IN 0..199999 LOOP
    SELECT abalance INTO b FROM pgbench_accounts WHERE aid = (i::bigint * 7919 % 1000000) + 1;
    checksum := checksum + b;
  END LOOP;
  RAISE NOTICE 'lookups 200000, checksum %', checksum;
END $$;
BEGIN;
DO $$
BEGIN
  FOR i IN 0..199999 LOOP
    UPDATE pgbench_accounts SET abalance = abalance + 1 WHERE aid = (i::bigint * 7919 % 1000000) + 1;
  END LOOP;
  RAISE NOTICE 'updates 200000';
END $$;
ROLLBACK;
