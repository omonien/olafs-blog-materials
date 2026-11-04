/// <summary>
/// DbCompareBench.FireDAC
/// Inserts and pgbench workloads against Firebird and PostgreSQL through FireDAC.
/// </summary>
///
/// <remarks>
/// Counterpart of dotnet/Program.cs for the tests that matter most to Delphi applications: one row
/// per transaction ("insert") and the three built-in pgbench scripts ("oltp"). Same tables, same SQL,
/// same transaction modes and the same RESULT lines, so tools/summarize.py reads both programs; every
/// line carries driver=firedac. Each client is a thread with its own connection. Deliberately one
/// program without a data module: it only measures.
/// Usage: DbCompareBench.FireDAC probe|insert|oltp fb|pg host port database user password [key=value ...]
/// Options: clients= seconds= warmup= script=tpcb|simple|select scale= cursor=automatic|default vendorlib= trace=
/// cursor=default sets FetchOptions.CursorKind := ckDefault on the SELECT: with PostgreSQL FireDAC then sends
/// the query itself instead of DECLARE CURSOR, FETCH and CLOSE (and, outside a transaction, BEGIN and COMMIT).
/// trace=<file> writes FireDAC's monitor log (statements, transactions, client library calls) for a
/// short diagnostic run; measured runs go without it.
/// The pgbench tables come from "oltp-setup" of the .NET program.
/// </remarks>
///
/// <copyright>
/// Copyright © 2026 Olaf Monien
/// Licensed under MIT
/// </copyright>

program DbCompareBench.FireDAC;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Variants,
  System.Diagnostics,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  Data.DB,
  Data.FmtBcd,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Error,
  FireDAC.Stan.Param,
  FireDAC.Phys.Intf,
  FireDAC.Phys,
  FireDAC.Phys.FB,
  FireDAC.Phys.FBDef,
  FireDAC.Phys.PG,
  FireDAC.Phys.PGDef,
  FireDAC.DApt,
  FireDAC.Moni.Base,
  FireDAC.Moni.FlatFile,
  FireDAC.ConsoleUI.Wait,
  FireDAC.Comp.Client;

const
  cMaxAttempts = 10;
  scEngineFirebird = 'fb';
  scEnginePostgres = 'pg';
  scInsertRow = 'INSERT INTO INS_ROWS (CLIENT_NO, CREATED_AT, AMOUNT, LABEL_TEXT) VALUES (:C, :T, :A, :L)';
  scUpdateAccount = 'UPDATE pgbench_accounts SET abalance = abalance + :DELTA WHERE aid = :AID';
  scSelectAccount = 'SELECT abalance FROM pgbench_accounts WHERE aid = :AID';
  scUpdateTeller = 'UPDATE pgbench_tellers SET tbalance = tbalance + :DELTA WHERE tid = :TID';
  scUpdateBranch = 'UPDATE pgbench_branches SET bbalance = bbalance + :DELTA WHERE bid = :BID';
  scInsertHistory = 'INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) ' +
    'VALUES (:TID, :BID, :AID, :DELTA, LOCALTIMESTAMP)';

type
  {$SCOPEDENUMS ON}
  /// <summary>What one transaction of a client does.</summary>
  TWorkKind = (Insert, Tpcb, Simple, Select);
  {$SCOPEDENUMS OFF}

  /// <summary>Command line: connection data and the key=value options.</summary>
  TSettings = class
  private
    FOptions: TDictionary<string, string>;
  public
    Test, Engine, Server, Port, Database, UserName, Password: string;
    constructor Create;
    destructor Destroy; override;
    function GetOption(const AKey, ADefault: string): string;
    function GetOptionInt(const AKey: string; const ADefault: Integer): Integer;
    function IsFirebird: Boolean;
  end;

  /// <summary>
  /// One client: owns its connection and prepared commands, waits for the common start and runs
  /// transactions until the end of the measured window. Latencies are kept per transaction.
  /// </summary>
  TClientThread = class(TThread)
  private
    FSettings: TSettings;
    FKind: TWorkKind;
    FClientNo: Integer;
    FReady: TCountdownEvent;
    FGo: TEvent;
    FConnection: TFDConnection;
    FCommands: TObjectList<TFDQuery>;
    FRandomState: UInt64;
    FCounter: Int64;
    FChecksum: Int64;
    FScale: Integer;
    procedure Connect;
    function AddCommand(const ASql: string; const ATypes: array of TFieldType;
      const APlainCursor: Boolean = False): TFDQuery;
    function NextRandom(const ALow, AHigh: Integer): Integer;
    procedure RunTransaction;
    procedure Rollback;
  protected
    procedure Execute; override;
  public
    Latencies: TList<Integer>;
    Total, Retries, Failed: Int64;
    Error: string;
    constructor Create(const ASettings: TSettings; const AKind: TWorkKind; const AClientNo: Integer;
      const AReady: TCountdownEvent; const AGo: TEvent);
    destructor Destroy; override;
  end;

