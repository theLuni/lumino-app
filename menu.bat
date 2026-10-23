@echo off
setlocal enabledelayedexpansion

:MAIN_MENU
cls
echo.
echo  ================================
echo    GIT + FLUTTER TOOLKIT
echo  ================================
echo.
echo   [1]  GIT   -- push / pull / status
echo   [2]  BUILD -- android / windows
echo   [3]  RUN   -- android / windows
echo   [4]  TOOLS -- test / doctor
echo   [5]  EXIT
echo.
echo  ================================
echo.
set CHOICE=
set /p CHOICE=  Choose (1-5): 
if "!CHOICE!"=="1" goto GIT_MENU
if "!CHOICE!"=="2" goto BUILD_MENU
if "!CHOICE!"=="3" goto RUN_MENU
if "!CHOICE!"=="4" goto TOOLS_MENU
if "!CHOICE!"=="5" goto EXIT
echo   Invalid choice.
pause
goto MAIN_MENU


rem ================================
rem  GIT
rem ================================
:GIT_MENU
cls
echo.
echo  ================================
echo           GIT
echo  ================================
echo.
echo   [1]  PUSH   (upload to GitHub)
echo   [2]  PULL   (download from GitHub)
echo   [3]  STATUS
echo   [4]  Back
echo.
set CHOICE=
set /p CHOICE=  Choose (1-4): 
if "!CHOICE!"=="1" goto PUSH
if "!CHOICE!"=="2" goto PULL
if "!CHOICE!"=="3" goto STATUS
if "!CHOICE!"=="4" goto MAIN_MENU
echo   Invalid choice.
pause
goto GIT_MENU

:PUSH
cls
echo.
echo  ================================
echo    PUSH  --^>  GitHub
echo  ================================
echo.
echo  [1/3] git add .
git add .
echo  [1/3] DONE  (exit: %errorlevel%)
echo.
echo  [2/3] Commit message:
set MSG=
set /p MSG=  ^> 
if "!MSG!"=="" set MSG=update
git commit -m "!MSG!"
echo  [2/3] DONE  (exit: %errorlevel%)
echo.
echo  [3/3] git push...
git push
echo  [3/3] DONE  (exit: %errorlevel%)
echo.
echo  Push complete!
echo.
pause
goto GIT_MENU

:PULL
cls
echo.
echo  ================================
echo    PULL  ^<--  GitHub
echo  ================================
echo.
echo  [1/1] git pull...
git pull
echo  [1/1] DONE  (exit: %errorlevel%)
echo.
echo  Pull complete!
echo.
pause
goto GIT_MENU

:STATUS
cls
echo.
echo  ================================
echo          GIT STATUS
echo  ================================
echo.
git status
echo.
echo  -- Last 5 commits --
git log --oneline -5
echo.
pause
goto GIT_MENU


rem ================================
rem  BUILD
rem ================================
:BUILD_MENU
cls
echo.
echo  ================================
echo           BUILD
echo  ================================
echo.
echo   [1]  Android  --release
echo   [2]  Android  --debug
echo   [3]  Windows  --release
echo   [4]  Windows  --debug
echo   [5]  Back
echo.
set CHOICE=
set /p CHOICE=  Choose (1-5): 
if "!CHOICE!"=="1" goto BUILD_ANDROID_RELEASE
if "!CHOICE!"=="2" goto BUILD_ANDROID_DEBUG
if "!CHOICE!"=="3" goto BUILD_WINDOWS_RELEASE
if "!CHOICE!"=="4" goto BUILD_WINDOWS_DEBUG
if "!CHOICE!"=="5" goto MAIN_MENU
echo   Invalid choice.
pause
goto BUILD_MENU

:BUILD_ANDROID_RELEASE
cls
echo.
echo  ================================
echo    BUILD  Android  --release
echo  ================================
echo.
flutter build apk --release
echo.
echo  DONE  (exit: %errorlevel%)
echo  Output: build\app\outputs\flutter-apk\app-release.apk
echo.
pause
goto BUILD_MENU

:BUILD_ANDROID_DEBUG
cls
echo.
echo  ================================
echo    BUILD  Android  --debug
echo  ================================
echo.
flutter build apk --debug
echo.
echo  DONE  (exit: %errorlevel%)
echo  Output: build\app\outputs\flutter-apk\app-debug.apk
echo.
pause
goto BUILD_MENU

