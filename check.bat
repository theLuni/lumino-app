@echo off
chcp 65001 >nul
echo ====================================
echo  ПРОВЕРКА ОКРУЖЕНИЯ
echo ====================================
echo.

echo [GIT]
git --version
if errorlevel 1 echo   ОШИБКА: git не найден в PATH
echo.

echo [FLUTTER]
flutter --version
if errorlevel 1 echo   ОШИБКА: flutter не найден в PATH
echo.

echo [ТЕКУЩАЯ ПАПКА]
cd
echo.

echo [ФАЙЛЫ В ПАПКЕ]
dir /b
echo.

echo ====================================
echo  Готово. Нажми любую клавишу...
pause >nul
