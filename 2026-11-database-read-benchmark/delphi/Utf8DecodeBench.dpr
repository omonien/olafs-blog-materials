/// <summary>
/// Utf8DecodeBench
/// Micro benchmark of UTF-8 to UTF-16 conversion paths in the Delphi RTL.
/// </summary>
///
/// <remarks>
/// Decodes the same short UTF-8 string six million times, about as many
/// string decodes as one pass of the database benchmark, through
/// System.UnicodeFromLocaleChars, System.Utf8ToUnicode and TEncoding.UTF8.
/// On POSIX it also measures iconv with one reused converter, which is what
/// UnicodeFromLocaleChars could do with a cache. Every path is checked for
/// the same decoded text before it is timed.
/// </remarks>
///
/// <copyright>
/// Copyright © 2026 Olaf Monien
/// Licensed under MIT
/// </copyright>

program Utf8DecodeBench;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics
  {$IFDEF POSIX}
  , Posix.Base
  , Posix.SysTypes
  , Posix.Iconv
  {$ENDIF}
  ;

const
  cCalls = 6000000;
  scSample = 'Grüße aus Österreich, Zeile 1234567';

var
  GSource: TBytes;
  GDest: array[0..255] of WideChar;
  GChecksum: Int64;

/// <summary>Prints the cost of one path per call.</summary>
procedure Report(const AName: string; const AWatch: TStopwatch);
begin
  Writeln(Format('%-36s %8.1f ns/call   %6.2f s for %d calls',
    [AName, AWatch.Elapsed.TotalMilliseconds * 1000000 / cCalls, AWatch.Elapsed.TotalSeconds, cCalls]));
end;

/// <summary>Stops with an error unless the decoded text equals the sample.</summary>
procedure Verify(const AName: string; const ACount: Integer);
begin
  if (ACount <> Length(scSample)) or (StrLComp(PWideChar(@GDest[0]), PWideChar(scSample), ACount) <> 0) then
    raise Exception.CreateFmt('%s decoded %d chars, expected "%s"', [AName, ACount, scSample]);
end;

/// <summary>The RTL entry point FireDAC uses for every string column.</summary>
procedure BenchUnicodeFromLocaleChars;
var
  i, LCount: Integer;
  LWatch: TStopwatch;
begin
  LCount := UnicodeFromLocaleChars(CP_UTF8, 0, PAnsiChar(@GSource[0]), Length(GSource), @GDest[0], Length(GDest));
  Verify('UnicodeFromLocaleChars', LCount);
  LWatch := TStopwatch.StartNew;
  for i := 1 to cCalls do
    Inc(GChecksum, UnicodeFromLocaleChars(CP_UTF8, 0, PAnsiChar(@GSource[0]), Length(GSource), @GDest[0], Length(GDest)));
  LWatch.Stop;
  Report('UnicodeFromLocaleChars(CP_UTF8)', LWatch);
end;

/// <summary>The RTL's own UTF-8 decoder; it counts the terminating null.</summary>
procedure BenchUtf8ToUnicode;
var
  i, LCount: Integer;
  LWatch: TStopwatch;
begin
  LCount := Integer(Utf8ToUnicode(@GDest[0], Length(GDest), PAnsiChar(@GSource[0]), Length(GSource))) - 1;
  Verify('Utf8ToUnicode', LCount);
  LWatch := TStopwatch.StartNew;
  for i := 1 to cCalls do
    Inc(GChecksum, Utf8ToUnicode(@GDest[0], Length(GDest), PAnsiChar(@GSource[0]), Length(GSource)));
  LWatch.Stop;
  Report('Utf8ToUnicode', LWatch);
end;

/// <summary>What application code typically calls; includes the string allocation.</summary>
procedure BenchTEncoding;
var
  i: Integer;
  LText: string;
  LWatch: TStopwatch;
begin
  LText := TEncoding.UTF8.GetString(GSource);
  if LText <> scSample then
    raise Exception.Create('TEncoding.UTF8 decoded a different text');
  LWatch := TStopwatch.StartNew;
  for i := 1 to cCalls do
    Inc(GChecksum, Length(TEncoding.UTF8.GetString(GSource)));
  LWatch.Stop;
  Report('TEncoding.UTF8.GetString', LWatch);
end;

{$IFDEF POSIX}
/// <summary>One converter opened once and reset per call: the cost UnicodeFromLocaleChars could have.</summary>
procedure BenchCachedIconv;
var
  i: Integer;
  LConverter: iconv_t;
  LIn, LOut: Pointer;
  LInLeft, LOutLeft: size_t;
  LWatch: TStopwatch;

  function DecodeOnce: Integer;
  begin
    iconv(LConverter, nil, nil, nil, nil);
    LIn := @GSource[0];
    LInLeft := Length(GSource);
    LOut := @GDest[0];
    LOutLeft := SizeOf(GDest);
    iconv(LConverter, @LIn, @LInLeft, @LOut, @LOutLeft);
    Result := Integer((SizeOf(GDest) - LOutLeft) div SizeOf(WideChar));
  end;

begin
  LConverter := iconv_open('UTF-16LE', 'UTF-8');
  if LConverter = iconv_t(-1) then
    raise Exception.Create('iconv_open failed');
  try
    Verify('iconv cached', DecodeOnce);
    LWatch := TStopwatch.StartNew;
    for i := 1 to cCalls do
      Inc(GChecksum, DecodeOnce);
    LWatch.Stop;
    Report('iconv, one reused converter', LWatch);
  finally
    iconv_close(LConverter);
  end;
end;
{$ENDIF}

begin
  try
    GSource := TEncoding.UTF8.GetBytes(scSample);
    GChecksum := 0;
    Writeln(Format('Sample: %d UTF-8 bytes, %d chars', [Length(GSource), Length(scSample)]));
    BenchUnicodeFromLocaleChars;
    BenchUtf8ToUnicode;
    BenchTEncoding;
    {$IFDEF POSIX}
    BenchCachedIconv;
    {$ENDIF}
    Writeln('Checksum: ', GChecksum);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
