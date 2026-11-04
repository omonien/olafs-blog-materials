// Benchmark harness for comparing Firebird and PostgreSQL through their .NET providers (FirebirdClient, Npgsql).
// Both servers get the same program, the same data and, where the dialects allow it, the same SQL, so the
// comparison measures the servers and not two different client stacks. Every measurement prints one line
// "RESULT key=value ..." that tools/summarize.py collects.
//
// Usage: DbCompareBench <test> fb|pg host port database user password [key=value ...]
//   probe        server version and the settings that matter for a fair comparison
//   size         database size on disk
//   read         reads the 2,000,000 rows of BENCH_ROWS three times (table of the first post); zoned=on|off
//   insert       one row per transaction through a prepared INSERT; clients= seconds= warmup=
//                durability=default|relaxed (relaxed: Firebird forced writes off, PostgreSQL synchronous_commit off)
//   bulk         loads rows= into LOAD_ROWS in one transaction; mode=prepared (row by row) or
//                mode=native (Firebird batch API, PostgreSQL binary COPY)
//   oltp-setup   pgbench-compatible tables for scale= (100,000 accounts per scale unit), filled on the server
//   oltp         script=tpcb|simple|select (the three built-in pgbench scripts) clients= seconds= warmup= scale=
//   json-setup   docs= order documents: jsonb with a GIN index (PostgreSQL), VARCHAR (Firebird, no JSON type)
//   json         query=lookup-index|lookup-scan|lookup-like|lookup-client|agg-sql|agg-client repeat=
// Common options: wirecrypt=on|off (Firebird, default off), serverproc=<name> adds up the CPU time of all
// server processes with that name (firebird, postgres) during each measurement.
using System.Data;
using System.Data.Common;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using FirebirdSql.Data.FirebirdClient;
using FirebirdSql.Data.Services;
using Npgsql;
using NpgsqlTypes;

CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;

if (args.Length < 7)
{
    Console.WriteLine("Usage: DbCompareBench <test> fb|pg host port database user password [key=value ...]");
    return 2;
}
var options = args[7..].Select(a => a.Split('=', 2)).ToDictionary(p => p[0], p => p.Length > 1 ? p[1] : "");
var db = new Db(args[1], args[2], int.Parse(args[3]), args[4], args[5], args[6], options);
switch (args[0])
{
    case "probe": Tests.Probe(db); break;
    case "size": Tests.Size(db); break;
    case "read": Tests.Read(db); break;
    case "insert": Tests.Insert(db); break;
    case "bulk": Tests.Bulk(db); break;
    case "oltp-setup": Tests.OltpSetup(db); break;
    case "oltp": Tests.Oltp(db); break;
    case "json-setup": Tests.JsonSetup(db); break;
    case "json": Tests.Json(db); break;
    default: Console.WriteLine($"unknown test {args[0]}"); return 2;
}
return 0;

/// <summary>Column types the tests bind; mapped to the provider's own type enum so neither side guesses.</summary>
enum Col { Int, BigInt, Decimal, Double, Char, Text, Timestamp, Json }

/// <summary>Connection settings and the few places where the two servers need different code.</summary>
sealed class Db
{
    public readonly bool Fb;
    public readonly string Engine;
    readonly string _connectionString;
    readonly Dictionary<string, string> _options;

    public Db(string engine, string host, int port, string database, string user, string password, Dictionary<string, string> options)
    {
        Engine = engine;
        Fb = engine == "fb";
        _options = options;
        _connectionString = engine switch
        {
            // Firebird servers require wire encryption by default (WireCrypt = Required); the benchmark servers are
            // set to Enabled, so the client decides. PostgreSQL runs without TLS, so both sides send plain text.
            "fb" => new FbConnectionStringBuilder
            {
                DataSource = host, Port = port, Database = database, UserID = user, Password = password,
                Charset = "UTF8", Pooling = false, PacketSize = 32767,
                WireCrypt = Opt("wirecrypt", "off") == "on" ? FbWireCrypt.Required : FbWireCrypt.Disabled,
            }.ToString(),
            "pg" => new NpgsqlConnectionStringBuilder
            {
                Host = host, Port = port, Database = database, Username = user, Password = password,
                Pooling = false, SslMode = SslMode.Disable,
            }.ToString(),
            _ => throw new ArgumentException($"unknown engine {engine}"),
        };
    }

    public string ConnectionString => _connectionString;
    public string Opt(string key, string fallback) => _options.TryGetValue(key, out var v) ? v : fallback;
    public int OptInt(string key, int fallback) => _options.TryGetValue(key, out var v) ? int.Parse(v) : fallback;

    public DbConnection Open()
    {
        DbConnection con = Fb ? new FbConnection(_connectionString) : new NpgsqlConnection(_connectionString);
        con.Open();
        return con;
    }

    /// <summary>
    /// Read committed, read-write, waiting on locks: the default of PostgreSQL, and the Firebird mode in which a
    /// conflicting update waits and, with ReadConsistency = 1 (default since Firebird 4), restarts the statement
    /// instead of failing.
    /// </summary>
    public DbTransaction BeginWrite(DbConnection con) => Fb
        ? ((FbConnection)con).BeginTransaction(new FbTransactionOptions
        {
            TransactionBehavior = FbTransactionBehavior.Write | FbTransactionBehavior.ReadCommitted |
                                  FbTransactionBehavior.RecVersion | FbTransactionBehavior.Wait,
        })
        : con.BeginTransaction(IsolationLevel.ReadCommitted);

