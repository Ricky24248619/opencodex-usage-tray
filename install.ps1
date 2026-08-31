param(
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceApp = Join-Path $sourceRoot "OpenCodexUsageTray.ps1"
$sourceLegacyApp = Join-Path $sourceRoot "OpenCodexUsageTray.WinForms.ps1"
$sourceProvider = Join-Path $sourceRoot "status-provider.mjs"
$sourceLauncher = Join-Path $sourceRoot "Start-OpenCodexUsageTray.vbs"
$sourceIcon = Join-Path $sourceRoot "OpenCodexUsage.ico"
$sourceReadme = Join-Path $sourceRoot "README.md"
foreach ($requiredFile in @($sourceApp, $sourceProvider, $sourceLauncher)) {
  if (-not [System.IO.File]::Exists($requiredFile)) {
    throw "Missing required file: $requiredFile"
  }
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { $node = Get-Command node -ErrorAction Stop }
$nodeVersion = (& $node.Source -p "process.versions.node").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($nodeVersion)) {
  throw "Node.js could not report its version"
}
$nodeMajor = [int]($nodeVersion.Split('.')[0])
if ($nodeMajor -lt 22) {
  throw "OpenCodex Usage Tray requires Node.js 22 or newer; found $nodeVersion"
}
& $node.Source -e "require('node:sqlite')" | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "This Node.js installation does not provide node:sqlite"
}

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if ([System.IO.File]::Exists($windowsPowerShell)) {
  $powerShellPath = $windowsPowerShell
} else {
  $powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
}

$installRoot = Join-Path $env:LOCALAPPDATA "OpenCodexUsageTray"
$installedApp = Join-Path $installRoot "OpenCodexUsageTray.ps1"
$mutexName = "Local\OpenCodexUsageTray-v1"
$resolvedInstallRoot = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
$resolvedLocalAppData = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
$allowedInstallFiles = @(
  "OpenCodexUsageTray.ps1",
  "OpenCodexUsageTray.WinForms.ps1",
  "status-provider.mjs",
  "Start-OpenCodexUsageTray.vbs",
  "OpenCodexUsage.ico",
  "README.md",
  "tray-heartbeat.json",
  "tray-settings.json"
)

if (-not $resolvedInstallRoot.StartsWith($resolvedLocalAppData + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to write to an unexpected install path"
}

function Assert-SafeInstallRoot {
  if (-not (Test-Path -LiteralPath $resolvedInstallRoot)) { return }
  $rootItem = Get-Item -LiteralPath $resolvedInstallRoot -Force
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to write through an install root that is not a normal directory"
  }
  foreach ($item in Get-ChildItem -LiteralPath $resolvedInstallRoot -Force) {
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to traverse unexpected directory or reparse point: $($item.Name)"
    }
    if ($allowedInstallFiles -notcontains $item.Name) {
      throw "Refusing to overwrite an install directory containing unexpected file: $($item.Name)"
    }
  }
}

Assert-SafeInstallRoot

function Test-TrayStopped {
  $createdNew = $false
  $probe = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
  $acquired = $false
  try {
    try {
      $acquired = $probe.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if ($acquired) {
      try { $probe.ReleaseMutex() } catch { }
      return $true
    }
    return $false
  } finally {
    $probe.Dispose()
  }
}

function Wait-ForTrayStop {
  for ($attempt = 0; $attempt -lt 80; $attempt++) {
    if (Test-TrayStopped) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "The existing OpenCodex usage tray did not stop; no files were overwritten"
}

& $powerShellPath -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $sourceApp -Mode Stop
if ($LASTEXITCODE -ne 0) { throw "The existing OpenCodex usage tray could not be asked to stop" }
Wait-ForTrayStop
$sourceHeartbeat = Join-Path $sourceRoot "tray-heartbeat.json"
$installedHeartbeat = Join-Path $installRoot "tray-heartbeat.json"
Remove-Item -LiteralPath $sourceHeartbeat -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $installedHeartbeat -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Assert-SafeInstallRoot
Copy-Item -LiteralPath $sourceApp -Destination $installedApp -Force
if (Test-Path -LiteralPath $sourceLegacyApp) {
  Copy-Item -LiteralPath $sourceLegacyApp -Destination (Join-Path $installRoot "OpenCodexUsageTray.WinForms.ps1") -Force
}
Copy-Item -LiteralPath $sourceProvider -Destination (Join-Path $installRoot "status-provider.mjs") -Force
Copy-Item -LiteralPath $sourceLauncher -Destination (Join-Path $installRoot "Start-OpenCodexUsageTray.vbs") -Force
if (Test-Path -LiteralPath $sourceIcon) {
  Copy-Item -LiteralPath $sourceIcon -Destination (Join-Path $installRoot "OpenCodexUsage.ico") -Force
}
if (Test-Path -LiteralPath $sourceReadme) {
  Copy-Item -LiteralPath $sourceReadme -Destination (Join-Path $installRoot "README.md") -Force
}

$startupRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$programsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
$startupShortcutPath = Join-Path $startupRoot "OpenCodex Usage Tray.lnk"
$startMenuShortcutPath = Join-Path $programsRoot "OpenCodex Usage.lnk"
$installedLauncher = Join-Path $installRoot "Start-OpenCodexUsageTray.vbs"
$wscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
if (-not (Test-Path -LiteralPath $wscriptPath -PathType Leaf)) {
  throw "Windows Script Host is unavailable"
}
$iconPath = Join-Path $installRoot "OpenCodexUsage.ico"
if (-not (Test-Path -LiteralPath $iconPath)) {
  $iconPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) ".opencodex\opencodex-tray-online.ico"
}

$shell = New-Object -ComObject WScript.Shell
function Save-Shortcut {
  param([string]$Path)
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $wscriptPath
  $shortcut.Arguments = '//B //NoLogo "' + $installedLauncher + '"'
  $shortcut.WorkingDirectory = $installRoot
  $shortcut.WindowStyle = 7
  $shortcut.Description = "OpenCodex usage, tasks, quota windows, and account switcher"
  if (Test-Path -LiteralPath $iconPath) { $shortcut.IconLocation = "$iconPath,0" }
  $shortcut.Save()
}

Save-Shortcut $startupShortcutPath
Save-Shortcut $startMenuShortcutPath
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

$launchedPid = $null
$started = $false
$connected = $false
if (-not $NoStart) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $powerShellPath
  $psi.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $installedApp + '" -ShowOnStart'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $process = [System.Diagnostics.Process]::Start($psi)
  if ($null -eq $process) { throw "The installed tray process did not start" }
  $launchedPid = $process.Id
  $heartbeat = $null
  for ($attempt = 0; $attempt -lt 120; $attempt++) {
    $process.Refresh()
    if ($process.HasExited) {
      throw "The installed tray process exited before becoming ready"
    }
    if (Test-Path -LiteralPath $installedHeartbeat) {
      try {
        $heartbeat = Get-Content -LiteralPath $installedHeartbeat -Raw | ConvertFrom-Json
        if ([int]$heartbeat.pid -eq $launchedPid) {
          $started = $true
          $connected = [bool]$heartbeat.connected
          if ($connected) { break }
        }
      } catch { }
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not $started) { throw "The installed tray process did not publish a readiness heartbeat" }
  $process.Dispose()
}

[pscustomobject]@{
  Installed = $true
  InstallRoot = $installRoot
  StartupShortcut = $startupShortcutPath
  StartMenuShortcut = $startMenuShortcutPath
  Node = $node.Source
  PowerShell = $powerShellPath
  LaunchedPid = $launchedPid
  Started = $started
  Connected = $connected
}
