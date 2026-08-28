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

$providerPath = Join-Path $root "status-provider.mjs"
if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
  throw "Missing required file: status-provider.mjs"
}
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { $node = Get-Command node -ErrorAction Stop }
& $node.Source --check $providerPath
if ($LASTEXITCODE -ne 0) { throw "Node syntax validation failed" }

foreach ($asset in @("docs\hero.png", "docs\tray-light.png", "docs\tray-dark.png")) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $asset) -PathType Leaf)) {
    throw "Missing documentation asset: $asset"
  }
}

[pscustomobject]@{
  Valid = $true
  PowerShellFiles = $powerShellFiles.Count
  Provider = "status-provider.mjs"
  DocumentationAssets = 3
}
