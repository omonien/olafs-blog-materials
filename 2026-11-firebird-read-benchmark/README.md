# Firebird read benchmark: FireDAC and the .NET provider

Sources and data behind the blog post on [developer-experts.net](https://www.developer-experts.net).

Two small programs read the same 2,000,000 rows from a Firebird 5 database and report rows per second plus checksums:

- `delphi/FirebirdBench.FireDAC.dpr`: FireDAC, Delphi 13.1, built for Win64 and OSX64.
- `dotnet/Program.cs`: the FirebirdClient ADO.NET provider 10.3.4 on .NET 9.

Both use the same query, a read-only snapshot transaction, forward-only fetching in blocks of 2,000 rows, UTF-8 as connection character set, and touch the same columns per row: a `BIGINT`, a `NUMERIC(18,2)`, a UTF-8 `VARCHAR`, a `TIMESTAMP`, an `INT128` and optionally a `TIMESTAMP WITH TIME ZONE`.

## Results

Rows per second, three passes each, 3 November 2026. Details and a control run under load: [results/2026-11-03-runs.md](results/2026-11-03-runs.md).

| Platform | Driver | without zoned column | with zoned column |
| --- | --- | ---: | ---: |
| macOS 26, Intel i9, local container | FireDAC (OSX64) | 65,800 to 66,600 | below 3,300 (no pass finished in 600 s) |
| macOS 26, Intel i9, local container | FirebirdClient (.NET 9) | 200,200 to 207,400 | 184,900 to 197,000 |
| Windows 11 VM, network via Tailscale | FireDAC (Win64) | | 46,500 to 61,500 |
| Windows 11 VM, network via Tailscale | FirebirdClient (.NET 9) | | 50,700 to 72,600 |

All checksums matched the server side in every pass, for both drivers.

On Windows the network path limits both drivers; the numbers say nothing about their CPU cost there. On macOS nothing but the client limits: the FireDAC process sits at 100 % of one core while the server is idle.

## Why FireDAC is slower on macOS

A five second CPU profile (`sample`) of the FireDAC program, symbols resolved with the linker map (`tools/resolve-ld64-map.ps1`):

| Share of CPU | Where |
| ---: | --- |
| about 35 % | `iconv_open`, `iconv`, `iconv_close`, called from `System.UnicodeFromLocaleChars` |
| about 25 % | the row fetch inside `libfbclient` (`YResultSet::fetchNext`), including rebuilding the message BLR on every fetch call |
| about 15 % | `malloc` and `free` |
| about 9 % | `memmove` and `bzero` |
| about 5 % | `INT128` converted to text by `libfbclient` (`IInt128::toString`) and parsed back into a BCD |
| about 4 % | ChaCha wire encryption |
| about 6 % | FireDAC and RTL code itself |

The hot path is `TFDPhysCommand.FetchBase` → `TFDPhysIBCommandBase.FetchRow` → `ProcessColumn` → `TIBVariable.GetData` → `TFDEncoder.Decode` → `System.UnicodeFromLocaleChars`.

The Delphi 13 RTL implements `UnicodeFromLocaleChars` differently per platform: on Windows it calls `MultiByteToWideChar`; on Linux it uses ICU, with a direct UTF-8 path and a cached converter; on macOS it opens an iconv converter for `UTF-16LE`, converts, and closes the converter again on every call, without a cache and without a special case for UTF-8. FireDAC decodes every string column of every row through that function, so on macOS each row pays for several iconv sessions.

The .NET provider speaks the Firebird wire protocol itself and decodes UTF-8 with the runtime's own decoder; it loads no native library at all.

Not measured: FireDAC on Windows without a network limit. Since Windows takes the `MultiByteToWideChar` path, the iconv share should not exist there.

## The time zone trap

With the `TIMESTAMP WITH TIME ZONE` column FireDAC on macOS did not finish a single pass within ten minutes. The profile shows `libfbclient` trying to load ICU through `dlopen` for every decoded time stamp (`decodeTimeStampTz` → `TimeZoneUtil::decodeTimeStamp` → `UnicodeUtil::getConversionICU`), failing, and not caching the failure. This happened with the client library taken from the official package without installing the framework. With a regularly installed Firebird client (as on the Windows VM) the column costs nothing special. The .NET provider decodes time zones itself.

## Reproduce

1. Firebird 5.0.4 in Docker (local throwaway password `bench`):
   ```bash
   docker run -d --name fbbench -p 53050:3050 -e FIREBIRD_ROOT_PASSWORD=bench -e FIREBIRD_DATABASE=bench.fdb -e FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8 firebirdsql/firebird:5.0.4-bookworm
   ```
2. Create and fill the table (about 30 seconds):
   ```bash
   docker cp fill.sql fbbench:/tmp/ && docker exec fbbench /opt/firebird/bin/isql -user SYSDBA -password bench -ch UTF8 /var/lib/firebird/data/bench.fdb -i /tmp/fill.sql
   ```
3. .NET, from `dotnet/`:
   ```bash
   dotnet run -c Release -- 127.0.0.1 53050 /var/lib/firebird/data/bench.fdb SYSDBA bench 2000 notz
   ```
4. FireDAC: build `delphi/FirebirdBench.FireDAC.dproj` for Win64 or OSX64 and run
   `FirebirdBench.FireDAC host port database user password [vendorlib] [notz]`.
   FireDAC needs the Firebird 5 client library: on Windows `fbclient.dll` from a Firebird installation, on macOS a client directory staged with `macos/stage-fbclient.sh` from the official package `Firebird-5.0.4.1812-0-macos-x64.pkg`.
5. Profile on macOS: `sample <pid> 5 -file out.txt` while a pass runs; build once more with a detailed map (`DCC_MapFile=3`) and resolve offsets with `tools/resolve-ld64-map.ps1`.

`notz` leaves out the `TIMESTAMP WITH TIME ZONE` column in both programs.

## Caveats

- One machine, one database, one table shape. Real workloads with fewer string columns per row will see a smaller difference.
- The Windows VM runs on the same Mac and reached the database through Tailscale; its numbers are network bound.
- Both connections were encrypted on the wire: FireDAC through `libfbclient` with ChaCha, the .NET provider with Arc4.

## Trademarks

Delphi, RAD Studio, FireDAC and Embarcadero are trademarks or registered trademarks of Embarcadero Technologies, Inc. or its affiliates in the United States and/or other countries. Firebird is a registered trademark of the Firebird Foundation. .NET is a trademark of Microsoft Corporation. All other trademarks are the property of their respective owners. This project is not affiliated with, endorsed by, or sponsored by Embarcadero Technologies, Inc.
