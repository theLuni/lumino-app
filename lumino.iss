#define MyAppName "Lumino"
#define MyAppVersion "0.3.4"
#define MyAppExeName "lumino.exe"
#define MyAppPublisher "Lumino Industries"

[Setup]
AppId={{8D7F1D25-6B43-4C27-9B18-7A6D1E202626}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Lumino
UsePreviousAppDir=no
DefaultGroupName=Lumino
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile={#SourcePath}\assets\icon.ico
OutputDir={#SourcePath}\Output
OutputBaseFilename=Lumino
WizardStyle=modern
WizardSizePercent=120
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Messages]
WelcomeLabel1=Добро пожаловать в установку Lumino
WelcomeLabel2=Эта программа установит Lumino на ваш компьютер.%n%nРекомендуется закрыть все остальные приложения перед тем, как нажать «Далее».
FinishedHeadingLabel=Установка Lumino завершена
FinishedLabel=Lumino успешно установлен на ваш компьютер.%n%nНажмите «Завершить», чтобы закрыть мастер установки.

[Files]
Source: "{#SourcePath}\assets\icon.ico"; DestDir: "{app}"; DestName: "lumino.ico"; Flags: ignoreversion
Source: "{#SourcePath}\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; GroupDescription: "Дополнительные значки:"; Flags: unchecked

[Icons]
Name: "{autoprograms}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"
Name: "{autodesktop}\Lumino"; Filename: "{app}\lumino.exe"; IconFilename: "{app}\lumino.ico"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\lumino"; ValueType: string; ValueName: ""; ValueData: "URL:Lumino Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\lumino"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\lumino\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\lumino\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Lumino"; Flags: postinstall nowait skipifsilent