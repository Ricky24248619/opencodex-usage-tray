param(
  [ValidateSet("Run", "Stop")]
  [string]$Mode = "Run",
  [switch]$ShowOnStart
)

$ErrorActionPreference = "Stop"

if ($Mode -eq "Stop") {
  $existingStopEvent = $null
  try {
    $existingStopEvent = [System.Threading.EventWaitHandle]::OpenExisting("Local\OpenCodexUsageTrayStop-v1")
    [void]$existingStopEvent.Set()
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    # No tray instance currently owns the stop event.
  } finally {
    if ($null -ne $existingStopEvent) { $existingStopEvent.Dispose() }
  }
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$focusTypeDefinition = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class OpenCodexPopupForm : Form {
  public bool ShowPassively { get; set; }
  protected override bool ShowWithoutActivation { get { return ShowPassively; } }
}

public sealed class OpenCodexIconButton : Button {
  protected override bool ShowFocusCues { get { return false; } }
}

public struct OpenCodexWindowRect {
  public int Left;
  public int Top;
  public int Right;
  public int Bottom;
}

public static class OpenCodexFocusNative {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool GetWindowRect(IntPtr window, out OpenCodexWindowRect rect);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool SetForegroundWindow(IntPtr window);
}
'@
Add-Type -TypeDefinition $focusTypeDefinition -ReferencedAssemblies "System.Windows.Forms.dll"

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$providerPath = Join-Path $scriptRoot "status-provider.mjs"

$stopEventCreated = $false
$stopEvent = [System.Threading.EventWaitHandle]::new(
  $false,
  [System.Threading.EventResetMode]::AutoReset,
  "Local\OpenCodexUsageTrayStop-v1",
  [ref]$stopEventCreated
)
$showEventCreated = $false
$showEvent = [System.Threading.EventWaitHandle]::new(
  $false,
  [System.Threading.EventResetMode]::AutoReset,
  "Local\OpenCodexUsageTrayShow-v1",
  [ref]$showEventCreated
)

$createdNew = $false
$mutex = [System.Threading.Mutex]::new(
  $true,
  "Local\OpenCodexUsageTray-v1",
  [ref]$createdNew
)
if (-not $createdNew) {
  if ($ShowOnStart) { [void]$showEvent.Set() }
  $showEvent.Dispose()
  $stopEvent.Dispose()
  $mutex.Dispose()
  exit 0
}

$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $nodeCommand) { $nodeCommand = Get-Command node -ErrorAction Stop }
$nodePath = $nodeCommand.Source

function Get-CodexDarkTheme {
  $configPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\config.toml"
  try {
    if ([System.IO.File]::Exists($configPath)) {
      $configText = [System.IO.File]::ReadAllText($configPath)
      $themeMatch = [regex]::Match(
        $configText,
        '(?m)^\s*appearanceTheme\s*=\s*"(system|light|dark)"\s*(?:#.*)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      if ($themeMatch.Success) {
        $theme = $themeMatch.Groups[1].Value.ToLowerInvariant()
        if ($theme -eq "light") { return $false }
        if ($theme -eq "dark") { return $true }
      }
    }
  } catch { }

  # Codex's "system" appearance follows the Windows application theme.
  try {
    $personalize = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
    return [int]$personalize.AppsUseLightTheme -eq 0
  } catch {
    return $false
  }
}

function Get-ThemePalette {
  param([bool]$Dark)
  if ($Dark) {
    return @{
      Background = [System.Drawing.Color]::FromArgb(18, 18, 20)
      Surface = [System.Drawing.Color]::FromArgb(28, 28, 31)
      SurfaceRaised = [System.Drawing.Color]::FromArgb(37, 37, 41)
      Text = [System.Drawing.Color]::FromArgb(244, 244, 246)
      RowText = [System.Drawing.Color]::FromArgb(224, 224, 228)
      Muted = [System.Drawing.Color]::FromArgb(161, 161, 170)
      Dim = [System.Drawing.Color]::FromArgb(113, 113, 122)
      Accent = [System.Drawing.Color]::FromArgb(121, 167, 255)
      Green = [System.Drawing.Color]::FromArgb(72, 199, 142)
      Amber = [System.Drawing.Color]::FromArgb(240, 170, 69)
      Red = [System.Drawing.Color]::FromArgb(239, 115, 115)
      Track = [System.Drawing.Color]::FromArgb(50, 50, 55)
      Hover = [System.Drawing.Color]::FromArgb(48, 48, 53)
      Pressed = [System.Drawing.Color]::FromArgb(56, 56, 62)
      ActiveButton = [System.Drawing.Color]::FromArgb(48, 55, 68)
      ActiveSurface = [System.Drawing.Color]::FromArgb(31, 35, 43)
    }
  }
  return @{
    Background = [System.Drawing.Color]::FromArgb(248, 248, 249)
    Surface = [System.Drawing.Color]::FromArgb(255, 255, 255)
    SurfaceRaised = [System.Drawing.Color]::FromArgb(245, 245, 244)
    Text = [System.Drawing.Color]::FromArgb(31, 31, 33)
    RowText = [System.Drawing.Color]::FromArgb(55, 55, 58)
    Muted = [System.Drawing.Color]::FromArgb(100, 100, 106)
    Dim = [System.Drawing.Color]::FromArgb(126, 126, 132)
    Accent = [System.Drawing.Color]::FromArgb(54, 99, 205)
    Green = [System.Drawing.Color]::FromArgb(23, 135, 82)
    Amber = [System.Drawing.Color]::FromArgb(181, 102, 0)
    Red = [System.Drawing.Color]::FromArgb(198, 57, 57)
    Track = [System.Drawing.Color]::FromArgb(222, 222, 225)
    Hover = [System.Drawing.Color]::FromArgb(239, 239, 238)
    Pressed = [System.Drawing.Color]::FromArgb(229, 229, 228)
    ActiveButton = [System.Drawing.Color]::FromArgb(225, 231, 243)
    ActiveSurface = [System.Drawing.Color]::FromArgb(246, 248, 251)
  }
}

