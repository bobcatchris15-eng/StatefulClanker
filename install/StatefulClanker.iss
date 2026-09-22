; StatefulClanker Windows installer (Inno Setup 6).
;
; Build with install\Build-Installer.ps1. It generates the icon, publishes the
; self-contained native WinForms host, then invokes ISCC with RepoRoot/PublishDir.

#ifndef MyAppVersion
  #define MyAppVersion "0.8.16"
#endif
#ifndef RepoRoot
  #define RepoRoot ".."
#endif
#ifndef PublishDir
  #define PublishDir "publish"
#endif
#ifndef RouterPublishDir
  #define RouterPublishDir "router-publish"
#endif

#define MyAppName "StatefulClanker"
#define MyAppPublisher "StatefulClanker"
#define MyAppURL "https://github.com/bobcatchris15-eng/StatefulClanker"
#define MyAppExeName "StatefulClanker.exe"

[Setup]
AppId={{8E2A4F3C-7B91-4D6E-A5C2-1F0B9D3E6A47}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=StatefulClankerSetup-{#MyAppVersion}
SetupIconFile={#RepoRoot}\install\StatefulClanker.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#RepoRoot}\LICENSE
AppReadmeFile={app}\docs\SETUP.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startupicon"; Description: "Start {#MyAppName} automatically when I sign in"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; Native app shell. Build-Installer publishes it self-contained, so end users do not
; need a separate .NET runtime.
Source: "{#PublishDir}\*";                         DestDir: "{app}";          Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RouterPublishDir}\*";                   DestDir: "{app}\router";   Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime / MCP / docs remain ordinary files beside the app so provider CLI and
; PowerShell users can inspect, grep and invoke them directly.
Source: "{#RepoRoot}\StatefulClanker.ps1";         DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\Install-McpServer.ps1";       DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\statefulclanker.example.json";DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\README.md";                   DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE";                     DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\lib\*.ps1";                   DestDir: "{app}\lib";      Flags: ignoreversion
Source: "{#RepoRoot}\mcp\*.ps1";                   DestDir: "{app}\mcp";      Flags: ignoreversion
Source: "{#RepoRoot}\desktop\*.ps1";               DestDir: "{app}\desktop";  Flags: ignoreversion
Source: "{#RepoRoot}\docs\*.md";                   DestDir: "{app}\docs";     Flags: ignoreversion
Source: "{#RepoRoot}\skills\*";                    DestDir: "{app}\skills";   Flags: ignoreversion recursesubdirs
Source: "{#RepoRoot}\examples\*";                  DestDir: "{app}\examples"; Flags: ignoreversion recursesubdirs
Source: "{#RepoRoot}\tests\*";                     DestDir: "{app}\tests";    Flags: ignoreversion recursesubdirs
Source: "{#RepoRoot}\install\StatefulClanker.ico"; DestDir: "{app}\install";  Flags: ignoreversion
Source: "{#RepoRoot}\pi\*";                       DestDir: "{app}\pi";       Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RepoRoot}\install\pi-runtime\*";      DestDir: "{app}\pi\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}";                  Filename: "{app}\{#MyAppExeName}"; Comment: "Open the StatefulClanker Windows host"
Name: "{group}\Setup guide";                   Filename: "{app}\docs\SETUP.md"
Name: "{group}\Verify installation";           Filename: "powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -File ""{app}\tests\Smoke.ps1"""; Comment: "Run the local test suite"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";            Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}";            Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\install"
Type: dirifempty;     Name: "{app}"

[Code]
function PowerShellPresent(): Boolean;
var
  Found: Boolean;
  Paths: array[0..2] of String;
  I: Integer;
begin
  Paths[0] := ExpandConstant('{pf}\PowerShell\7\pwsh.exe');
  Paths[1] := ExpandConstant('{localappdata}\Microsoft\WindowsApps\pwsh.exe');
  Paths[2] := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Found := False;
  for I := 0 to 2 do
    if FileExists(Paths[I]) then Found := True;
  Result := Found;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not PowerShellPresent() then
  begin
    if MsgBox('No PowerShell host was found.' + Chr(13) + Chr(13) +
              'StatefulClanker uses PowerShell for its orchestration runtime and MCP provider adapters.' + Chr(13) +
              'Install PowerShell 7 with:  winget install Microsoft.PowerShell' + Chr(13) + Chr(13) +
              'Continue anyway?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;

procedure StopTrayApp();
var
  ResultCode: Integer;
begin
  // /T terminates the resident MCP PowerShell child as well as the native host.
  Exec(ExpandConstant('{cmd}'), '/C taskkill /F /T /IM StatefulClanker.exe >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopTrayApp();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopTrayApp();
  Result := True;
end;
