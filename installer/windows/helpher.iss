; Inno Setup installer script for HelpHer (Windows).
; Version and output file name are injected by CI using ISCC /D switches.

#ifndef AppName
  #define AppName "HelpHer"
#endif

#ifndef AppExeName
  #define AppExeName "helpher.exe"
#endif

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef OutputBaseFilename
  #define OutputBaseFilename "HelpHer-Setup"
#endif

[Setup]
AppId={{8E9C6B82-0A37-4B0E-9A03-3EAD4C2B71C7}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename={#OutputBaseFilename}
UninstallDisplayIcon={app}\{#AppExeName}
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; CI passes /DSourceDir to point at Flutter Release output folder.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

