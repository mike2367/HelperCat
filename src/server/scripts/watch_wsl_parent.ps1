param(
  [string]$Distro = "Ubuntu-24.04",
  [int]$ParentPid = 0,
  [switch]$PrintParentPid,
  [string]$OwnerScript = "",
  [string]$OwnerCreation = "",
  [string]$ComposeFile = "",
  [switch]$StopDockerServices,
  [string]$DockerContainer = "",
  [string]$DockerVolume = "",
  [int]$RedisPort = 0,
  [string]$RedisDataDir = "",
  [string]$RuntimeDir = "",
  [string]$LockDir = ""
)

if (-not ("CatToneNativeProcessQuery" -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CatToneNativeProcessQuery {
    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessBasicInformation {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(IntPtr process, int infoClass, ref ProcessBasicInformation info, int length, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Get-ParentProcessId([int]$ProcessId) {
  try {
    $process = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop
    if ($process) {
      return [int]$process.ParentProcessId
    }
  } catch { }
  $handle = [CatToneNativeProcessQuery]::OpenProcess(0x1000, $false, [uint32]$ProcessId)
  if ($handle -eq [IntPtr]::Zero) {
    return 0
  }
  try {
    $info = New-Object CatToneNativeProcessQuery+ProcessBasicInformation
    $status = [CatToneNativeProcessQuery]::NtQueryInformationProcess($handle, 0, [ref]$info, [Runtime.InteropServices.Marshal]::SizeOf($info), [IntPtr]::Zero)
    if ($status -eq 0) {
      return $info.InheritedFromUniqueProcessId.ToInt32()
    }
  } finally {
    [CatToneNativeProcessQuery]::CloseHandle($handle) | Out-Null
  }
  return 0
}

if ($PrintParentPid) {
  $commandShellPid = Get-ParentProcessId $PID
  Get-ParentProcessId $commandShellPid
  exit 0
}

if ($ParentPid -le 0) {
  $ParentPid = Get-ParentProcessId $PID
}

function Test-LauncherOwner {
  $process = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  if (-not $process) {
    return $false
  }
  if ($OwnerCreation) {
    try {
      if ([string]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $OwnerCreation) {
        return $false
      }
    } catch {
      return $false
    }
  }
  return $true
}

while (Test-LauncherOwner) {
  Start-Sleep -Seconds 2
}

if ($LockDir -and (Test-Path -LiteralPath $LockDir)) {
  $ownerPath = Join-Path $LockDir "owner.pid"
  $ownerPid = Get-Content -LiteralPath $ownerPath -ErrorAction SilentlyContinue
  $ownerCreationPath = Join-Path $LockDir "owner.creation"
  $ownerScriptPath = Join-Path $LockDir "owner.script"
  $currentCreation = Get-Content -LiteralPath $ownerCreationPath -ErrorAction SilentlyContinue
  $currentScript = Get-Content -LiteralPath $ownerScriptPath -ErrorAction SilentlyContinue
  if ($ownerPid -ne [string]$ParentPid -or ($OwnerCreation -and $currentCreation -ne $OwnerCreation) -or ($OwnerScript -and $currentScript -ne $OwnerScript)) {
    exit 0
  }
}

if ($DockerContainer) {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    & $docker.Source rm -f $DockerContainer 2>$null | Out-Null
  }
}

if ($DockerVolume) {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    & $docker.Source volume rm -f $DockerVolume 2>$null | Out-Null
  }
}

if ($StopDockerServices -and $ComposeFile) {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    & $docker.Source compose -f $ComposeFile stop open-webui | Out-Null
  }
}

if ($RedisPort -gt 0) {
  $redisCli = "C:\Program Files\Redis-x64-5.0.14.1\redis-cli.exe"
  if (Test-Path -LiteralPath $redisCli) {
    & $redisCli -p $RedisPort -n 1 FLUSHDB 2>$null | Out-Null
    & $redisCli -p $RedisPort shutdown nosave 2>$null | Out-Null
  }
}

& wsl.exe --terminate $Distro | Out-Null
Start-Sleep -Seconds 1

if ($RuntimeDir) {
  $resolvedRuntimeDir = [IO.Path]::GetFullPath($RuntimeDir)
  if ($resolvedRuntimeDir -match '[\\/]src[\\/]server[\\/]logs[\\/]test[\\/]\d{8}-\d{6}-\d+[\\/]runtime$') {
    Remove-Item -LiteralPath $resolvedRuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$running = @(
  & wsl.exe -l -q --running |
    ForEach-Object { ($_ -replace [char]0, "").Trim() } |
    Where-Object { $_ }
)

if (-not ($running | Where-Object { $_ -ne $Distro })) {
  & wsl.exe --shutdown | Out-Null
}

if ($LockDir -and (Get-Content -LiteralPath (Join-Path $LockDir "owner.pid") -ErrorAction SilentlyContinue) -eq [string]$ParentPid) {
  $ownerCreationPath = Join-Path $LockDir "owner.creation"
  $ownerScriptPath = Join-Path $LockDir "owner.script"
  $currentCreation = Get-Content -LiteralPath $ownerCreationPath -ErrorAction SilentlyContinue
  $currentScript = Get-Content -LiteralPath $ownerScriptPath -ErrorAction SilentlyContinue
  if ((-not $OwnerCreation -or $currentCreation -eq $OwnerCreation) -and (-not $OwnerScript -or $currentScript -eq $OwnerScript)) {
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
