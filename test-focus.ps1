$ErrorActionPreference = 'Stop'

# Exercise the real visibility functions with window metadata, without moving desktop windows.
Add-Type @'
using System;
using System.Text;
public static class OpenCodexFocusNative {
  public static IntPtr Foreground = IntPtr.Zero;
  public static bool Visible = true;
  public static bool Minimized = false;
  public static IntPtr GetForegroundWindow() { return Foreground; }
  public static bool IsWindowVisible(IntPtr h) { return Visible; }
  public static bool IsIconic(IntPtr h) { return Minimized; }
  public static uint GetWindowThreadProcessId(IntPtr h, out uint id) { id = h.ToInt64() == 4 ? 200u : 100u; return 0; }
  public static int GetWindowLong(IntPtr h, int index) { return h.ToInt64() == 3 || h.ToInt64() == 5 ? unchecked((int)0x96000000) : 0x14C70000; }
  public static bool SetForegroundWindow(IntPtr h) { Foreground = h; return true; }
}
'@
$script:mainHandle = [IntPtr]1
function Get-Process {
  param($Id, $ErrorAction)
  [pscustomobject]@{
    ProcessName = if ($Id -eq 100) { 'ChatGPT' } else { 'explorer' }
    Path = if ($Id -eq 100) { 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe' } else { 'C:\Windows\explorer.exe' }
    MainWindowHandle = $script:mainHandle
  }
}
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'OpenCodexUsageTray.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Test-CodexMainWindow', 'Get-ForegroundContext', 'Update-PopupFocusVisibility', 'Show-Popup', 'Hide-Popup')) {
  $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Invoke-Expression $definition.Extent.Text
}
function Sync-CodexTheme { }
function Position-Popup { param($AnchorWindow) }
function Write-Heartbeat { }
$window = [pscustomobject]@{ IsVisible = $false; ShowActivated = $false; Topmost = $true; ShowCount = 0 }
$window | Add-Member ScriptMethod Show { $this.IsVisible = $true; $this.ShowCount++ }
$window | Add-Member ScriptMethod Hide { $this.IsVisible = $false }
$window | Add-Member ScriptMethod UpdateLayout { }
$window | Add-Member ScriptMethod Activate { [OpenCodexFocusNative]::Foreground = [IntPtr]2; return $true }
$showItem = [pscustomobject]@{ Text = 'Show usage' }
$script:windowHandle = [IntPtr]2
$script:lastCodexWindowHandle = [IntPtr]::Zero
$script:lastForegroundHandle = [IntPtr]::Zero
$script:lastForegroundContext = 'other'
$script:popupRequestedVisible = $false
function Assert-Visibility($expected, $label) {
  if ($window.IsVisible -ne $expected) { throw "Wrong visibility: $label" }
}

Show-Popup # Same entry point as -ShowOnStart and show-event requests at sign-in.
Assert-Visibility $false 'boot without Codex'
if ($window.ShowCount -ne 0 -or -not $script:popupRequestedVisible) { throw 'Boot must arm display without showing it' }
[OpenCodexFocusNative]::Foreground = [IntPtr]1
Update-PopupFocusVisibility
Assert-Visibility $true 'normal Codex window'
Update-PopupFocusVisibility
Assert-Visibility $true 'unchanged main-window focus'
[OpenCodexFocusNative]::Foreground = [IntPtr]2
Update-PopupFocusVisibility
Assert-Visibility $true 'interacting with usage controls'
[OpenCodexFocusNative]::Minimized = $true
Update-PopupFocusVisibility
Assert-Visibility $false 'underlying Codex minimized while usage has focus'
[OpenCodexFocusNative]::Foreground = [IntPtr]3
Show-Popup
Assert-Visibility $false 'Codex tray menu with main window minimized'
[OpenCodexFocusNative]::Minimized = $false
$script:mainHandle = [IntPtr]3
Show-Popup
Assert-Visibility $false 'menu incorrectly reported as process main window'
$script:mainHandle = [IntPtr]5
[OpenCodexFocusNative]::Foreground = [IntPtr]5
Show-Popup
Assert-Visibility $false 'custom Chrome_WidgetWin_1 tray menu reported as process main window'
$script:mainHandle = [IntPtr]1
[OpenCodexFocusNative]::Foreground = [IntPtr]1
Update-PopupFocusVisibility
Assert-Visibility $true 'Codex restored'
[OpenCodexFocusNative]::Visible = $false
Update-PopupFocusVisibility
Assert-Visibility $false 'same foreground handle hidden without cache invalidation'
[OpenCodexFocusNative]::Visible = $true
Update-PopupFocusVisibility
Assert-Visibility $true 'same handle visible again'
[OpenCodexFocusNative]::Foreground = [IntPtr]4
Show-Popup
Assert-Visibility $false 'show request outside Codex has no grace period'
Write-Output 'Codex-only visibility regression checks passed'
