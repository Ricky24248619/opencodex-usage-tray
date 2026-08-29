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

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
  throw "OpenCodex Usage Tray must run in an STA PowerShell process. Use Windows PowerShell or add -STA."
}

$nativeTypeDefinition = @'
using System;
using System.Runtime.InteropServices;

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

  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr window);
}
'@
Add-Type -TypeDefinition $nativeTypeDefinition

[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$providerPath = Join-Path $scriptRoot "status-provider.mjs"
$settingsRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "OpenCodexUsageTray"
$settingsPath = Join-Path $settingsRoot "tray-settings.json"
$script:popupCorner = "BottomLeft"
try {
  if ([System.IO.File]::Exists($settingsPath)) {
    $savedSettings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    if (@("TopLeft", "BottomLeft") -contains [string]$savedSettings.popupCorner) {
      $script:popupCorner = [string]$savedSettings.popupCorner
    } elseif ([string]$savedSettings.popupCorner -eq "TopRight") {
      $script:popupCorner = "BottomLeft"
    }
  }
} catch { }

function Save-TraySettings {
  try {
    [void][System.IO.Directory]::CreateDirectory($settingsRoot)
    $settingsJson = [ordered]@{ popupCorner = $script:popupCorner } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($settingsPath, $settingsJson, [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

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

  try {
    $personalize = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction Stop
    return [int]$personalize.AppsUseLightTheme -eq 0
  } catch {
    return $false
  }
}

function Get-ThemePalette {
  param([bool]$Dark)

  $highContrast = [System.Windows.SystemParameters]::HighContrast
  if ($highContrast) {
    return @{
      Root = if ($Dark) { "#FF111111" } else { "#FFFFFFFF" }
      Card = if ($Dark) { "#FF1A1A1A" } else { "#FFFFFFFF" }
      Segment = if ($Dark) { "#FF242424" } else { "#FFF1F1F1" }
      ActiveSurface = if ($Dark) { "#FF222A31" } else { "#FFEFF5F7" }
      ActiveButton = if ($Dark) { "#FF303B45" } else { "#FFE4EEF1" }
      Text = if ($Dark) { "#FFFFFFFF" } else { "#FF000000" }
      RowText = if ($Dark) { "#FFF1F1F1" } else { "#FF202020" }
      Muted = if ($Dark) { "#FFD0D0D0" } else { "#FF505050" }
      Dim = if ($Dark) { "#FFAAAAAA" } else { "#FF686868" }
      Border = if ($Dark) { "#FFFFFFFF" } else { "#FF000000" }
      Track = if ($Dark) { "#FF555555" } else { "#FFCCCCCC" }
      Hover = if ($Dark) { "#FF3B3B3B" } else { "#FFE5E5E5" }
      Pressed = if ($Dark) { "#FF4A4A4A" } else { "#FFD7D7D7" }
      Accent = "#FF5EA9B5"
      Green = "#FF42B883"
      Amber = "#FFF1A340"
      Red = "#FFEB6B6B"
    }
  }

  if ($Dark) {
    return @{
      Root = "#E6111111"
      Card = "#00000000"
      Segment = "#FF1A1A1A"
      ActiveSurface = "#FF1D1D1D"
      ActiveButton = "#FF212121"
      Text = "#FFFCFCFC"
      RowText = "#FFDFDFDF"
      Muted = "#FFAAAAAA"
      Dim = "#FF888888"
      Border = "#FF242424"
      Track = "#FF303030"
      Hover = "#FF222222"
      Pressed = "#FF292929"
      Accent = "#FF0169CC"
      Green = "#FF48C78E"
      Amber = "#FFF0AA45"
      Red = "#FFEF7373"
    }
  }

  return @{
    Root = "#E6F9F9F7"
    Card = "#00000000"
    Segment = "#FFEEEEEC"
    ActiveSurface = "#FFEEEEEC"
    ActiveButton = "#FFE6E6E4"
    Text = "#FF2D2D2B"
    RowText = "#FF2D2D2B"
    Muted = "#FF757573"
    Dim = "#FF8F8F8D"
    Border = "#FFE9E9E7"
    Track = "#FFE1E1DF"
    Hover = "#FFE6E6E4"
    Pressed = "#FFD9D9D6"
    Accent = "#FF0D6ECA"
    Green = "#FF238A5B"
    Amber = "#FFB76A08"
    Red = "#FFC73D3D"
  }
}

function New-WpfBrush {
  param([string]$Color)
  $mediaColor = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
  $brush = [System.Windows.Media.SolidColorBrush]::new($mediaColor)
  $brush.Freeze()
  return $brush
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

function Format-ResetCountdown {
  param($UnixMilliseconds)
  if ($null -eq $UnixMilliseconds) { return "reset unknown" }
  try {
    $resetTime = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$UnixMilliseconds)
    $remaining = $resetTime - [DateTimeOffset]::UtcNow
    if ($remaining.TotalSeconds -le 0) { return "resetting" }
    if ($remaining.TotalDays -ge 1) { return "resets $([Math]::Floor($remaining.TotalDays))d $($remaining.Hours)h" }
    if ($remaining.TotalHours -ge 1) { return "resets $([Math]::Floor($remaining.TotalHours))h $($remaining.Minutes)m" }
    if ($remaining.TotalMinutes -ge 1) { return "resets $([Math]::Floor($remaining.TotalMinutes))m" }
    return "resets <1m"
  } catch {
    return "reset unknown"
  }
}

function Get-QuotaBrush {
  param($Value)
  if ($null -eq $Value) { return $window.Resources["DimBrush"] }
  $percent = [double]$Value
  if ($percent -ge 90) { return $window.Resources["RedBrush"] }
  if ($percent -ge 75) { return $window.Resources["AmberBrush"] }
  return $window.Resources["GreenBrush"]
}

function Set-QuotaMeter {
  param(
    $Meter,
    $Fill,
    $FillColumn,
    $EmptyColumn,
    $Value,
    [string]$ToolTip
  )
  $percent = if ($null -eq $Value) { 0.0 } else { [Math]::Max(0.0, [Math]::Min(100.0, [double]$Value)) }
  $FillColumn.Width = [System.Windows.GridLength]::new($percent, [System.Windows.GridUnitType]::Star)
  $EmptyColumn.Width = [System.Windows.GridLength]::new(100.0 - $percent, [System.Windows.GridUnitType]::Star)
  $Fill.Background = Get-QuotaBrush $Value
  $Meter.ToolTip = $ToolTip
}

$xaml = @'
<Window
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  x:Name="PopupWindow"
  Title="OpenCodex Usage"
  Width="316"
  SizeToContent="Height"
  MaxHeight="520"
  WindowStyle="None"
  ResizeMode="NoResize"
  AllowsTransparency="True"
  Background="Transparent"
  Opacity="1"
  ShowInTaskbar="False"
  ShowActivated="False"
  Topmost="True"
  WindowStartupLocation="Manual"
  Left="-10000"
  Top="-10000"
  FontFamily="Segoe UI Variable Text, Segoe UI"
  TextOptions.TextFormattingMode="Display"
  SnapsToDevicePixels="True"
  UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="RootBrush" Color="#E6F9F9F7" />
    <SolidColorBrush x:Key="CardBrush" Color="#00000000" />
    <SolidColorBrush x:Key="SegmentBrush" Color="#FFEEEEEC" />
    <SolidColorBrush x:Key="ActiveSurfaceBrush" Color="#FFEEEEEC" />
    <SolidColorBrush x:Key="ActiveButtonBrush" Color="#FFE6E6E4" />
    <SolidColorBrush x:Key="TextBrush" Color="#FF2D2D2B" />
    <SolidColorBrush x:Key="RowTextBrush" Color="#FF2D2D2B" />
    <SolidColorBrush x:Key="MutedBrush" Color="#FF757573" />
    <SolidColorBrush x:Key="DimBrush" Color="#FF8F8F8D" />
    <SolidColorBrush x:Key="BorderBrush" Color="#FFE9E9E7" />
    <SolidColorBrush x:Key="TrackBrush" Color="#FFE1E1DF" />
    <SolidColorBrush x:Key="HoverBrush" Color="#FFE6E6E4" />
    <SolidColorBrush x:Key="PressedBrush" Color="#FFD9D9D6" />
    <SolidColorBrush x:Key="AccentBrush" Color="#FF0D6ECA" />
    <SolidColorBrush x:Key="GreenBrush" Color="#FF238A5B" />
    <SolidColorBrush x:Key="AmberBrush" Color="#FFB76A08" />
    <SolidColorBrush x:Key="RedBrush" Color="#FFC73D3D" />

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
      <Setter Property="FontSize" Value="12" />
      <Setter Property="VerticalAlignment" Value="Center" />
    </Style>

    <Style x:Key="IconButtonStyle" TargetType="Button">
      <Setter Property="Width" Value="26" />
      <Setter Property="Height" Value="26" />
      <Setter Property="Margin" Value="1,0,0,0" />
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="FontFamily" Value="Segoe UI Symbol" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="Focusable" Value="False" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource HoverBrush}" />
                <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource PressedBrush}" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SegmentButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="28" />
      <Setter Property="Margin" Value="2" />
      <Setter Property="Padding" Value="4,0" />
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}" />
      <Setter Property="Background" Value="{DynamicResource SegmentBrush}" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="FontSize" Value="11.5" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Focusable" Value="False" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource HoverBrush}" />
                <Setter Property="Foreground" Value="{DynamicResource TextBrush}" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource PressedBrush}" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccountCardStyle" TargetType="Border">
      <Setter Property="Height" Value="66" />
      <Setter Property="Padding" Value="8,5" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}" />
      <Setter Property="BorderThickness" Value="0,0,0,1" />
      <Setter Property="CornerRadius" Value="4" />
    </Style>
  </Window.Resources>

  <Border x:Name="RootSurface" Background="{DynamicResource RootBrush}" BorderThickness="0" CornerRadius="8" Padding="8">
    <Grid>
      <Grid x:Name="CompactPanel" Height="46">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="14" />
          <ColumnDefinition Width="72" />
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="7" />
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="24" />
          <ColumnDefinition Width="24" />
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="CompactConnectionDot" Grid.Column="0" Width="7" Height="7" HorizontalAlignment="Left" Fill="{DynamicResource DimBrush}" />
        <StackPanel Grid.Column="1" Margin="0,0,5,0" VerticalAlignment="Center">
          <TextBlock x:Name="CompactAccount" Text="Loading" FontSize="12.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="CompactMeta" Text="active account" FontSize="9.5" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
        </StackPanel>
        <Grid Grid.Column="2" VerticalAlignment="Center">
          <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="7" /></Grid.RowDefinitions>
          <Grid Grid.Row="0"><TextBlock Text="5-hour" FontSize="9.5" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="CompactFiveValue" Text="--" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
          <Grid x:Name="CompactFiveBar" Grid.Row="1" Height="4" ClipToBounds="True">
            <Grid.ColumnDefinitions><ColumnDefinition x:Name="CompactFiveFillColumn" Width="0*" /><ColumnDefinition x:Name="CompactFiveEmptyColumn" Width="100*" /></Grid.ColumnDefinitions>
            <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="2" />
            <Border x:Name="CompactFiveFill" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="2" />
          </Grid>
        </Grid>
        <Border Grid.Column="3" Width="1" Height="28" HorizontalAlignment="Center" Background="{DynamicResource BorderBrush}" />
        <Grid Grid.Column="4" VerticalAlignment="Center">
          <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="7" /></Grid.RowDefinitions>
          <Grid Grid.Row="0"><TextBlock Text="Weekly" FontSize="9.5" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="CompactWeekValue" Text="--" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
          <Grid x:Name="CompactWeekBar" Grid.Row="1" Height="4" ClipToBounds="True">
            <Grid.ColumnDefinitions><ColumnDefinition x:Name="CompactWeekFillColumn" Width="0*" /><ColumnDefinition x:Name="CompactWeekEmptyColumn" Width="100*" /></Grid.ColumnDefinitions>
            <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="2" />
            <Border x:Name="CompactWeekFill" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="2" />
          </Grid>
        </Grid>
        <Button x:Name="CompactDashboardButton" Grid.Column="5" Content="&#x2197;" Width="24" Height="24" Style="{StaticResource IconButtonStyle}" ToolTip="Open full OpenCodex dashboard" AutomationProperties.Name="Open full OpenCodex dashboard" />
        <Button x:Name="ExpandButton" Grid.Column="6" Content="&#x25BE;" Width="24" Height="24" Style="{StaticResource IconButtonStyle}" ToolTip="Expand usage details" AutomationProperties.Name="Expand usage details" />
      </Grid>

      <StackPanel x:Name="ExpandedPanel" Visibility="Collapsed">
      <Grid Height="40">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto" />
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="ConnectionDot" Grid.Column="0" Width="8" Height="8" Margin="1,0,9,12" VerticalAlignment="Center" Fill="{DynamicResource DimBrush}" />
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="Usage" FontSize="16" FontWeight="SemiBold" Height="20" />
          <TextBlock x:Name="ConnectionLabel" Text="Loading local usage..." FontSize="11" Foreground="{DynamicResource MutedBrush}" Height="16" TextTrimming="CharacterEllipsis" />
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
          <Button x:Name="DashboardButton" Content="&#x2197;" Style="{StaticResource IconButtonStyle}" ToolTip="Open full OpenCodex dashboard" AutomationProperties.Name="Open full OpenCodex dashboard" />
          <Button x:Name="PositionButton" Content="&#x2196;" Style="{StaticResource IconButtonStyle}" ToolTip="Move popup to top left" AutomationProperties.Name="Change popup corner" />
          <Button x:Name="CollapseButton" Content="&#x25B4;" Style="{StaticResource IconButtonStyle}" ToolTip="Collapse to current account" AutomationProperties.Name="Collapse usage details" />
          <Button x:Name="RefreshButton" Content="&#x21BB;" Style="{StaticResource IconButtonStyle}" ToolTip="Refresh usage and task status" AutomationProperties.Name="Refresh usage" />
          <Button x:Name="CloseButton" Content="&#x00D7;" Style="{StaticResource IconButtonStyle}" ToolTip="Hide usage" AutomationProperties.Name="Hide usage" />
        </StackPanel>
      </Grid>

      <Border Height="32" Margin="0,6,0,8" Background="{DynamicResource SegmentBrush}" CornerRadius="6" Padding="1">
        <UniformGrid Rows="1" Columns="3">
          <Button x:Name="SwitchButton1" Content="-" Style="{StaticResource SegmentButtonStyle}" Visibility="Collapsed" />
          <Button x:Name="SwitchButton2" Content="-" Style="{StaticResource SegmentButtonStyle}" Visibility="Collapsed" />
          <Button x:Name="SwitchButton3" Content="-" Style="{StaticResource SegmentButtonStyle}" Visibility="Collapsed" />
        </UniformGrid>
      </Border>

      <StackPanel x:Name="AccountsPanel">
        <Border x:Name="AccountCard1" Style="{StaticResource AccountCardStyle}" Visibility="Collapsed">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="94" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="12" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Border x:Name="AccountRail1" Width="2" Margin="0,7,0,7" HorizontalAlignment="Left" Background="Transparent" CornerRadius="1" />
            <StackPanel Grid.Column="0" Margin="6,0,4,0" VerticalAlignment="Center">
              <TextBlock x:Name="AccountName1" Text="-" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
              <TextBlock x:Name="AccountMeta1" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
            </StackPanel>
            <Grid Grid.Column="1" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="5-hour" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="FiveValue1" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="FiveBar1" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="FiveFillColumn1" Width="0*" /><ColumnDefinition x:Name="FiveEmptyColumn1" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="FiveFill1" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="FiveReset1" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
            <Grid Grid.Column="3" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="Weekly" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="WeekValue1" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="WeekBar1" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="WeekFillColumn1" Width="0*" /><ColumnDefinition x:Name="WeekEmptyColumn1" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="WeekFill1" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="WeekReset1" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
          </Grid>
        </Border>

        <Border x:Name="AccountCard2" Style="{StaticResource AccountCardStyle}" Visibility="Collapsed">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="94" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="12" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Border x:Name="AccountRail2" Width="2" Margin="0,7,0,7" HorizontalAlignment="Left" Background="Transparent" CornerRadius="1" />
            <StackPanel Grid.Column="0" Margin="6,0,4,0" VerticalAlignment="Center">
              <TextBlock x:Name="AccountName2" Text="-" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
              <TextBlock x:Name="AccountMeta2" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
            </StackPanel>
            <Grid Grid.Column="1" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="5-hour" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="FiveValue2" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="FiveBar2" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="FiveFillColumn2" Width="0*" /><ColumnDefinition x:Name="FiveEmptyColumn2" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="FiveFill2" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="FiveReset2" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
            <Grid Grid.Column="3" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="Weekly" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="WeekValue2" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="WeekBar2" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="WeekFillColumn2" Width="0*" /><ColumnDefinition x:Name="WeekEmptyColumn2" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="WeekFill2" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="WeekReset2" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
          </Grid>
        </Border>

        <Border x:Name="AccountCard3" Style="{StaticResource AccountCardStyle}" Visibility="Collapsed">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="94" />
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="12" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Border x:Name="AccountRail3" Width="2" Margin="0,7,0,7" HorizontalAlignment="Left" Background="Transparent" CornerRadius="1" />
            <StackPanel Grid.Column="0" Margin="6,0,4,0" VerticalAlignment="Center">
              <TextBlock x:Name="AccountName3" Text="-" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
              <TextBlock x:Name="AccountMeta3" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
            </StackPanel>
            <Grid Grid.Column="1" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="5-hour" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="FiveValue3" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="FiveBar3" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="FiveFillColumn3" Width="0*" /><ColumnDefinition x:Name="FiveEmptyColumn3" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="FiveFill3" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="FiveReset3" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
            <Grid Grid.Column="3" VerticalAlignment="Center">
              <Grid.RowDefinitions><RowDefinition Height="18" /><RowDefinition Height="8" /><RowDefinition Height="16" /></Grid.RowDefinitions>
              <Grid Grid.Row="0"><TextBlock Text="Weekly" FontSize="11" Foreground="{DynamicResource MutedBrush}" /><TextBlock x:Name="WeekValue3" Text="-" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Right" /></Grid>
              <Grid x:Name="WeekBar3" Grid.Row="1" Height="6" ClipToBounds="True">
                <Grid.ColumnDefinitions><ColumnDefinition x:Name="WeekFillColumn3" Width="0*" /><ColumnDefinition x:Name="WeekEmptyColumn3" Width="100*" /></Grid.ColumnDefinitions>
                <Border Grid.ColumnSpan="2" Background="{DynamicResource TrackBrush}" CornerRadius="3" />
                <Border x:Name="WeekFill3" Grid.Column="0" Background="{DynamicResource GreenBrush}" CornerRadius="3" />
              </Grid>
              <TextBlock x:Name="WeekReset3" Grid.Row="2" Text="reset unknown" FontSize="10" Foreground="{DynamicResource DimBrush}" />
            </Grid>
          </Grid>
        </Border>
      </StackPanel>

      <Grid Height="24" Margin="2,3,2,0">
        <TextBlock Text="Tasks" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource DimBrush}" />
        <TextBlock x:Name="FreshnessLabel" Text="waiting for data" FontSize="10.5" Foreground="{DynamicResource DimBrush}" HorizontalAlignment="Right" />
      </Grid>

      <StackPanel x:Name="TaskPanel">
        <Grid x:Name="TaskRow1" Height="27" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="66" /><ColumnDefinition Width="*" /><ColumnDefinition Width="60" /></Grid.ColumnDefinitions>
          <Ellipse x:Name="TaskDot1" Grid.Column="0" Width="6" Height="6" Fill="{DynamicResource DimBrush}" />
          <TextBlock x:Name="TaskAccount1" Grid.Column="1" Text="-" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTitle1" Grid.Column="2" Text="-" FontSize="11.5" Margin="2,0,8,0" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTokens1" Grid.Column="3" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Right" />
        </Grid>
        <Grid x:Name="TaskRow2" Height="27" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="66" /><ColumnDefinition Width="*" /><ColumnDefinition Width="60" /></Grid.ColumnDefinitions>
          <Ellipse x:Name="TaskDot2" Grid.Column="0" Width="6" Height="6" Fill="{DynamicResource DimBrush}" />
          <TextBlock x:Name="TaskAccount2" Grid.Column="1" Text="-" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTitle2" Grid.Column="2" Text="-" FontSize="11.5" Margin="2,0,8,0" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTokens2" Grid.Column="3" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Right" />
        </Grid>
        <Grid x:Name="TaskRow3" Height="27" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="66" /><ColumnDefinition Width="*" /><ColumnDefinition Width="60" /></Grid.ColumnDefinitions>
          <Ellipse x:Name="TaskDot3" Grid.Column="0" Width="6" Height="6" Fill="{DynamicResource DimBrush}" />
          <TextBlock x:Name="TaskAccount3" Grid.Column="1" Text="-" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource MutedBrush}" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTitle3" Grid.Column="2" Text="-" FontSize="11.5" Margin="2,0,8,0" TextTrimming="CharacterEllipsis" />
          <TextBlock x:Name="TaskTokens3" Grid.Column="3" Text="-" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Right" />
        </Grid>
        <TextBlock x:Name="MoreTasksLabel" Height="18" Text="" FontSize="10.5" Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Center" Visibility="Collapsed" />
        <TextBlock x:Name="EmptyTasksLabel" Height="27" Text="No live or recent tasks" FontSize="11.5" Foreground="{DynamicResource MutedBrush}" TextAlignment="Center" />
      </StackPanel>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$xmlDocument = [xml]$xaml
