/// <summary>
/// DbReadBench.FireDAC
/// Read-throughput benchmark of FireDAC against Firebird, PostgreSQL and SQL Server.
/// </summary>
///
/// <remarks>
/// Counterpart of dotnet/Program.cs: reads the 2 million rows created by the
/// fill scripts, builds the same checksums and prints rows per second, so the
/// drivers are compared on identical data. Deliberately a single program
/// without a data module: it only measures.
/// Usage: DbReadBench.FireDAC fb|pg|mssql host port database user password [vendorlib] [notz] [tuned]
/// "tuned" changes only FireDAC options, never the query: larger rowsets, no
/// metadata lookups, silent mode and a read-only dataset.
/// </remarks>
///
/// <copyright>
/// Copyright © 2026 Olaf Monien
/// Licensed under MIT
/// </copyright>

program DbReadBench.FireDAC;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  Data.DB,
  Data.FmtBcd,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Error,
  FireDAC.Phys.Intf,
  FireDAC.Phys,
  FireDAC.Phys.FB,
  FireDAC.Phys.FBDef,
  FireDAC.Phys.PG,
  FireDAC.Phys.PGDef,
  FireDAC.Phys.ODBCBase,
  FireDAC.Phys.MSSQL,
  FireDAC.Phys.MSSQLDef,
  FireDAC.DApt,
  FireDAC.ConsoleUI.Wait,
  FireDAC.Comp.Client;

const
  cRuns = 3;
  cRowsetSize = 2000;
  cTunedRowsetSize = 10000;
  scSelectColumns = 'SELECT ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, OLD_PRICE, FACTOR, ' +
    'LABEL_TEXT, CREATED_AT, BIG_AMOUNT';
  // The zoned column needs ICU in the Firebird client; "notz" leaves it out.
  scZonedColumn = ', CREATED_TZ';
  scFrom = ' FROM BENCH_ROWS';
  scNoZonedSwitch = 'notz';
  scTunedSwitch = 'tuned';
  scUmlautMarker = 'Österreich';
  scEngineFirebird = 'fb';
  scEnginePostgres = 'pg';
  scEngineSqlServer = 'mssql';
  scOdbcDriver = 'ODBC Driver 18 for SQL Server';

/// <summary>Configures the connection for the engine named in the first argument.</summary>
procedure ConfigureConnection(const AConnection: TFDConnection; const AEngine: string);
begin
  AConnection.LoginPrompt := False;
  AConnection.Params.Values['Database'] := ParamStr(4);
  AConnection.Params.Values['User_Name'] := ParamStr(5);
  AConnection.Params.Values['Password'] := ParamStr(6);
  if AEngine = scEngineFirebird then
  begin
    AConnection.DriverName := 'FB';
    AConnection.Params.Values['Protocol'] := 'TCPIP';
    AConnection.Params.Values['Server'] := ParamStr(2);
    AConnection.Params.Values['Port'] := ParamStr(3);
    AConnection.Params.Values['CharacterSet'] := 'UTF8';
  end
  else if AEngine = scEnginePostgres then
  begin
    AConnection.DriverName := 'PG';
    AConnection.Params.Values['Server'] := ParamStr(2);
    AConnection.Params.Values['Port'] := ParamStr(3);
    AConnection.Params.Values['CharacterSet'] := 'UTF8';
  end
  else if AEngine = scEngineSqlServer then
  begin
    AConnection.DriverName := 'MSSQL';
    AConnection.Params.Values['Server'] := ParamStr(2) + ',' + ParamStr(3);
    AConnection.Params.Values['ODBCDriver'] := scOdbcDriver;
    // Encrypted like the .NET connection; the test server has a self-signed certificate.
    AConnection.Params.Values['Encrypt'] := 'Yes';
    AConnection.Params.Values['ODBCAdvanced'] := 'TrustServerCertificate=yes';
  end
  else
    raise EArgumentException.CreateFmt('Unknown engine "%s"', [AEngine]);
  // Snapshot semantics everywhere: Firebird concurrency, PostgreSQL repeatable read, SQL Server snapshot.
  AConnection.TxOptions.Isolation := xiSnapshot;
  AConnection.TxOptions.ReadOnly := AEngine <> scEngineSqlServer;
end;

/// <summary>Sets the client library of the engine's driver when the run names one.</summary>
procedure ConfigureVendorLib(const AEngine, AVendorLib: string;
  const AFB: TFDPhysFBDriverLink; const APG: TFDPhysPgDriverLink; const AMSSQL: TFDPhysMSSQLDriverLink);
begin
  if AVendorLib = '' then
    Exit;
  if AEngine = scEngineFirebird then
    AFB.VendorLib := AVendorLib
  else if AEngine = scEnginePostgres then
    APG.VendorLib := AVendorLib
  else if AEngine = scEngineSqlServer then
    AMSSQL.VendorLib := AVendorLib; // the ODBC driver manager, e.g. unixODBC on macOS
end;

/// <summary>Type name of the zoned field, or "skipped" when the run leaves it out.</summary>
function GetZonedTypeName(const AField: TField): string;
begin
  if Assigned(AField) then
    Result := FieldTypeNames[AField.DataType]
  else
    Result := 'skipped';
end;

