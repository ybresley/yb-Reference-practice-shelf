Option Explicit

If WScript.Arguments.Count < 4 Or WScript.Arguments.Count > 6 Then WScript.Quit 2

Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function

Dim shell, command, exitCode, launchError, resultPath, fallbackPath, fso, fallback, optionIndex
Set shell = CreateObject("WScript.Shell")
resultPath = WScript.Arguments(1)
command = "powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " _
  & Quote(WScript.Arguments(0)) _
  & " -ResultPath " & Quote(WScript.Arguments(1)) _
  & " -Title " & Quote(WScript.Arguments(2)) _
  & " -InitialFolder " & Quote(WScript.Arguments(3))
For optionIndex = 4 To WScript.Arguments.Count - 1
  If WScript.Arguments(optionIndex) = "TEST" Then
    command = command & " -TestMode"
  End If
  If WScript.Arguments(optionIndex) = "FORCE_INITIAL" Then
    command = command & " -ForceInitialFolder"
  End If
Next

On Error Resume Next
exitCode = shell.Run(command, 0, True)
If Err.Number <> 0 Then
  launchError = Err.Description
  exitCode = 1
  Err.Clear
End If
On Error GoTo 0

' PowerShell can fail before its own catch block is active. Publish a terminal
' error here as a second safety net so the REAPER-side poll never waits forever.
Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FileExists(resultPath) Then
  fallbackPath = resultPath & ".vbs.tmp"
  Set fallback = fso.CreateTextFile(fallbackPath, True, False)
  If launchError <> "" Then
    fallback.Write "ERROR" & vbLf & "The folder browser could not start: " & launchError
  Else
    fallback.Write "ERROR" & vbLf & "The folder browser closed without returning a result (code " & exitCode & ")."
  End If
  fallback.Close
  If fso.FileExists(resultPath) Then fso.DeleteFile resultPath, True
  fso.MoveFile fallbackPath, resultPath
End If

WScript.Quit exitCode
