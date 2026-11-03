/// <summary>
/// Utf8DecodeBench
/// Micro benchmark of UTF-8 to UTF-16 conversion paths in the Delphi RTL.
/// </summary>
///
/// <remarks>
/// Decodes the same short UTF-8 string six million times, about as many
/// string decodes as one pass of the database benchmark, through
/// System.UnicodeFromLocaleChars, System.Utf8ToUnicode, TEncoding.UTF8 and
/// the proposed fix in RtlFix.Utf8Decode. On POSIX it also measures iconv
/// with one reused converter, which is what UnicodeFromLocaleChars could do
/// with a cache. Every path is checked for the same decoded text before it
/// is timed, and the proposed fix is compared with the RTL on test vectors
/// including invalid UTF-8.
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
  System.Diagnostics,
  RtlFix.Utf8Decode in 'RtlFix.Utf8Decode.pas'
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

/// <summary>The proposed fix: decode UTF-8 directly instead of through iconv.</summary>
procedure BenchProposedFix;
var
  i, LCount: Integer;
  LWatch: TStopwatch;
begin
  LCount := UnicodeFromLocaleCharsFixed(CP_UTF8, 0, PAnsiChar(@GSource[0]), Length(GSource), @GDest[0], Length(GDest));
  Verify('UnicodeFromLocaleCharsFixed', LCount);
  LWatch := TStopwatch.StartNew;
  for i := 1 to cCalls do
    Inc(GChecksum, UnicodeFromLocaleCharsFixed(CP_UTF8, 0, PAnsiChar(@GSource[0]), Length(GSource), @GDest[0], Length(GDest)));
  LWatch.Stop;
  Report('Proposed fix (RtlFix.Utf8Decode)', LWatch);
end;

/// <summary>Compares the proposed fix with the RTL on valid and invalid UTF-8; returns the number of differences.</summary>
function CompareWithRtl: Integer;
const
  cVectors: array[0..10] of RawByteString = (
    'Gr'#$C3#$BC#$C3#$9F'e aus '#$C3#$96'sterreich',   // two-byte sequences
    #$E2#$82#$AC' '#$E6#$BC#$A2' '#$F0#$9F#$98#$80,      // three and four bytes, surrogate pair
    'A'#$80'B',                                          // lone continuation byte
    'A'#$E2#$82,                                         // truncated at the end
    #$E2#$82'A',                                         // truncated before ASCII
    #$C0#$AF,                                            // overlong form
    #$E0#$80#$80,                                        // overlong three-byte form
    #$ED#$A0#$80,                                        // encoded surrogate
    #$F4#$90#$80#$80,                                    // above U+10FFFF
    #$FF'x',                                             // invalid lead byte
    #$F0#$9F#$98);                                       // truncated four-byte sequence
var
  LVector: RawByteString;
  LFlags: Cardinal;
  LRtl, LFixed: array[0..63] of WideChar;
  LRtlCount, LFixedCount, LRtlLen, LFixedLen, j: Integer;
  LSame: Boolean;
begin
  Result := 0;
  for LVector in cVectors do
    for LFlags in [0, cErrInvalidChars] do
    begin
      LRtlLen := UnicodeFromLocaleChars(CP_UTF8, LFlags, PAnsiChar(LVector), Length(LVector), nil, 0);
      LFixedLen := UnicodeFromLocaleCharsFixed(CP_UTF8, LFlags, PAnsiChar(LVector), Length(LVector), nil, 0);
      LRtlCount := UnicodeFromLocaleChars(CP_UTF8, LFlags, PAnsiChar(LVector), Length(LVector), @LRtl[0], Length(LRtl));
      LFixedCount := UnicodeFromLocaleCharsFixed(CP_UTF8, LFlags, PAnsiChar(LVector), Length(LVector), @LFixed[0], Length(LFixed));
      LSame := (LRtlLen = LFixedLen) and (LRtlCount = LFixedCount);
      if LSame then
        for j := 0 to LRtlCount - 1 do
          if LRtl[j] <> LFixed[j] then
            LSame := False;
      if not LSame then
      begin
        Inc(Result);
        Write(Format('  differs: %d bytes, flags %d: RTL %d/%d [', [Length(LVector), LFlags, LRtlLen, LRtlCount]));
        for j := 0 to LRtlCount - 1 do
          Write(Format(' %.4x', [Ord(LRtl[j])]));
        Write(' ], fix ', LFixedLen, '/', LFixedCount, ' [');
        for j := 0 to LFixedCount - 1 do
          Write(Format(' %.4x', [Ord(LFixed[j])]));
        Writeln(' ]');
      end;
    end;
  Writeln(Format('Conformance: %d of %d cases identical to the RTL', [2 * Length(cVectors) - Result, 2 * Length(cVectors)]));
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
    BenchProposedFix;
    {$IFDEF POSIX}
    BenchCachedIconv;
    {$ENDIF}
    Writeln('Checksum: ', GChecksum);
    CompareWithRtl;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
