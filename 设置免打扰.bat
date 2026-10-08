@echo off
chcp 65001 >nul
pushd "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\set_quiet_hours.ps1"
pause