    /// <summary>Read-only read committed: the cheap reader transaction of Firebird, kept open by the select script.</summary>
    public DbTransaction BeginReadOnly(DbConnection con) => Fb
        ? ((FbConnection)con).BeginTransaction(new FbTransactionOptions
        {
            TransactionBehavior = FbTransactionBehavior.Read | FbTransactionBehavior.ReadCommitted |
                                  FbTransactionBehavior.RecVersion | FbTransactionBehavior.Wait,
        })
        : con.BeginTransaction(IsolationLevel.ReadCommitted);

    /// <summary>Snapshot semantics for the long reads: Firebird concurrency, PostgreSQL repeatable read.</summary>
    public DbTransaction BeginSnapshot(DbConnection con) => Fb
        ? ((FbConnection)con).BeginTransaction(new FbTransactionOptions
        {
            TransactionBehavior = FbTransactionBehavior.Concurrency | FbTransactionBehavior.Read | FbTransactionBehavior.Wait,
        })
        : con.BeginTransaction(IsolationLevel.RepeatableRead);

    public DbCommand Command(DbConnection con, DbTransaction? tx, string sql, params (string Name, Col Type)[] parameters)
    {
        var cmd = con.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.CommandTimeout = 0;
        foreach (var (name, type) in parameters)
        {
            if (cmd is FbCommand fb)
                fb.Parameters.Add(name, type switch
                {
                    Col.Int => FbDbType.Integer, Col.BigInt => FbDbType.BigInt, Col.Decimal => FbDbType.Decimal,
                    Col.Double => FbDbType.Double, Col.Char => FbDbType.Char, Col.Timestamp => FbDbType.TimeStamp,
                    _ => FbDbType.VarChar,
                });
            else
                ((NpgsqlCommand)cmd).Parameters.Add(name, Pg(type));
        }
        return cmd;
    }

    public static NpgsqlDbType Pg(Col type) => type switch
    {
        Col.Int => NpgsqlDbType.Integer, Col.BigInt => NpgsqlDbType.Bigint, Col.Decimal => NpgsqlDbType.Numeric,
        Col.Double => NpgsqlDbType.Double, Col.Char => NpgsqlDbType.Char, Col.Timestamp => NpgsqlDbType.Timestamp,
        Col.Json => NpgsqlDbType.Jsonb, _ => NpgsqlDbType.Varchar,
    };

    public void Exec(DbConnection con, DbTransaction? tx, string sql)
    {
        using var cmd = Command(con, tx, sql);
        cmd.ExecuteNonQuery();
    }

    public object? Scalar(DbConnection con, DbTransaction? tx, string sql)
    {
        using var cmd = Command(con, tx, sql);
        return cmd.ExecuteScalar();
    }

    /// <summary>Drops and creates a table; Firebird commits each DDL statement on its own (no transaction given).</summary>
    public void Recreate(DbConnection con, string table, string columns)
    {
        if (Fb)
            Exec(con, null, $"RECREATE TABLE {table} ({columns})");
        else
        {
            Exec(con, null, $"DROP TABLE IF EXISTS {table}");
            Exec(con, null, $"CREATE TABLE {table} ({columns})");
        }
    }

    /// <summary>Updates index statistics so that both optimizers know the loaded data.</summary>
    public void Analyze(DbConnection con, string table)
    {
        if (!Fb)
        {
            Exec(con, null, $"VACUUM ANALYZE {table}");
            return;
        }
        var names = new List<string>();
        using (var cmd = Command(con, null, $"SELECT TRIM(RDB$INDEX_NAME) FROM RDB$INDICES WHERE RDB$RELATION_NAME = '{table.ToUpperInvariant()}'"))
        using (var r = cmd.ExecuteReader())
            while (r.Read()) names.Add(r.GetString(0));
        foreach (var name in names)
            Exec(con, null, $"SET STATISTICS INDEX {name}");
    }

    /// <summary>Lock conflicts and deadlocks are retried, as pgbench does with --max-tries.</summary>
    public static bool IsRetryable(Exception e) => e switch
    {
        PostgresException pg => pg.SqlState is "40001" or "40P01",
        FbException fb => fb.Errors.Any(x => x.Number is 335544336 or 335544345 or 335544878 or 335545096),
        _ => false,
    };

    /// <summary>Durability as configured in the server, reported with every write measurement.</summary>
    public string Durability(DbConnection con) => Fb
        ? $"forced_writes={Scalar(con, null, "SELECT MON$FORCED_WRITES FROM MON$DATABASE")}"
        : $"synchronous_commit={Scalar(con, null, "SHOW synchronous_commit")},fsync={Scalar(con, null, "SHOW fsync")}";

    /// <summary>Forced writes are a database attribute in Firebird; the services API switches them.</summary>
    public void SetForcedWrites(bool on)
    {
        var configuration = new FbConfiguration(_connectionString);
        configuration.SetForcedWrites(on);
    }
}

/// <summary>
/// CPU time of this process and, optionally, of the server processes, between Start and Stop. The server processes are
/// sampled every 200 ms per process ID, so that processes which start and end in between (autovacuum, parallel
/// workers) count as well; a process that ends loses at most its last 200 ms.
/// </summary>
sealed class CpuMeter
{
    readonly string? _serverProcess;
    readonly Dictionary<int, (TimeSpan First, TimeSpan Last)> _seen = [];
    TimeSpan _client;
    Timer? _timer;

    public CpuMeter(Db db) => _serverProcess = db.Opt("serverproc", "") is { Length: > 0 } name ? name : null;

