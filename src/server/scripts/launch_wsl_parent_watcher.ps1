param(
  [Parameter(Mandatory = $true)]
  [string]$WatcherPath,
  [Parameter(Mandatory = $true)]
  [string]$Distro,
  [Parameter(Mandatory = $true)]
  [int]$ParentPid,
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

function Quote-Argument([string]$Value) {
  '"{0}"' -f $Value
}

$watcherArguments = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-WindowStyle",
  "Hidden",
  "-File",
  (Quote-Argument $WatcherPath),
  "-Distro",
  (Quote-Argument $Distro),
  "-ParentPid",
  $ParentPid
)

if ($OwnerScript) {
  $watcherArguments += "-OwnerScript", (Quote-Argument $OwnerScript)
}
if ($OwnerCreation) {
  $watcherArguments += "-OwnerCreation", (Quote-Argument $OwnerCreation)
}

if ($ComposeFile) {
  $watcherArguments += "-ComposeFile", (Quote-Argument $ComposeFile)
}
if ($StopDockerServices) {
  $watcherArguments += "-StopDockerServices"
}
if ($DockerContainer) {
  $watcherArguments += "-DockerContainer", (Quote-Argument $DockerContainer)
}
if ($DockerVolume) {
  $watcherArguments += "-DockerVolume", (Quote-Argument $DockerVolume)
}
if ($RedisPort -gt 0) {
  $watcherArguments += "-RedisPort", $RedisPort
}
if ($RedisDataDir) {
  $watcherArguments += "-RedisDataDir", (Quote-Argument $RedisDataDir)
}
if ($RuntimeDir) {
  $watcherArguments += "-RuntimeDir", (Quote-Argument $RuntimeDir)
}
if ($LockDir) {
  $watcherArguments += "-LockDir", (Quote-Argument $LockDir)
}

$shell = New-Object -ComObject Shell.Application
$shell.ShellExecute("powershell.exe", $watcherArguments -join ' ', "", "open", 0)
