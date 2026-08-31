$ErrorActionPreference = "Stop"

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if ([System.IO.File]::Exists($windowsPowerShell)) {
  $powerShellPath = $windowsPowerShell
} else {
  $powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
}

$installRoot = Join-Path $env:LOCALAPPDATA "OpenCodexUsageTray"
$expectedRoot = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
$resolvedLocalAppData = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
if (-not $expectedRoot.StartsWith($resolvedLocalAppData + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to remove an unexpected install path"
}

$allowedFiles = @(
  "OpenCodexUsageTray.ps1",
  "OpenCodexUsageTray.WinForms.ps1",
  "status-provider.mjs",
  "Start-OpenCodexUsageTray.vbs",
  "OpenCodexUsage.ico",
  "README.md",
  "tray-heartbeat.json",
  "tray-settings.json"
)

function Assert-SafeInstallContents {
  if (-not (Test-Path -LiteralPath $expectedRoot)) { return }
  $rootItem = Get-Item -LiteralPath $expectedRoot -Force
  if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove an install root that is a reparse point"
  }
  foreach ($item in Get-ChildItem -LiteralPath $expectedRoot -Force) {
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to traverse unexpected directory or reparse point: $($item.Name)"
    }
    if ($allowedFiles -notcontains $item.Name) {
      throw "Refusing to remove unexpected file from the install directory: $($item.Name)"
    }
  }
}

$mutexName = "Local\OpenCodexUsageTray-v1"
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
  throw "The OpenCodex usage tray did not stop; no installed files were removed"
}

Assert-SafeInstallContents
$installedApp = Join-Path $expectedRoot "OpenCodexUsageTray.ps1"
$sourceApp = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "OpenCodexUsageTray.ps1"
$stopScript = if (Test-Path -LiteralPath $installedApp) { $installedApp } else { $sourceApp }
if (-not (Test-TrayStopped)) {
  if (-not (Test-Path -LiteralPath $stopScript)) { throw "The running tray could not be signaled safely" }
  & $powerShellPath -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $stopScript -Mode Stop
  if ($LASTEXITCODE -ne 0) { throw "The OpenCodex usage tray could not be asked to stop" }
  Wait-ForTrayStop
}

$startupShortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) "OpenCodex Usage Tray.lnk"
$startMenuShortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "OpenCodex Usage.lnk"
Remove-Item -LiteralPath $startupShortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuShortcutPath -Force -ErrorAction SilentlyContinue

Assert-SafeInstallContents
if (Test-Path -LiteralPath $expectedRoot) {
  foreach ($name in $allowedFiles) {
    $path = Join-Path $expectedRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Remove-Item -LiteralPath $path -Force
    }
  }
  $remaining = @(Get-ChildItem -LiteralPath $expectedRoot -Force)
  if ($remaining.Count -ne 0) { throw "The install directory is not empty; it was left in place" }
  Remove-Item -LiteralPath $expectedRoot -Force
}

[pscustomobject]@{
  Uninstalled = $true
  RemovedInstallRoot = $expectedRoot
  RemovedStartupShortcut = $startupShortcutPath
  RemovedStartMenuShortcut = $startMenuShortcutPath
}