    void Sample(bool baseline)
    {
        lock (_seen)
        {
            // PostgreSQL retitles its processes ("postgres: walwriter"), and on Linux .NET takes the name from that title.
            foreach (var p in System.Diagnostics.Process.GetProcesses())
            {
                try
                {
                    if (!p.ProcessName.StartsWith(_serverProcess!, StringComparison.Ordinal)) continue;
                    var cpu = p.TotalProcessorTime;
                    _seen[p.Id] = _seen.TryGetValue(p.Id, out var known) ? (known.First, cpu) : (baseline ? cpu : TimeSpan.Zero, cpu);
                }
                catch (InvalidOperationException) { } // ended meanwhile
                catch (System.ComponentModel.Win32Exception) { } // not accessible
                finally { p.Dispose(); }
            }
        }
    }

    public void Start()
    {
        _client = System.Diagnostics.Process.GetCurrentProcess().TotalProcessorTime;
        if (_serverProcess == null) return;
        lock (_seen) _seen.Clear();
        Sample(baseline: true);
        _timer = new Timer(_ => Sample(baseline: false), null, 200, 200);
    }

    public string Stop()
    {
        var client = System.Diagnostics.Process.GetCurrentProcess().TotalProcessorTime - _client;
        var text = $"client_cpu_s={client.TotalSeconds:F2}";
        if (_serverProcess == null) return text;
        _timer?.Dispose();
        Sample(baseline: false);
        TimeSpan server;
        lock (_seen) server = _seen.Values.Aggregate(TimeSpan.Zero, (sum, v) => sum + (v.Last - v.First));
        return text + $" server_cpu_s={server.TotalSeconds:F2}";
    }
}

/// <summary>One client of a concurrent test: owns its connection and prepared commands.</summary>
interface IWork : IDisposable
{
    void Run(Random random);
    void Abort();
}

static class Runner
{
    /// <summary>
    /// Starts the clients together, lets them work for warmup plus seconds, and counts the transactions that started
    /// after the warm-up and finished inside the measured window. Latencies are kept per transaction.
    /// </summary>
    public static string Run(Db db, int clients, double warmup, double seconds, Func<int, IWork> create)
    {
        var freq = (double)System.Diagnostics.Stopwatch.Frequency;
        long start = 0;
        var cpu = new CpuMeter(db);
        using var barrier = new Barrier(clients, _ => { cpu.Start(); start = System.Diagnostics.Stopwatch.GetTimestamp(); });
        // CPU is read when the last client has finished and before any connection closes: a PostgreSQL backend ends
        // with its connection and takes its CPU time with it.
        var cpuText = "";
        using var finished = new Barrier(clients, _ => cpuText = cpu.Stop());
        var latencies = new List<int>[clients];
        long total = 0, retries = 0, failed = 0;
        Exception? error = null;
        var threads = Enumerable.Range(0, clients).Select(n => new Thread(() =>
        {
            var mine = latencies[n] = new List<int>(1 << 16);
            IWork? work = null;
            try
            {
                work = create(n);
                barrier.SignalAndWait();
                var measureFrom = start + (long)(warmup * freq);
                var end = measureFrom + (long)(seconds * freq);
                var random = new Random(4711 + n);
                long done = 0, retried = 0, lost = 0;
                while (true)
                {
                    var t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                    if (t0 >= end) break;
                    var ok = false;
                    for (var attempt = 1; ; attempt++)
                    {
                        try { work.Run(random); ok = true; break; }
                        catch (Exception e) when (Db.IsRetryable(e))
                        {
                            work.Abort();
                            if (attempt == 10) { lost++; break; }
                            retried++;
                        }
                    }
                    var t1 = System.Diagnostics.Stopwatch.GetTimestamp();
                    done++;
                    if (ok && t0 >= measureFrom && t1 <= end)
                        mine.Add((int)((t1 - t0) * 1_000_000 / freq));
                }
                Interlocked.Add(ref total, done);
                Interlocked.Add(ref retries, retried);
                Interlocked.Add(ref failed, lost);
                finished.SignalAndWait();
            }
            catch (Exception e)
            {
                error ??= e;
                barrier.RemoveParticipant();
                finished.RemoveParticipant();
            }
            finally { work?.Dispose(); }
        }) { IsBackground = true }).ToList();
        threads.ForEach(t => t.Start());
        threads.ForEach(t => t.Join());
        if (error != null) throw new InvalidOperationException("a client failed", error);
        var all = latencies.SelectMany(l => l).ToArray();
        Array.Sort(all);
        double Pct(double q) => all.Length == 0 ? 0 : all[Math.Min(all.Length - 1, (int)(q * all.Length))] / 1000.0;
        var avg = all.Length == 0 ? 0 : all.Average() / 1000.0;
        return $"clients={clients} seconds={seconds:F0} txns={all.Length} tps={all.Length / seconds:F1} lat_avg_ms={avg:F3} " +
               $"p50_ms={Pct(0.50):F3} p95_ms={Pct(0.95):F3} p99_ms={Pct(0.99):F3} max_ms={(all.Length == 0 ? 0 : all[^1] / 1000.0):F3} " +
               $"retries={retries} failed={failed} total_txns={total} run_s={warmup + seconds:F0} {cpuText}";
    }
}

sealed class InsertWork : IWork
{
    readonly Db _db;
    readonly DbConnection _con;
    readonly DbCommand _insert;
    readonly int _client;
    DbTransaction? _tx;
    bool _prepared;
    long _n;

    public InsertWork(Db db, int client)
    {
        _db = db;
        _client = client;
        _con = db.Open();
        if (!db.Fb && db.Opt("durability", "default") == "relaxed")
            db.Exec(_con, null, "SET synchronous_commit = off");
        _insert = db.Command(_con, null, "INSERT INTO INS_ROWS (CLIENT_NO, CREATED_AT, AMOUNT, LABEL_TEXT) VALUES (@c, @t, @a, @l)",
            ("@c", Col.Int), ("@t", Col.Timestamp), ("@a", Col.Decimal), ("@l", Col.Text));
    }