$script:isDarkTheme = Get-CodexDarkTheme
$script:colors = Get-ThemePalette $script:isDarkTheme

$script:ownedFonts = [System.Collections.Generic.List[System.Drawing.Font]]::new()
function New-UiFont {
  param(
    [float]$Size,
    [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
  )
  $font = [System.Drawing.Font]::new("Segoe UI", $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
  [void]$script:ownedFonts.Add($font)
  return $font
}

$fontTitle = New-UiFont 11.5 ([System.Drawing.FontStyle]::Bold)
$fontHeading = New-UiFont 7.6 ([System.Drawing.FontStyle]::Bold)
$fontBody = New-UiFont 8.6
$fontBodyBold = New-UiFont 8.6 ([System.Drawing.FontStyle]::Bold)
$fontSmall = New-UiFont 8.0
$fontSmallBold = New-UiFont 8.0 ([System.Drawing.FontStyle]::Bold)
$fontMetric = New-UiFont 12.3 ([System.Drawing.FontStyle]::Bold)
$fontButton = New-UiFont 8.0 ([System.Drawing.FontStyle]::Bold)
$fontIcon = New-UiFont 10.0

function New-Label {
  param(
    [System.Windows.Forms.Control]$Parent,
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height,
    [System.Drawing.Font]$Font = $fontBody,
    [System.Drawing.Color]$Color = $script:colors.Text,
    [System.Drawing.ContentAlignment]$Alignment = [System.Drawing.ContentAlignment]::MiddleLeft
  )
  $label = [System.Windows.Forms.Label]::new()
  $label.Text = $Text
  $label.Location = [System.Drawing.Point]::new($X, $Y)
  $label.Size = [System.Drawing.Size]::new($Width, $Height)
  $label.Font = $Font
  $label.ForeColor = $Color
  $label.BackColor = [System.Drawing.Color]::Transparent
  $label.TextAlign = $Alignment
  $label.AutoEllipsis = $true
  [void]$Parent.Controls.Add($label)
  return $label
}

function New-FlatButton {
  param(
    [System.Windows.Forms.Control]$Parent,
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height,
    [switch]$Icon
  )
  $button = if ($Icon) { [OpenCodexIconButton]::new() } else { [System.Windows.Forms.Button]::new() }
  $button.Text = $Text
  $button.Location = [System.Drawing.Point]::new($X, $Y)
  $button.Size = [System.Drawing.Size]::new($Width, $Height)
  $button.Font = $fontButton
  $button.ForeColor = $script:colors.Muted
  $button.BackColor = $script:colors.SurfaceRaised
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 0
  $button.FlatAppearance.MouseOverBackColor = $script:colors.Hover
  $button.FlatAppearance.MouseDownBackColor = $script:colors.Pressed
  $button.UseVisualStyleBackColor = $false
  $button.Cursor = [System.Windows.Forms.Cursors]::Hand
  [void]$Parent.Controls.Add($button)
  return $button
}

function Format-CompactNumber {
  param([double]$Value)
  if ($Value -ge 1000000000) { return "{0:0.#}B" -f ($Value / 1000000000) }
  if ($Value -ge 1000000) { return "{0:0.#}M" -f ($Value / 1000000) }
  if ($Value -ge 1000) { return "{0:0.#}K" -f ($Value / 1000) }
  return "{0:N0}" -f $Value
}

function Format-Percent {
  param($Value)
  if ($null -eq $Value) { return "--" }
  return "{0:0}%" -f [double]$Value
}

function Get-QuotaColor {
  param($Value)
  if ($null -eq $Value) { return $script:colors.Dim }
  $percent = [double]$Value
  if ($percent -ge 90) { return $script:colors.Red }
  if ($percent -ge 75) { return $script:colors.Amber }
  return $script:colors.Green
}

function Format-Elapsed {
  param($Milliseconds)
  if ($null -eq $Milliseconds) { return "" }
  $seconds = [Math]::Max(0, [Math]::Floor([double]$Milliseconds / 1000))
  if ($seconds -lt 60) { return "${seconds}s" }
  $minutes = [Math]::Floor($seconds / 60)
  if ($minutes -lt 60) { return "${minutes}m" }
  $hours = [Math]::Floor($minutes / 60)
  if ($hours -lt 24) { return "${hours}h" }
  return "$([Math]::Floor($hours / 24))d"
}

function Set-Meter {
  param(
    [System.Windows.Forms.Panel]$Track,
    [System.Windows.Forms.Panel]$Fill,
    $Value
  )
  $percent = if ($null -eq $Value) { 0 } else { [Math]::Max(0, [Math]::Min(100, [double]$Value)) }
  $Fill.BackColor = Get-QuotaColor $Value
  $Fill.Width = [Math]::Max(0, [int][Math]::Round($Track.ClientSize.Width * $percent / 100))
}

function Set-CompactTaskCount {
  param([int]$Count)
  $visibleRows = [Math]::Max(1, [Math]::Min(3, $Count))
  $targetHeight = 333 + (23 * ($visibleRows - 1))
  if ($form.ClientSize.Height -eq $targetHeight) { return }
  $form.ClientSize = [System.Drawing.Size]::new(364, $targetHeight)
  if ($form.Visible) { Position-Popup -AnchorWindow $script:lastCodexWindowHandle }
}

$form = [OpenCodexPopupForm]::new()
$form.Text = "OpenCodex Usage"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor = $script:colors.Background
$form.ForeColor = $script:colors.Text
$form.ClientSize = [System.Drawing.Size]::new(364, 333)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Opacity = if ([System.Windows.Forms.SystemInformation]::HighContrast) { 1.0 } else { 0.96 }
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true

$usageIconPath = Join-Path $scriptRoot "OpenCodexUsage.ico"
$onlineIconPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".opencodex\opencodex-tray-online.ico"
$warningIconPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".opencodex\opencodex-tray-warning.ico"
$script:ownedIcons = [System.Collections.Generic.List[System.Drawing.Icon]]::new()
function Get-AppIcon {
  param([string]$Path, [System.Drawing.Icon]$Fallback)
  if ([System.IO.File]::Exists($Path)) {
    try {
      $icon = [System.Drawing.Icon]::new($Path)
      [void]$script:ownedIcons.Add($icon)
      return $icon
    } catch { }
  }
  return $Fallback
}
$onlineIcon = Get-AppIcon $usageIconPath (Get-AppIcon $onlineIconPath ([System.Drawing.SystemIcons]::Information))
$warningIcon = Get-AppIcon $warningIconPath ([System.Drawing.SystemIcons]::Warning)
$form.Icon = $onlineIcon

$titleLabel = New-Label $form "Usage" 12 5 140 19 $fontTitle
$connectionLabel = New-Label $form "Loading local usage..." 12 23 250 14 $fontSmall $script:colors.Muted

$dashboardButton = New-FlatButton $form ([string][char]0x2197) 278 8 20 20 -Icon
$dashboardButton.Font = $fontIcon
$dashboardButton.AccessibleName = "Open full OpenCodex dashboard"
$toolTip = [System.Windows.Forms.ToolTip]::new()
$toolTip.SetToolTip($dashboardButton, "Open full OpenCodex dashboard")

$refreshButton = New-FlatButton $form ([string][char]0x21BB) 306 8 20 20 -Icon
$refreshButton.Font = $fontIcon
$refreshButton.AccessibleName = "Refresh usage"
$toolTip.SetToolTip($refreshButton, "Refresh quotas and task status")

$closeButton = New-FlatButton $form ([string][char]0x00D7) 334 8 20 20 -Icon
$closeButton.Font = $fontIcon
$closeButton.AccessibleName = "Hide popup"
$toolTip.SetToolTip($closeButton, "Hide")

foreach ($headerButton in @($dashboardButton, $refreshButton, $closeButton)) {
  $headerButton.BackColor = $script:colors.Background
  $headerButton.TabStop = $false
  $headerButton.Padding = [System.Windows.Forms.Padding]::Empty
  $headerButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
}

$switchPanel = [System.Windows.Forms.Panel]::new()
$switchPanel.Location = [System.Drawing.Point]::new(10, 44)
$switchPanel.Size = [System.Drawing.Size]::new(344, 30)
$switchPanel.BackColor = $script:colors.SurfaceRaised
[void]$form.Controls.Add($switchPanel)

$script:switchButtons = @()
for ($index = 0; $index -lt 3; $index++) {
  $button = New-FlatButton $switchPanel "--" (2 + ($index * 114)) 2 112 26 -Icon
  $button.Visible = $false
  $button.add_Click({
    param($sender, $eventArgs)
    $accountId = [string]$sender.Tag
    if ([string]::IsNullOrWhiteSpace($accountId)) { return }
    if ($script:lastData -and [string]$script:lastData.activeAccountId -eq $accountId) { return }
    Start-ProviderRequest -Operation "switch" -AccountId $accountId
  })
  $script:switchButtons += $button
}

$summaryPanel = [System.Windows.Forms.Panel]::new()
$summaryPanel.Location = [System.Drawing.Point]::new(10, 80)
$summaryPanel.Size = [System.Drawing.Size]::new(344, 24)
$summaryPanel.BackColor = $script:colors.Background
[void]$form.Controls.Add($summaryPanel)

$script:metricValues = @()
$metricNames = @("Running tasks", "Tokens used in 7 days", "Requests in 7 days")
for ($index = 0; $index -lt 3; $index++) {
  $x = if ($index -eq 0) { 0 } elseif ($index -eq 1) { 114 } else { 229 }
  if ($index -gt 0) {
    $divider = [System.Windows.Forms.Panel]::new()
    $divider.Location = [System.Drawing.Point]::new($x, 4)
    $divider.Size = [System.Drawing.Size]::new(1, 16)
    $divider.BackColor = $script:colors.Track
    [void]$summaryPanel.Controls.Add($divider)
  }
  $width = if ($index -eq 0) { 114 } else { 115 }
  $value = New-Label $summaryPanel "--" ($x + 4) 1 ($width - 8) 22 $fontSmallBold $script:colors.Text ([System.Drawing.ContentAlignment]::MiddleCenter)
  $toolTip.SetToolTip($value, $metricNames[$index])
  $script:metricValues += $value
}

$quotaCaption = New-Label $form "Usage" 12 109 330 14 $fontHeading $script:colors.Dim

$script:accountRows = @()
for ($index = 0; $index -lt 3; $index++) {
  $row = [System.Windows.Forms.Panel]::new()
  $row.Location = [System.Drawing.Point]::new(10, (126 + ($index * 52)))
  $row.Size = [System.Drawing.Size]::new(344, 50)
  $row.BackColor = $script:colors.Background
  $row.Visible = $false
  [void]$form.Controls.Add($row)

  $indicator = [System.Windows.Forms.Panel]::new()
  $indicator.Location = [System.Drawing.Point]::new(0, 0)
  $indicator.Size = [System.Drawing.Size]::new(2, 50)
  $indicator.BackColor = $script:colors.Accent
  $indicator.Visible = $false
  [void]$row.Controls.Add($indicator)

  $name = New-Label $row "--" 10 2 90 15 $fontBodyBold
  $plan = New-Label $row "--" 10 16 90 12 $fontSmall $script:colors.Muted
  $tokens = New-Label $row "--" 10 30 90 14 $fontSmall $script:colors.Muted

  $fiveName = New-Label $row "5h" 106 2 42 14 $fontSmall $script:colors.Muted
  $fiveValue = New-Label $row "--" 272 1 59 15 $fontSmallBold $script:colors.Text ([System.Drawing.ContentAlignment]::MiddleRight)
  $fiveTrack = [System.Windows.Forms.Panel]::new()
  $fiveTrack.Location = [System.Drawing.Point]::new(150, 8)
  $fiveTrack.Size = [System.Drawing.Size]::new(116, 4)
  $fiveTrack.BackColor = $script:colors.Track
  [void]$row.Controls.Add($fiveTrack)
  $fiveFill = [System.Windows.Forms.Panel]::new()
  $fiveFill.Location = [System.Drawing.Point]::new(0, 0)
  $fiveFill.Size = [System.Drawing.Size]::new(0, 4)
  $fiveFill.BackColor = $script:colors.Dim
  [void]$fiveTrack.Controls.Add($fiveFill)

  $weekName = New-Label $row "1w" 106 28 42 14 $fontSmall $script:colors.Muted
  $weekValue = New-Label $row "--" 272 27 59 15 $fontSmallBold $script:colors.Text ([System.Drawing.ContentAlignment]::MiddleRight)
  $weekTrack = [System.Windows.Forms.Panel]::new()
  $weekTrack.Location = [System.Drawing.Point]::new(150, 34)
  $weekTrack.Size = [System.Drawing.Size]::new(116, 4)
  $weekTrack.BackColor = $script:colors.Track
  [void]$row.Controls.Add($weekTrack)
  $weekFill = [System.Windows.Forms.Panel]::new()
  $weekFill.Location = [System.Drawing.Point]::new(0, 0)
  $weekFill.Size = [System.Drawing.Size]::new(0, 4)
  $weekFill.BackColor = $script:colors.Dim
  [void]$weekTrack.Controls.Add($weekFill)

  $script:accountRows += [pscustomobject]@{
    Panel = $row
    Indicator = $indicator
    Name = $name
    Plan = $plan
    Tokens = $tokens
    FiveValue = $fiveValue
    FiveTrack = $fiveTrack
    FiveFill = $fiveFill
    WeekValue = $weekValue
    WeekTrack = $weekTrack
    WeekFill = $weekFill
  }
}

$taskCaption = New-Label $form "Tasks" 12 286 330 14 $fontHeading $script:colors.Dim

$script:taskRows = @()
for ($index = 0; $index -lt 3; $index++) {
  $taskPanel = [System.Windows.Forms.Panel]::new()
  $taskPanel.Location = [System.Drawing.Point]::new(10, (303 + ($index * 23)))
  $taskPanel.Size = [System.Drawing.Size]::new(344, 22)
  $taskPanel.BackColor = $script:colors.Background
  $taskPanel.Visible = $false
  [void]$form.Controls.Add($taskPanel)

  $dot = [System.Windows.Forms.Panel]::new()
  $dot.Location = [System.Drawing.Point]::new(7, 9)
  $dot.Size = [System.Drawing.Size]::new(5, 5)
  $dot.BackColor = $script:colors.Dim
  [void]$taskPanel.Controls.Add($dot)
  $account = New-Label $taskPanel "--" 18 1 54 20 $fontSmallBold $script:colors.Muted
  $title = New-Label $taskPanel "--" 76 1 203 20 $fontSmall $script:colors.Text
  $tokens = New-Label $taskPanel "--" 283 1 54 20 $fontSmall $script:colors.Muted ([System.Drawing.ContentAlignment]::MiddleRight)
  $script:taskRows += [pscustomobject]@{
    Panel = $taskPanel
    Dot = $dot
    Account = $account
    Title = $title
    Tokens = $tokens
  }
}

$emptyTasksLabel = New-Label $form "No live or recent tasks" 10 303 344 22 $fontSmall $script:colors.Muted ([System.Drawing.ContentAlignment]::MiddleCenter)

$footerLabel = New-Label $form "" 0 0 1 1 $fontSmall $script:colors.Dim
$footerLabel.Visible = $false

$notify = [System.Windows.Forms.NotifyIcon]::new()
$notify.Icon = $onlineIcon
$notify.Text = "OpenCodex Usage: loading"
$notify.Visible = $true

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$showItem = $menu.Items.Add("Show usage")
$refreshItem = $menu.Items.Add("Refresh now")
$dashboardItem = $menu.Items.Add("Open OpenCodex dashboard")
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$startupItem = $menu.Items.Add("Starts with Windows")
$startupItem.Checked = $true
$startupItem.Enabled = $false
[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
$exitItem = $menu.Items.Add("Exit usage tray")
$notify.ContextMenuStrip = $menu

$script:pendingProcess = $null
$script:pendingStdout = $null
$script:pendingStderr = $null
$script:pendingRequest = $null
$script:pendingStartedAt = $null
$script:lastData = $null
$script:lastUpdatedAt = $null
$script:lastForcedRefreshAt = [DateTime]::MinValue
$script:lastShownAt = [DateTime]::MinValue
$script:isConnected = $false
$script:confirmedActiveLabel = $null
$script:exiting = $false
$script:popupRequestedVisible = $false
$script:autoHiddenForFocus = $false
$script:lastForegroundHandle = [IntPtr]::Zero
$script:lastForegroundContext = "other"
$script:lastCodexWindowHandle = [IntPtr]::Zero
$heartbeatPath = Join-Path $scriptRoot "tray-heartbeat.json"

function Set-ControlPalette {
  param(
    [System.Windows.Forms.Control]$Control,
    [hashtable]$OldPalette,
    [hashtable]$NewPalette
  )
  foreach ($key in @(
    "Background", "Surface", "SurfaceRaised", "Text", "RowText", "Muted", "Dim",
    "Accent", "Green", "Amber", "Red", "Track", "Hover", "Pressed",
    "ActiveButton", "ActiveSurface"
  )) {
    if ($Control.BackColor.ToArgb() -eq $OldPalette[$key].ToArgb()) {
      $Control.BackColor = $NewPalette[$key]
    }
    if ($Control.ForeColor.ToArgb() -eq $OldPalette[$key].ToArgb()) {
      $Control.ForeColor = $NewPalette[$key]
    }
  }
  if ($Control -is [System.Windows.Forms.Button]) {
    $Control.FlatAppearance.MouseOverBackColor = $NewPalette.Hover
    $Control.FlatAppearance.MouseDownBackColor = $NewPalette.Pressed
  }
  foreach ($child in $Control.Controls) {
    Set-ControlPalette -Control $child -OldPalette $OldPalette -NewPalette $NewPalette
  }
}

function Sync-CodexTheme {
  $darkTheme = Get-CodexDarkTheme
  if ($darkTheme -eq $script:isDarkTheme) { return }

  $oldPalette = $script:colors
  $newPalette = Get-ThemePalette $darkTheme
  Set-ControlPalette -Control $form -OldPalette $oldPalette -NewPalette $newPalette
  $script:colors = $newPalette
  $script:isDarkTheme = $darkTheme
  $form.BackColor = $newPalette.Background
  $form.ForeColor = $newPalette.Text

  if ($script:lastData) { Update-Interface $script:lastData }
}

function Get-CodexWindowHandle {
  foreach ($process in @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })) {
    try {
      if ([string]$process.Path -like "*\OpenAI.Codex_*") { return $process.MainWindowHandle }
    } catch { }
  }
  return [IntPtr]::Zero
}

function Get-ForegroundContext {
  $window = [OpenCodexFocusNative]::GetForegroundWindow()
  if ($window -eq $script:lastForegroundHandle) { return $script:lastForegroundContext }

  $context = "other"
  if ($window -ne [IntPtr]::Zero) {
    $foregroundProcessId = [uint32]0
    [void][OpenCodexFocusNative]::GetWindowThreadProcessId($window, [ref]$foregroundProcessId)
    if ($foregroundProcessId -eq [uint32]$PID) {
      $context = "popup"
    } else {
      try {
        $foregroundProcess = Get-Process -Id ([int]$foregroundProcessId) -ErrorAction Stop
        if (
          $foregroundProcess.ProcessName -eq "ChatGPT" -and
          [string]$foregroundProcess.Path -like "*\OpenAI.Codex_*"
        ) {
          $context = "codex"
          $script:lastCodexWindowHandle = $window
        }
      } catch { }
    }
  }

  $script:lastForegroundHandle = $window
  $script:lastForegroundContext = $context
  return $context
}

function Update-PopupFocusVisibility {
  $context = Get-ForegroundContext
  if (-not $script:popupRequestedVisible) { return }

  if ($context -eq "other") {
    if ($form.Visible) { Hide-Popup -ForFocus }
    return
  }
  if ($context -eq "codex") {
    if (-not $form.Visible) {
      Show-Popup -ForFocusRestore -AnchorWindow $script:lastForegroundHandle
    } else {
      Position-Popup -AnchorWindow $script:lastForegroundHandle
    }
  }
}

function Write-Heartbeat {
  try {
    $heartbeat = [ordered]@{
      pid = $PID
      updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      popupVisible = $form.Visible
      windowHandle = if ($form.IsHandleCreated) { $form.Handle.ToInt64() } else { 0 }
      theme = if ($script:isDarkTheme) { "dark" } else { "light" }
      opacity = $form.Opacity
      topMost = $form.TopMost
      requestedVisible = $script:popupRequestedVisible
      autoHiddenForFocus = $script:autoHiddenForFocus
      foregroundContext = $script:lastForegroundContext
      activeAccount = if (-not [string]::IsNullOrWhiteSpace($script:confirmedActiveLabel)) { $script:confirmedActiveLabel } elseif ($script:lastData) { [string]$script:lastData.activeAccountLabel } else { $null }
      runningTasks = if ($script:lastData) { [int]$script:lastData.counts.running } else { $null }
      connected = [bool]$script:isConnected
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($heartbeatPath, $heartbeat, [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

function Set-BusyState {
  param([bool]$Busy, [string]$Message = "")
  $refreshButton.Enabled = -not $Busy
  foreach ($button in $script:switchButtons) { $button.Enabled = -not $Busy }
  if ($Busy -and -not [string]::IsNullOrWhiteSpace($Message)) {
    $connectionLabel.Text = $Message
    $connectionLabel.ForeColor = $script:colors.Muted
  }
}

function ConvertTo-NativeArgument {
  param([string]$Value)
  if ($Value.Contains('"')) { throw "Invalid local process argument" }
  return '"' + $Value + '"'
}

function Start-ProviderRequest {
  param(
    [ValidateSet("status", "switch")]
    [string]$Operation,
    [string]$AccountId = "",
    [switch]$Force
  )
  if ($null -ne $script:pendingProcess) { return }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $nodePath
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $providerArguments = @($providerPath, $Operation)
  if ($Operation -eq "switch") {
    $providerArguments += $AccountId
  } elseif ($Force) {
    $providerArguments += "--refresh"
    $script:lastForcedRefreshAt = [DateTime]::Now
  }
  $psi.Arguments = (($providerArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join " ")

  try {
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "The local data provider did not start" }
    $script:pendingProcess = $process
    $script:pendingStdout = $process.StandardOutput.ReadToEndAsync()
    $script:pendingStderr = $process.StandardError.ReadToEndAsync()
    $script:pendingRequest = [pscustomobject]@{ Operation = $Operation; AccountId = $AccountId }
    $script:pendingStartedAt = [DateTime]::Now
    if ($Operation -eq "switch") {
      $targetButton = $script:switchButtons | Where-Object { [string]$_.Tag -eq $AccountId } | Select-Object -First 1
      $targetName = if ($null -ne $targetButton) { $targetButton.Text } else { "account" }
      Set-BusyState $true "Switching to $targetName..."
    } else {
      Set-BusyState $true "Refreshing local usage..."
    }
  } catch {
    $script:isConnected = $false
    Set-BusyState $false
    $connectionLabel.Text = "OpenCodex data unavailable"
    $connectionLabel.ForeColor = $script:colors.Red
    $footerLabel.Text = $_.Exception.Message
    $footerLabel.ForeColor = $script:colors.Red
    Write-Heartbeat
  }
}

function Update-Interface {
  param($Data)
  $script:lastData = $Data
  $script:lastUpdatedAt = [DateTime]::Now
  $script:isConnected = $true
  $accounts = @($Data.accounts)
  $activeAccount = $accounts | Where-Object { [bool]$_.active } | Select-Object -First 1
  $activeLabel = if ($null -ne $activeAccount -and -not [string]::IsNullOrWhiteSpace([string]$activeAccount.displayName)) {
    [string]$activeAccount.displayName
  } else {
    [string]$Data.activeAccountLabel
  }
  $script:confirmedActiveLabel = $activeLabel

  $runningCount = [int]$Data.counts.running
  $stalledCount = [int]$Data.counts.stalled
  $connectionLabel.Text = "$activeLabel active  |  $runningCount running"
  if ($stalledCount -gt 0) { $connectionLabel.Text += "  |  $stalledCount stalled" }
  $connectionLabel.ForeColor = $script:colors.Muted

  $script:metricValues[0].Text = "$runningCount running"
  $script:metricValues[0].ForeColor = if ($runningCount -gt 0) { $script:colors.Green } else { $script:colors.Text }
  $script:metricValues[1].Text = "$(Format-CompactNumber ([double]$Data.totals.tokens7d)) tokens"
  $script:metricValues[2].Text = "$(Format-CompactNumber ([double]$Data.totals.requests7d)) requests"

  for ($index = 0; $index -lt 3; $index++) {
    $button = $script:switchButtons[$index]
    $row = $script:accountRows[$index]
    if ($index -ge $accounts.Count) {
      $button.Visible = $false
      $row.Panel.Visible = $false
      continue
    }

    $accountData = $accounts[$index]
    $isActive = [bool]$accountData.active
    $displayName = [string]$accountData.displayName
    $button.Text = $displayName
    $button.Tag = [string]$accountData.id
    $button.Visible = $true
    $button.ForeColor = if ($isActive) { $script:colors.Text } else { $script:colors.Muted }
    $button.BackColor = if ($isActive) { $script:colors.ActiveButton } else { $script:colors.SurfaceRaised }
    $toolTip.SetToolTip($button, "$($accountData.email)  |  $($accountData.plan)")

    $row.Panel.Visible = $true
    $row.Panel.BackColor = if ($isActive) { $script:colors.ActiveSurface } else { $script:colors.Background }
    $row.Indicator.Visible = $isActive
    $row.Name.Text = $displayName
    $row.Name.ForeColor = if ($isActive) { $script:colors.Text } else { $script:colors.RowText }
    $row.Plan.Text = ([string]$accountData.plan).ToLowerInvariant()
    $taskText = if ([int]$accountData.runningTasks -eq 1) { "1 live" } else { "$([int]$accountData.runningTasks) live" }
    $row.Tokens.Text = "$(Format-CompactNumber ([double]$accountData.tokens7d))  |  $taskText"
    $row.FiveValue.Text = Format-Percent $accountData.fiveHour.usedPercent
    $row.FiveValue.ForeColor = Get-QuotaColor $accountData.fiveHour.usedPercent
    Set-Meter $row.FiveTrack $row.FiveFill $accountData.fiveHour.usedPercent
    $row.WeekValue.Text = Format-Percent $accountData.week.usedPercent
    $row.WeekValue.ForeColor = Get-QuotaColor $accountData.week.usedPercent
    Set-Meter $row.WeekTrack $row.WeekFill $accountData.week.usedPercent
  }

  $tasks = @($Data.tasks) | Select-Object -First 3
  $emptyTasksLabel.Visible = $tasks.Count -eq 0
  for ($index = 0; $index -lt 3; $index++) {
    $taskRow = $script:taskRows[$index]
    if ($index -ge $tasks.Count) {
      $taskRow.Panel.Visible = $false
      continue
    }
    $task = $tasks[$index]
    $status = ([string]$task.status).ToLowerInvariant()
    $taskRow.Panel.Visible = $true
    $taskRow.Dot.BackColor = switch ($status) {
      "running" { $script:colors.Green }
      "stalled" { $script:colors.Amber }
      "failed" { $script:colors.Red }
      default { $script:colors.Dim }
    }
    $taskRow.Account.Text = ([string]$task.accountLabel).ToUpperInvariant()
    $taskRow.Account.ForeColor = if ($status -eq "running") { $script:colors.Green } elseif ($status -eq "stalled") { $script:colors.Amber } else { $script:colors.Muted }
    $elapsed = Format-Elapsed $task.durationMs
    $taskRow.Title.Text = if ([string]::IsNullOrWhiteSpace($elapsed)) { [string]$task.title } else { "$($task.title)  |  $elapsed" }
    $toolTip.SetToolTip($taskRow.Title, $taskRow.Title.Text)
    $taskRow.Tokens.Text = Format-CompactNumber ([double]$task.tokensUsed)
    $toolTip.SetToolTip($taskRow.Tokens, "$(Format-CompactNumber ([double]$task.tokensUsed)) tokens")
  }
  Set-CompactTaskCount $tasks.Count

  $footerLabel.Text = "Updated just now  |  local only"
  $footerLabel.ForeColor = $script:colors.Dim
  $fiveHourText = if ($null -ne $activeAccount) { Format-Percent $activeAccount.fiveHour.usedPercent } else { "--" }
  $toolText = "OpenCodex: $activeLabel | 5h $fiveHourText | $runningCount running"
  if ($toolText.Length -gt 63) { $toolText = $toolText.Substring(0, 63) }
  $notify.Text = $toolText
  $notify.Icon = $onlineIcon
  Write-Heartbeat
}

function Show-ConfirmedSwitchWithoutStatus {
  param($Data)
  $accountId = [string]$Data.activeAccountId
  $activeAccount = @($Data.accounts) | Where-Object { [bool]$_.active } | Select-Object -First 1
  $accountLabel = if ($null -ne $activeAccount -and -not [string]::IsNullOrWhiteSpace([string]$activeAccount.displayName)) {
    [string]$activeAccount.displayName
  } else {
    [string]$Data.activeAccountLabel
  }
  $script:confirmedActiveLabel = $accountLabel
  $script:isConnected = $false
  for ($index = 0; $index -lt 3; $index++) {
    $button = $script:switchButtons[$index]
    $row = $script:accountRows[$index]
    $isActive = [string]$button.Tag -eq $accountId
    if ($button.Visible) {
      $button.ForeColor = if ($isActive) { $script:colors.Text } else { $script:colors.Muted }
      $button.BackColor = if ($isActive) { $script:colors.ActiveButton } else { $script:colors.SurfaceRaised }
    }
    if ($row.Panel.Visible) {
      $row.Panel.BackColor = if ($isActive) { $script:colors.ActiveSurface } else { $script:colors.Background }
      $row.Indicator.Visible = $isActive
    }
  }
  $connectionLabel.Text = "$accountLabel active  |  usage refresh pending"
  $connectionLabel.ForeColor = $script:colors.Amber
  $footerLabel.Text = "Account switched; usage will retry automatically"
  $footerLabel.ForeColor = $script:colors.Amber
  $notify.Icon = $warningIcon
  $notify.Text = "OpenCodex: $accountLabel | usage refresh pending"
  Write-Heartbeat
}

function Complete-ProviderRequest {
  if ($null -eq $script:pendingProcess) { return }
  $process = $script:pendingProcess
  $request = $script:pendingRequest
  $timedOut = ([DateTime]::Now - $script:pendingStartedAt).TotalSeconds -gt 38
  if (-not $process.HasExited -and -not $timedOut) { return }

  if ($timedOut -and -not $process.HasExited) {
    try { $process.Kill() } catch { }
  }
  try { $process.WaitForExit(1500) } catch { }

  $stdout = ""
  $stderr = ""
  try { $stdout = $script:pendingStdout.GetAwaiter().GetResult() } catch { }
  try { $stderr = $script:pendingStderr.GetAwaiter().GetResult() } catch { }
  $exitCode = if ($process.HasExited) { $process.ExitCode } else { -1 }
  $process.Dispose()

  $script:pendingProcess = $null
  $script:pendingStdout = $null
  $script:pendingStderr = $null
  $script:pendingRequest = $null
  $script:pendingStartedAt = $null
  Set-BusyState $false

  if ($timedOut -or $exitCode -ne 0) {
    $script:isConnected = $false
    $message = if ($timedOut) { "OpenCodex refresh timed out" } elseif (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } else { "OpenCodex refresh failed" }
    $connectionLabel.Text = "OpenCodex data unavailable"
    $connectionLabel.ForeColor = $script:colors.Red
    $footerLabel.Text = $message
    $footerLabel.ForeColor = $script:colors.Red
    $notify.Icon = $warningIcon
    $notify.Text = "OpenCodex Usage: data unavailable"
    if ($request.Operation -eq "switch") {
      $notify.ShowBalloonTip(3500, "Account switch failed", $message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
    Write-Heartbeat
    return
  }

  try {
    $data = $stdout | ConvertFrom-Json
    if ($request.Operation -eq "switch") {
      if (-not [bool]$data.switchConfirmed) { throw "The account switch was not confirmed" }
      if ([bool]$data.connected) { Update-Interface $data }
      else { Show-ConfirmedSwitchWithoutStatus $data }
      $balloonText = "Now using $($data.activeAccountLabel)."
      if (-not [bool]$data.connected) { $balloonText += " Usage refresh will retry." }
      $notify.ShowBalloonTip(2200, "OpenCodex account switched", $balloonText, [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
      Update-Interface $data
    }
  } catch {
    $script:isConnected = $false
    $connectionLabel.Text = "OpenCodex data unavailable"
    $connectionLabel.ForeColor = $script:colors.Red
    $footerLabel.Text = "The local usage response could not be read"
    $footerLabel.ForeColor = $script:colors.Red
    $notify.Icon = $warningIcon
    Write-Heartbeat
  }
}

function Position-Popup {
  param([IntPtr]$AnchorWindow = [IntPtr]::Zero)
  if ($AnchorWindow -eq [IntPtr]::Zero) {
    $AnchorWindow = if ($script:lastCodexWindowHandle -ne [IntPtr]::Zero) {
      $script:lastCodexWindowHandle
    } else {
      Get-CodexWindowHandle
    }
  }
  $screen = if ($AnchorWindow -ne [IntPtr]::Zero) {
    [System.Windows.Forms.Screen]::FromHandle($AnchorWindow)
  } else {
    [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
  }
  $workingArea = $screen.WorkingArea
  $x = $workingArea.Right - $form.Width - 8
  $y = $workingArea.Bottom - $form.Height - 8

  if ($AnchorWindow -ne [IntPtr]::Zero) {
    $windowRect = [OpenCodexWindowRect]::new()
    $hasRect = [OpenCodexFocusNative]::GetWindowRect($AnchorWindow, [ref]$windowRect)
    if ($hasRect) {
      $leftInset = 286
      $rightReserve = 500
      $edgeGap = 12
      $preferredX = $windowRect.Left + $leftInset
      $browserSafeMaxX = $windowRect.Right - $rightReserve - $form.Width - $edgeGap
      $x = if ($browserSafeMaxX -ge ($windowRect.Left + $edgeGap)) {
        [Math]::Min($preferredX, $browserSafeMaxX)
      } else {
        $windowRect.Left + $edgeGap
      }
      $y = $windowRect.Bottom - $form.Height - $edgeGap
    }
  }

  $maxX = $workingArea.Right - $form.Width - 8
  $maxY = $workingArea.Bottom - $form.Height - 8
  $x = [Math]::Max($workingArea.Left + 8, [Math]::Min($x, $maxX))
  $y = [Math]::Max($workingArea.Top + 8, [Math]::Min($y, $maxY))
  $newLocation = [System.Drawing.Point]::new($x, $y)
  if ($form.Location -ne $newLocation) { $form.Location = $newLocation }
}

function Show-Popup {
  param(
    [switch]$ForFocusRestore,
    [IntPtr]$AnchorWindow = [IntPtr]::Zero
  )
  $script:popupRequestedVisible = $true
  $script:autoHiddenForFocus = $false
  Sync-CodexTheme
  Position-Popup -AnchorWindow $AnchorWindow
  $script:lastShownAt = [DateTime]::Now
  $form.ShowPassively = [bool]$ForFocusRestore
  try {
    $form.Show()
    if ($ForFocusRestore -and $AnchorWindow -ne [IntPtr]::Zero) {
      [void][OpenCodexFocusNative]::SetForegroundWindow($AnchorWindow)
    } else {
      $form.TopMost = $true
      $form.BringToFront()
      $form.Activate()
    }
    $form.ActiveControl = $null
  } finally {
    $form.ShowPassively = $false
  }
  $showItem.Text = "Hide usage"
  Write-Heartbeat
}

function Hide-Popup {
  param([switch]$ForFocus)
  $form.Hide()
  if ($ForFocus) {
    $script:autoHiddenForFocus = $true
    $showItem.Text = "Hide usage"
  } else {
    $script:popupRequestedVisible = $false
    $script:autoHiddenForFocus = $false
    $showItem.Text = "Show usage"
  }
  Write-Heartbeat
}

function Toggle-Popup {
  if ($script:popupRequestedVisible) { Hide-Popup } else { Show-Popup }
}

$openDashboard = {
  try {
    Start-Process "http://127.0.0.1:10100/" | Out-Null
  } catch { }
}

$refreshButton.add_Click({ Start-ProviderRequest -Operation "status" -Force })
$dashboardButton.add_Click($openDashboard)
$closeButton.add_Click({ Hide-Popup })
$form.add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Hide-Popup }
})
$form.add_Deactivate({ $form.ActiveControl = $null })
$form.add_FormClosing({
  param($sender, $eventArgs)
  if (-not $script:exiting) {
    $eventArgs.Cancel = $true
    Hide-Popup
  }
})

$notify.add_MouseClick({
  param($sender, $eventArgs)
  if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Popup }
})
$showItem.add_Click({ Toggle-Popup })
$refreshItem.add_Click({ Start-ProviderRequest -Operation "status" -Force })
$dashboardItem.add_Click($openDashboard)
$exitItem.add_Click({
  $script:exiting = $true
  [System.Windows.Forms.Application]::Exit()
})

$pollTimer = [System.Windows.Forms.Timer]::new()
$pollTimer.Interval = 250
$pollTimer.add_Tick({
  if ($showEvent.WaitOne(0)) { Show-Popup }
  if ($stopEvent.WaitOne(0)) {
    $script:exiting = $true
    [System.Windows.Forms.Application]::Exit()
    return
  }
  Update-PopupFocusVisibility
  Complete-ProviderRequest
  if ($null -ne $script:lastUpdatedAt -and $null -eq $script:pendingProcess) {
    $ageSeconds = [Math]::Floor(([DateTime]::Now - $script:lastUpdatedAt).TotalSeconds)
    if ($ageSeconds -ge 60) {
      $footerLabel.Text = "Updated $([Math]::Floor($ageSeconds / 60))m ago  |  local only"
    }
  }
})

$refreshTimer = [System.Windows.Forms.Timer]::new()
$refreshTimer.Interval = 30000
$refreshTimer.add_Tick({
  if ($null -ne $script:pendingProcess) { return }
  $force = ([DateTime]::Now - $script:lastForcedRefreshAt).TotalMinutes -ge 5
  if ($force) { Start-ProviderRequest -Operation "status" -Force }
  else { Start-ProviderRequest -Operation "status" }
})

$heartbeatTimer = [System.Windows.Forms.Timer]::new()
$heartbeatTimer.Interval = 5000
$heartbeatTimer.add_Tick({
  Sync-CodexTheme
  Write-Heartbeat
})

try {
  $pollTimer.Start()
  $refreshTimer.Start()
  $heartbeatTimer.Start()
  Write-Heartbeat
  Start-ProviderRequest -Operation "status" -Force
  if ($ShowOnStart) { Show-Popup }
  [System.Windows.Forms.Application]::Run()
} finally {
  $pollTimer.Stop()
  $refreshTimer.Stop()
  $heartbeatTimer.Stop()
  if ($null -ne $script:pendingProcess) {
    try {
      if (-not $script:pendingProcess.HasExited) { $script:pendingProcess.Kill() }
      $script:pendingProcess.Dispose()
    } catch { }
  }
  $notify.Visible = $false
  $notify.Dispose()
  $menu.Dispose()
  $toolTip.Dispose()
  $form.Dispose()
  foreach ($icon in $script:ownedIcons) { $icon.Dispose() }
  foreach ($font in $script:ownedFonts) { $font.Dispose() }
  $pollTimer.Dispose()
  $refreshTimer.Dispose()
  $heartbeatTimer.Dispose()
  try { Remove-Item -LiteralPath $heartbeatPath -Force -ErrorAction SilentlyContinue } catch { }
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
  $showEvent.Dispose()
  $stopEvent.Dispose()
}
