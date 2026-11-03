; © 2026 Apurba Laskar — Byte for Windows installer (Inno Setup 6)
#define AppVer GetEnv("BYTE_VERSION")
#if AppVer == ""
  #define AppVer "1.4.3"
#endif

[Setup]
AppId={{6B7E3A52-1C4D-4E8B-9B1A-2F6A0C5D7E43}
AppName=Byte
AppVersion={#AppVer}
AppVerName=Byte {#AppVer}
AppPublisher=Apurba Laskar
AppCopyright=© 2026 Apurba Laskar
DefaultDirName={autopf}\Byte
DefaultGroupName=Byte
DisableProgramGroupPage=yes
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=Byte-Setup-v{#AppVer}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Byte.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Byte"; Filename: "{app}\Byte.exe"
Name: "{autodesktop}\Byte"; Filename: "{app}\Byte.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Byte.exe"; Description: "{cm:LaunchProgram,Byte}"; Flags: nowait postinstall skipifsilent
