# Runs the benchmark against a local PostgreSQL 18 server on Windows, without network and without Docker.
# setup:   downloads the official EDB binaries zip once (no installation, no service), creates a cluster
#          in a work folder and fills the bench database.
# measure: starts the cluster, runs FireDAC (default and tuned) and .NET against it, and stops it again.
# Example: .\local-postgresql.ps1 setup
#          .\local-postgresql.ps1 measure -FireDacExe <path>\DbReadBench.FireDAC.exe
param(
  [Parameter(Mandatory)][ValidateSet('setup', 'measure')][string]$Phase,
  [string]$FireDacExe,
  [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'dbbench-local'),
  [int]$Port = 55434,
  [int]$Rounds = 1,
  [switch]$NoZoned
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-common.ps1')

$zipUrl = 'https://get.enterprisedb.com/postgresql/postgresql-18.1-1-windows-x64-binaries.zip'
$zipSha256 = 'B2A7302ECB78088209EDD96A936EC360FC12C58EC27DC8CC4E8CE5AEFB9F8D3B'
$pgDir = Join-Path $WorkDir 'pgsql'
$bin = Join-Path $pgDir 'bin'
$data = Join-Path $WorkDir 'pgdata'
$password = 'bench' # local throwaway password, as in the Docker setup
$env:PGPASSWORD = $password
# psql would otherwise read fill.sql in the console code page and break the umlauts.
$env:PGCLIENTENCODING = 'UTF8'
# libpq.dll needs its neighbours (OpenSSL, libintl, ...) on the PATH, for psql and for FireDAC.
$env:PATH = "$bin;$env:PATH"

function Start-Postgres {
  Invoke-Native (Join-Path $bin 'pg_ctl.exe') @('-D', $data, '-l', (Join-Path $WorkDir 'postgresql.log'),
    '-o', "-p $Port -c listen_addresses=127.0.0.1", '-w', 'start')
}

function Stop-Postgres { & (Join-Path $bin 'pg_ctl.exe') -D $data -m fast -w stop }

function Invoke-Psql([string[]]$Arguments) {
  Invoke-Native (Join-Path $bin 'psql.exe') (@('-h', '127.0.0.1', '-p', "$Port", '-U', 'bench', '-v', 'ON_ERROR_STOP=1', '-q') + $Arguments)
}

if ($Phase -eq 'setup') {
  if (-not (Test-Path (Join-Path $pgDir '.extracted'))) {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $zip = Join-Path $WorkDir 'postgresql-binaries.zip'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($hash -ne $zipSha256) { throw "unexpected SHA-256 $hash for $zipUrl" }
    if (Test-Path $pgDir) { Remove-Item $pgDir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($entry in $archive.Entries) {
        # Server, clients and their data files; pgAdmin, documentation, headers and symbols are not needed.
        if ($entry.Name -and $entry.FullName -match '^pgsql/(bin|lib|share)/' -and $entry.FullName -notmatch '\.\.') {
          $target = Join-Path $WorkDir ($entry.FullName -replace '/', '\')
          New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
      }
    }
    finally { $archive.Dispose() }
    Remove-Item $zip
    New-Item -ItemType File -Path (Join-Path $pgDir '.extracted') | Out-Null
    "extracted PostgreSQL binaries, SHA-256 of the zip $hash"
  }
  if (Test-Path $data) {
    Stop-Postgres 2>&1 | Out-Null
    Remove-Item $data -Recurse -Force
  }
  $passwordFile = Join-Path $WorkDir 'pg-password.txt'
  Set-Content -Path $passwordFile -Value $password -NoNewline -Encoding ascii
  try {
    Invoke-Native (Join-Path $bin 'initdb.exe') @('-D', $data, '-U', 'bench', "--pwfile=$passwordFile",
      '-E', 'UTF8', '--no-locale', '-A', 'scram-sha-256')
  }
  finally { Remove-Item $passwordFile }
  Start-Postgres
  try {
    Invoke-Psql @('-d', 'postgres', '-c', 'CREATE DATABASE bench')
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Psql @('-d', 'bench', '-f', (Join-Path $BenchDir 'postgresql\fill.sql'))
    'filled in {0:F0} s' -f $watch.Elapsed.TotalSeconds
  }
  finally { Stop-Postgres }
}
else {
  if (-not $FireDacExe) { throw 'measure needs -FireDacExe' }
  $libpq = Join-Path $bin 'libpq.dll'
  Write-MachineInfo $libpq
  "server: PostgreSQL $((& (Join-Path $bin 'postgres.exe') --version) -replace '^\D+'), 127.0.0.1:$Port"
  $dotnetDll = Build-DotNetBench
  Start-Postgres
  try {
    Invoke-Rounds -Rounds $Rounds -FireDacExe $FireDacExe -DotNetDll $dotnetDll -FireDacExtra @($libpq) -NoZoned:$NoZoned `
      -Connection @('pg', '127.0.0.1', "$Port", 'bench', 'bench', $password)
  }
  finally { Stop-Postgres }
}
