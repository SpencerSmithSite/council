; Inno Setup script for the Council Windows installer.
;
; Built by .github/workflows/release-desktop.yml, which passes the version in:
;   ISCC.exe /DAppVersion=2026.7.27 windows\packaging\council.iss
;
; Paths are relative to this file, so it also compiles from a local checkout
; after `flutter build windows --release`.

#define AppName "Council"
#define AppPublisher "Spencer Smith"
#define AppURL "https://spencersmith.site/council/"
#define ExeName "council.exe"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId — it is what lets an installer upgrade a previous install
; in place rather than leaving two copies of Council in Add/Remove Programs.
AppId={{3F1C7215-105A-4E68-9D9C-5575FFD85F31}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
VersionInfoVersion={#AppVersion}

; Per-user install into %LOCALAPPDATA%, so the installer needs no administrator
; prompt. Council writes only to its own data directories and registers nothing
; machine-wide, so there is nothing to gain from an elevated install.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir=..\..\dist
OutputBaseFilename=Council-windows-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; The whole Flutter bundle: council.exe, flutter_windows.dll, the plugin DLLs
; and the data\ directory. Shipping less than all of it produces an app that
; installs and then fails to start.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
