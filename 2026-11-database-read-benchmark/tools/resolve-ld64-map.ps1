# Resolves offsets from the image base (hex, as printed by macOS `sample`) to symbols of an
# ld64 link map, as written by the Delphi OSX64 linker with DCC_MapFile=3.
# Usage: pwsh resolve-ld64-map.ps1 -MapFile FirebirdBench.FireDAC.map 26c81 1860d ...
param([Parameter(Mandatory)][string]$MapFile, [Parameter(ValueFromRemainingArguments)][string[]]$Offsets)
$ErrorActionPreference = 'Stop'
$base = [Convert]::ToInt64('100000000', 16)
$addrs = New-Object System.Collections.Generic.List[long]
$sizes = New-Object System.Collections.Generic.List[long]
$names = New-Object System.Collections.Generic.List[string]
$inSymbols = $false
foreach ($line in [System.IO.File]::ReadLines($MapFile)) {
  if ($line -like '# Symbols:*') { $inSymbols = $true; continue }
  if ($inSymbols -and $line -match '^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+\[\s*\d+\]\s+(.+)$') {
    $addrs.Add([Convert]::ToInt64($matches[1], 16)); $sizes.Add([Convert]::ToInt64($matches[2], 16)); $names.Add($matches[3])
  }
}
foreach ($o in $Offsets) {
  $t = $base + [Convert]::ToInt64($o, 16)
  $hit = -1
  for ($i = 0; $i -lt $addrs.Count; $i++) { if ($addrs[$i] -le $t -and $t -lt $addrs[$i] + $sizes[$i]) { $hit = $i; break } }
  if ($hit -ge 0) { '{0} -> {1}' -f $o, $names[$hit] } else { "$o -> (none)" }
}