$xmlReader = [System.Xml.XmlNodeReader]::new($xmlDocument)
try {
  $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
} finally {
  $xmlReader.Close()
}

function Find-UiElement {
  param([string]$Name)
  $element = $window.FindName($Name)
  if ($null -eq $element) { throw "The UI element '$Name' was not loaded" }
  return $element
}

$rootSurface = Find-UiElement "RootSurface"
$compactPanel = Find-UiElement "CompactPanel"
$expandedPanel = Find-UiElement "ExpandedPanel"
$compactConnectionDot = Find-UiElement "CompactConnectionDot"
$compactAccount = Find-UiElement "CompactAccount"
$compactMeta = Find-UiElement "CompactMeta"
$compactFiveValue = Find-UiElement "CompactFiveValue"
$compactFiveBar = Find-UiElement "CompactFiveBar"
$compactFiveFill = Find-UiElement "CompactFiveFill"
$compactFiveFillColumn = Find-UiElement "CompactFiveFillColumn"
$compactFiveEmptyColumn = Find-UiElement "CompactFiveEmptyColumn"
$compactWeekValue = Find-UiElement "CompactWeekValue"
$compactWeekBar = Find-UiElement "CompactWeekBar"
$compactWeekFill = Find-UiElement "CompactWeekFill"
$compactWeekFillColumn = Find-UiElement "CompactWeekFillColumn"
$compactWeekEmptyColumn = Find-UiElement "CompactWeekEmptyColumn"
$compactDashboardButton = Find-UiElement "CompactDashboardButton"
$expandButton = Find-UiElement "ExpandButton"
$connectionDot = Find-UiElement "ConnectionDot"
$connectionLabel = Find-UiElement "ConnectionLabel"
$freshnessLabel = Find-UiElement "FreshnessLabel"
$dashboardButton = Find-UiElement "DashboardButton"
$positionButton = Find-UiElement "PositionButton"
$collapseButton = Find-UiElement "CollapseButton"
$refreshButton = Find-UiElement "RefreshButton"
$closeButton = Find-UiElement "CloseButton"
$emptyTasksLabel = Find-UiElement "EmptyTasksLabel"
$moreTasksLabel = Find-UiElement "MoreTasksLabel"

