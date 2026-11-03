/// <summary>
/// RtlFix.Utf8Decode
/// Proposed UTF-8 fast path for System.UnicodeFromLocaleChars on POSIX.
/// </summary>
///
/// <remarks>
/// On macOS the Delphi 13 RTL converts every call of UnicodeFromLocaleChars
/// through a freshly opened and closed iconv converter, also for UTF-8. This
/// unit shows the proposed fix: decode UTF-8 directly, with the contract of
/// UnicodeFromLocaleChars (MultiByteToWideChar on Windows): a destination
/// length of 0 only counts, a source length of -1 means null-terminated and
/// counts the terminator, a too small destination returns 0, and invalid
/// sequences become U+FFFD, one per maximal subpart as the Unicode standard
/// recommends, or make the call return 0 when MB_ERR_INVALID_CHARS is set.
/// Other code pages keep using the RTL; there a per-thread cached iconv
/// converter would be the matching fix.
/// </remarks>
///
/// <copyright>
/// Copyright © 2026 Olaf Monien
/// Licensed under MIT
/// </copyright>

unit RtlFix.Utf8Decode;

interface

const
  /// <summary>Same value as MB_ERR_INVALID_CHARS in Windows and in the RTL.</summary>
  cErrInvalidChars = $00000008;

/// <summary>Decodes UTF-8 to UTF-16 with the contract of UnicodeFromLocaleChars(CP_UTF8, ...).</summary>
function Utf8ToUtf16(AFlags: Cardinal; ASource: PAnsiChar; ASourceLen: Integer;
  ADest: PWideChar; ADestLen: Integer): Integer;

/// <summary>UnicodeFromLocaleChars with the UTF-8 fast path; other code pages go to the RTL.</summary>
function UnicodeFromLocaleCharsFixed(ACodePage, AFlags: Cardinal; ASource: PAnsiChar;
  ASourceLen: Integer; ADest: PWideChar; ADestLen: Integer): Integer;

implementation

const
  cReplacementChar = WideChar($FFFD);

function Utf8ToUtf16(AFlags: Cardinal; ASource: PAnsiChar; ASourceLen: Integer;
  ADest: PWideChar; ADestLen: Integer): Integer;
var
  LSource, LSourceEnd: PByte;
  LCount, LNeed, i: Integer;
  LLow, LHigh, LLead: Byte;
  LCode: Cardinal;
  LValid: Boolean;

  // Writes one UTF-16 code unit, or only counts it when no destination is given.
  function Put(const AChar: WideChar): Boolean;
  begin
    if ADestLen > 0 then
    begin
      if LCount >= ADestLen then
        Exit(False);
      ADest[LCount] := AChar;
    end;
    Inc(LCount);
    Result := True;
  end;

begin
  Result := 0;
  if ASource = nil then
    Exit;
  if ASourceLen = -1 then
  begin
    ASourceLen := 0;
    while ASource[ASourceLen] <> #0 do
      Inc(ASourceLen);
    Inc(ASourceLen); // the terminator is converted and counted, as on Windows
  end;
  LSource := PByte(ASource);
  LSourceEnd := LSource + ASourceLen;
  LCount := 0;
  while LSource < LSourceEnd do
  begin
    LLead := LSource^;
    Inc(LSource);
    if LLead < $80 then
    begin
      if not Put(WideChar(LLead)) then
        Exit(0);
      Continue;
    end;
    // The allowed range of the second byte rules out overlong forms, surrogates and code points above U+10FFFF.
    LLow := $80;
    LHigh := $BF;
    case LLead of
      $C2..$DF:
        begin
          LNeed := 1;
          LCode := LLead and $1F;
        end;
      $E0:
        begin
          LNeed := 2;
          LLow := $A0;
          LCode := LLead and $0F;
        end;
      $E1..$EC, $EE..$EF:
        begin
          LNeed := 2;
          LCode := LLead and $0F;
        end;
      $ED:
        begin
          LNeed := 2;
          LHigh := $9F;
          LCode := LLead and $0F;
        end;
      $F0:
        begin
          LNeed := 3;
          LLow := $90;
          LCode := LLead and $07;
        end;
      $F1..$F3:
        begin
          LNeed := 3;
          LCode := LLead and $07;
        end;
      $F4:
        begin
          LNeed := 3;
          LHigh := $8F;
          LCode := LLead and $07;
        end;
    else
      LNeed := 0;
      LCode := 0;
    end;
    LValid := LNeed > 0;
    for i := 1 to LNeed do
    begin
      // A byte outside the range ends the maximal subpart; it is not consumed and starts the next sequence.
      if (LSource >= LSourceEnd) or (LSource^ < LLow) or (LSource^ > LHigh) then
      begin
        LValid := False;
        Break;
      end;
      LCode := (LCode shl 6) or (LSource^ and $3F);
      Inc(LSource);
      LLow := $80;
      LHigh := $BF;
    end;
    if not LValid then
    begin
      if (AFlags and cErrInvalidChars) <> 0 then
        Exit(0);
      if not Put(cReplacementChar) then
        Exit(0);
    end
    else if LCode >= $10000 then
    begin
      Dec(LCode, $10000);
      if not Put(WideChar($D800 + (LCode shr 10))) or not Put(WideChar($DC00 + (LCode and $3FF))) then
        Exit(0);
    end
    else if not Put(WideChar(LCode)) then
      Exit(0);
  end;
  Result := LCount;
end;

function UnicodeFromLocaleCharsFixed(ACodePage, AFlags: Cardinal; ASource: PAnsiChar;
  ASourceLen: Integer; ADest: PWideChar; ADestLen: Integer): Integer;
begin
  if ACodePage = CP_UTF8 then
    Result := Utf8ToUtf16(AFlags, ASource, ASourceLen, ADest, ADestLen)
  else
    Result := UnicodeFromLocaleChars(ACodePage, AFlags, ASource, ASourceLen, ADest, ADestLen);
end;

end.