    public void Run(Random random)
    {
        _n++;
        _tx = _db.BeginWrite(_con);
        _insert.Transaction = _tx;
        if (!_prepared) { _insert.Prepare(); _prepared = true; }
        _insert.Parameters[0].Value = _client;
        _insert.Parameters[1].Value = new DateTime(2026, 1, 1).AddSeconds(_n);
        _insert.Parameters[2].Value = 1.5m + _n % 400 / 100m;
        _insert.Parameters[3].Value = $"Grüße aus Österreich, Zeile {_n}";
        _insert.ExecuteNonQuery();
        _tx.Commit();
        _tx.Dispose();
        _tx = null;
    }

    public void Abort() { try { _tx?.Rollback(); } catch (DbException) { } _tx?.Dispose(); _tx = null; }

    public void Dispose() { _insert.Dispose(); _con.Dispose(); }
}

/// <summary>The three built-in pgbench scripts: tpcb-like, simple-update (-N) and select-only (-S).</summary>
sealed class OltpWork : IWork
{
    readonly Db _db;
    readonly DbConnection _con;
    readonly string _script;
    readonly int _scale;
    readonly DbCommand _updateAccount, _selectAccount, _updateTeller, _updateBranch, _insertHistory;
    DbTransaction? _tx;
    bool _prepared;

    public OltpWork(Db db, string script, int scale)
    {
        _db = db;
        _script = script;
        _scale = scale;
        _con = db.Open();
        _updateAccount = db.Command(_con, null, "UPDATE pgbench_accounts SET abalance = abalance + @delta WHERE aid = @aid", ("@delta", Col.Int), ("@aid", Col.Int));
        _selectAccount = db.Command(_con, null, "SELECT abalance FROM pgbench_accounts WHERE aid = @aid", ("@aid", Col.Int));
        _updateTeller = db.Command(_con, null, "UPDATE pgbench_tellers SET tbalance = tbalance + @delta WHERE tid = @tid", ("@delta", Col.Int), ("@tid", Col.Int));
        _updateBranch = db.Command(_con, null, "UPDATE pgbench_branches SET bbalance = bbalance + @delta WHERE bid = @bid", ("@delta", Col.Int), ("@bid", Col.Int));
        _insertHistory = db.Command(_con, null, "INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (@tid, @bid, @aid, @delta, LOCALTIMESTAMP)",
            ("@tid", Col.Int), ("@bid", Col.Int), ("@aid", Col.Int), ("@delta", Col.Int));
        // select-only: PostgreSQL runs each SELECT in its own implicit transaction, as pgbench -S does; Firebird keeps
        // one read-only read committed transaction open, the usual way to read there (it does not hold back garbage
        // collection). Both see the latest committed data with every statement.
        if (script == "select" && db.Fb)
            _tx = db.BeginReadOnly(_con);
    }

    DbCommand[] Commands => [_updateAccount, _selectAccount, _updateTeller, _updateBranch, _insertHistory];

    public void Run(Random random)
    {
        var aid = random.Next(1, 100_000 * _scale + 1);
        if (_script == "select")
        {
            _selectAccount.Transaction = _tx;
            if (!_prepared) { _selectAccount.Prepare(); _prepared = true; }
            _selectAccount.Parameters[0].Value = aid;
            _selectAccount.ExecuteScalar();
            return;
        }
        var bid = random.Next(1, _scale + 1);
        var tid = random.Next(1, 10 * _scale + 1);
        var delta = random.Next(-5000, 5001);
        _tx = _db.BeginWrite(_con);
        foreach (var cmd in Commands) cmd.Transaction = _tx;
        if (!_prepared) { foreach (var cmd in Commands) cmd.Prepare(); _prepared = true; }
        Exec(_updateAccount, delta, aid);
        _selectAccount.Parameters[0].Value = aid;
        _selectAccount.ExecuteScalar();
        if (_script == "tpcb")
        {
            Exec(_updateTeller, delta, tid);
            Exec(_updateBranch, delta, bid);
        }
        Exec(_insertHistory, tid, bid, aid, delta);
        _tx.Commit();
        _tx.Dispose();
        _tx = null;
    }

    static void Exec(DbCommand cmd, params int[] values)
    {
        for (var i = 0; i < values.Length; i++) cmd.Parameters[i].Value = values[i];
        cmd.ExecuteNonQuery();
    }

    public void Abort() { try { _tx?.Rollback(); } catch (DbException) { } _tx?.Dispose(); _tx = null; }

    public void Dispose()
    {
        if (_tx != null) { _tx.Commit(); _tx.Dispose(); }
        foreach (var cmd in Commands) cmd.Dispose();
        _con.Dispose();
    }
}

static class Tests
{
    static void Result(Db db, string test, string fields) => Console.WriteLine($"RESULT test={test} engine={db.Engine} {fields}");

