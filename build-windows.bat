@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo === Cunversa: gerando o .exe ===
where node >nul 2>nul || (echo Instale o Node.js primeiro: https://nodejs.org & pause & exit /b 1)
call npm install || (pause & exit /b 1)
call npm run dist || (pause & exit /b 1)
echo.
echo Pronto! Os arquivos estao na pasta "dist".
start "" "%~dp0dist"
pause
