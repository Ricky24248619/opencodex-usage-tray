Option Explicit

Dim shell, fso, scriptDir, powerShellPath, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = fso.BuildPath(scriptDir, "OpenCodexUsageTray.ps1")
command = Chr(34) & powerShellPath & Chr(34) & _
  " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
  Chr(34) & scriptPath & Chr(34) & " -ShowOnStart"

shell.Run command, 0, False
