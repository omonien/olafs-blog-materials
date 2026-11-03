# Poor man's sampling profiler for a Win64 Delphi program, the Windows counterpart of macOS `sample`.
# Starts the program, waits for the warm-up, then repeatedly suspends its busiest thread, walks the stack with
# dbghelp (x64 unwind data, which Delphi Win64 emits) and resumes it. Frames in the program resolve through its
# detailed .map file (DCC_MapFile=3), frames in DLLs to the nearest exported symbol.
# Example: .\sample-windows.ps1 -FilePath DbReadBench.FireDAC.exe -Arguments fb,127.0.0.1,... -MapFile DbReadBench.FireDAC.map
param(
  [Parameter(Mandatory)][string]$FilePath,
  [string[]]$Arguments = @(),
  [Parameter(Mandatory)][string]$MapFile,
  [int]$WarmupSeconds = 4,
  [int]$Seconds = 15,
  [int]$MaxDepth = 48,
  [int]$Top = 30
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class StackSampler
{
    const uint ThreadAccess = 0x0002 | 0x0008 | 0x0040; // suspend/resume, get context, query information
    const int ContextFull = 0x10000B;                  // CONTEXT_AMD64 | control | integer | floating point
    const int ContextSize = 1232;
    const uint MachineAmd64 = 0x8664;

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, int threadId);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetThreadContext(IntPtr thread, IntPtr context);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint period);
    [DllImport("dbghelp.dll", SetLastError = true)] public static extern bool SymInitialize(IntPtr process, string searchPath, bool invade);
    [DllImport("dbghelp.dll", SetLastError = true)] public static extern bool SymCleanup(IntPtr process);
    [DllImport("dbghelp.dll", SetLastError = true)] static extern bool StackWalk64(uint machine, IntPtr process, IntPtr thread,
        IntPtr frame, IntPtr context, IntPtr readMemory, IntPtr functionTableAccess, IntPtr getModuleBase, IntPtr translateAddress);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)] static extern bool SymFromAddr(IntPtr process, ulong address,
        out ulong displacement, IntPtr symbol);

    /// <summary>Samples one thread for the given time; every sample is its stack, innermost frame first.</summary>
    public static List<ulong[]> Sample(IntPtr process, int threadId, int seconds, int maxDepth)
    {
        IntPtr dbghelp = LoadLibrary("dbghelp.dll");
        IntPtr functionTableAccess = GetProcAddress(dbghelp, "SymFunctionTableAccess64");
        IntPtr getModuleBase = GetProcAddress(dbghelp, "SymGetModuleBase64");
        IntPtr thread = OpenThread(ThreadAccess, false, threadId);
        if (thread == IntPtr.Zero) throw new InvalidOperationException("OpenThread failed: " + Marshal.GetLastWin32Error());
        IntPtr contextRaw = Marshal.AllocHGlobal(ContextSize + 16);
        IntPtr context = new IntPtr((contextRaw.ToInt64() + 15) & ~15L); // CONTEXT must be 16-byte aligned
        IntPtr frame = Marshal.AllocHGlobal(1024);                        // STACKFRAME64, with room to spare
        var samples = new List<ulong[]>();
        timeBeginPeriod(1);
        try
        {
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < seconds * 1000L)
            {
                if (SuspendThread(thread) == -1) break; // the thread has ended
                try
                {
                    Zero(context, ContextSize);
                    Marshal.WriteInt32(context, 0x30, ContextFull);
                    if (GetThreadContext(thread, context))
                    {
                        Zero(frame, 1024);
                        SetAddress(frame, 0, Marshal.ReadInt64(context, 0xF8));  // AddrPC = Rip
                        SetAddress(frame, 32, Marshal.ReadInt64(context, 0xA0)); // AddrFrame = Rbp
                        SetAddress(frame, 48, Marshal.ReadInt64(context, 0x98)); // AddrStack = Rsp
                        var stack = new List<ulong>();
                        while (stack.Count < maxDepth && StackWalk64(MachineAmd64, process, thread, frame, context,
                            IntPtr.Zero, functionTableAccess, getModuleBase, IntPtr.Zero))
                        {
                            ulong pc = (ulong)Marshal.ReadInt64(frame, 0);
                            if (pc == 0) break;
                            stack.Add(pc);
                        }
                        if (stack.Count > 0) samples.Add(stack.ToArray());
                    }
                }
                finally { ResumeThread(thread); }
                Thread.Sleep(1);
            }
        }
        finally
        {
            timeEndPeriod(1);
            Marshal.FreeHGlobal(frame);
            Marshal.FreeHGlobal(contextRaw);
            CloseHandle(thread);
        }
        return samples;
    }

    /// <summary>Nearest exported symbol of a DLL address, or null.</summary>
    public static string ExportName(IntPtr process, ulong address)
    {
        IntPtr symbol = Marshal.AllocHGlobal(88 + 512);
        try
        {
            Zero(symbol, 88 + 512);
            Marshal.WriteInt32(symbol, 0, 88);  // SizeOfStruct = sizeof(SYMBOL_INFO)
            Marshal.WriteInt32(symbol, 80, 500); // MaxNameLen
            ulong displacement;
            if (!SymFromAddr(process, address, out displacement, symbol)) return null;
            return Marshal.PtrToStringAnsi(IntPtr.Add(symbol, 84));
        }
        finally { Marshal.FreeHGlobal(symbol); }
    }

    static void SetAddress(IntPtr frame, int offset, long value)
    {
        Marshal.WriteInt64(frame, offset, value);
        Marshal.WriteInt32(frame, offset + 12, 3); // AddrModeFlat
    }

    static void Zero(IntPtr buffer, int size)
    {
        for (int i = 0; i < size; i += 8) Marshal.WriteInt64(buffer, i, 0);
    }
}
'@

