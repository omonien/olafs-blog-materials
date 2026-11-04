# Runs the comparison on Windows against a local Firebird 5 and a local PostgreSQL 18, without Docker and without
# a network between client and server. Both servers live in a work folder next to anything installed:
#   Firebird:   a copy of an installed Firebird 5 with its own port, IPC name and SYSDBA password
#   PostgreSQL: the official EDB binaries 18.1 as a zip (no installation, no service)
# setup: prepares both servers (copy, download, fill) and builds the .NET program; run it once.
# run:   starts one server, runs the given steps against it one after the other, and stops it again.
# fsync: measures with pg_test_fsync how expensive a flush is on the disk of the work folder.
# Examples: .\compare.ps1 setup
#           .\compare.ps1 run -Engine fb -Steps 'probe;read;insert clients=1'
# Steps are separated by semicolons, so that the list survives powershell -File as one argument.
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('setup', 'run', 'fsync')][string]$Phase,
  [ValidateSet('fb', 'pg')][string]$Engine,
  [string]$Steps = '',
  [string]$FirebirdDir = 'C:\Program Files\Firebird\Firebird_5_0',
  [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'dbbench-local')
)
$ErrorActionPreference = 'Stop'
$BenchDir = Split-Path $PSScriptRoot -Parent
$password = 'bench' # local throwaway password

$fbRoot = Join-Path $WorkDir 'firebird5'
$fbPort = 53051
$fbDatabase = Join-Path $WorkDir 'bench.fdb'
$isql = Join-Path $fbRoot 'isql.exe'

$pgZipUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.1-1-windows-x64-binaries.zip'
$pgZipSha256 = 'B2A7302ECB78088209EDD96A936EC360FC12C58EC27DC8CC4E8CE5AEFB9F8D3B'
$pgBin = Join-Path $WorkDir 'pgsql\bin'
$pgData = Join-Path $WorkDir 'pgdata'
$pgPort = 55434
$env:PGPASSWORD = $password
$env:PGCLIENTENCODING = 'UTF8'
$env:PATH = "$pgBin;$env:PATH"

$dotnetDll = Join-Path $BenchDir 'dotnet\bin\Release\net9.0\DbCompareBench.dll'
$connection = @{
  fb = @('fb', '127.0.0.1', "$fbPort", $fbDatabase, 'SYSDBA', $password, 'serverproc=firebird')
  pg = @('pg', '127.0.0.1', "$pgPort", 'bench', 'bench', $password, 'serverproc=postgres')
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $FilePath -Leaf) failed with exit code $LASTEXITCODE" }
}

function Wait-TcpPort([int]$Port, [int]$Seconds = 60) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try { $client.Connect('127.0.0.1', $Port); return }
    catch { Start-Sleep -Milliseconds 300 }
    finally { $client.Dispose() }
  }
  throw "nothing listens on 127.0.0.1:$Port after $Seconds s"
}

# CPU load of the VM over one second; the Mac's load is written on the Mac side.
function Write-Load {
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  "LOAD time=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')) vm_cpu_percent=$cpu"
}

# Same settings as the containers on the Mac: 32,768 pages of 8 KB, client chooses the wire encryption,
# defaults otherwise (Super server, forced writes on the database).
function Write-FirebirdConf {
  @(
    '# Benchmark instance next to the installed service: own port and IPC name, loopback only.'
    "RemoteServicePort = $fbPort"
    'RemoteBindAddress = 127.0.0.1'
    'IpcName = FIREBIRD_DBBENCH'
    'ServerMode = Super'
    'DefaultDbCachePages = 32768'
    'WireCrypt = Enabled'
  ) | Set-Content -Path (Join-Path $fbRoot 'firebird.conf') -Encoding ascii
}

function Start-Firebird {
  $env:FIREBIRD = $fbRoot
  try { $server = Start-Process -FilePath (Join-Path $fbRoot 'firebird.exe') -ArgumentList '-a' -WindowStyle Hidden -PassThru }
  finally { Remove-Item Env:FIREBIRD }
  Wait-TcpPort $fbPort
  $server
}

# Not piped: the server inherits pg_ctl's output handle, and a pipeline would wait for it to close.
# A server left over from an aborted run is stopped first.
function Start-Postgres {
  & (Join-Path $pgBin 'pg_ctl.exe') -D $pgData status *> $null
  if ($LASTEXITCODE -eq 0) { Stop-Postgres }
  Invoke-Native (Join-Path $pgBin 'pg_ctl.exe') @('-D', $pgData, '-l', (Join-Path $WorkDir 'postgresql.log'),
    '-o', "-p $pgPort -c listen_addresses=127.0.0.1 -c shared_buffers=256MB", '-w', 'start')
}

function Stop-Postgres { & (Join-Path $pgBin 'pg_ctl.exe') -D $pgData -m fast -w stop | Out-Null }

function Invoke-Bench([string]$Engine, [string]$Step) {
  $parts = $Step -split ' '
  Write-Load
  "=== $Engine $Step"
  & dotnet $dotnetDll $parts[0] @($connection[$Engine]) @($parts | Select-Object -Skip 1)
  if ($LASTEXITCODE -ne 0) { "FAILED $Engine $Step" }
}

function Invoke-IsqlScript([string]$Sql, [string[]]$Arguments = @()) {
  $file = Join-Path $WorkDir 'firebird-step.sql'
  Set-Content -Path $file -Value $Sql -Encoding ascii
  try { Invoke-Native $isql (@('-q', '-i', $file) + $Arguments) }
  finally { Remove-Item $file }
}

