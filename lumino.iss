
#define MyAppName "Lumino"
#define MyAppVersion "1.0.0"
#define MyAppExeName "lumino.exe"
#define MyAppPublisher "Lumino Industries"

[Setup]
AppId={{8D7F1D25-6B43-4C27-9B18-7A6D1E202626}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Lumino
DefaultGroupName=Lumino
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=C:\Users\luni\Music\flutter_app\assets\icon.ico
OutputDir=C:\Users\luni\Music\flutter_app\Output
OutputBaseFilename=Lumino_Setup
WizardStyle=modern
WizardSizePercent=120
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Messages]
WelcomeLabel1=Добро пожаловать в Lumino 💀
WelcomeLabel2=Сейчас мы сделаем вид, что всё под контролем.%n%nНажми «Далее». Назад пути нет.
FinishedHeadingLabel=Lumino успешно материализовался!
FinishedLabel=Установка завершена.%n%nПоздравляем. Ваш компьютер теперь в клубе Lumino.

[Files]
Source: "C:\Users\luni\Music\flutter_app\assets\icon.ico"; DestDir: "{app}"; DestName: "lumino.ico"; Flags: ignoreversion
Source: "C:\Users\luni\Music\flutter_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные приколы:"; Flags: unchecked

[Icons]
Name: "{autoprograms}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"
Name: "{autodesktop}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Lumino и принять последствия"; Flags: postinstall nowait skipifsilent