# Map file: publics as offsets into segment 0001, which is the .text section of the program.
function Read-MapPublics([string]$Path) {
  $offsets = [System.Collections.Generic.List[long]]::new()
  $names = [System.Collections.Generic.List[string]]::new()
  $inPublics = $false
  foreach ($line in [System.IO.File]::ReadLines($Path)) {
    if ($line -match 'Publics by Value') { $inPublics = $true; continue }
    if ($inPublics -and $line -match 'Line numbers for') { break }
    if ($inPublics -and $line -match '^\s*0001:([0-9A-Fa-f]+)\s+(\S+)') {
      $offsets.Add([Convert]::ToInt64($matches[1], 16)); $names.Add($matches[2])
    }
  }
  $offsetArray = $offsets.ToArray(); $nameArray = $names.ToArray()
  [Array]::Sort($offsetArray, $nameArray)
  [pscustomobject]@{ Offsets = $offsetArray; Names = $nameArray }
}

# RVA of the .text section from the PE section table.
function Get-TextSectionRva([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  $sections = [BitConverter]::ToUInt16($bytes, $pe + 6)
  $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
  $table = $pe + 24 + $optionalSize
  for ($i = 0; $i -lt $sections; $i++) {
    $entry = $table + 40 * $i
    if ([System.Text.Encoding]::ASCII.GetString($bytes, $entry, 5) -eq '.text') { return [BitConverter]::ToUInt32($bytes, $entry + 12) }
  }
  throw "no .text section in $Path"
}

# Program frames resolve through the map, DLL frames to the nearest export; dbghelp reads those from the live process.
function Resolve-Frame([uint64]$Address) {
  if ($cache.ContainsKey($Address)) { return $cache[$Address] }
  $module = $modules | Where-Object { $Address -ge $_.Base -and $Address -lt $_.End } | Select-Object -First 1
  if (-not $module) { $name = 'unknown' }
  elseif ($module -eq $exe) {
    $offset = [long]($Address - $exe.Base) - $textRva
    $index = [Array]::BinarySearch($map.Offsets, $offset)
    if ($index -lt 0) { $index = (-bnot $index) - 1 }
    $name = if ($index -ge 0) { $map.Names[$index] } else { "$exeName+0x{0:x}" -f ($Address - $exe.Base) }
  }
  else {
    $export = [StackSampler]::ExportName($target.Handle, $Address)
    $name = if ($export) { "$($module.Name)!$export" } else { "$($module.Name)+0x{0:x}" -f ($Address - $module.Base) }
  }
  $result = [pscustomobject]@{ Module = if ($module) { $module.Name } else { 'unknown' }; Name = $name }
  $cache[$Address] = $result
  $result
}

function Write-Share([hashtable]$Counts, [int]$Count) {
  $Counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Count |
    ForEach-Object { '{0,6:F1} %  {1}' -f (100.0 * $_.Value / $samples.Count), $_.Key }
}

$programPath = (Resolve-Path $FilePath).Path
$exeName = [System.IO.Path]::GetFileName($programPath)
$textRva = Get-TextSectionRva $programPath
$map = Read-MapPublics $MapFile
$cache = @{}

$info = [System.Diagnostics.ProcessStartInfo]::new($programPath)
foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true
$target = [System.Diagnostics.Process]::Start($info)
$stdout = $target.StandardOutput.ReadToEndAsync()
try {
  Start-Sleep -Seconds $WarmupSeconds
  $target.Refresh()
  $busiest = $target.Threads | Sort-Object TotalProcessorTime -Descending | Select-Object -First 1
  $modules = $target.Modules | ForEach-Object {
    [pscustomobject]@{ Name = $_.ModuleName; Base = [uint64]$_.BaseAddress.ToInt64(); End = [uint64]$_.BaseAddress.ToInt64() + [uint64]$_.ModuleMemorySize }
  }
  $exe = $modules | Where-Object Name -eq $exeName
  [void][StackSampler]::SymInitialize($target.Handle, $null, $true)
  $samples = [StackSampler]::Sample($target.Handle, $busiest.Id, $Seconds, $MaxDepth)

  "samples: $($samples.Count) from thread $($busiest.Id) over $Seconds s"
  $selfModule = @{}; $selfName = @{}; $inclusive = @{}
  foreach ($stack in $samples) {
    $leaf = Resolve-Frame $stack[0]
    $selfModule[$leaf.Module] = 1 + [int]$selfModule[$leaf.Module]
    $selfName[$leaf.Name] = 1 + [int]$selfName[$leaf.Name]
    $seen = @{}
    foreach ($address in $stack) {
      $frame = Resolve-Frame $address
      if (-not $seen.ContainsKey($frame.Name)) { $seen[$frame.Name] = $true; $inclusive[$frame.Name] = 1 + [int]$inclusive[$frame.Name] }
    }
  }
  [void][StackSampler]::SymCleanup($target.Handle)
}
finally {
  if (-not $target.HasExited) { $target.Kill() }
}
'--- self time by module'; Write-Share $selfModule 12
'--- self time by function'; Write-Share $selfName $Top
'--- inclusive time by function'; Write-Share $inclusive ($Top * 2)