$script:switchButtons = @(
  (Find-UiElement "SwitchButton1"),
  (Find-UiElement "SwitchButton2"),
  (Find-UiElement "SwitchButton3")
)

$script:accountRows = @()
for ($index = 1; $index -le 3; $index++) {
  $script:accountRows += [pscustomobject]@{
    Card = Find-UiElement "AccountCard$index"
    Rail = Find-UiElement "AccountRail$index"
    Name = Find-UiElement "AccountName$index"
    Meta = Find-UiElement "AccountMeta$index"
    FiveValue = Find-UiElement "FiveValue$index"
    FiveBar = Find-UiElement "FiveBar$index"
    FiveFill = Find-UiElement "FiveFill$index"
    FiveFillColumn = Find-UiElement "FiveFillColumn$index"
    FiveEmptyColumn = Find-UiElement "FiveEmptyColumn$index"
    FiveReset = Find-UiElement "FiveReset$index"
    WeekValue = Find-UiElement "WeekValue$index"
    WeekBar = Find-UiElement "WeekBar$index"
    WeekFill = Find-UiElement "WeekFill$index"
    WeekFillColumn = Find-UiElement "WeekFillColumn$index"
    WeekEmptyColumn = Find-UiElement "WeekEmptyColumn$index"
    WeekReset = Find-UiElement "WeekReset$index"
  }
}