/// <summary>Reads all rows once and prints throughput and checksums.</summary>
procedure RunOnce(const AConnection: TFDConnection; const AQuery: TFDQuery; const ARun: Integer);
var
  LWatch: TStopwatch;
  LRows, LIdSum, LUmlautRows, LZonedRows: Int64;
  LPriceSum, LBigSum: TBcd;
  LLastCreated: TDateTime;
  LId, LPrice, LLabel, LCreated, LBig, LZoned: TField;
begin
  LRows := 0;
  LIdSum := 0;
  LUmlautRows := 0;
  LZonedRows := 0;
  LLastCreated := 0;
  LPriceSum := IntegerToBcd(0);
  LBigSum := IntegerToBcd(0);
  AConnection.StartTransaction;
  LWatch := TStopwatch.StartNew;
  AQuery.Open;
  LId := AQuery.Fields[0];
  LPrice := AQuery.Fields[5];
  LLabel := AQuery.Fields[8];
  LCreated := AQuery.Fields[9];
  LBig := AQuery.Fields[10];
  if AQuery.FieldCount > 11 then
    LZoned := AQuery.Fields[11]
  else
    LZoned := nil;
  while not AQuery.Eof do
  begin
    Inc(LRows);
    Inc(LIdSum, LId.AsLargeInt);
    BcdAdd(LPriceSum, LPrice.AsBCD, LPriceSum);
    if LLabel.AsString.Contains(scUmlautMarker) then
      Inc(LUmlautRows);
    LLastCreated := LCreated.AsDateTime;
    BcdAdd(LBigSum, LBig.AsBCD, LBigSum);
    if Assigned(LZoned) and not LZoned.IsNull then
      Inc(LZonedRows);
    AQuery.Next;
  end;
  AQuery.Close;
  LWatch.Stop;
  AConnection.Commit;
  Writeln(Format('Run %d: %d rows in %.2f s = %.0f rows/s; idSum=%d; priceSum=%s; umlauts ok=%s; ' +
    'int128Sum=%s; zoned rows=%d; last created=%s; label field=%s; zoned field=%s',
    [ARun, LRows, LWatch.Elapsed.TotalSeconds, LRows / LWatch.Elapsed.TotalSeconds, LIdSum,
    BcdToStr(LPriceSum), BoolToStr(LUmlautRows = LRows, True), BcdToStr(LBigSum), LZonedRows,
    DateTimeToStr(LLastCreated), FieldTypeNames[LLabel.DataType], GetZonedTypeName(LZoned)]));
end;

/// <summary>Runs the measurement cRuns times on one connection.</summary>
procedure RunBenchmark;
var
  LEngine, LVendorLib: string;
  LWithZoned, LTuned: Boolean;
  LFB: TFDPhysFBDriverLink;
  LPG: TFDPhysPgDriverLink;
  LMSSQL: TFDPhysMSSQLDriverLink;
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  i: Integer;
begin
  LEngine := LowerCase(ParamStr(1));
  LWithZoned := True;
  LTuned := False;
  LVendorLib := '';
  // Optional arguments in any order: the two switches, anything else is the client library.
  for i := 7 to ParamCount do
    if SameText(ParamStr(i), scNoZonedSwitch) then
      LWithZoned := False
    else if SameText(ParamStr(i), scTunedSwitch) then
      LTuned := True
    else
      LVendorLib := ParamStr(i);
  LFB := TFDPhysFBDriverLink.Create(nil);
  LPG := TFDPhysPgDriverLink.Create(nil);
  LMSSQL := TFDPhysMSSQLDriverLink.Create(nil);
  LConnection := TFDConnection.Create(nil);
  LQuery := TFDQuery.Create(nil);
  try
    ConfigureVendorLib(LEngine, LVendorLib, LFB, LPG, LMSSQL);
    ConfigureConnection(LConnection, LEngine);
    LConnection.Connected := True;
    LQuery.Connection := LConnection;
    // Forward-only streaming in large rowsets: the access pattern of a data export.
    LQuery.FetchOptions.Unidirectional := True;
    LQuery.FetchOptions.Mode := fmOnDemand;
    LQuery.FetchOptions.RowsetSize := cRowsetSize;
    if LTuned then
    begin
      LQuery.FetchOptions.RowsetSize := cTunedRowsetSize;
      LQuery.FetchOptions.Items := LQuery.FetchOptions.Items - [fiMeta];
      LQuery.ResourceOptions.SilentMode := True;
      LQuery.UpdateOptions.ReadOnly := True;
    end;
    if LWithZoned then
      LQuery.SQL.Text := scSelectColumns + scZonedColumn + scFrom
    else
      LQuery.SQL.Text := scSelectColumns + scFrom;
    Writeln(LEngine, ': zoned column ', LWithZoned, ', tuned ', LTuned);
    for i := 1 to cRuns do
      RunOnce(LConnection, LQuery, i);
  finally
    LQuery.Free;
    LConnection.Free;
    LMSSQL.Free;
    LPG.Free;
    LFB.Free;
  end;
end;

begin
  if ParamCount < 6 then
  begin
    Writeln('Usage: DbReadBench.FireDAC fb|pg|mssql host port database user password [vendorlib] [notz] [tuned]');
    ExitCode := 2;
    Exit;
  end;
  try
    RunBenchmark;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
