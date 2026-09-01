$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$powerShellFiles = @(
  "OpenCodexUsageTray.ps1",
  "OpenCodexUsageTray.WinForms.ps1",
  "install.ps1",
  "uninstall.ps1"
)

foreach ($name in $powerShellFiles) {
  $path = Join-Path $root $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required file: $name"
  }
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $path,
    [ref]$tokens,
    [ref]$errors
  )
  if ($errors.Count -gt 0) {
    $message = ($errors | ForEach-Object { $_.Message }) -join "; "
    throw "PowerShell parse failed for $name`: $message"
  }
}

$mainPath = Join-Path $root "OpenCodexUsageTray.ps1"
$nonAscii = Select-String -LiteralPath $mainPath -Pattern '[^\x00-\x7F]'
if ($nonAscii) {
  throw "The Windows PowerShell entry script must remain ASCII-safe"
}
$mainText = [System.IO.File]::ReadAllText($mainPath)
foreach ($requiredUiMapping in @(
  '$compactFivePercent = $activeAccount.fiveHour.usedPercent',
  '$compactWeekPercent = $activeAccount.week.usedPercent',
  '$fivePercent = $accountData.fiveHour.usedPercent',
  '$weekPercent = $accountData.week.usedPercent',
  '$refreshTimer.Interval = [TimeSpan]::FromSeconds(3)',
  'runtime-config.json',
  'Resolve-NodePath',
  'tray-startup-error.log',
  '$script:popupFocusGraceUntil = [DateTime]::MinValue',
  '$script:popupFocusGraceUntil = [DateTime]::Now.AddSeconds(20)',
  'x:Name="CompactPanel"',
  'x:Name="ExpandButton"',
  'x:Name="CollapseButton"'
)) {
  if (-not $mainText.Contains($requiredUiMapping)) {
    throw "Missing required UI mapping: $requiredUiMapping"
  }
}

$providerPath = Join-Path $root "status-provider.mjs"
if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
  throw "Missing required file: status-provider.mjs"
}
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { $node = Get-Command node -ErrorAction Stop }
& $node.Source --check $providerPath
if ($LASTEXITCODE -ne 0) { throw "Node syntax validation failed" }
$providerTestPath = Join-Path $root "test-provider.mjs"
if (-not (Test-Path -LiteralPath $providerTestPath -PathType Leaf)) {
  throw "Missing required file: test-provider.mjs"
}
& $node.Source $providerTestPath
if ($LASTEXITCODE -ne 0) { throw "Provider projection tests failed" }

$launcherPath = Join-Path $root "Start-OpenCodexUsageTray.vbs"
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "Missing required file: Start-OpenCodexUsageTray.vbs"
}
$launcherText = [System.IO.File]::ReadAllText($launcherPath)
foreach ($requiredLauncherMapping in @(
  'WScript.Shell',
  '-WindowStyle Hidden',
  'WScript.Arguments.Named.Exists("supervise")',
  'WScript.Arguments.Unnamed(0)',
  'exitCode = shell.Run(command, 0, True)',
  'WScript.Sleep 30000',
  'If exitCode = 0 Then WScript.Quit 0'
)) {
  if (-not $launcherText.Contains($requiredLauncherMapping)) {
    throw "Missing required invisible-launcher mapping: $requiredLauncherMapping"
  }
}

$installPath = Join-Path $root "install.ps1"
$installText = [System.IO.File]::ReadAllText($installPath)
foreach ($requiredInstallMapping in @(
  '"runtime-config.json"',
  '"tray-startup-error.log"',
  'nodePath = $node.Source',
  '[System.IO.File]::WriteAllText(',
  '$startupRunCommand',
  'New-ItemProperty',
  'Start-Process -FilePath $startMenuShortcutPath',
  '" supervise',
  'Unregister-ScheduledTask -TaskName $scheduledTaskName'
)) {
  if (-not $installText.Contains($requiredInstallMapping)) {
    throw "Missing required install mapping: $requiredInstallMapping"
  }
}

$uninstallPath = Join-Path $root "uninstall.ps1"
$uninstallText = [System.IO.File]::ReadAllText($uninstallPath)
foreach ($requiredUninstallMapping in @(
  '"runtime-config.json"',
  '"tray-startup-error.log"',
  'Remove-ItemProperty -Path $startupRunPath -Name $startupRunName',
  'Unregister-ScheduledTask -TaskName $scheduledTaskName'
)) {
  if (-not $uninstallText.Contains($requiredUninstallMapping)) {
    throw "Missing required uninstall mapping: $requiredUninstallMapping"
  }
}

$documentationAssets = @("docs\hero.png", "docs\tray-compact.png", "docs\tray-light.png", "docs\tray-dark.png")
foreach ($asset in $documentationAssets) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $asset) -PathType Leaf)) {
    throw "Missing documentation asset: $asset"
  }
}

[pscustomobject]@{
  Valid = $true
  PowerShellFiles = $powerShellFiles.Count
  Provider = "status-provider.mjs"
  ProviderTests = "test-provider.mjs"
  DocumentationAssets = $documentationAssets.Count
}