$script:taskRows = @()
for ($index = 1; $index -le 3; $index++) {
  $script:taskRows += [pscustomobject]@{
    Row = Find-UiElement "TaskRow$index"
    Dot = Find-UiElement "TaskDot$index"
    Account = Find-UiElement "TaskAccount$index"
    Title = Find-UiElement "TaskTitle$index"
    Tokens = Find-UiElement "TaskTokens$index"
  }
}

$script:isDarkTheme = Get-CodexDarkTheme
function Apply-Theme {
  param([bool]$Dark)
  $palette = Get-ThemePalette $Dark
  foreach ($entry in @{
    RootBrush = "Root"; CardBrush = "Card"; SegmentBrush = "Segment";
    ActiveSurfaceBrush = "ActiveSurface"; ActiveButtonBrush = "ActiveButton";
    TextBrush = "Text"; RowTextBrush = "RowText"; MutedBrush = "Muted";
    DimBrush = "Dim"; BorderBrush = "Border"; TrackBrush = "Track";
    HoverBrush = "Hover"; PressedBrush = "Pressed"; AccentBrush = "Accent";
    GreenBrush = "Green"; AmberBrush = "Amber"; RedBrush = "Red"
  }.GetEnumerator()) {
    $window.Resources[$entry.Key] = New-WpfBrush $palette[$entry.Value]
  }
}
Apply-Theme $script:isDarkTheme

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
if ([System.IO.File]::Exists($usageIconPath)) {
  try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$usageIconPath) } catch { }
}

