' Launches the StatefulClanker tray app with no console window.
'
' A shortcut to pwsh.exe flashes a console window on every launch, even with
' -WindowStyle Hidden, because the host is created before the style is applied.
' WScript.Shell.Run with intWindowStyle 0 never creates one. This needs nothing
' installed beyond what ships with Windows.
Option Explicit

Dim shell, fso, here, tray, pwsh, quote, args
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

quote = Chr(34)
here = fso.GetParentFolderName(WScript.ScriptFullName)
tray = fso.BuildPath(here, "desktop\StatefulClanker.Tray.ps1")

If Not fso.FileExists(tray) Then
    MsgBox "Could not find:" & vbCrLf & tray, vbCritical, "StatefulClanker"
    WScript.Quit 1
End If

' Prefer PowerShell 7; fall back to Windows PowerShell.
pwsh = "pwsh.exe"
On Error Resume Next
Dim probe
probe = shell.Run("pwsh.exe -NoProfile -Command exit", 0, True)
If Err.Number <> 0 Then
    Err.Clear
    pwsh = "powershell.exe"
End If
On Error GoTo 0

args = pwsh & " -NoProfile -ExecutionPolicy Bypass -File " & quote & tray & quote

' 0 = hidden window, False = do not wait.
shell.Run args, 0, False
