; © 2026 Apurba Laskar
; Byte 2.0 for Windows: per-user setup program. No administrator rights needed.
; Installs the Flutter Windows Release folder, a Start menu entry, an optional desktop
; shortcut, and an uninstaller listed under Installed apps. Same AppId on every build,
; so a newer setup upgrades an older install in place.
; Compile with the Inno Setup 6 compiler (ISCC). Run from the repository root by
; .github/scripts/windows-installer-build.ps1, which passes the paths below.

#ifndef MyAppVersion
  #define MyAppVersion "2.0.0.2007"
#endif
#ifndef MyOutputName
  #define MyOutputName "Byte-2.0.0.2007-setup"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDirPath
  #define OutputDirPath "..\out\installer"
#endif

#define MyAppName "Byte"
#define MyAppExe "Byte.exe"
#define MyPublisher "Apurba Laskar"

[Setup]
AppId={{A3967736-04A6-40BC-9D80-86F101275C9D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyPublisher}
AppCopyright=© 2026 Apurba Laskar
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyPublisher}
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} Setup
VersionInfoCopyright=© 2026 Apurba Laskar
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExe}
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir={#OutputDirPath}
OutputBaseFilename={#MyOutputName}
#ifdef FastBuild
Compression=lzma2/fast
#else
Compression=lzma2/max
#endif
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
UsePreviousAppDir=yes
CloseApplications=yes
CloseApplicationsFilter={#MyAppExe}
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExe}"; WorkingDir: "{app}"; Description: "Open {#MyAppName}"; Flags: nowait postinstall skipifsilent
