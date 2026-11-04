-- 200,000 primary key lookups and 200,000 single-row updates inside the server, without the client protocol.
-- Run after "oltp-setup scale=10" (pgbench tables). The difference to the oltp test is the cost of the round trips.
SET STATS ON;
SET TERM ^;
EXECUTE BLOCK RETURNS (LOOKUPS INTEGER, CHECKSUM BIGINT) AS
DECLARE I INTEGER = 0;
DECLARE B INTEGER;
BEGIN
  CHECKSUM = 0;
  WHILE (I < 200000) DO
  BEGIN
    SELECT ABALANCE FROM PGBENCH_ACCOUNTS WHERE AID = MOD(:I * 7919, 1000000) + 1 INTO :B;
    CHECKSUM = CHECKSUM + B;
    I = I + 1;
  END
  LOOKUPS = I;
  SUSPEND;
END^
EXECUTE BLOCK RETURNS (UPDATES INTEGER) AS
DECLARE I INTEGER = 0;
BEGIN
  WHILE (I < 200000) DO
  BEGIN
    UPDATE PGBENCH_ACCOUNTS SET ABALANCE = ABALANCE + 1 WHERE AID = MOD(:I * 7919, 1000000) + 1;
    I = I + 1;
  END
  UPDATES = I;
  SUSPEND;
END^
SET TERM ;^
ROLLBACK;
