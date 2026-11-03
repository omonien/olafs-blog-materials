// Read-throughput benchmark of the FirebirdClient ADO.NET provider against Firebird 5.
// Counterpart of delphi/FirebirdBench.FireDAC.dpr: same query, same checksums, same fetch size.
// Usage: dotnet run -c Release -- host port database user password [fetchSize] [notz]
using System;
using System.Diagnostics;
using System.Numerics;
using FirebirdSql.Data.FirebirdClient;

if (args.Length < 5)
{
    Console.WriteLine("Usage: FirebirdBench.DotNet host port database user password [fetchSize] [notz]");
    return 2;
}
var fetchSize = args.Length >= 6 ? int.Parse(args[5]) : 2000;
// "notz" leaves out the TIMESTAMP WITH TIME ZONE column, exactly like the FireDAC program.
var withZoned = !(args.Length >= 7 && args[6] == "notz");
var sql = "SELECT ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, OLD_PRICE, FACTOR, LABEL_TEXT, CREATED_AT, BIG_AMOUNT"
    + (withZoned ? ", CREATED_TZ" : "") + " FROM BENCH_ROWS";
var cs = new FbConnectionStringBuilder
{
    DataSource = args[0], Port = int.Parse(args[1]), Database = args[2],
    UserID = args[3], Password = args[4], Charset = "UTF8", Pooling = false, PacketSize = 32767,
}.ToString();

using var con = new FbConnection(cs);
con.Open();
Console.WriteLine($"Server: {con.ServerVersion}; fetch size {fetchSize}; zoned column {(withZoned ? "on" : "off")}");
for (int run = 1; run <= 3; run++)
{
    using var tx = con.BeginTransaction(new FbTransactionOptions { TransactionBehavior = FbTransactionBehavior.Concurrency | FbTransactionBehavior.Read });
    using var cmd = new FbCommand(sql, con, tx) { FetchSize = fetchSize };
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
            bigSum += (BigInteger)r.GetValue(10);
            if (withZoned && !r.IsDBNull(11)) zonedRows++;
        }
    }
    sw.Stop();
    Console.WriteLine($"Run {run}: {rows} rows in {sw.Elapsed.TotalSeconds:F2} s = {rows / sw.Elapsed.TotalSeconds:F0} rows/s; idSum={idSum}; priceSum={priceSum}; umlauts ok={umlautRows == rows}; int128Sum={bigSum}; zoned rows={zonedRows}");
    tx.Commit();
}
return 0;
