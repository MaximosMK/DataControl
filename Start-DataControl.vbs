' DataControl Silent Launcher
' Starts DataControl PowerShell script with a completely hidden console window.
Dim objShell, strDir, strCommand
Set objShell = CreateObject("Wscript.Shell")
strDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strDir & "\DataControl.ps1"""
objShell.Run strCommand, 0, False
Set objShell = Nothing