if ($Phase -eq 'setup') {
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
  $env:DOTNET_NOLOGO = '1'
  # The hash shows that the VM builds the same source as the Mac.
  "source: Program.cs SHA-256 $((Get-FileHash (Join-Path $BenchDir 'dotnet\Program.cs') -Algorithm SHA256).Hash)"
  Invoke-Native 'dotnet' @('build', (Join-Path $BenchDir 'dotnet\DbCompareBench.csproj'), '-c', 'Release', '-nologo', '-v', 'q')

  if (-not (Test-Path (Join-Path $fbRoot 'firebird.exe'))) {
    New-Item -ItemType Directory -Force -Path $fbRoot | Out-Null
    robocopy $FirebirdDir $fbRoot /E /XF *.fdb firebird.log /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    $securityDb = Join-Path $fbRoot 'security5.fdb'
    $env:FIREBIRD = $fbRoot
    try {
      try { Copy-Item (Join-Path $FirebirdDir 'security5.fdb') $securityDb }
      catch { Invoke-IsqlScript "CREATE DATABASE '$securityDb';" }
      Invoke-IsqlScript "CREATE OR ALTER USER SYSDBA PASSWORD '$password' USING PLUGIN Srp;`r`nCOMMIT;" @('-user', 'SYSDBA', $securityDb)
    }
    finally { Remove-Item Env:FIREBIRD }
  }
  Write-FirebirdConf
  $server = Start-Firebird
  try {
    if (-not (Test-Path $fbDatabase)) {
      Invoke-IsqlScript "CREATE DATABASE '127.0.0.1/${fbPort}:$fbDatabase' USER 'SYSDBA' PASSWORD '$password' DEFAULT CHARACTER SET UTF8;"
      $watch = [System.Diagnostics.Stopwatch]::StartNew()
      Invoke-Native $isql @('-q', '-user', 'SYSDBA', '-password', $password, '-ch', 'UTF8',
        '-i', (Join-Path $BenchDir 'firebird\fill-bench-rows.sql'), "127.0.0.1/${fbPort}:$fbDatabase")
      'RESULT test=fill engine=fb seconds={0:F0}' -f $watch.Elapsed.TotalSeconds
    }
    Invoke-Bench fb 'json-setup docs=500000'
  }
  finally { Stop-Process -Id $server.Id -Force }

  if (-not (Test-Path (Join-Path $pgBin 'postgres.exe'))) {
    $zip = Join-Path $WorkDir 'postgresql-binaries.zip'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $pgZipUrl -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($hash -ne $pgZipSha256) { throw "unexpected SHA-256 $hash for $pgZipUrl" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($entry in $archive.Entries) {
        if ($entry.Name -and $entry.FullName -match '^pgsql/(bin|lib|share)/' -and $entry.FullName -notmatch '\.\.') {
          $target = Join-Path $WorkDir ($entry.FullName -replace '/', '\')
          New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
      }
    }
    finally { $archive.Dispose() }
    Remove-Item $zip
  }
  if (-not (Test-Path $pgData)) {
    $passwordFile = Join-Path $WorkDir 'pg-password.txt'
    Set-Content -Path $passwordFile -Value $password -NoNewline -Encoding ascii
    try { Invoke-Native (Join-Path $pgBin 'initdb.exe') @('-D', $pgData, '-U', 'bench', "--pwfile=$passwordFile", '-E', 'UTF8', '--no-locale', '-A', 'scram-sha-256') }
    finally { Remove-Item $passwordFile }
    Start-Postgres
    try {
      $psql = Join-Path $pgBin 'psql.exe'
      Invoke-Native $psql @('-h', '127.0.0.1', '-p', "$pgPort", '-U', 'bench', '-q', '-d', 'postgres', '-c', 'CREATE DATABASE bench')
      $watch = [System.Diagnostics.Stopwatch]::StartNew()
      Invoke-Native $psql @('-h', '127.0.0.1', '-p', "$pgPort", '-U', 'bench', '-q', '-v', 'ON_ERROR_STOP=1', '-d', 'bench',
        '-f', (Join-Path $BenchDir 'postgresql\fill-bench-rows.sql'))
      'RESULT test=fill engine=pg seconds={0:F0}' -f $watch.Elapsed.TotalSeconds
    }
    finally { Stop-Postgres }
  }
  Start-Postgres
  try { Invoke-Bench pg 'json-setup docs=500000' }
  finally { Stop-Postgres }
}
elseif ($Phase -eq 'fsync') {
  & (Join-Path $pgBin 'pg_test_fsync.exe') -s 2 -f (Join-Path $WorkDir 'pg_test_fsync.tmp')
}
else {
  if (-not $Engine) { throw 'run needs -Engine' }
  "machine: $([Environment]::ProcessorCount) logical CPUs ($((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)), " +
    "$([math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)) GB, $((Get-CimInstance Win32_OperatingSystem).Caption), .NET SDK $(& dotnet --version)"
  if ($Engine -eq 'fb') {
    "server: Firebird $((Get-Item (Join-Path $fbRoot 'firebird.exe')).VersionInfo.FileVersion), 127.0.0.1:$fbPort"
    Write-FirebirdConf
    $server = Start-Firebird
    try { foreach ($step in $Steps -split ';') { Invoke-Bench fb $step.Trim() } }
    finally { Stop-Process -Id $server.Id -Force }
  }
  else {
    "server: PostgreSQL $((& (Join-Path $pgBin 'postgres.exe') --version) -replace '^\D+'), 127.0.0.1:$pgPort"
    Start-Postgres
    try { foreach ($step in $Steps -split ';') { Invoke-Bench pg $step.Trim() } }
    finally { Stop-Postgres }
  }
}
