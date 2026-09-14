; StatefulClanker Windows installer (Inno Setup 6).
;
; Build with install\Build-Installer.ps1, which generates the icon and passes
; MyAppVersion and RepoRoot. Do not run ISCC directly without those defines.
;
; Deliberately a PER-USER install (PrivilegesRequired=lowest):
;   - no UAC prompt, so it installs on a locked-down machine
;   - the MCP client configs it writes are per-user anyway
;   - the tray app runs as the user and needs no elevation

#ifndef MyAppVersion
  #define MyAppVersion "0.5.0"
#endif
#ifndef RepoRoot
  #define RepoRoot ".."
#endif

#define MyAppName "StatefulClanker"
#define MyAppPublisher "StatefulClanker"
#define MyAppURL "https://github.com/bobcatchris15-eng/StatefulClanker"
#define MyAppExeName "StatefulClankerTray.vbs"

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
UninstallDisplayIcon={app}\install\StatefulClanker.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#RepoRoot}\LICENSE
AppReadmeFile={app}\docs\SETUP.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startupicon"; Description: "Start {#MyAppName} automatically when I sign in"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#RepoRoot}\StatefulClanker.ps1";            DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\Install-McpServer.ps1";          DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\statefulclanker.example.json";   DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\README.md";                      DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE";                        DestDir: "{app}";          Flags: ignoreversion
Source: "{#RepoRoot}\lib\*.ps1";                      DestDir: "{app}\lib";      Flags: ignoreversion
Source: "{#RepoRoot}\mcp\*.ps1";                      DestDir: "{app}\mcp";      Flags: ignoreversion
Source: "{#RepoRoot}\desktop\*.ps1";                  DestDir: "{app}\desktop";  Flags: ignoreversion
Source: "{#RepoRoot}\docs\*.md";                      DestDir: "{app}\docs";     Flags: ignoreversion
Source: "{#RepoRoot}\skills\*";                       DestDir: "{app}\skills";   Flags: ignoreversion recursesubdirs
Source: "{#RepoRoot}\examples\*";                     DestDir: "{app}\examples"; Flags: ignoreversion recursesubdirs
Source: "{#RepoRoot}\install\StatefulClankerTray.vbs"; DestDir: "{app}";         Flags: ignoreversion
Source: "{#RepoRoot}\install\StatefulClanker.ico";    DestDir: "{app}\install";  Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";                  Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\install\StatefulClanker.ico"; Comment: "Open the StatefulClanker tray app"
Name: "{group}\Setup guide";                   Filename: "{app}\docs\SETUP.md"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";            Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\install\StatefulClanker.ico"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}";            Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\install\StatefulClanker.ico"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName} now"; Flags: shellexec nowait postinstall skipifsilent

[UninstallDelete]
; Generated at runtime, so Inno does not track these.
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
    if FileExists(Paths[I]) then
      Found := True;
  Result := Found;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not PowerShellPresent() then
  begin
    // Keep '#13' off the start of a line: Inno's preprocessor reads a leading '#'
    // as a directive even inside [Code].
    if MsgBox('No PowerShell host was found.' + Chr(13) + Chr(13) +
              'StatefulClanker needs PowerShell 7 (recommended) or Windows PowerShell 5.1.' + Chr(13) +
              'Install it with:  winget install Microsoft.PowerShell' + Chr(13) + Chr(13) +
              'Continue anyway?', mbConfirmation, MB_YESNO) = IDNO then
      Result := False;
  end;
end;

// The tray app keeps running after install; leaving it running would lock its own
// files on upgrade or uninstall.
procedure StopTrayApp();
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /F /FI "WINDOWTITLE eq StatefulClanker*" >nul 2>&1',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
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
