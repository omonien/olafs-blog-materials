# Shared helpers for the Windows scripts that run the benchmark against a local server, without Docker and
# without a network between client and server. Dot-source it from local-firebird.ps1 or local-postgresql.ps1.

$BenchDir = Split-Path $PSScriptRoot -Parent

# Runs a native program and stops the script when it fails.
function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $FilePath -Leaf) failed with exit code $LASTEXITCODE" }
}

# Waits until a server accepts TCP connections on the loopback address.
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

# Builds the .NET benchmark and returns the path of its program.
function Build-DotNetBench {
  $project = Join-Path $BenchDir 'dotnet\DbReadBench.DotNet.csproj'
  $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
  $env:DOTNET_NOLOGO = '1'
  Invoke-Native 'dotnet' @('build', $project, '-c', 'Release', '-nologo', '-v', 'q') | Out-Null
  Join-Path $BenchDir 'dotnet\bin\Release\net9.0\DbReadBench.DotNet.dll'
}

function Write-MachineInfo([string]$ClientLibrary) {
  $os = (Get-CimInstance Win32_OperatingSystem).Caption
  $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
  "machine: $([Environment]::ProcessorCount) logical CPUs ($cpu), $os, PowerShell $($PSVersionTable.PSVersion), .NET SDK $(& dotnet --version)"
  "client library: $ClientLibrary $((Get-Item $ClientLibrary).VersionInfo.FileVersion)"
}

# Runs one benchmark program and prints its output with wall time and the CPU time of the client process.
# With a server process it also prints the CPU time the server spent meanwhile; together they show which side limits.
function Invoke-Measured([string]$Label, [string]$FilePath, [string[]]$Arguments, [System.Diagnostics.Process]$Server) {
  $info = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
  foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  if ($Server) { $Server.Refresh(); $serverBefore = $Server.TotalProcessorTime }
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $process = [System.Diagnostics.Process]::Start($info)
  try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $watch.Stop()
    $line = '=== {0}: exit {1}, wall {2:F1} s, client CPU {3:F1} s' -f $Label, $process.ExitCode,
      $watch.Elapsed.TotalSeconds, $process.TotalProcessorTime.TotalSeconds
    if ($Server) {
      $Server.Refresh()
      $line += (', server CPU {0:F1} s' -f ($Server.TotalProcessorTime - $serverBefore).TotalSeconds)
    }
    $line
    $stdout.Result.TrimEnd()
    if ($stderr.Result) { 'stderr: ' + $stderr.Result.TrimEnd() }
  }
  finally { $process.Dispose() }
}

# Alternates FireDAC, FireDAC tuned and .NET so that drift on the machine hits all three alike.
function Invoke-Rounds {
  param(
    [int]$Rounds,
    [string]$FireDacExe,
    [string[]]$Connection,
    [string[]]$FireDacExtra = @(),
    [string]$DotNetDll,
    [System.Diagnostics.Process]$Server,
    [switch]$NoZoned
  )
  $zoned = if ($NoZoned) { @('notz') } else { @() }
  $dotnet = (Get-Command dotnet).Source
  for ($round = 1; $round -le $Rounds; $round++) {
    Invoke-Measured "round $round FireDAC" $FireDacExe ($Connection + $FireDacExtra + $zoned) $Server
    Invoke-Measured "round $round FireDAC tuned" $FireDacExe ($Connection + $FireDacExtra + $zoned + 'tuned') $Server
    Invoke-Measured "round $round .NET" $dotnet (@($DotNetDll) + $Connection + $zoned) $Server
  }
}
