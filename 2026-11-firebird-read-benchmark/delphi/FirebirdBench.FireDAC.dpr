/// <summary>
/// FirebirdBench.FireDAC
/// Read-throughput benchmark of FireDAC against Firebird 5.
/// </summary>
///
/// <remarks>
/// Counterpart of dotnet/Program.cs: reads the 2 million rows created by
/// fill.sql, builds the same checksums and prints rows per second, so both
/// drivers are compared on identical data. Deliberately a single program
/// without a data module: it only measures.
/// Usage: FirebirdBench.FireDAC host port database user password [vendorlib] [notz]
/// </remarks>
///
/// <copyright>
/// Copyright © 2026 Olaf Monien
/// Licensed under MIT
/// </copyright>

program FirebirdBench.FireDAC;

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
  FireDAC.DApt,
  FireDAC.ConsoleUI.Wait,
  FireDAC.Comp.Client;

const
  cRuns = 3;
  cRowsetSize = 2000;
  scSelectColumns = 'SELECT ID, PARENT_ID, BRANCH_NO, KIND, STATUS, PRICE, OLD_PRICE, FACTOR, ' +
    'LABEL_TEXT, CREATED_AT, BIG_AMOUNT';
  // The zoned column needs ICU in the Firebird client; "notz" leaves it out.
  scZonedColumn = ', CREATED_TZ';
  scFrom = ' FROM BENCH_ROWS';
  scNoZonedSwitch = 'notz';
  scUmlautMarker = 'Österreich';

/// <summary>Configures the connection from the command-line arguments.</summary>
procedure ConfigureConnection(const AConnection: TFDConnection);
begin
  AConnection.DriverName := 'FB';
  AConnection.LoginPrompt := False;
  AConnection.Params.Values['Protocol'] := 'TCPIP';
  AConnection.Params.Values['Server'] := ParamStr(1);
  AConnection.Params.Values['Port'] := ParamStr(2);
  AConnection.Params.Values['Database'] := ParamStr(3);
  AConnection.Params.Values['User_Name'] := ParamStr(4);
  AConnection.Params.Values['Password'] := ParamStr(5);
  AConnection.Params.Values['CharacterSet'] := 'UTF8';
  // Snapshot read-only transaction, the same isolation the .NET program uses.
  AConnection.TxOptions.Isolation := xiSnapshot;
  AConnection.TxOptions.ReadOnly := True;
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
    'int128Sum=%s; zoned rows=%d; last created=%s; zoned field=%s',
    [ARun, LRows, LWatch.Elapsed.TotalSeconds, LRows / LWatch.Elapsed.TotalSeconds, LIdSum,
    BcdToStr(LPriceSum), BoolToStr(LUmlautRows = LRows, True), BcdToStr(LBigSum), LZonedRows,
    DateTimeToStr(LLastCreated), GetZonedTypeName(LZoned)]));
end;

/// <summary>Runs the measurement cRuns times on one connection.</summary>
procedure RunBenchmark;
var
  LDriverLink: TFDPhysFBDriverLink;
  LConnection: TFDConnection;
  LQuery: TFDQuery;
  i: Integer;
begin
  LDriverLink := TFDPhysFBDriverLink.Create(nil);
  LConnection := TFDConnection.Create(nil);
  LQuery := TFDQuery.Create(nil);
  try
    if (ParamCount >= 6) and (ParamStr(6) <> '') and not SameText(ParamStr(6), scNoZonedSwitch) then
      LDriverLink.VendorLib := ParamStr(6);
    ConfigureConnection(LConnection);
    LConnection.Connected := True;
    LQuery.Connection := LConnection;
    // Forward-only streaming in large rowsets: the access pattern of a data export.
    LQuery.FetchOptions.Unidirectional := True;
    LQuery.FetchOptions.Mode := fmOnDemand;
    LQuery.FetchOptions.RowsetSize := cRowsetSize;
    if SameText(ParamStr(ParamCount), scNoZonedSwitch) then
      LQuery.SQL.Text := scSelectColumns + scFrom
    else
      LQuery.SQL.Text := scSelectColumns + scZonedColumn + scFrom;
    Writeln('Zoned column: ', not SameText(ParamStr(ParamCount), scNoZonedSwitch));
    for i := 1 to cRuns do
      RunOnce(LConnection, LQuery, i);
  finally
    LQuery.Free;
    LConnection.Free;
    LDriverLink.Free;
  end;
end;

begin
  if ParamCount < 5 then
  begin
    Writeln('Usage: FirebirdBench.FireDAC host port database user password [vendorlib] [notz]');
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
