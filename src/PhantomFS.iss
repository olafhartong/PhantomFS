; PhantomFS.iss — Inno Setup 6 installer script
; https://jrsoftware.org/isinfo.php
;
; Compile with:  ISCC.exe PhantomFS.iss
; Output:        installer\Output\PhantomFSSetup-1.0.0.exe

#define AppName      "PhantomFS"
#define AppVersion   "1.0.0"
#define AppPublisher "Your Organisation"
#define AppURL       "https://github.com/yourorg/phantomfs"
#define AppExeName   "PhantomFS.exe"
#define AppGUID      "{{A3F7C2D1-84BE-4E9A-B0C5-123456789ABC}"

[Setup]
AppId                    = {#AppGUID}
AppName                  = {#AppName}
AppVersion               = {#AppVersion}
AppPublisher             = {#AppPublisher}
AppPublisherURL          = {#AppURL}
AppSupportURL            = {#AppURL}/issues
AppUpdatesURL            = {#AppURL}/releases
DefaultDirName           = {autopf}\{#AppName}
DefaultGroupName         = {#AppName}
OutputDir                = Output
OutputBaseFilename       = PhantomFSSetup-{#AppVersion}
SetupIconFile            = ..\assets\phantomfs.ico
Compression              = lzma2/ultra64
SolidCompression         = yes
WizardStyle              = modern
PrivilegesRequired       = admin
PrivilegesRequiredOverridesAllowed = commandline
MinVersion               = 10.0.17763
; Windows 10 v1809 (Build 17763) required for ProjFS
UninstallDisplayIcon     = {app}\{#AppExeName}
UninstallDisplayName     = {#AppName} {#AppVersion}
VersionInfoVersion       = {#AppVersion}
VersionInfoCompany       = {#AppPublisher}
VersionInfoDescription   = PhantomFS — Virtual Honeypot File System
VersionInfoCopyright     = Copyright (C) 2025 {#AppPublisher}
ArchitecturesInstallIn64BitMode = x64compatible
ArchitecturesAllowed     = x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon";    Description: "Create a &Desktop shortcut";    GroupDescription: "Additional icons:"; Flags: unchecked
Name: "startuptask";    Description: "Run at &Windows startup (Task Scheduler)"; GroupDescription: "Autostart:"; Flags: unchecked

[Files]
; Main executable and config
Source: "..\bin\Release\PhantomFS.exe";       DestDir: "{app}";  Flags: ignoreversion
Source: "..\PhantomFS.exe.config";            DestDir: "{app}";  Flags: ignoreversion onlyifdoesntexist
; Documentation
Source: "..\README.md";                        DestDir: "{app}";  Flags: ignoreversion
Source: "..\docs\index.md";                    DestDir: "{app}\docs"; Flags: ignoreversion
; Assets
Source: "..\assets\phantomfs.ico";            DestDir: "{app}";  Flags: ignoreversion

[Icons]
Name: "{group}\PhantomFS";                   Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\PhantomFS";           Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{group}\Configuration";               Filename: "{app}\PhantomFS.exe.config"
Name: "{group}\Documentation";               Filename: "{app}\docs\index.md"

[Run]
; ── Enable ProjFS ──────────────────────────────────────────────────────────
; Check whether Client-ProjFS is already enabled before attempting to enable
; it — the Enable cmdlet returns an error code if the feature is already on.
Filename: "powershell.exe";
  Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""$f=(Get-WindowsOptionalFeature -Online -FeatureName Client-ProjFS); if($f.State -ne 'Enabled') {{ Enable-WindowsOptionalFeature -Online -FeatureName Client-ProjFS -NoRestart }}""";
  Description: "Enabling Windows ProjFS optional feature";
  StatusMsg: "Enabling Windows Projected File System\u2026";
  Flags: runhidden waituntilterminated; RunOnceId: "EnableProjFS"

; ── Register EventLog source ───────────────────────────────────────────────
Filename: "powershell.exe";
  Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""if(-not [System.Diagnostics.EventLog]::SourceExists('PhantomFS')) {{ [System.Diagnostics.EventLog]::CreateEventSource('PhantomFS','Application') }}""";
  Description: "Registering Windows Event Log source";
  StatusMsg: "Registering Event Log source\u2026";
  Flags: runhidden waituntilterminated; RunOnceId: "RegisterEventLog"

; ── Create default virtual root ────────────────────────────────────────────
Filename: "powershell.exe";
  Parameters: "-NonInteractive -NoProfile -Command ""New-Item -ItemType Directory -Force -Path 'C:\PhantomFS\Virtual' | Out-Null""";
  Description: "Creating default virtual root directory";
  Flags: runhidden waituntilterminated; RunOnceId: "CreateVirtRoot"

; ── Launch PhantomFS after install (optional) ─────────────────────────────
Filename: "{app}\{#AppExeName}";
  Parameters: "--syntheticonly --virtroot ""C:\PhantomFS\Virtual""";
  Description: "Launch PhantomFS now";
  Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop any running PhantomFS instances gracefully before uninstall.
Filename: "taskkill.exe";
  Parameters: "/IM PhantomFS.exe /F";
  Flags: runhidden waituntilterminated; RunOnceId: "KillPhantomFS"

; Remove scheduled startup task if it was created.
Filename: "schtasks.exe";
  Parameters: "/Delete /TN ""PhantomFS"" /F";
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveStartupTask"

; Remove the EventLog source.
Filename: "powershell.exe";
  Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""try{{ [System.Diagnostics.EventLog]::DeleteEventSource('PhantomFS') }}catch{{}}""";
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveEventLog"

[Code]
// ── Inno Setup Pascal code ─────────────────────────────────────────────────

// Checks for Windows 10 v1809 (Build 17763) or later.
// ProjFS is only available from this build onward.
function InitializeSetup(): Boolean;
var
  Build: Cardinal;
begin
  Result := True;
  if not GetWindowsVersionEx(GetWindowsVersion, Build) then
    Build := 0;
  // WindowsVersionIsAtLeast reports the OS version; check build number via registry.
  if Build < 17763 then
  begin
    MsgBox(
      'PhantomFS requires Windows 10 version 1809 (Build 17763) or later.'  + #13#10
    + 'Windows Projected File System (ProjFS) is not available on this system.' + #13#10#13#10
    + 'Please upgrade Windows and try again.',
      mbError, MB_OK);
    Result := False;
  end;
end;

// Register the startup scheduled task if the user chose that option.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  ExePath: String;
begin
  if CurStep = ssPostInstall then
  begin
    if IsTaskSelected('startuptask') then
    begin
      ExePath := ExpandConstant('{app}\PhantomFS.exe');
      Exec(
        'schtasks.exe',
        '/Create /SC ONLOGON /TN "PhantomFS"'
        + ' /TR "\"' + ExePath + '\" --syntheticonly --virtroot ""C:\PhantomFS\Virtual\"""'
        + ' /RU SYSTEM /RL HIGHEST /F',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;

// Dummy function to satisfy the WindowsVersionIsAtLeast check above.
// Inno Setup does not expose the build number natively; read it from registry.
function GetWindowsVersionEx(Version: Cardinal; var Build: Cardinal): Boolean;
var
  S: String;
begin
  Result := RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    'CurrentBuildNumber', S);
  if Result then
    Build := StrToIntDef(S, 0);
end;