var
  // Set by the main thread before the start signal; read-only for the clients afterwards.
  GMeasureFrom, GEnd: Int64;

{ TSettings }

constructor TSettings.Create;
begin
  inherited Create;
  FOptions := TDictionary<string, string>.Create;
end;

destructor TSettings.Destroy;
begin
  FOptions.Free;
  inherited Destroy;
end;

function TSettings.GetOption(const AKey, ADefault: string): string;
begin
  if not FOptions.TryGetValue(AKey, Result) then
    Result := ADefault;
end;

function TSettings.GetOptionInt(const AKey: string; const ADefault: Integer): Integer;
begin
  Result := StrToIntDef(GetOption(AKey, ''), ADefault);
end;

function TSettings.IsFirebird: Boolean;
begin
  Result := Engine = scEngineFirebird;
end;

/// <summary>Reads the command line into a settings object.</summary>
function ParseSettings: TSettings;
var
  i, LPos: Integer;
begin
  Result := TSettings.Create;
  Result.Test := LowerCase(ParamStr(1));
  Result.Engine := LowerCase(ParamStr(2));
  Result.Server := ParamStr(3);
  Result.Port := ParamStr(4);
  Result.Database := ParamStr(5);
  Result.UserName := ParamStr(6);
  Result.Password := ParamStr(7);
  for i := 8 to ParamCount do
  begin
    LPos := Pos('=', ParamStr(i));
    if LPos > 0 then
      Result.FOptions.AddOrSetValue(Copy(ParamStr(i), 1, LPos - 1), Copy(ParamStr(i), LPos + 1, MaxInt));
  end;
end;

/// <summary>
/// A connection with FireDAC's default options, except SilentMode (worker threads must not touch the
/// console wait cursor) and LockWait. Read committed as in the .NET program; for Firebird 4+ with
/// ReadConsistency = 1 (the default) a conflicting update waits and restarts instead of failing.
/// </summary>
/// <remarks>
/// FireDAC starts Firebird transactions with NOWAIT unless UpdateOptions.LockWait is True or
/// TxOptions.Params names "wait" (TFDPhysIBTransactionBase.InternalChanged). A NOWAIT transaction fails at
/// once on a row another transaction holds; the .NET client waits, so LockWait makes both behave alike.
/// PostgreSQL always waits for row locks.
/// </remarks>
function CreateConnection(const ASettings: TSettings): TFDConnection;
begin
  Result := TFDConnection.Create(nil);
  try
    Result.LoginPrompt := False;
    Result.ResourceOptions.SilentMode := True;
    Result.Params.Values['Database'] := ASettings.Database;
    Result.Params.Values['User_Name'] := ASettings.UserName;
    Result.Params.Values['Password'] := ASettings.Password;
    Result.Params.Values['Server'] := ASettings.Server;
    Result.Params.Values['Port'] := ASettings.Port;
    Result.Params.Values['CharacterSet'] := 'UTF8';
    if ASettings.IsFirebird then
    begin
      Result.DriverName := 'FB';
      Result.Params.Values['Protocol'] := 'TCPIP';
    end
    else if ASettings.Engine = scEnginePostgres then
      Result.DriverName := 'PG'
    else
      raise EArgumentException.CreateFmt('Unknown engine "%s"', [ASettings.Engine]);
    Result.TxOptions.Isolation := xiReadCommitted;
    Result.UpdateOptions.LockWait := True;
    if ASettings.GetOption('trace', '') <> '' then
      Result.Params.Values['MonitorBy'] := 'FlatFile';
  except
    Result.Free;
    raise;
  end;
end;

/// <summary>Runs one statement outside an explicit transaction and returns the first column as text.</summary>
function QueryValue(const AConnection: TFDConnection; const ASql: string): string;
begin
  Result := VarToStr(AConnection.ExecSQLScalar(ASql));
