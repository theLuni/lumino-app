@echo off
setlocal enabledelayedexpansion

:MAIN_MENU
cls
echo ==============================
echo    GIT + FLUTTER MENU
echo ==============================
echo.
echo  1. PUSH  (upload to GitHub)
echo  2. PULL  (download from GitHub)
echo  3. STATUS
echo  4. EXIT
echo.
echo ==============================
echo.
set CHOICE=
set /p CHOICE=Choose (1-4): 
echo.

if "!CHOICE!"=="1" goto PUSH
if "!CHOICE!"=="2" goto PULL
if "!CHOICE!"=="3" goto STATUS
if "!CHOICE!"=="4" goto EXIT
echo Invalid choice.
pause
goto MAIN_MENU


:PUSH
cls
echo ==============================
echo  PUSH - Upload to GitHub
echo ==============================
echo.

echo [1/3] Running: git add .
git add .
echo [1/3] git add DONE (exit code: %errorlevel%)
echo.

echo [2/3] Enter commit message:
set MSG=
set /p MSG=^> 
if "!MSG!"=="" set MSG=update
echo.
git commit -m "!MSG!"
echo [2/3] git commit DONE (exit code: %errorlevel%)
echo.

echo [3/3] Running: git push...
git push
echo [3/3] git push DONE (exit code: %errorlevel%)
echo.
echo All done! Press any key to go back...
pause
goto MAIN_MENU


:PULL
cls
echo ==============================
echo  PULL - Download from GitHub
echo ==============================
echo.
echo [1/1] Running: git pull...
git pull
echo [1/1] git pull DONE (exit code: %errorlevel%)
echo.
pause
goto MAIN_MENU


:STATUS
cls
echo ==============================
echo         GIT STATUS
echo ==============================
echo.
git status
echo.
echo === LAST 5 COMMITS ===
git log --oneline -5
echo.
pause
goto MAIN_MENU


:EXIT
endlocal
exit /b 0
