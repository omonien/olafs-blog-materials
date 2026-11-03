// Read-throughput benchmark of the .NET providers for Firebird, PostgreSQL and SQL Server.
// Counterpart of delphi/DbReadBench.FireDAC.dpr: same query, same checksums, same isolation.
// Usage: dotnet run -c Release -- fb|pg|mssql host port database user password [notz]
using System;
using System.Data;
using System.Data.Common;
using System.Diagnostics;
using System.Numerics;
using FirebirdSql.Data.FirebirdClient;
using Microsoft.Data.SqlClient;
using Npgsql;

if (args.Length < 6)
{
    Console.WriteLine("Usage: DbReadBench.DotNet fb|pg|mssql host port database user password [notz]");
    return 2;
}
var engine = args[0];
var (host, port, database, user, password) = (args[1], int.Parse(args[2]), args[3], args[4], args[5]);
// "notz" leaves out the time zone column, exactly like the FireDAC program.
var withZoned = args[^1] != "notz";
var sql = "SELECT ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, OLD_PRICE, FACTOR, LABEL_TEXT, CREATED_AT, BIG_AMOUNT"
    + (withZoned ? ", CREATED_TZ" : "") + " FROM BENCH_ROWS";

DbConnection con = engine switch
{
    "fb" => new FbConnection(new FbConnectionStringBuilder
    {
        DataSource = host, Port = port, Database = database, UserID = user, Password = password,
        Charset = "UTF8", Pooling = false, PacketSize = 32767,
    }.ToString()),
    "pg" => new NpgsqlConnection(new NpgsqlConnectionStringBuilder
    {
        Host = host, Port = port, Database = database, Username = user, Password = password, Pooling = false,
    }.ToString()),
    "mssql" => new SqlConnection(new SqlConnectionStringBuilder
    {
        DataSource = $"{host},{port}", InitialCatalog = database, UserID = user, Password = password,
        Encrypt = SqlConnectionEncryptOption.Mandatory, TrustServerCertificate = true, Pooling = false,
    }.ToString()),
    _ => throw new ArgumentException($"unknown engine {engine}"),
};
// Snapshot semantics everywhere: Firebird concurrency, PostgreSQL repeatable read, SQL Server snapshot.
var isolation = engine switch { "pg" => IsolationLevel.RepeatableRead, "mssql" => IsolationLevel.Snapshot, _ => IsolationLevel.Snapshot };

using (con)
{
    con.Open();
    Console.WriteLine($"{engine}: server {con.ServerVersion}; zoned column {(withZoned ? "on" : "off")}");
    for (int run = 1; run <= 3; run++)
    {
        using var tx = engine == "fb"
            ? ((FbConnection)con).BeginTransaction(new FbTransactionOptions { TransactionBehavior = FbTransactionBehavior.Concurrency | FbTransactionBehavior.Read })
            : con.BeginTransaction(isolation);
        using var cmd = con.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.CommandTimeout = 0;
        if (cmd is FbCommand fbCmd)
            fbCmd.FetchSize = 2000;
        var sw = Stopwatch.StartNew();
        long rows = 0, idSum = 0, umlautRows = 0, zonedRows = 0; decimal priceSum = 0; BigInteger bigSum = 0;
        using (var r = cmd.ExecuteReader())
        {
            while (r.Read())
            {
                rows++;
                idSum += r.GetInt64(0);
                priceSum += r.GetDecimal(5);
                if (r.GetString(8).Contains("Österreich")) umlautRows++;
                _ = r.GetDateTime(9);
                // INT128 in Firebird arrives as BigInteger; NUMERIC(38,0) elsewhere fits a decimal here.
                bigSum += engine == "fb" ? (BigInteger)r.GetValue(10) : new BigInteger(r.GetDecimal(10));
                if (withZoned && !r.IsDBNull(11)) zonedRows++;
            }
        }
        sw.Stop();
        Console.WriteLine($"Run {run}: {rows} rows in {sw.Elapsed.TotalSeconds:F2} s = {rows / sw.Elapsed.TotalSeconds:F0} rows/s; idSum={idSum}; priceSum={priceSum}; umlauts ok={umlautRows == rows}; int128Sum={bigSum}; zoned rows={zonedRows}");
        tx.Commit();
    }
}
return 0;
