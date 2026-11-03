# Runs the benchmark against a local Firebird 5 server on Windows, without network and without Docker.
# setup:   copies an installed Firebird 5 into a work folder and gives the copy its own port, IPC name and
#          SYSDBA password, so the installed service stays untouched; then creates and fills bench.fdb.
# measure: starts the copy, runs FireDAC (default and tuned) and .NET against it, and stops it again.
# profile: starts the copy and samples a FireDAC run with tools\sample-windows.ps1 (needs the .map of the build).
# Example: .\local-firebird.ps1 setup
#          .\local-firebird.ps1 measure -FireDacExe <path>\DbReadBench.FireDAC.exe
param(
  [Parameter(Mandatory)][ValidateSet('setup', 'measure', 'profile')][string]$Phase,
  [string]$FireDacExe,
  [string]$MapFile,
  [string]$FirebirdDir = 'C:\Program Files\Firebird\Firebird_5_0',
  [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'dbbench-local'),
  [int]$Port = 53051,
  [int]$Rounds = 1,
  [switch]$NoZoned
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-common.ps1')

$root = Join-Path $WorkDir 'firebird5'
$database = Join-Path $WorkDir 'bench.fdb'
$securityDb = Join-Path $root 'security5.fdb'
$isql = Join-Path $root 'isql.exe'
$sqlFile = Join-Path $WorkDir 'firebird-step.sql'
$password = 'bench' # local throwaway password, as in the Docker setup

# FIREBIRD points the server, and isql in embedded mode, at the copy's configuration.
function Start-Firebird {
  $env:FIREBIRD = $root
  try { $server = Start-Process -FilePath (Join-Path $root 'firebird.exe') -ArgumentList '-a' -WindowStyle Hidden -PassThru }
  finally { Remove-Item Env:FIREBIRD }
  Wait-TcpPort $Port
  $server
}

function Invoke-IsqlScript([string]$Sql, [string[]]$Arguments = @()) {
  Set-Content -Path $sqlFile -Value $Sql -Encoding ascii
  try { Invoke-Native $isql (@('-q', '-i', $sqlFile) + $Arguments) }
  finally { Remove-Item $sqlFile }
}

if ($Phase -eq 'setup') {
  if (Test-Path $root) { Remove-Item $root -Recurse -Force }
  Remove-Item $database -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  robocopy $FirebirdDir $root /E /XF *.fdb firebird.log /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
  @(
    '# Benchmark instance next to the installed service: own port and IPC name, loopback only, defaults otherwise.'
    "RemoteServicePort = $Port"
    'RemoteBindAddress = 127.0.0.1'
    'IpcName = FIREBIRD_DBBENCH'
    'ServerMode = Super'
  ) | Set-Content -Path (Join-Path $root 'firebird.conf') -Encoding ascii

  $env:FIREBIRD = $root
  try {
    try { Copy-Item (Join-Path $FirebirdDir 'security5.fdb') $securityDb }
    catch {
      # The running service may hold its security database open; the SRP plugin creates its table on first use.
      'installed security database is locked, creating a fresh one'
      Invoke-IsqlScript "CREATE DATABASE '$securityDb';"
    }
    Invoke-IsqlScript "CREATE OR ALTER USER SYSDBA PASSWORD '$password' USING PLUGIN Srp;`r`nCOMMIT;" @('-user', 'SYSDBA', $securityDb)
  }
  finally { Remove-Item Env:FIREBIRD }

  $server = Start-Firebird
  try {
    Invoke-IsqlScript "CREATE DATABASE '127.0.0.1/${Port}:$database' USER 'SYSDBA' PASSWORD '$password' DEFAULT CHARACTER SET UTF8;"
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Native $isql @('-q', '-user', 'SYSDBA', '-password', $password, '-ch', 'UTF8',
      '-i', (Join-Path $BenchDir 'firebird\fill.sql'), "127.0.0.1/${Port}:$database")
    'filled in {0:F0} s' -f $watch.Elapsed.TotalSeconds
  }
  finally { Stop-Process -Id $server.Id -Force }
}
elseif ($Phase -eq 'profile') {
  if (-not $FireDacExe -or -not $MapFile) { throw 'profile needs -FireDacExe and -MapFile' }
  $server = Start-Firebird
  try {
    $arguments = @('fb', '127.0.0.1', "$Port", $database, 'SYSDBA', $password) + $(if ($NoZoned) { @('notz') } else { @() })
    & (Join-Path $BenchDir 'tools\sample-windows.ps1') -FilePath $FireDacExe -MapFile $MapFile -Arguments $arguments
  }
  finally { Stop-Process -Id $server.Id -Force }
}
else {
  if (-not $FireDacExe) { throw 'measure needs -FireDacExe' }
  Write-MachineInfo (Join-Path $env:SystemRoot 'System32\fbclient.dll')
  "server: $((Get-Item (Join-Path $root 'firebird.exe')).VersionInfo.FileVersion), 127.0.0.1:$Port"
  $dotnetDll = Build-DotNetBench
  $server = Start-Firebird
  try {
    Invoke-Rounds -Rounds $Rounds -FireDacExe $FireDacExe -DotNetDll $dotnetDll -Server $server -NoZoned:$NoZoned `
      -Connection @('fb', '127.0.0.1', "$Port", $database, 'SYSDBA', $password)
  }
  finally { Stop-Process -Id $server.Id -Force }
}