:BUILD_WINDOWS_RELEASE
cls
echo.
echo  ================================
echo    BUILD  Windows  --release
echo  ================================
echo.
flutter build windows --release
echo.
echo  DONE  (exit: %errorlevel%)
echo  Output: build\windows\x64\runner\Release\
echo.
pause
goto BUILD_MENU

:BUILD_WINDOWS_DEBUG
cls
echo.
echo  ================================
echo    BUILD  Windows  --debug
echo  ================================
echo.
flutter build windows --debug
echo.
echo  DONE  (exit: %errorlevel%)
echo  Output: build\windows\x64\runner\Debug\
echo.
pause
goto BUILD_MENU


rem ================================
rem  RUN
rem ================================
:RUN_MENU
cls
echo.
echo  ================================
echo             RUN
echo  ================================
echo.
echo   [1]  Android  --release
echo   [2]  Android  --debug
echo   [3]  Android  --profile
echo   [4]  Windows  --release
echo   [5]  Windows  --debug
echo   [6]  Windows  --profile
echo   [7]  Back
echo.
set CHOICE=
set /p CHOICE=  Choose (1-7): 
if "!CHOICE!"=="1" goto RUN_ANDROID_RELEASE
if "!CHOICE!"=="2" goto RUN_ANDROID_DEBUG
if "!CHOICE!"=="3" goto RUN_ANDROID_PROFILE
if "!CHOICE!"=="4" goto RUN_WINDOWS_RELEASE
if "!CHOICE!"=="5" goto RUN_WINDOWS_DEBUG
if "!CHOICE!"=="6" goto RUN_WINDOWS_PROFILE
if "!CHOICE!"=="7" goto MAIN_MENU
echo   Invalid choice.
pause
goto RUN_MENU

:RUN_ANDROID_RELEASE
cls
echo.
echo  ================================
echo    RUN  Android  --release
echo  ================================
echo.
flutter run --release
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU

:RUN_ANDROID_DEBUG
cls
echo.
echo  ================================
echo    RUN  Android  --debug
echo  ================================
echo.
flutter run --debug
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU

:RUN_ANDROID_PROFILE
cls
echo.
echo  ================================
echo    RUN  Android  --profile
echo  ================================
echo.
flutter run --profile
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU

:RUN_WINDOWS_RELEASE
cls
echo.
echo  ================================
echo    RUN  Windows  --release
echo  ================================
echo.
flutter run -d windows --release
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU

:RUN_WINDOWS_DEBUG
cls
echo.
echo  ================================
echo    RUN  Windows  --debug
echo  ================================
echo.
flutter run -d windows --debug
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU

:RUN_WINDOWS_PROFILE
cls
echo.
echo  ================================
echo    RUN  Windows  --profile
echo  ================================
echo.
flutter run -d windows --profile
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto RUN_MENU


rem ================================
rem  TOOLS
rem ================================
:TOOLS_MENU
cls
echo.
echo  ================================
echo            TOOLS
echo  ================================
echo.
echo   [1]  flutter test
echo   [2]  flutter test  (verbose)
echo   [3]  flutter doctor
echo   [4]  flutter doctor  (verbose)
echo   [5]  Back
echo.
set CHOICE=
set /p CHOICE=  Choose (1-5): 
if "!CHOICE!"=="1" goto TEST
if "!CHOICE!"=="2" goto TEST_VERBOSE
if "!CHOICE!"=="3" goto DOCTOR
if "!CHOICE!"=="4" goto DOCTOR_VERBOSE
if "!CHOICE!"=="5" goto MAIN_MENU
echo   Invalid choice.
pause
goto TOOLS_MENU

:TEST
cls
echo.
echo  ================================
echo        FLUTTER TEST
echo  ================================
echo.
flutter test
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto TOOLS_MENU

:TEST_VERBOSE
cls
echo.
echo  ================================
echo    FLUTTER TEST  (verbose)
echo  ================================
echo.
flutter test --reporter expanded
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto TOOLS_MENU

:DOCTOR
cls
echo.
echo  ================================
echo       FLUTTER DOCTOR
echo  ================================
echo.
flutter doctor
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto TOOLS_MENU

:DOCTOR_VERBOSE
cls
echo.
echo  ================================
echo   FLUTTER DOCTOR  (verbose)
echo  ================================
echo.
flutter doctor -v
echo.
echo  DONE  (exit: %errorlevel%)
echo.
pause
goto TOOLS_MENU


:EXIT
endlocal
exit /b 0