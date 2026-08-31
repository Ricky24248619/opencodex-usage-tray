Option Explicit

Dim shell, fso, scriptDir, powerShellPath, scriptPath, command, waitForExit, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

waitForExit = WScript.Arguments.Named.Exists("supervise")
If Not waitForExit And WScript.Arguments.Unnamed.Count > 0 Then
  waitForExit = (LCase(WScript.Arguments.Unnamed(0)) = "supervise")
End If

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = fso.BuildPath(scriptDir, "OpenCodexUsageTray.ps1")
command = Chr(34) & powerShellPath & Chr(34) & _
  " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
  Chr(34) & scriptPath & Chr(34) & " -ShowOnStart"

If waitForExit Then
  Do
    exitCode = shell.Run(command, 0, True)
    If exitCode = 0 Then WScript.Quit 0
    WScript.Sleep 30000
  Loop
Else
  shell.Run command, 0, False
End If
