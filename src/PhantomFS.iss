; PhantomFS.iss - Inno Setup 6 installer script
; https://jrsoftware.org/isinfo.php
;
; This script lives in src\, alongside PhantomFS.cs and PhantomFS.exe.config.
; It packages the build output from bin\x64\ (produced by
; .github\workflows\build.yml or a local build), not files from src\
; directly, so the installer always ships exactly what was compiled and
; staged, not whatever happens to be sitting in the source tree.
;
; Compile with:  ISCC.exe PhantomFS.iss
; Output:        src\Output\PhantomFSSetup-1.3.0.exe

#define AppName      "PhantomFS"
; AppVersion defaults to 1.3.0 for a local "double-click ISCC.exe on this
; file" compile. CI passes /DAppVersion=<actual release version> instead,
; which wins over this default since #ifndef only defines it when the
; command line has not already done so, keeping the installer's version
; in lockstep with whatever version the release workflow is actually
; building rather than needing to be bumped here by hand every release.
#ifndef AppVersion
  #define AppVersion "1.3.0"
#endif
#define AppPublisher "Alloy Secure"
#define AppURL       "https://github.com/AlloySecureGroup/PhantomFS"
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
; No SetupIconFile: the repo's assets folder currently only has .png logos
; (phantomfs-logo.png, sticker_logo.png), and Inno Setup requires an actual
; .ico resource here. Add a real .ico under assets\ and uncomment the line
; below once one exists, rather than reference a file that doesn't exist.
; SetupIconFile          = ..\assets\phantomfs.ico
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
VersionInfoDescription   = PhantomFS - Virtual Honeypot File System
VersionInfoCopyright     = Copyright (C) 2026 {#AppPublisher}
ArchitecturesInstallIn64BitMode = x64compatible
ArchitecturesAllowed     = x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon";    Description: "Create a &Desktop shortcut";    GroupDescription: "Additional icons:"; Flags: unchecked
Name: "startuptask";    Description: "Run at &Windows startup (Task Scheduler)"; GroupDescription: "Autostart:"; Flags: unchecked

[Files]
; Main executable and its config, taken from the build output (bin\x64\),
; not from src\, so the installer ships exactly what CI compiled and
; staged together, config drift between src\ and the shipped binary is
; not possible this way.
Source: "..\bin\x64\PhantomFS.exe";           DestDir: "{app}";  Flags: ignoreversion
Source: "..\bin\x64\PhantomFS.exe.config";    DestDir: "{app}";  Flags: ignoreversion onlyifdoesntexist
; Documentation
Source: "..\README.md";                        DestDir: "{app}";  Flags: ignoreversion
Source: "..\docs_index.md";                    DestDir: "{app}\docs"; DestName: "index.md"; Flags: ignoreversion
; Assets
; No .ico currently exists in assets\ (only .png). Add one and uncomment
; once available; shortcuts below already work fine without it, they use
; the compiled exe's own embedded icon via {app}\{#AppExeName}.
; Source: "..\assets\phantomfs.ico";           DestDir: "{app}";  Flags: ignoreversion

[Icons]
Name: "{group}\PhantomFS";                   Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\PhantomFS";           Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{group}\Configuration";               Filename: "{app}\PhantomFS.exe.config"
Name: "{group}\Documentation";               Filename: "{app}\docs\index.md"

[Run]
; -- Enable ProjFS --------------------------------------------------------
; Check whether Client-ProjFS is already enabled before attempting to enable
; it - the Enable cmdlet returns an error code if the feature is already on.
; Each entry below is a single physical line: Inno Setup parses one line
; per [Run]/[UninstallRun] entry, it does not support continuing a single
; entry's Filename/Parameters/Description/Flags across multiple lines the
; way earlier revisions of this script assumed.
Filename: "powershell.exe"; Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""$f=(Get-WindowsOptionalFeature -Online -FeatureName Client-ProjFS); if($f.State -ne 'Enabled') {{ Enable-WindowsOptionalFeature -Online -FeatureName Client-ProjFS -NoRestart }}"""; Description: "Enabling Windows ProjFS optional feature"; StatusMsg: "Enabling Windows Projected File System..."; Flags: runhidden waituntilterminated

; -- Register EventLog source ---------------------------------------------
Filename: "powershell.exe"; Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""if(-not [System.Diagnostics.EventLog]::SourceExists('PhantomFS')) {{ [System.Diagnostics.EventLog]::CreateEventSource('PhantomFS','Application') }}"""; Description: "Registering Windows Event Log source"; StatusMsg: "Registering Event Log source..."; Flags: runhidden waituntilterminated

; -- Create default virtual root -------------------------------------------
Filename: "powershell.exe"; Parameters: "-NonInteractive -NoProfile -Command ""New-Item -ItemType Directory -Force -Path 'C:\PhantomFS\Virtual' | Out-Null"""; Description: "Creating default virtual root directory"; Flags: runhidden waituntilterminated

; -- Launch PhantomFS after install (optional) -----------------------------
Filename: "{app}\{#AppExeName}"; Parameters: "--syntheticonly --virtroot ""C:\PhantomFS\Virtual"""; Description: "Launch PhantomFS now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop any running PhantomFS instances gracefully before uninstall.
Filename: "taskkill.exe"; Parameters: "/IM PhantomFS.exe /F"; Flags: runhidden waituntilterminated; RunOnceId: "KillPhantomFS"

; Remove scheduled startup task if it was created.
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""PhantomFS"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveStartupTask"

; Remove the EventLog source.
Filename: "powershell.exe"; Parameters: "-NonInteractive -NoProfile -WindowStyle Hidden -Command ""try{{ [System.Diagnostics.EventLog]::DeleteEventSource('PhantomFS') }}catch{{}}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveEventLog"

[Code]
// -- Inno Setup Pascal code -------------------------------------------------

// Reads the OS build number from the registry. Defined before
// InitializeSetup below since Inno's Pascal Script has no forward
// declarations, a function must appear before its first use in the file.
function GetWindowsBuildNumber(): Cardinal;
var
  S: String;
begin
  Result := 0;
  if RegQueryStringValue(HKEY_LOCAL_MACHINE,
       'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
       'CurrentBuildNumber', S) then
    Result := StrToIntDef(S, 0);
end;

// Checks for Windows 10 v1809 (Build 17763) or later.
// ProjFS is only available from this build onward.
function InitializeSetup(): Boolean;
begin
  Result := True;
  if GetWindowsBuildNumber() < 17763 then
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
