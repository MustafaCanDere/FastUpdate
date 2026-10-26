@echo off
rem FastUpdate baslatici - yonetici izni istenir
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FastUpdate.ps1" %*
