@echo off
rem FastUpdate baslatici: terminal penceresi acmadan baslatir
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FastUpdate.ps1" %*