$notify = [System.Windows.Forms.NotifyIcon]::new()
$notify.Icon = $onlineIcon
$notify.Text = "OpenCodex Usage: loading"
$notify.Visible = $true

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$showItem = $menu.Items.Add("Show usage")
$refreshItem = $menu.Items.Add("Refresh now")
$dashboardItem = $menu.Items.Add("Open OpenCodex dashboard")
$positionMenu = [System.Windows.Forms.ToolStripMenuItem]::new("Popup corner")
$positionLeftItem = [System.Windows.Forms.ToolStripMenuItem]::new("Top left")
$positionBottomItem = [System.Windows.Forms.ToolStripMenuItem]::new("Bottom left")
[void]$positionMenu.DropDownItems.Add($positionLeftItem)
[void]$positionMenu.DropDownItems.Add($positionBottomItem)
[void]$menu.Items.Add($positionMenu)
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
$script:isConnected = $false
$script:confirmedActiveLabel = $null
$script:exiting = $false
$script:isExpanded = $false
$script:compactWidth = 316.0
$script:expandedWidth = 428.0
$script:popupRequestedVisible = $false
$script:autoHiddenForFocus = $false
$script:lastForegroundHandle = [IntPtr]::Zero
$script:lastForegroundContext = "other"
$script:lastCodexWindowHandle = [IntPtr]::Zero
$script:windowHandle = [IntPtr]::Zero
$heartbeatPath = Join-Path $scriptRoot "tray-heartbeat.json"

function Sync-CodexTheme {
  $darkTheme = Get-CodexDarkTheme
  if ($darkTheme -eq $script:isDarkTheme) { return }
  $script:isDarkTheme = $darkTheme
  Apply-Theme $darkTheme
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
  $foregroundWindow = [OpenCodexFocusNative]::GetForegroundWindow()
  if ($foregroundWindow -eq $script:lastForegroundHandle) { return $script:lastForegroundContext }

  $context = "other"
  if ($foregroundWindow -ne [IntPtr]::Zero) {
    $foregroundProcessId = [uint32]0
    [void][OpenCodexFocusNative]::GetWindowThreadProcessId($foregroundWindow, [ref]$foregroundProcessId)
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
          $script:lastCodexWindowHandle = $foregroundWindow
        }
      } catch { }
    }
  }

  $script:lastForegroundHandle = $foregroundWindow
  $script:lastForegroundContext = $context
  return $context
}

