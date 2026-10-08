@echo off
chcp 65001 >nul
pushd "%~dp0"
echo.
echo   1 = 常规清理（按保留策略删除过期文件）
echo   2 = 演练（只报告，不删除）
echo   3 = 强制清理（删除全部截图与轮转日志）
echo.
set /p c=请选择 [1]: 
if "%c%"=="" set c=1
if "%c%"=="2" powershell -ExecutionPolicy Bypass -File "%~dp0scripts\cleanup.ps1" -DryRun
if "%c%"=="3" powershell -ExecutionPolicy Bypass -File "%~dp0scripts\cleanup.ps1" -Force
if "%c%"=="1" powershell -ExecutionPolicy Bypass -File "%~dp0scripts\cleanup.ps1"
pause
