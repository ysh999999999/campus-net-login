@echo off
chcp 65001 >nul
pushd "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\reset.ps1"
popd
pause