end;

{ TClientThread }

constructor TClientThread.Create(const ASettings: TSettings; const AKind: TWorkKind; const AClientNo: Integer;
  const AReady: TCountdownEvent; const AGo: TEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSettings := ASettings;
  FKind := AKind;
  FClientNo := AClientNo;
  FReady := AReady;
  FGo := AGo;
  FScale := ASettings.GetOptionInt('scale', 10);
  FRandomState := UInt64(4711 + AClientNo) * UInt64(6364136223846793005) + UInt64(1442695040888963407);
  FCommands := TObjectList<TFDQuery>.Create(True);
  Latencies := TList<Integer>.Create;
  Latencies.Capacity := 1 shl 16;
end;

destructor TClientThread.Destroy;
begin
  FCommands.Free;
  FConnection.Free;
  Latencies.Free;
  inherited Destroy;
end;

/// <summary>xorshift64*: the RTL's Random is shared between threads.</summary>
function TClientThread.NextRandom(const ALow, AHigh: Integer): Integer;
begin
  FRandomState := FRandomState xor (FRandomState shr 12);
  FRandomState := FRandomState xor (FRandomState shl 25);
  FRandomState := FRandomState xor (FRandomState shr 27);
  Result := ALow + Integer((FRandomState * UInt64(2685821657736338717)) shr 33 mod UInt64(AHigh - ALow + 1));
end;

/// <summary>
/// A prepared command whose parameter types are set before Prepare, so values never retype them.
/// APlainCursor: ckDefault instead of FireDAC's automatic cursor choice (only for the SELECT).
/// </summary>
function TClientThread.AddCommand(const ASql: string; const ATypes: array of TFieldType;
  const APlainCursor: Boolean): TFDQuery;
var
  i: Integer;
begin
  Result := TFDQuery.Create(nil);
  FCommands.Add(Result);
  Result.Connection := FConnection;
  Result.SQL.Text := ASql;
  if APlainCursor then
    Result.FetchOptions.CursorKind := ckDefault;
  for i := 0 to High(ATypes) do
  begin
    Result.Params[i].DataType := ATypes[i];
    if ATypes[i] = ftFMTBcd then
    begin
      Result.Params[i].Precision := 18;
      Result.Params[i].NumericScale := 2;
    end
    else if ATypes[i] = ftWideString then
      Result.Params[i].Size := 100;
  end;
  Result.Prepare;
end;

procedure TClientThread.Connect;
begin
  FConnection := CreateConnection(FSettings);
  FConnection.Connected := True;
  // Firebird prepares a statement within a transaction. Outside an explicit one FireDAC starts that transaction
  // itself and leaves it open (seen in the trace: no commit until the end); every StartTransaction after it is
  // then only a savepoint inside it and Commit releases the savepoint, so nothing would be committed before the
  // end of the run. Preparing inside an explicit transaction that is committed at once avoids that.
  FConnection.StartTransaction;
  case FKind of
    TWorkKind.Insert:
      AddCommand(scInsertRow, [ftInteger, ftDateTime, ftFMTBcd, ftWideString]);
  else
    AddCommand(scUpdateAccount, [ftInteger, ftInteger]);
    AddCommand(scSelectAccount, [ftInteger], FSettings.GetOption('cursor', 'automatic') = 'default');
    AddCommand(scUpdateTeller, [ftInteger, ftInteger]);
    AddCommand(scUpdateBranch, [ftInteger, ftInteger]);
    AddCommand(scInsertHistory, [ftInteger, ftInteger, ftInteger, ftInteger]);
  end;
  FConnection.Commit;
  if FConnection.InTransaction then
    raise EInvalidOpException.Create('a transaction is still open after preparing');
  // select-only: PostgreSQL runs each SELECT on its own (auto commit), Firebird keeps one read-only
  // read committed transaction open, as in the .NET program.
  if (FKind = TWorkKind.Select) and FSettings.IsFirebird then
  begin
    FConnection.TxOptions.ReadOnly := True;
    FConnection.StartTransaction;
  end;
end;

procedure TClientThread.RunTransaction;
var
  LAid, LBid, LTid, LDelta: Integer;
  LSelect: TFDQuery;
begin
  if FKind = TWorkKind.Insert then
  begin
    Inc(FCounter);
    FConnection.StartTransaction;
    FCommands[0].Params[0].AsInteger := FClientNo;
    FCommands[0].Params[1].AsDateTime := EncodeDate(2026, 1, 1) + FCounter / SecsPerDay;
    FCommands[0].Params[2].AsFMTBCD := DoubleToBcd(1.5 + (FCounter mod 400) / 100);
    FCommands[0].Params[3].AsWideString := Format('Grüße aus Österreich, Zeile %d', [FCounter]);
    FCommands[0].ExecSQL;
    FConnection.Commit;
    Exit;
  end;
  LAid := NextRandom(1, 100000 * FScale);
  LSelect := FCommands[1];
  if FKind = TWorkKind.Select then
  begin
    LSelect.Params[0].AsInteger := LAid;
    LSelect.Open;
    Inc(FChecksum, LSelect.Fields[0].AsInteger);
    LSelect.Close;
    Exit;
  end;
  LBid := NextRandom(1, FScale);
  LTid := NextRandom(1, 10 * FScale);
  LDelta := NextRandom(-5000, 5000);
  FConnection.StartTransaction;
  FCommands[0].Params[0].AsInteger := LDelta;
  FCommands[0].Params[1].AsInteger := LAid;
  FCommands[0].ExecSQL;
  LSelect.Params[0].AsInteger := LAid;
  LSelect.Open;
  Inc(FChecksum, LSelect.Fields[0].AsInteger);
  LSelect.Close;
  if FKind = TWorkKind.Tpcb then
  begin
    FCommands[2].Params[0].AsInteger := LDelta;
    FCommands[2].Params[1].AsInteger := LTid;
    FCommands[2].ExecSQL;
    FCommands[3].Params[0].AsInteger := LDelta;
    FCommands[3].Params[1].AsInteger := LBid;
    FCommands[3].ExecSQL;
  end;
  FCommands[4].Params[0].AsInteger := LTid;
  FCommands[4].Params[1].AsInteger := LBid;
  FCommands[4].Params[2].AsInteger := LAid;
  FCommands[4].Params[3].AsInteger := LDelta;
  FCommands[4].ExecSQL;
  FConnection.Commit;
end;

procedure TClientThread.Rollback;
begin
  try
    if FConnection.InTransaction then
      FConnection.Rollback;
  except
    on EFDDBEngineException do ;
  end;
end;

procedure TClientThread.Execute;
var
  LStart, LStop: Int64;
  LAttempt: Integer;
  LDone: Boolean;
begin
  try
    Connect;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
  FReady.Signal;
  FGo.WaitFor(INFINITE);
  if Error <> '' then
    Exit;
  try
    while True do
    begin
      LStart := TStopwatch.GetTimeStamp;
      if LStart >= GEnd then
        Break;
      LDone := False;
      for LAttempt := 1 to cMaxAttempts do
      begin
        try
          RunTransaction;
          LDone := True;
          Break;
        except
          // Lock conflicts and deadlocks are retried, as pgbench does with --max-tries.
          on E: EFDDBEngineException do
          begin
            if E.Kind <> ekRecordLocked then
              raise;
            Rollback;
            if LAttempt < cMaxAttempts then
              Inc(Retries);
          end;
        end;
      end;
      if not LDone then
        Inc(Failed);
      LStop := TStopwatch.GetTimeStamp;
      Inc(Total);
      if LDone and (LStart >= GMeasureFrom) and (LStop <= GEnd) then
        Latencies.Add(Integer((LStop - LStart) * 1000000 div TStopwatch.Frequency));
    end;
    if FConnection.InTransaction then
      FConnection.Commit;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

/// <summary>Value at quantile AQ of sorted microsecond latencies, in milliseconds.</summary>
function GetPercentile(const ASorted: TArray<Integer>; const AQ: Double): Double;
var
  LIndex: Integer;
begin
  if Length(ASorted) = 0 then
    Exit(0);
  LIndex := Trunc(AQ * Length(ASorted));
  if LIndex > High(ASorted) then
    LIndex := High(ASorted);
  Result := ASorted[LIndex] / 1000;
end;

/// <summary>Starts the clients together and prints one RESULT line for the measured window.</summary>
procedure RunClients(const ASettings: TSettings; const AKind: TWorkKind; const AFields: string);
var
  LClients, LWarmup, LSeconds, i: Integer;
  LReady: TCountdownEvent;
  LGo: TEvent;
  LThreads: TObjectList<TClientThread>;
  LAll: TList<Integer>;
  LSorted: TArray<Integer>;
  LTotal, LRetries, LFailed, LSum: Int64;
  LFormat: TFormatSettings;
begin
  LClients := ASettings.GetOptionInt('clients', 1);
  LWarmup := ASettings.GetOptionInt('warmup', 5);
  LSeconds := ASettings.GetOptionInt('seconds', 30);
  LFormat := TFormatSettings.Invariant;
  LReady := TCountdownEvent.Create(LClients);
  LGo := TEvent.Create(nil, True, False, '');
  LThreads := TObjectList<TClientThread>.Create(True);
  LAll := TList<Integer>.Create;
  try
    for i := 0 to LClients - 1 do
      LThreads.Add(TClientThread.Create(ASettings, AKind, i, LReady, LGo));
    for i := 0 to LClients - 1 do
      LThreads[i].Start;
    LReady.WaitFor(INFINITE);
    GMeasureFrom := TStopwatch.GetTimeStamp + Int64(LWarmup) * TStopwatch.Frequency;
    GEnd := GMeasureFrom + Int64(LSeconds) * TStopwatch.Frequency;
    LGo.SetEvent;
    LTotal := 0;
    LRetries := 0;
    LFailed := 0;
    for i := 0 to LClients - 1 do
    begin
      LThreads[i].WaitFor;
      if LThreads[i].Error <> '' then
        raise Exception.CreateFmt('client %d failed: %s', [i, LThreads[i].Error]);
      LAll.AddRange(LThreads[i].Latencies);
      Inc(LTotal, LThreads[i].Total);
      Inc(LRetries, LThreads[i].Retries);
      Inc(LFailed, LThreads[i].Failed);
    end;
    LSorted := LAll.ToArray;
    TArray.Sort<Integer>(LSorted);
    LSum := 0;
    for i := 0 to High(LSorted) do
      Inc(LSum, LSorted[i]);
    Writeln(Format('RESULT test=%s engine=%s driver=firedac %s clients=%d seconds=%d txns=%d tps=%.1f ' +
      'lat_avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f retries=%d failed=%d total_txns=%d run_s=%d',
      [ASettings.Test, ASettings.Engine, AFields, LClients, LSeconds, Length(LSorted), Length(LSorted) / LSeconds,
      LSum / Max(Length(LSorted), 1) / 1000, GetPercentile(LSorted, 0.5), GetPercentile(LSorted, 0.95),
      GetPercentile(LSorted, 0.99), GetPercentile(LSorted, 1), LRetries, LFailed, LTotal, LWarmup + LSeconds], LFormat));
  finally
    LAll.Free;
    LThreads.Free;
    LGo.Free;
    LReady.Free;
  end;
end;

/// <summary>Prints the client library, the wire encryption and the transaction mode FireDAC really uses.</summary>
procedure RunProbe(const ASettings: TSettings);
var
  LConnection: TFDConnection;
  LQuery: TFDQuery;
begin
  LConnection := CreateConnection(ASettings);
  try
    LConnection.Connected := True;
    Writeln('client: ', LConnection.ConnectionMetaDataIntf.ClientVersion, ', server: ',
      LConnection.ConnectionMetaDataIntf.ServerVersion);
    if ASettings.IsFirebird then
    begin
      Writeln('wire_encrypted=', QueryValue(LConnection,
        'SELECT RDB$GET_CONTEXT(''SYSTEM'', ''WIRE_ENCRYPTED'') FROM RDB$DATABASE'));
      LConnection.StartTransaction;
      Writeln('write_tx_isolation_mode(4=read consistency)=', QueryValue(LConnection,
        'SELECT MON$ISOLATION_MODE FROM MON$TRANSACTIONS WHERE MON$TRANSACTION_ID = CURRENT_TRANSACTION'));
      Writeln('write_tx_lock_timeout(-1=wait)=', QueryValue(LConnection,
        'SELECT MON$LOCK_TIMEOUT FROM MON$TRANSACTIONS WHERE MON$TRANSACTION_ID = CURRENT_TRANSACTION'));
      LConnection.Commit;
    end;
    // What an explicit Prepare outside a transaction leaves behind (see TClientThread.Connect).
    LQuery := TFDQuery.Create(nil);
    try
      LQuery.Connection := LConnection;
      LQuery.SQL.Text := scSelectAccount;
      LQuery.Params[0].DataType := ftInteger;
      LQuery.Prepare;
      Writeln('in_transaction_after_prepare=', BoolToStr(LConnection.InTransaction, True));
      if LConnection.InTransaction then
        LConnection.Commit;
    finally
      LQuery.Free;
    end;
    if not ASettings.IsFirebird then
    begin
      Writeln('connection_ssl=', QueryValue(LConnection, 'SELECT CAST(ssl AS text) FROM pg_stat_ssl WHERE pid = pg_backend_pid()'));
      Writeln('synchronous_commit=', QueryValue(LConnection, 'SHOW synchronous_commit'));
    end;
  finally
    LConnection.Free;
  end;
end;

/// <summary>Drops and creates INS_ROWS like the .NET program, so both start from an empty table.</summary>
procedure RecreateInsertTable(const ASettings: TSettings);
var
  LConnection: TFDConnection;
begin
  LConnection := CreateConnection(ASettings);
  try
    LConnection.Connected := True;
    if ASettings.IsFirebird then
      LConnection.ExecSQL('RECREATE TABLE INS_ROWS (ID BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, ' +
        'CLIENT_NO INTEGER NOT NULL, CREATED_AT TIMESTAMP NOT NULL, AMOUNT NUMERIC(18,2) NOT NULL, ' +
        'LABEL_TEXT VARCHAR(100) CHARACTER SET UTF8 NOT NULL)')
    else
    begin
      LConnection.ExecSQL('DROP TABLE IF EXISTS ins_rows');
      LConnection.ExecSQL('CREATE TABLE ins_rows (id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, ' +
        'client_no integer NOT NULL, created_at timestamp NOT NULL, amount numeric(18,2) NOT NULL, ' +
        'label_text varchar(100) NOT NULL)');
    end;
  finally
    LConnection.Free;
  end;
end;

procedure RunBenchmark;
var
  LSettings: TSettings;
  LFB: TFDPhysFBDriverLink;
  LPG: TFDPhysPgDriverLink;
  LTrace: TFDMoniFlatFileClientLink;
  LScript: string;
  LKind: TWorkKind;
begin
  LSettings := ParseSettings;
  LFB := TFDPhysFBDriverLink.Create(nil);
  LPG := TFDPhysPgDriverLink.Create(nil);
  LTrace := nil;
  try
    if LSettings.GetOption('trace', '') <> '' then
    begin
      LTrace := TFDMoniFlatFileClientLink.Create(nil);
      LTrace.FileName := LSettings.GetOption('trace', '');
      LTrace.FileAppend := False;
      LTrace.EventKinds := [ekError, ekConnTransact, ekCmdPrepare, ekCmdExecute, ekVendor];
      LTrace.Tracing := True;
    end;
    if LSettings.IsFirebird then
      LFB.VendorLib := LSettings.GetOption('vendorlib', '')
    else
      LPG.VendorLib := LSettings.GetOption('vendorlib', '');
    // FireDAC wants its manager active before threads open connections ("Multithreading (FireDAC)").
    FDManager.Active := True;
    if LSettings.Test = 'probe' then
      RunProbe(LSettings)
    else if LSettings.Test = 'insert' then
    begin
      RecreateInsertTable(LSettings);
      RunClients(LSettings, TWorkKind.Insert, 'durability=default');
    end
    else if LSettings.Test = 'oltp' then
    begin
      LScript := LSettings.GetOption('script', 'tpcb');
      if LScript = 'select' then
        LKind := TWorkKind.Select
      else if LScript = 'simple' then
        LKind := TWorkKind.Simple
      else
        LKind := TWorkKind.Tpcb;
      RunClients(LSettings, LKind, Format('script=%s scale=%d cursor=%s',
        [LScript, LSettings.GetOptionInt('scale', 10), LSettings.GetOption('cursor', 'automatic')]));
    end
    else
      raise EArgumentException.CreateFmt('Unknown test "%s"', [LSettings.Test]);
  finally
    // All connections are closed here; the monitor link goes last, the manager refers to it until it is closed.
    FDManager.Close;
    LTrace.Free;
    LPG.Free;
    LFB.Free;
    LSettings.Free;
  end;
end;

begin
  if ParamCount < 7 then
  begin
    Writeln('Usage: DbCompareBench.FireDAC probe|insert|oltp fb|pg host port database user password [key=value ...]');
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
