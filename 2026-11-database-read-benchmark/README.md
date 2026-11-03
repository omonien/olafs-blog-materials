# Database read benchmark: FireDAC and the .NET providers

Sources and data behind the blog post on [developer-experts.net](https://www.developer-experts.net).

Two small programs read the same 2,000,000 rows from Firebird 5, PostgreSQL 18 and SQL Server 2022 and report rows per second plus checksums:

- `delphi/DbReadBench.FireDAC.dpr`: FireDAC, Delphi 13.1, built for Win64 and OSX64. Firebird through the Firebird client library, PostgreSQL through `libpq`, SQL Server through Microsoft ODBC Driver 18.
- `dotnet/Program.cs`: .NET 9 with FirebirdClient 10.3.4, Npgsql 10.0.3 and Microsoft.Data.SqlClient 7.1.1.

Both programs run the same query, inside a snapshot transaction (Firebird concurrency, PostgreSQL repeatable read, SQL Server snapshot), fetch forward-only, and touch the same columns per row: a `BIGINT`, a `NUMERIC(18,2)`, a Unicode string, a timestamp, a `NUMERIC(38,0)` (`INT128` in Firebird) and optionally a timestamp with time zone. The fill scripts produce identical values in all three databases, so the checksums are identical too.

## Results

Rows per second, three passes each, 3 November 2026. All checksums matched in every pass, for every driver. Raw numbers, load and details: [results/2026-11-03-runs.md](results/2026-11-03-runs.md).

**macOS 26, Intel i9, databases in local containers, without the time zone column:**

| Database | FireDAC | .NET | Ratio |
| --- | ---: | ---: | ---: |
| Firebird 5.0.4 | 65,800 to 66,600 | 200,200 to 207,400 | about 3 : 1 |
| PostgreSQL 18.6 | 62,800 to 68,700 | 348,300 to 395,800 | about 5.6 : 1 |
| SQL Server 2022 | 50,300 to 58,300 | 153,900 to 190,200 | about 3.2 : 1 |

**Windows 11 VM on the same Mac, databases reached through Tailscale, with the time zone column:**

| Database | FireDAC | .NET | Ratio |
| --- | ---: | ---: | ---: |
| Firebird 5.0.4 | 46,500 to 61,500 | 50,700 to 72,600 | about 1.1 : 1 |
| PostgreSQL 18.6 | 30,400 to 35,600 | 44,700 to 48,500 | about 1.5 : 1 |
| SQL Server 2022 | 16,000 to 18,900 | 56,500 to 62,900 | about 3.3 : 1 |

The machine was not equally busy during all runs: the Firebird numbers on macOS come from a quiet machine, PostgreSQL and SQL Server ran with a load average between 10 and 37. Compare the ratios, not the absolute numbers across databases.

## Why FireDAC is slower on macOS

CPU profiles (`sample`) of the FireDAC program, symbols resolved with the linker map (`tools/resolve-ld64-map.ps1`). For Firebird, five seconds without the time zone column (the items overlap slightly, because memory management also shows up inside the other items):

| Share of CPU | Where |
| ---: | --- |
| about 35 % | `iconv_open`, `iconv`, `iconv_close`, called from `System.UnicodeFromLocaleChars` |
| about 25 % | the row fetch inside `libfbclient` (`YResultSet::fetchNext`), including rebuilding the message BLR on every fetch call |
| about 15 % | `malloc` and `free` |
| about 5 % | `INT128` converted to text by `libfbclient` (`IInt128::toString`) and parsed back into a BCD |
| about 4 % | ChaCha wire encryption |
| about 6 % | FireDAC and RTL code itself |

The hot path is `TFDPhysCommand.FetchBase` → `TFDPhysIBCommandBase.FetchRow` → `ProcessColumn` → `TIBVariable.GetData` → `TFDEncoder.Decode` → `System.UnicodeFromLocaleChars`.

The Delphi 13 RTL implements `UnicodeFromLocaleChars` differently per platform: on Windows it calls `MultiByteToWideChar`; on Linux it uses ICU, with a direct UTF-8 path and a cached converter; on macOS it opens an iconv converter for `UTF-16LE`, converts, and closes the converter again on every call, without a cache and without a special case for UTF-8.

The two other databases test that explanation:

- **PostgreSQL** sends UTF-8 text. In the FireDAC profile, iconv takes about 60 % of the CPU time (not counting time spent waiting on the socket). The gap to Npgsql is the largest of the three.
- **SQL Server** sends `NVARCHAR` as UTF-16. In the FireDAC profile, iconv does not appear at all. FireDAC is still about three times slower, but for a different reason: the FireDAC process used only about 68 % of one core while the SQL Server process used a full core. The same factor shows up on Windows, over the network. Something in the ODBC route (packet size, fetch pattern or server-side work) costs here; this was not investigated further.

The .NET providers implement their wire protocols in managed code and decode strings with the runtime's own decoders; none of them needs a native client library.

## The time zone trap (Firebird on macOS)

With the `TIMESTAMP WITH TIME ZONE` column FireDAC on macOS did not finish a single Firebird pass within ten minutes. The profile shows `libfbclient` trying to load ICU through `dlopen` for every decoded time stamp (`decodeTimeStampTz` → `TimeZoneUtil::decodeTimeStamp` → `UnicodeUtil::getConversionICU`), failing, and not caching the failure. This happened with the client library taken from the official package without installing the framework. With a regularly installed Firebird client (as on the Windows VM) the test with this column ran normally. PostgreSQL and SQL Server do not hit this trap, because their time zone values never pass through the Firebird client.

## Reproduce

Local throwaway passwords only. Start the database, fill it, run both programs.

**Firebird 5.0.4:**

```bash
docker run -d --name bench-fb -p 53050:3050 -e FIREBIRD_ROOT_PASSWORD=bench -e FIREBIRD_DATABASE=bench.fdb -e FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8 firebirdsql/firebird:5.0.4-bookworm
docker cp firebird/fill.sql bench-fb:/tmp/ && docker exec bench-fb /opt/firebird/bin/isql -user SYSDBA -password bench -ch UTF8 /var/lib/firebird/data/bench.fdb -i /tmp/fill.sql
```

Connection: `fb 127.0.0.1 53050 /var/lib/firebird/data/bench.fdb SYSDBA bench`

**PostgreSQL 18.6:**

```bash
docker run -d --name bench-pg -p 55433:5432 -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench postgres:18.6-bookworm
docker cp postgresql/fill.sql bench-pg:/tmp/ && docker exec bench-pg psql -q -U bench -d bench -f /tmp/fill.sql
```

Connection: `pg 127.0.0.1 55433 bench bench bench`

**SQL Server 2022 Developer** (starting it accepts the SQL Server license terms):

```bash
docker run -d --name bench-mssql -p 51433:1433 -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD=Bench2026xLocal mcr.microsoft.com/mssql/server:2022-latest
docker cp sqlserver/fill.sql bench-mssql:/tmp/ && docker exec bench-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P Bench2026xLocal -f 65001 -i /tmp/fill.sql
```

Connection: `mssql 127.0.0.1 51433 bench sa Bench2026xLocal`

**Run:**

- .NET, from `dotnet/`: `dotnet run -c Release -- <connection> [notz]`
- FireDAC: build `delphi/DbReadBench.FireDAC.dproj` for Win64 or OSX64, then `DbReadBench.FireDAC <connection> [vendorlib] [notz]`.
  - Firebird: on Windows `fbclient.dll` from a Firebird installation; on macOS a client directory staged with `firebird/stage-fbclient-macos.sh` from the official package `Firebird-5.0.4.1812-0-macos-x64.pkg`, vendorlib `<dir>/lib/libfbclient.dylib`.
  - PostgreSQL: `libpq` 18; on macOS for example `/Applications/Postgres.app/Contents/Versions/18/lib/libpq.5.dylib`, on Windows `libpq.dll` from the EDB binaries with its DLLs on the `PATH`.
  - SQL Server: Microsoft ODBC Driver 18 for SQL Server; on macOS with unixODBC, vendorlib `/usr/local/lib/libodbc.2.dylib`.
- `notz` leaves out the time zone column in both programs.
- Profile on macOS: `sample <pid> 5 -file out.txt` while a pass runs; build once more with a detailed map (`DCC_MapFile=3`) and resolve offsets with `tools/resolve-ld64-map.ps1`.

On macOS the FireDAC program prints `Unknown` as type name for some fields; the values and checksums are correct.

## Caveats

- One machine, one table shape. Real workloads with fewer string columns per row will see smaller differences.
- The Windows VM runs on the same Mac and reached the databases through Tailscale; its numbers are network bound.
- Encryption on the wire: Firebird both (FireDAC through `libfbclient` with ChaCha, .NET with Arc4), SQL Server both (TLS), PostgreSQL neither (the container offers no TLS).
- FireDAC ran with default driver settings plus forward-only fetching in rowsets of 2,000; driver-specific tuning was not tried.

## Trademarks

Delphi, RAD Studio, FireDAC and Embarcadero are trademarks or registered trademarks of Embarcadero Technologies, Inc. or its affiliates in the United States and/or other countries. Firebird is a registered trademark of the Firebird Foundation. PostgreSQL is a registered trademark of the PostgreSQL Community Association of Canada. SQL Server and .NET are trademarks of Microsoft Corporation. All other trademarks are the property of their respective owners. This project is not affiliated with, endorsed by, or sponsored by Embarcadero Technologies, Inc.
