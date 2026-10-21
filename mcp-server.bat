@echo off
rem Launcher for the PowerShell 5.1 MCP server. Keep "@echo off" on line 1:
rem anything cmd echoes to stdout would corrupt the MCP protocol stream.
setlocal
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0mcp-server.ps1"
exit /b %ERRORLEVEL%
