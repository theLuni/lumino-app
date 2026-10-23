
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
SetupIconFile={#SourcePath}\assets\icon.ico
OutputDir={#SourcePath}\Output
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
Source: "{#SourcePath}\assets\icon.ico"; DestDir: "{app}"; DestName: "lumino.ico"; Flags: ignoreversion
Source: "{#SourcePath}\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные приколы:"; Flags: unchecked

[Icons]
Name: "{autoprograms}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"
Name: "{autodesktop}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"; Tasks: desktopicon

[Registry]
Root: HKCR; Subkey: "lumino"; ValueType: string; ValueName: ""; ValueData: "URL:Lumino Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "lumino"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: "lumino\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Flags: uninsdeletekey
Root: HKCR; Subkey: "lumino\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Lumino и принять последствия"; Flags: postinstall nowait skipifsilent