    public static void Probe(Db db)
    {
        using var con = db.Open();
        Console.WriteLine($"server: {con.ServerVersion}");
        if (db.Fb)
        {
            Print(db, con, null, "SELECT RDB$GET_CONTEXT('SYSTEM', 'ENGINE_VERSION'), MON$PAGE_SIZE, MON$PAGE_BUFFERS, MON$FORCED_WRITES, " +
                                 "MON$SWEEP_INTERVAL, MON$ODS_MAJOR || '.' || MON$ODS_MINOR FROM MON$DATABASE",
                "engine_version", "page_size", "page_buffers", "forced_writes", "sweep_interval", "ods");
            Print(db, con, null, "SELECT RDB$GET_CONTEXT('SYSTEM', 'WIRE_ENCRYPTED'), RDB$GET_CONTEXT('SYSTEM', 'WIRE_CRYPT_PLUGIN'), " +
                                 "RDB$GET_CONTEXT('SYSTEM', 'WIRE_COMPRESSED') FROM RDB$DATABASE", "wire_encrypted", "wire_crypt_plugin", "wire_compressed");
            using (var cmd = db.Command(con, null, "SELECT TRIM(RDB$CONFIG_NAME), RDB$CONFIG_VALUE FROM RDB$CONFIG WHERE RDB$CONFIG_NAME IN " +
                       "('ServerMode', 'DefaultDbCachePages', 'ReadConsistency', 'WireCrypt', 'MaxParallelWorkers', 'ParallelWorkers', " +
                       "'GCPolicy', 'UseFileSystemCache', 'FileSystemCacheThreshold', 'TempCacheLimit', 'LockHashSlots', 'AuthServer')"))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) Console.WriteLine($"config {r.GetString(0)}={(r.IsDBNull(1) ? "" : r.GetString(1))}");
            using var tx = db.BeginWrite(con);
            Print(db, con, tx, "SELECT MON$ISOLATION_MODE, MON$LOCK_TIMEOUT FROM MON$TRANSACTIONS WHERE MON$TRANSACTION_ID = CURRENT_TRANSACTION",
                "write_tx_isolation_mode(4=read consistency)", "write_tx_lock_timeout(-1=wait)");
            tx.Commit();
        }
        else
        {
            Print(db, con, null, "SELECT version()", "version");
            using (var cmd = db.Command(con, null, "SELECT name, current_setting(name) FROM pg_settings WHERE name IN " +
                       "('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'synchronous_commit', 'fsync', " +
                       "'wal_sync_method', 'full_page_writes', 'wal_level', 'max_wal_size', 'checkpoint_timeout', 'max_connections', " +
                       "'max_parallel_workers_per_gather', 'max_worker_processes', 'io_method', 'jit', 'autovacuum', 'ssl', " +
                       "'default_transaction_isolation', 'password_encryption') ORDER BY name"))
            using (var r = cmd.ExecuteReader())
                while (r.Read()) Console.WriteLine($"config {r.GetString(0)}={r.GetString(1)}");
            Print(db, con, null, "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()", "connection_ssl");
        }
    }

    static void Print(Db db, DbConnection con, DbTransaction? tx, string sql, params string[] names)
    {
        try
        {
            using var cmd = db.Command(con, tx, sql);
            using var r = cmd.ExecuteReader();
            if (!r.Read()) return;
            for (var i = 0; i < names.Length; i++) Console.WriteLine($"{names[i]}={(r.IsDBNull(i) ? "null" : Convert.ToString(r.GetValue(i))?.Trim())}");
        }
        catch (DbException e) { Console.WriteLine($"{string.Join(",", names)}: {e.Message}"); }
    }

    public static void Size(Db db)
    {
        using var con = db.Open();
        // Firebird 4+ multiplies BIGINT values into INT128, which arrives as BigInteger.
        var bytes = (long)(db.Scalar(con, null, db.Fb
            ? "SELECT MON$PAGES * MON$PAGE_SIZE FROM MON$DATABASE"
            : "SELECT pg_database_size(current_database())") switch { BigInteger b => b, var v => new BigInteger(Convert.ToInt64(v)) });
        Result(db, "size", $"database_mb={bytes / 1048576.0:F1}");
        if (db.Fb) return;
        using var cmd = db.Command(con, null, "SELECT c.relname, pg_total_relation_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " +
                                              "WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY 1");
        using var r = cmd.ExecuteReader();
        while (r.Read()) Result(db, "size", $"table={r.GetString(0)} total_mb={r.GetInt64(1) / 1048576.0:F1}");
    }

    /// <summary>The read of the first post: same query, same checksums, snapshot transaction, forward only.</summary>
    public static void Read(Db db)
    {
        var zoned = db.Opt("zoned", "on") == "on";
        var sql = "SELECT ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, OLD_PRICE, FACTOR, LABEL_TEXT, CREATED_AT, BIG_AMOUNT"
                  + (zoned ? ", CREATED_TZ" : "") + " FROM BENCH_ROWS";
        using var con = db.Open();
        var cpu = new CpuMeter(db);
        for (var pass = 1; pass <= db.OptInt("passes", 3); pass++)
        {
            using var tx = db.BeginSnapshot(con);
            using var cmd = db.Command(con, tx, sql);
            if (cmd is FbCommand fbCmd) fbCmd.FetchSize = 2000;
            cpu.Start();
            var sw = System.Diagnostics.Stopwatch.StartNew();
            long rows = 0, idSum = 0, umlautRows = 0;
            decimal priceSum = 0;
            BigInteger bigSum = 0;
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    rows++;
                    idSum += r.GetInt64(0);
                    priceSum += r.GetDecimal(5);
                    if (r.GetString(8).Contains("Österreich")) umlautRows++;
                    _ = r.GetDateTime(9);
                    bigSum += db.Fb ? (BigInteger)r.GetValue(10) : new BigInteger(r.GetDecimal(10));
                    if (zoned) _ = r.GetValue(11);
                }
            }
            sw.Stop();
            var ok = idSum == 2000001000000 && priceSum == 6900000m && umlautRows == rows &&
                     bigSum == BigInteger.Parse("2000001000000000000000000");
            Result(db, "read", $"zoned={(zoned ? "on" : "off")} wirecrypt={db.Opt("wirecrypt", "off")} pass={pass} rows={rows} " +
                               $"seconds={sw.Elapsed.TotalSeconds:F2} rows_per_s={rows / sw.Elapsed.TotalSeconds:F0} checks_ok={ok} {cpu.Stop()}");
            tx.Commit();
        }
    }

    public static void Insert(Db db)
    {
        var relaxed = db.Opt("durability", "default") == "relaxed";
        using (var con = db.Open())
            db.Recreate(con, "INS_ROWS", db.Fb
                ? "ID BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, CLIENT_NO INTEGER NOT NULL, CREATED_AT TIMESTAMP NOT NULL, " +
                  "AMOUNT NUMERIC(18,2) NOT NULL, LABEL_TEXT VARCHAR(100) CHARACTER SET UTF8 NOT NULL"
                : "id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, client_no integer NOT NULL, created_at timestamp NOT NULL, " +
                  "amount numeric(18,2) NOT NULL, label_text varchar(100) NOT NULL");
        if (db.Fb) db.SetForcedWrites(!relaxed);
        string durability;
        using (var con = db.Open())
        {
            if (!db.Fb && relaxed) db.Exec(con, null, "SET synchronous_commit = off");
            durability = db.Durability(con);
        }
        try
        {
            var text = Runner.Run(db, db.OptInt("clients", 1), db.OptInt("warmup", 5), db.OptInt("seconds", 30), n => new InsertWork(db, n));
            Result(db, "insert", $"durability={(relaxed ? "relaxed" : "default")} {durability} {text}");
        }
        finally
        {
            if (db.Fb && relaxed) db.SetForcedWrites(true);
        }
    }

    // Same values as the fill scripts of BENCH_ROWS, nine columns.
    const string LoadColumnsFb = "ID BIGINT NOT NULL PRIMARY KEY, PARENT_ID INTEGER NOT NULL, BRANCH_NO INTEGER, KIND CHAR(1), STATUS CHAR(1), " +
                                 "PRICE NUMERIC(18,2), FACTOR DOUBLE PRECISION, LABEL_TEXT VARCHAR(200) CHARACTER SET UTF8, CREATED_AT TIMESTAMP";
    const string LoadColumnsPg = "id bigint NOT NULL PRIMARY KEY, parent_id integer NOT NULL, branch_no integer, kind char(1), status char(1), " +
                                 "price numeric(18,2), factor double precision, label_text varchar(200), created_at timestamp";
    static readonly (string Name, Col Type)[] LoadParams =
        [("@id", Col.BigInt), ("@parent", Col.Int), ("@branch", Col.Int), ("@kind", Col.Char), ("@status", Col.Char),
         ("@price", Col.Decimal), ("@factor", Col.Double), ("@label", Col.Text), ("@created", Col.Timestamp)];

    static object[] LoadRow(long i) =>
        [i, (int)(i / 3), (int)(i % 500), "K", i % 3 == 0 ? "W" : "L", 1.5m + i % 400 / 100m, 1.0,
         $"Grüße aus Österreich, Zeile {i}", new DateTime(2025, 1, 1).AddSeconds(i)];

    public static void Bulk(Db db)
    {
        var rows = db.OptInt("rows", 1_000_000);
        var mode = db.Opt("mode", "native");
        using var con = db.Open();
        db.Recreate(con, "LOAD_ROWS", db.Fb ? LoadColumnsFb : LoadColumnsPg);
        var durability = db.Durability(con);
        const string insert = "INSERT INTO LOAD_ROWS (ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, FACTOR, LABEL_TEXT, CREATED_AT) " +
                              "VALUES (@id, @parent, @branch, @kind, @status, @price, @factor, @label, @created)";
        var cpu = new CpuMeter(db);
        cpu.Start();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        using (var tx = db.BeginWrite(con))
        {
            if (mode == "prepared")
            {
                using var cmd = db.Command(con, tx, insert, LoadParams);
                cmd.Prepare();
                for (long i = 1; i <= rows; i++)
                {
                    var values = LoadRow(i);
                    for (var c = 0; c < values.Length; c++) cmd.Parameters[c].Value = values[c];
                    cmd.ExecuteNonQuery();
                }
            }
            else if (db.Fb)
                FbBatchLoad((FbConnection)con, (FbTransaction)tx, insert, LoadParams, rows, LoadRow);
            else
                PgCopy((NpgsqlConnection)con, "COPY LOAD_ROWS (ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, FACTOR, LABEL_TEXT, CREATED_AT) FROM STDIN (FORMAT BINARY)",
                    LoadParams, rows, LoadRow);
            var loaded = sw.Elapsed.TotalSeconds;
            tx.Commit();
            sw.Stop();
            var cpuText = cpu.Stop();
            var count = Convert.ToInt64(db.Scalar(con, null, "SELECT COUNT(*) FROM LOAD_ROWS"));
            Result(db, "bulk", $"mode={mode} {durability} rows={count} seconds={sw.Elapsed.TotalSeconds:F2} load_s={loaded:F2} " +
                               $"commit_s={sw.Elapsed.TotalSeconds - loaded:F2} rows_per_s={rows / sw.Elapsed.TotalSeconds:F0} {cpuText}");
        }
    }

    /// <summary>
    /// The Firebird 4+ batch API: many parameter sets sent in one message, executed in one call per chunk. The server
    /// buffers a chunk at the declared column sizes (VARCHAR(n) in UTF8 takes 4 n bytes), within FbBatchCommand.BatchBufferSize.
    /// </summary>
    static void FbBatchLoad(FbConnection con, FbTransaction tx, string sql, (string Name, Col Type)[] parameters, long rows,
        Func<long, object[]> row, int chunk = 10_000)
    {
        using var cmd = new FbBatchCommand(sql, con, tx);
        cmd.Prepare();
        var pending = 0;
        for (long i = 1; i <= rows; i++)
        {
            var batch = cmd.AddBatchParameters();
            var values = row(i);
            for (var c = 0; c < values.Length; c++) batch.Add(parameters[c].Name, values[c]);
            if (++pending == chunk || i == rows)
            {
                var result = cmd.ExecuteNonQuery();
                if (!result.AllSuccess) throw new InvalidOperationException("batch had failed rows");
                cmd.BatchParameters.Clear();
                pending = 0;
            }
        }
    }

    static void PgCopy(NpgsqlConnection con, string copy, (string Name, Col Type)[] parameters, long rows, Func<long, object[]> row)
    {
        using var writer = con.BeginBinaryImport(copy);
        for (long i = 1; i <= rows; i++)
        {
            writer.StartRow();
            var values = row(i);
            for (var c = 0; c < values.Length; c++) writer.Write(values[c], Db.Pg(parameters[c].Type));
        }
        writer.Complete();
    }

    public static void OltpSetup(Db db)
    {
        var scale = db.OptInt("scale", 10);
        using var con = db.Open();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        // pgbench's own schema (pgbench -i), so pgbench can drive the PostgreSQL side as a cross-check.
        db.Recreate(con, "pgbench_history", "tid integer, bid integer, aid integer, delta integer, mtime timestamp, filler char(22)");
        db.Recreate(con, "pgbench_accounts", "aid integer NOT NULL PRIMARY KEY, bid integer, abalance integer, filler char(84)");
        db.Recreate(con, "pgbench_tellers", "tid integer NOT NULL PRIMARY KEY, bid integer, tbalance integer, filler char(84)");
        db.Recreate(con, "pgbench_branches", "bid integer NOT NULL PRIMARY KEY, bbalance integer, filler char(88)");
        if (db.Fb)
        {
            db.Exec(con, null, $"EXECUTE BLOCK AS DECLARE I INTEGER = 1; BEGIN " +
                               $"WHILE (I <= {scale}) DO BEGIN INSERT INTO pgbench_branches VALUES (:I, 0, NULL); I = I + 1; END I = 1; " +
                               $"WHILE (I <= {10 * scale}) DO BEGIN INSERT INTO pgbench_tellers VALUES (:I, (:I - 1) / 10 + 1, 0, NULL); I = I + 1; END I = 1; " +
                               $"WHILE (I <= {100_000 * scale}) DO BEGIN INSERT INTO pgbench_accounts VALUES (:I, (:I - 1) / 100000 + 1, 0, ''); I = I + 1; END END");
        }
        else
        {
            db.Exec(con, null, $"INSERT INTO pgbench_branches SELECT b, 0, NULL FROM generate_series(1, {scale}) b");
            db.Exec(con, null, $"INSERT INTO pgbench_tellers SELECT t, (t - 1) / 10 + 1, 0, NULL FROM generate_series(1, {10 * scale}) t");
            db.Exec(con, null, $"INSERT INTO pgbench_accounts SELECT a, (a - 1) / 100000 + 1, 0, '' FROM generate_series(1, {100_000 * scale}) a");
        }
        foreach (var table in new[] { "pgbench_branches", "pgbench_tellers", "pgbench_accounts", "pgbench_history" })
            db.Analyze(con, table);
        var accounts = Convert.ToInt64(db.Scalar(con, null, "SELECT COUNT(*) FROM pgbench_accounts"));
        Result(db, "oltp-setup", $"scale={scale} accounts={accounts} seconds={sw.Elapsed.TotalSeconds:F1}");
    }

    public static void Oltp(Db db)
    {
        var script = db.Opt("script", "tpcb");
        var scale = db.OptInt("scale", 10);
        string durability;
        using (var con = db.Open()) durability = db.Durability(con);
        var text = Runner.Run(db, db.OptInt("clients", 1), db.OptInt("warmup", 5), db.OptInt("seconds", 30), _ => new OltpWork(db, script, scale));
        Result(db, "oltp", $"script={script} scale={scale} {durability} {text}");
    }

    static readonly string[] Statuses = ["open", "paid", "shipped", "cancelled"];
    static readonly string[] Countries = ["AT", "DE", "CH", "IT", "FR"];
    const int LookupCustomer = 4711;

    /// <summary>A small order document, about 230 bytes, the same text for both servers.</summary>
    static string Document(long id)
    {
        var sb = new StringBuilder(256);
        sb.Append("{\"id\": ").Append(id)
          .Append(", \"customer\": {\"id\": ").Append(id * 7919 % 10000 + 1).Append(", \"country\": \"").Append(Countries[id % 5]).Append("\"}")
          .Append(", \"status\": \"").Append(Statuses[id % 4]).Append('"')
          .Append(", \"amount\": ").Append((id * 37 % 100000 / 100m).ToString("0.00", CultureInfo.InvariantCulture))
          .Append(", \"created\": \"").Append(new DateTime(2026, 1, 1).AddSeconds(id).ToString("yyyy-MM-ddTHH:mm:ssZ")).Append('"')
          .Append(", \"items\": [");
        for (var k = 0; k <= id % 3; k++)
        {
            if (k > 0) sb.Append(", ");
            sb.Append("{\"sku\": \"SKU-").Append((id + k * 13) % 500).Append("\", \"qty\": ").Append((id + k) % 5 + 1).Append('}');
        }
        return sb.Append("]}").ToString();
    }

    public static void JsonSetup(Db db)
    {
        var docs = db.OptInt("docs", 500_000);
        using var con = db.Open();
        db.Recreate(con, "JSON_DOCS", db.Fb ? "ID BIGINT NOT NULL PRIMARY KEY, DOC VARCHAR(2000) CHARACTER SET UTF8 NOT NULL"
                                            : "id bigint NOT NULL PRIMARY KEY, doc jsonb NOT NULL");
        (string, Col)[] parameters = [("@id", Col.BigInt), ("@doc", db.Fb ? Col.Text : Col.Json)];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        using (var tx = db.BeginWrite(con))
        {
            if (db.Fb)
                FbBatchLoad((FbConnection)con, (FbTransaction)tx, "INSERT INTO JSON_DOCS (ID, DOC) VALUES (@id, @doc)", parameters, docs, i => [i, Document(i)], 1_000);
            else
                PgCopy((NpgsqlConnection)con, "COPY json_docs (id, doc) FROM STDIN (FORMAT BINARY)", parameters, docs, i => [i, Document(i)]);
            tx.Commit();
        }
        var loaded = sw.Elapsed.TotalSeconds;
        // A generic JSON index; Firebird 5 has no JSON functions to index.
        if (!db.Fb) db.Exec(con, null, "CREATE INDEX json_docs_doc ON json_docs USING gin (doc jsonb_path_ops)");
        db.Analyze(con, "JSON_DOCS");
        Result(db, "json-setup", $"docs={docs} load_s={loaded:F1} index_s={sw.Elapsed.TotalSeconds - loaded:F1}");
    }

    public static void Json(Db db)
    {
        var query = db.Opt("query", "lookup-client");
        using var con = db.Open();
        if (!db.Fb && db.Opt("parallel", "on") == "off") db.Exec(con, null, "SET max_parallel_workers_per_gather = 0");
        var cpu = new CpuMeter(db);
        for (var run = 1; run <= db.OptInt("repeat", 5); run++)
        {
            using var tx = db.BeginSnapshot(con);
            cpu.Start();
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var answer = query switch
            {
                "lookup-index" when !db.Fb => SqlLookup(db, con, tx, $"doc @> '{{\"customer\": {{\"id\": {LookupCustomer}}}}}'"),
                "lookup-scan" when !db.Fb => SqlLookup(db, con, tx, $"(doc -> 'customer' ->> 'id')::int = {LookupCustomer}"),
                // Text search instead of JSON: only correct because this test writes every document the same way.
                "lookup-like" => ClientScan(db, con, tx, (db.Fb ? "DOC" : "doc::text") + $" LIKE '%\"customer\": {{\"id\": {LookupCustomer},%'", lookup: true),
                "lookup-client" => ClientScan(db, con, tx, null, lookup: true),
                "agg-sql" when !db.Fb => SqlAggregate(db, con, tx),
                "agg-client" => ClientScan(db, con, tx, null, lookup: false),
                _ => throw new ArgumentException($"query {query} is not available for {db.Engine}"),
            };
            sw.Stop();
            Result(db, "json", $"query={query} parallel={db.Opt("parallel", "on")} run={run} ms={sw.Elapsed.TotalMilliseconds:F1} answer={answer} {cpu.Stop()}");
            tx.Commit();
        }
    }

    static string SqlLookup(Db db, DbConnection con, DbTransaction tx, string where)
    {
        using var cmd = db.Command(con, tx, $"SELECT count(*), sum((doc ->> 'amount')::numeric) FROM json_docs WHERE {where}");
        using var r = cmd.ExecuteReader();
        r.Read();
        return $"{r.GetInt64(0)}:{r.GetDecimal(1):F2}";
    }

    static string SqlAggregate(Db db, DbConnection con, DbTransaction tx)
    {
        using var cmd = db.Command(con, tx, "SELECT doc ->> 'status', count(*), sum((doc ->> 'amount')::numeric) FROM json_docs GROUP BY 1 ORDER BY 1");
        using var r = cmd.ExecuteReader();
        var parts = new List<string>();
        while (r.Read()) parts.Add($"{r.GetString(0)}:{r.GetInt64(1)}:{r.GetDecimal(2):F2}");
        return string.Join(",", parts);
    }

    /// <summary>What an application does without JSON support in the server: fetch the documents and parse them itself.</summary>
    static string ClientScan(Db db, DbConnection con, DbTransaction tx, string? where, bool lookup)
    {
        using var cmd = db.Command(con, tx, (db.Fb ? "SELECT DOC FROM JSON_DOCS" : "SELECT doc::text FROM json_docs") + (where == null ? "" : $" WHERE {where}"));
        if (cmd is FbCommand fbCmd) fbCmd.FetchSize = 2000;
        long count = 0;
        decimal sum = 0;
        var groups = new SortedDictionary<string, (long Count, decimal Sum)>(StringComparer.Ordinal);
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            using var doc = JsonDocument.Parse(r.GetString(0));
            var root = doc.RootElement;
            var amount = root.GetProperty("amount").GetDecimal();
            if (lookup)
            {
                if (root.GetProperty("customer").GetProperty("id").GetInt32() != LookupCustomer) continue;
                count++;
                sum += amount;
            }
            else
            {
                var status = root.GetProperty("status").GetString()!;
                groups[status] = groups.TryGetValue(status, out var g) ? (g.Count + 1, g.Sum + amount) : (1, amount);
            }
        }
        return lookup ? $"{count}:{sum:F2}" : string.Join(",", groups.Select(g => $"{g.Key}:{g.Value.Count}:{g.Value.Sum:F2}"));
    }
}
