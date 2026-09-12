Option Explicit
' NetSource Policy - zero-console launcher.
' Double-clicking this file opens the GUI without any command-prompt window.

Dim fso, sh, app, script, engine
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
app = fso.GetParentFolderName(WScript.ScriptFullName)
script = app & "\src\NetSourcePolicy.ps1"
engine = app & "\src\engine.ps1"

If Not fso.FileExists(script) Or Not fso.FileExists(engine) Then
    MsgBox "NetSource Policy is missing files in: " & app, vbCritical, "NetSource Policy"
    WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False