function Update-PopupFocusVisibility {
  $context = Get-ForegroundContext
  if (-not $script:popupRequestedVisible) { return }

  if ($context -eq "other") {
    if ($window.IsVisible) { Hide-Popup -ForFocus }
    return
  }
  if ($context -eq "codex") {
    if (-not $window.IsVisible) {
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
      popupVisible = $window.IsVisible
      windowHandle = $script:windowHandle.ToInt64()
      theme = if ($script:isDarkTheme) { "dark" } else { "light" }
      opacity = $window.Opacity
      topMost = $window.Topmost
      requestedVisible = $script:popupRequestedVisible
      autoHiddenForFocus = $script:autoHiddenForFocus
      foregroundContext = $script:lastForegroundContext
      popupCorner = $script:popupCorner
      expanded = $script:isExpanded
      activeAccount = if (-not [string]::IsNullOrWhiteSpace($script:confirmedActiveLabel)) { $script:confirmedActiveLabel } elseif ($script:lastData) { [string]$script:lastData.activeAccountLabel } else { $null }
      runningTasks = if ($script:lastData) { [int]$script:lastData.counts.running } else { $null }
      connected = [bool]$script:isConnected
      presentation = "wpf"
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($heartbeatPath, $heartbeat, [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

function Set-BusyState {
  param([bool]$Busy, [string]$Message = "")
  $refreshButton.IsEnabled = -not $Busy
  foreach ($button in $script:switchButtons) { $button.IsEnabled = -not $Busy }
  if ($Busy -and -not [string]::IsNullOrWhiteSpace($Message)) {
    $connectionLabel.Text = $Message
    $connectionLabel.Foreground = $window.Resources["MutedBrush"]
    $connectionDot.Fill = $window.Resources["AccentBrush"]
    $compactConnectionDot.Fill = $connectionDot.Fill
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
      $targetName = if ($null -ne $targetButton) { [string]$targetButton.Content } else { "account" }
      Set-BusyState $true "Switching to $targetName..."
    } else {
      Set-BusyState $true "Refreshing local usage..."
    }
  } catch {
    $script:isConnected = $false
    Set-BusyState $false
    $connectionLabel.Text = "OpenCodex data unavailable"
    $connectionLabel.Foreground = $window.Resources["RedBrush"]
    $connectionDot.Fill = $window.Resources["RedBrush"]
    $compactConnectionDot.Fill = $connectionDot.Fill
    $freshnessLabel.Text = $_.Exception.Message
    Write-Heartbeat
  }
}

function Update-WindowLayout {
  $window.UpdateLayout()
  if ($window.IsVisible) { Position-Popup -AnchorWindow $script:lastCodexWindowHandle }
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
  $liveMetric = if ($runningCount -eq 1) { "1 live" } else { "$runningCount live" }
  $metricParts = @(
    $liveMetric
    "$(Format-CompactNumber ([double]$Data.totals.tokens7d)) tokens"
    "$(Format-CompactNumber ([double]$Data.totals.requests7d)) req"
  )
  if ($stalledCount -gt 0) { $metricParts += "$stalledCount stalled" }
  $connectionLabel.Text = $metricParts -join "  |  "
  $connectionLabel.Foreground = $window.Resources["MutedBrush"]
  $connectionDot.Fill = if ($stalledCount -gt 0) { $window.Resources["AmberBrush"] } else { $window.Resources["GreenBrush"] }
  $compactConnectionDot.Fill = $connectionDot.Fill

  if ($null -ne $activeAccount) {
    $compactAccount.Text = $activeLabel
    $activePlan = ([string]$activeAccount.plan).ToLowerInvariant()
    $compactMeta.Text = $activePlan
    $compactFivePercent = $activeAccount.fiveHour.usedPercent
    $compactFiveReset = Format-ResetCountdown $activeAccount.fiveHour.resetAt
    $compactFiveValue.Text = Format-Percent $compactFivePercent
    $compactFiveValue.Foreground = Get-QuotaBrush $compactFivePercent
    Set-QuotaMeter $compactFiveBar $compactFiveFill $compactFiveFillColumn $compactFiveEmptyColumn $compactFivePercent "5-hour window | $(Format-Percent $compactFivePercent) used | $compactFiveReset"
    $compactWeekPercent = $activeAccount.week.usedPercent
    $compactWeekReset = Format-ResetCountdown $activeAccount.week.resetAt
    $compactWeekValue.Text = Format-Percent $compactWeekPercent
    $compactWeekValue.Foreground = Get-QuotaBrush $compactWeekPercent
    Set-QuotaMeter $compactWeekBar $compactWeekFill $compactWeekFillColumn $compactWeekEmptyColumn $compactWeekPercent "Weekly window | $(Format-Percent $compactWeekPercent) used | $compactWeekReset"
  } else {
    $compactAccount.Text = "No account"
    $compactMeta.Text = "OpenCodex"
    $compactFiveValue.Text = "--"
    $compactWeekValue.Text = "--"
    Set-QuotaMeter $compactFiveBar $compactFiveFill $compactFiveFillColumn $compactFiveEmptyColumn $null "5-hour usage unavailable"
    Set-QuotaMeter $compactWeekBar $compactWeekFill $compactWeekFillColumn $compactWeekEmptyColumn $null "Weekly usage unavailable"
  }

  for ($index = 0; $index -lt 3; $index++) {
    $button = $script:switchButtons[$index]
    $row = $script:accountRows[$index]
    if ($index -ge $accounts.Count) {
      $button.Visibility = [System.Windows.Visibility]::Collapsed
      $row.Card.Visibility = [System.Windows.Visibility]::Collapsed
      continue
    }

    $accountData = $accounts[$index]
    $isActive = [bool]$accountData.active
    $displayName = [string]$accountData.displayName
    $button.Content = $displayName
    $button.Tag = [string]$accountData.id
    $button.Visibility = [System.Windows.Visibility]::Visible
    $button.Foreground = if ($isActive) { $window.Resources["TextBrush"] } else { $window.Resources["MutedBrush"] }
    $button.Background = if ($isActive) { $window.Resources["ActiveButtonBrush"] } else { $window.Resources["SegmentBrush"] }
    $button.ToolTip = "$($accountData.email) | $($accountData.plan) | $([int]$accountData.runningTasks) live"

    $row.Card.Visibility = [System.Windows.Visibility]::Visible
    $row.Card.Background = if ($isActive) { $window.Resources["ActiveSurfaceBrush"] } else { $window.Resources["CardBrush"] }
    $row.Card.BorderBrush = $window.Resources["BorderBrush"]
    $row.Card.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $row.Rail.Background = if ($isActive) { $window.Resources["AccentBrush"] } else { $window.Resources["CardBrush"] }
    $row.Card.ToolTip = "$($accountData.email) | $($accountData.health)"
    $row.Name.Text = $displayName
    $row.Name.Foreground = if ($isActive) { $window.Resources["TextBrush"] } else { $window.Resources["RowTextBrush"] }
    $plan = ([string]$accountData.plan).ToLowerInvariant()
    $row.Meta.Text = "$plan | $(Format-CompactNumber ([double]$accountData.tokens7d)) 7d"

    $fivePercent = $accountData.fiveHour.usedPercent
    $fiveReset = Format-ResetCountdown $accountData.fiveHour.resetAt
    $row.FiveValue.Text = "$(Format-Percent $fivePercent) used"
    $row.FiveValue.Foreground = Get-QuotaBrush $fivePercent
    $row.FiveReset.Text = $fiveReset
    Set-QuotaMeter $row.FiveBar $row.FiveFill $row.FiveFillColumn $row.FiveEmptyColumn $fivePercent "5-hour window | $(Format-Percent $fivePercent) used | $fiveReset"

    $weekPercent = $accountData.week.usedPercent
    $weekReset = Format-ResetCountdown $accountData.week.resetAt
    $row.WeekValue.Text = "$(Format-Percent $weekPercent) used"
    $row.WeekValue.Foreground = Get-QuotaBrush $weekPercent
    $row.WeekReset.Text = $weekReset
    Set-QuotaMeter $row.WeekBar $row.WeekFill $row.WeekFillColumn $row.WeekEmptyColumn $weekPercent "Weekly window | $(Format-Percent $weekPercent) used | $weekReset"
  }

  $allTasks = @($Data.tasks)
  $tasks = @($allTasks | Select-Object -First 3)
  $emptyTasksLabel.Visibility = if ($tasks.Count -eq 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  for ($index = 0; $index -lt 3; $index++) {
    $taskRow = $script:taskRows[$index]
    if ($index -ge $tasks.Count) {
      $taskRow.Row.Visibility = [System.Windows.Visibility]::Collapsed
      continue
    }

    $task = $tasks[$index]
    $status = ([string]$task.status).ToLowerInvariant()
    $statusBrush = switch ($status) {
      "running" { $window.Resources["GreenBrush"] }
      "stalled" { $window.Resources["AmberBrush"] }
      "failed" { $window.Resources["RedBrush"] }
      default { $window.Resources["DimBrush"] }
    }
    $taskRow.Row.Visibility = [System.Windows.Visibility]::Visible
    $taskRow.Dot.Fill = $statusBrush
    $taskRow.Account.Text = [string]$task.accountLabel
    $taskRow.Account.Foreground = $statusBrush
    $elapsed = Format-Elapsed $task.durationMs
    $taskText = if ([string]::IsNullOrWhiteSpace($elapsed)) { [string]$task.title } else { "$($task.title) | $elapsed" }
    $taskRow.Title.Text = $taskText
    $taskRow.Title.ToolTip = "$status | $taskText"
    $taskRow.Tokens.Text = Format-CompactNumber ([double]$task.tokensUsed)
    $taskRow.Tokens.ToolTip = "$(Format-CompactNumber ([double]$task.tokensUsed)) tokens"
  }

  $moreCount = [Math]::Max(0, $allTasks.Count - 3)
  if ($moreCount -gt 0) {
    $moreTasksLabel.Text = "+$moreCount more in dashboard"
    $moreTasksLabel.Visibility = [System.Windows.Visibility]::Visible
  } else {
    $moreTasksLabel.Visibility = [System.Windows.Visibility]::Collapsed
  }

  $freshnessLabel.Text = "updated now | local"
  $activeFiveHourText = if ($null -ne $activeAccount) { Format-Percent $activeAccount.fiveHour.usedPercent } else { "--" }
  $toolText = "OpenCodex: $activeLabel | 5h $activeFiveHourText | $runningCount running"
  if ($toolText.Length -gt 63) { $toolText = $toolText.Substring(0, 63) }
  $notify.Text = $toolText
  $notify.Icon = $onlineIcon
  Update-WindowLayout
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
    if ($button.Visibility -eq [System.Windows.Visibility]::Visible) {
      $button.Foreground = if ($isActive) { $window.Resources["TextBrush"] } else { $window.Resources["MutedBrush"] }
      $button.Background = if ($isActive) { $window.Resources["ActiveButtonBrush"] } else { $window.Resources["SegmentBrush"] }
    }
    if ($row.Card.Visibility -eq [System.Windows.Visibility]::Visible) {
      $row.Card.Background = if ($isActive) { $window.Resources["ActiveSurfaceBrush"] } else { $window.Resources["CardBrush"] }
      $row.Card.BorderBrush = $window.Resources["BorderBrush"]
      $row.Card.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
      $row.Rail.Background = if ($isActive) { $window.Resources["AccentBrush"] } else { $window.Resources["CardBrush"] }
    }
  }

  $connectionLabel.Text = "$accountLabel active | usage refresh pending"
  $connectionLabel.Foreground = $window.Resources["AmberBrush"]
  $connectionDot.Fill = $window.Resources["AmberBrush"]
  $compactConnectionDot.Fill = $connectionDot.Fill
  $compactAccount.Text = $accountLabel
  $compactMeta.Text = "usage refresh pending"
  $compactFiveValue.Text = "--"
  $compactFiveValue.Foreground = $window.Resources["DimBrush"]
  $compactWeekValue.Text = "--"
  $compactWeekValue.Foreground = $window.Resources["DimBrush"]
  Set-QuotaMeter $compactFiveBar $compactFiveFill $compactFiveFillColumn $compactFiveEmptyColumn $null "5-hour usage refresh pending"
  Set-QuotaMeter $compactWeekBar $compactWeekFill $compactWeekFillColumn $compactWeekEmptyColumn $null "Weekly usage refresh pending"
  $freshnessLabel.Text = "retrying | local"
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
    $connectionLabel.Foreground = $window.Resources["RedBrush"]
    $connectionDot.Fill = $window.Resources["RedBrush"]
    $compactConnectionDot.Fill = $connectionDot.Fill
    $freshnessLabel.Text = "refresh failed | local"
    $freshnessLabel.ToolTip = $message
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
    $connectionLabel.Foreground = $window.Resources["RedBrush"]
    $connectionDot.Fill = $window.Resources["RedBrush"]
    $compactConnectionDot.Fill = $connectionDot.Fill
    $freshnessLabel.Text = "response unreadable | local"
    $notify.Icon = $warningIcon
    Write-Heartbeat
  }
}

function Get-WindowScale {
  param([IntPtr]$AnchorWindow)
  if ($AnchorWindow -eq [IntPtr]::Zero) { return 1.0 }
  try {
    $dpi = [OpenCodexFocusNative]::GetDpiForWindow($AnchorWindow)
    if ($dpi -ge 96) { return [double]$dpi / 96.0 }
  } catch { }
  return 1.0
}

function Position-Popup {
  param([IntPtr]$AnchorWindow = [IntPtr]::Zero)
  if ($AnchorWindow -eq [IntPtr]::Zero) {
    $AnchorWindow = if ($script:lastCodexWindowHandle -ne [IntPtr]::Zero) { $script:lastCodexWindowHandle } else { Get-CodexWindowHandle }
  }

  $screen = if ($AnchorWindow -ne [IntPtr]::Zero) {
    [System.Windows.Forms.Screen]::FromHandle($AnchorWindow)
  } else {
    [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
  }
  $scale = Get-WindowScale $AnchorWindow
  $workingArea = $screen.WorkingArea
  $popupWidth = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { $window.Width }
  $popupHeight = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { 360 }
  $workLeft = $workingArea.Left / $scale
  $workTop = $workingArea.Top / $scale
  $workRight = $workingArea.Right / $scale
  $workBottom = $workingArea.Bottom / $scale
  $x = $workLeft + 8
  $y = if ($script:popupCorner -eq "TopLeft") { $workTop + 8 } else { $workBottom - $popupHeight - 8 }

  if ($AnchorWindow -ne [IntPtr]::Zero) {
    $windowRect = [OpenCodexWindowRect]::new()
    if ([OpenCodexFocusNative]::GetWindowRect($AnchorWindow, [ref]$windowRect)) {
      $anchorLeft = $windowRect.Left / $scale
      $anchorTop = $windowRect.Top / $scale
      $anchorRight = $windowRect.Right / $scale
      $anchorBottom = $windowRect.Bottom / $scale
      $leftInset = 286
      $rightReserve = 500
      $edgeGap = 12
      $topInset = 96
      $leftX = $anchorLeft + $leftInset
      $browserSafeMaxX = $anchorRight - $rightReserve - $popupWidth - $edgeGap
      if ($browserSafeMaxX -ge ($anchorLeft + $edgeGap)) {
        $x = [Math]::Min($leftX, $browserSafeMaxX)
      } else {
        $x = $anchorLeft + $edgeGap
      }
      $y = if ($script:popupCorner -eq "TopLeft") { $anchorTop + $topInset } else { $anchorBottom - $popupHeight - $edgeGap }
    }
  }

  $maxX = $workRight - $popupWidth - 8
  $maxY = $workBottom - $popupHeight - 8
  $window.Left = [Math]::Max($workLeft + 8, [Math]::Min($x, $maxX))
  $window.Top = [Math]::Max($workTop + 8, [Math]::Min($y, $maxY))
}

function Set-DisplayMode {
  param([bool]$Expanded)
  $script:isExpanded = $Expanded
  $compactPanel.Visibility = if ($Expanded) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
  $expandedPanel.Visibility = if ($Expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $window.Width = if ($Expanded) { $script:expandedWidth } else { $script:compactWidth }
  $rootSurface.Padding = if ($Expanded) { [System.Windows.Thickness]::new(12) } else { [System.Windows.Thickness]::new(8) }
  $window.UpdateLayout()
  if ($window.IsVisible) { Position-Popup -AnchorWindow $script:lastCodexWindowHandle }
  Write-Heartbeat
}

function Update-PositionControls {
  $isTop = $script:popupCorner -eq "TopLeft"
  $positionLeftItem.Checked = $isTop
  $positionBottomItem.Checked = -not $isTop
  if (-not $isTop) {
    $positionButton.Content = [char]0x2196
    $positionButton.ToolTip = "Popup corner: bottom left. Click to move to top left"
    [System.Windows.Automation.AutomationProperties]::SetName($positionButton, "Move popup to top left")
  } else {
    $positionButton.Content = [char]0x2199
    $positionButton.ToolTip = "Popup corner: top left. Click to move to bottom left"
    [System.Windows.Automation.AutomationProperties]::SetName($positionButton, "Move popup to bottom left")
  }
}

function Set-PopupCorner {
  param([ValidateSet("TopLeft", "BottomLeft")][string]$Corner)
  if ($script:popupCorner -ne $Corner) {
    $script:popupCorner = $Corner
    Save-TraySettings
  }
  Update-PositionControls
  if ($window.IsVisible) { Position-Popup -AnchorWindow $script:lastCodexWindowHandle }
  Write-Heartbeat
}

function Show-Popup {
  param(
    [switch]$ForFocusRestore,
    [IntPtr]$AnchorWindow = [IntPtr]::Zero
  )
  $script:popupRequestedVisible = $true
  $script:autoHiddenForFocus = $false
  Sync-CodexTheme

  if (-not $window.IsVisible) {
    $window.ShowActivated = -not [bool]$ForFocusRestore
    $window.Show()
    $window.UpdateLayout()
  }
  $window.Topmost = $true
  Position-Popup -AnchorWindow $AnchorWindow
  if ($ForFocusRestore -and $AnchorWindow -ne [IntPtr]::Zero) {
    [void][OpenCodexFocusNative]::SetForegroundWindow($AnchorWindow)
  } elseif (-not $ForFocusRestore) {
    [void]$window.Activate()
  }
  $showItem.Text = "Hide usage"
  Write-Heartbeat
}

function Hide-Popup {
  param([switch]$ForFocus)
  $window.Hide()
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

function Get-OpenCodexDashboardUrl {
  $port = 10100
  $openCodexRoot = if (-not [string]::IsNullOrWhiteSpace($env:OPENCODEX_HOME)) {
    $env:OPENCODEX_HOME.Trim()
  } else {
    Join-Path ([Environment]::GetFolderPath("UserProfile")) ".opencodex"
  }
  $configPath = Join-Path $openCodexRoot "config.json"
  try {
    if ([System.IO.File]::Exists($configPath)) {
      $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
      $configuredPort = [int]$config.port
      if ($configuredPort -gt 0 -and $configuredPort -le 65535) { $port = $configuredPort }
    }
  } catch { }
  return "http://127.0.0.1:$port/"
}

$openDashboard = {
  try { Start-Process (Get-OpenCodexDashboardUrl) | Out-Null } catch { }
}

Set-DisplayMode $false
Update-PositionControls

foreach ($button in $script:switchButtons) {
  $button.Add_Click({
    param($sender, $eventArgs)
    $accountId = [string]$sender.Tag
    if ([string]::IsNullOrWhiteSpace($accountId)) { return }
    if ($script:lastData -and [string]$script:lastData.activeAccountId -eq $accountId) { return }
    Start-ProviderRequest -Operation "switch" -AccountId $accountId
  })
}

$refreshButton.Add_Click({ Start-ProviderRequest -Operation "status" -Force })
$dashboardButton.Add_Click($openDashboard)
$compactDashboardButton.Add_Click($openDashboard)
$expandButton.Add_Click({ Set-DisplayMode $true })
$collapseButton.Add_Click({ Set-DisplayMode $false })
$positionButton.Add_Click({
  Set-PopupCorner $(if ($script:popupCorner -eq "TopLeft") { "BottomLeft" } else { "TopLeft" })
})
$closeButton.Add_Click({ Hide-Popup })
$window.Add_KeyDown({
  param($sender, $eventArgs)
  if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) { Hide-Popup }
})
$window.Add_SourceInitialized({
  $script:windowHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
})
$window.Add_Closing({
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
$positionLeftItem.add_Click({ Set-PopupCorner "TopLeft" })
$positionBottomItem.add_Click({ Set-PopupCorner "BottomLeft" })

$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$exitItem.add_Click({
  $script:exiting = $true
  $application.Shutdown()
})

$pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$pollTimer.Add_Tick({
  if ($showEvent.WaitOne(0)) { Show-Popup }
  if ($stopEvent.WaitOne(0)) {
    $script:exiting = $true
    $application.Shutdown()
    return
  }
  Update-PopupFocusVisibility
  Complete-ProviderRequest
  if ($null -ne $script:lastUpdatedAt -and $null -eq $script:pendingProcess) {
    $ageSeconds = [Math]::Floor(([DateTime]::Now - $script:lastUpdatedAt).TotalSeconds)
    if ($ageSeconds -lt 60) { $freshnessLabel.Text = "updated now | local" }
    elseif ($ageSeconds -lt 3600) { $freshnessLabel.Text = "updated $([Math]::Floor($ageSeconds / 60))m ago | local" }
    else { $freshnessLabel.Text = "updated $([Math]::Floor($ageSeconds / 3600))h ago | local" }
  }
})

$refreshTimer = [System.Windows.Threading.DispatcherTimer]::new()
$refreshTimer.Interval = [TimeSpan]::FromSeconds(30)
$refreshTimer.Add_Tick({
  if ($null -ne $script:pendingProcess) { return }
  $force = ([DateTime]::Now - $script:lastForcedRefreshAt).TotalMinutes -ge 5
  if ($force) { Start-ProviderRequest -Operation "status" -Force }
  else { Start-ProviderRequest -Operation "status" }
})

$heartbeatTimer = [System.Windows.Threading.DispatcherTimer]::new()
$heartbeatTimer.Interval = [TimeSpan]::FromSeconds(5)
$heartbeatTimer.Add_Tick({
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
  [void]$application.Run()
} finally {
  $script:exiting = $true
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
  foreach ($icon in $script:ownedIcons) { $icon.Dispose() }
  try { if ($window.IsVisible) { $window.Close() } } catch { }
  try { Remove-Item -LiteralPath $heartbeatPath -Force -ErrorAction SilentlyContinue } catch { }
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
  $showEvent.Dispose()
  $stopEvent.Dispose()
}
