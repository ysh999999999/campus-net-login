@echo off
chcp 65001 >nul
pushd "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\reconnect.ps1"
pause
