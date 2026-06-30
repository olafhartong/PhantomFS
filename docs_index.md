# PhantomFS — Documentation

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [How ProjFS Works](#2-how-projfs-works)
3. [Alert Flow](#3-alert-flow)
4. [Event Log Reference](#4-event-log-reference)
5. [Toast Notifications](#5-toast-notifications)
6. [Configuration Reference](#6-configuration-reference)
7. [Synthetic File List](#7-synthetic-file-list)
8. [Content Templates](#8-content-templates)
9. [Deployment Patterns](#9-deployment-patterns)
10. [Building from Source](#10-building-from-source)
11. [Troubleshooting](#11-troubleshooting)
12. [FAQ](#12-faq)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    PhantomFS.exe                   │
│                                                     │
│  ┌─────────────────┐    ┌────────────────────────┐  │
│  │ PhantomFSProvider│  │     AlertManager       │  │
│  │                 │    │                        │  │
│  │  OnStartDir     │───▶│  OnPlaceholderCreated  │  │
│  │  OnGetEntries   │    │  OnFileAccessed        │  │
│  │  OnEndDir       │    │                        │  │
│  │  OnGetPhi       │    │  ┌──────────────────┐  │  │
│  │  OnData         │    │  │  EventLog writer  │  │  │
│  └────────┬────────┘    │  │  Toast (PS1)      │  │  │
│           │             │  └──────────────────┘  │  │
│           │             └────────────────────────┘  │
│           │                                         │
│           ▼                                         │
│  ┌─────────────────┐                                │
│  │  ConfigLoader   │                                │
│  │  (XML config)   │                                │
│  └─────────────────┘                                │
└───────────────┬─────────────────────────────────────┘
                │  ProjFS callbacks
                ▼
┌─────────────────────────────────────────────────────┐
│           Windows ProjFS Kernel Driver              │
│         (ProjectedFSLib.dll / projectedfslib.sys)   │
└───────────────┬─────────────────────────────────────┘
                │  File I/O
                ▼
       C:\PhantomFS\Virtual\
       └── Documents\
           ├── Q4_Financial_Report_2024.pdf      (projected)
           ├── Employee_Salaries_2024.xlsx        (projected)
           ├── Board_Meeting_Notes_Confidential.docx
           └── ...
```

PhantomFS sits entirely in user space. The ProjFS kernel driver intercepts file system calls to the virtual root and issues callbacks to `PhantomFSProvider`. The provider answers each callback from in-memory state — no real files exist on disk until a caller reads one.

---

## 2. How ProjFS Works

Windows Projected File System (ProjFS) is a kernel-mode file system filter that ships as an optional Windows component (`Client-ProjFS`). It allows a user-mode provider to project a virtual directory tree that is indistinguishable from a real directory to any application.

**Key concepts:**

- **Placeholder** — A sparse on-disk entry created the first time a file is stat'd or browsed. It stores metadata (name, size, timestamps) but no data. The callback that creates it is `GetPlaceholderInfo` — abbreviated `GetPhi` in ProjFS convention, since "Phi" is shorthand for "PlaceholderInfo."
- **Hydration** — When an application actually reads bytes from a placeholder, ProjFS calls `GetFileData`. The provider streams the content; ProjFS caches it. This is the primary alert trigger.
- **Virtualization instance** — Identified by a GUID stored in the root reparse point. PhantomFS wipes and re-marks the root on every start to avoid stale state.

Because placeholders look identical to real files in Explorer, `dir`, `Get-ChildItem`, and every other enumeration tool, the decoys are indistinguishable from real files to any attacker — even those who avoid Explorer entirely.

---

## 3. Alert Flow

```
Explorer / attacker tool
        │
        │  CreateFile / FindFirstFile / GetFileInformationByHandle
        ▼
ProjFS kernel driver
        │
        ├─── Directory enumeration ──▶ OnStartDir / OnGetEntries / OnEndDir
        │                               (no alert — browsing alone is not conclusive)
        │
        ├─── File stat / metadata ───▶ OnGetPlaceholderInfo (OnGetPhi)
        │                               AlertManager.OnPlaceholderCreated
        │                               → EventLog Warning 1002 (if alertOnOpen=true)
        │
        └─── File read (ReadFile) ───▶ OnData (GetFileData)
                                        AlertManager.OnFileAccessed
                                        → EventLog Warning 1001
                                        → Toast notification (if cooldown expired)
```

**Why two alert levels?**

- **1002 — Placeholder created:** Fires when a file is stat'd or its metadata is queried — e.g., an attacker running `dir` with metadata flags, or a tool enumerating ACLs. Lower confidence; useful for audit trails.
- **1001 — File read:** Fires when bytes are actually read. High confidence — no legitimate user touches files they don't know about. This is the primary actionable alert.

The per-file cooldown (`toastCooldownSeconds`) prevents alert storms when a tool reads a large file in multiple `ReadFile` chunks. The EventLog entry is written on every read regardless of cooldown; only the Toast is throttled.

---

## 4. Event Log Reference

All events are written to **Windows Logs → Application** with source `PhantomFS`.

To view in PowerShell:

```powershell
Get-EventLog -LogName Application -Source PhantomFS -Newest 50
```

To export to CSV:

```powershell
Get-EventLog -LogName Application -Source PhantomFS |
    Select-Object TimeGenerated, EventID, EntryType, Message |
    Export-Csv -Path phantomfs_alerts.csv -NoTypeInformation
```

### Event ID Table

| ID | Level | Trigger | Message format |
|---|---|---|---|
| 1001 | Warning | File data read (`GetFileData`) | `PhantomFS — File accessed: <path>` |
| 1002 | Warning | Placeholder created (`GetPlaceholderInfo`) | `PhantomFS — Placeholder created: <path>` |
| 1003 | Information | Provider started | `PhantomFS — Started. Virtual root: <path>` |
| 1004 | Information | Provider stopped | `PhantomFS — Stopped.` |

### Forwarding to a SIEM

Use Windows Event Forwarding (WEF) or a log shipper (Winlogbeat, NXLog) to forward events to your SIEM. Filter on:

```
Source = "PhantomFS" AND EventID IN (1001, 1002)
```

---

## 5. Toast Notifications

PhantomFS sends Toast notifications via PowerShell using the Windows Runtime `ToastNotificationManager` API. No external dependencies are required beyond Windows PowerShell 5.1, which ships with every supported Windows version.

**Notification content:**

- **Title:** `PhantomFS — Honeypot Alert`
- **Body:** `File accessed: <filename>` — `<timestamp>`

Toasts are sent using a PowerShell `-EncodedCommand` launched in a detached process so they do not block the alert path. The AUMID used is the Windows PowerShell shell entry, which is guaranteed to be registered on all supported Windows versions.

**Cooldown behavior:**

Each unique file path has its own cooldown timer tracked in a `ConcurrentDictionary<string, DateTime>`. When a file is read:

1. Check if the path is in the dictionary and the last alert was within `toastCooldownSeconds`
2. If within cooldown — skip Toast, still write EventLog
3. If outside cooldown (or first access) — send Toast, update dictionary

**Disabling Toasts:**

Set `enableToast` to `false` in `<settings>`. EventLog alerts continue regardless.

---

## 6. Configuration Reference

Full annotated `PhantomFS.exe.config`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>

  <!-- Runtime settings -->
  <settings>
    <!-- Write to Windows Application event log -->
    <add key="enableEventLog"       value="true"  />

    <!-- Send desktop Toast notification on file access -->
    <add key="enableToast"          value="true"  />

    <!-- Alert when a placeholder is first created (file stat / metadata query) -->
    <add key="alertOnOpen"          value="true"  />

    <!-- Alert when file data is actually read (primary alert) -->
    <add key="alertOnRead"          value="true"  />

    <!-- Minimum seconds between Toast alerts for the same file path -->
    <add key="toastCooldownSeconds" value="15"    />

    <!-- Extra console output for diagnostics -->
    <add key="verbose"              value="false" />

    <!-- Override virtual root path — leave empty to use command-line argument -->
    <add key="virtRoot"             value=""      />

    <!-- Optional real backing directory — leave empty for synthetic-only -->
    <add key="sourceRoot"           value=""      />

    <!-- Serve only files listed in <syntheticFileList>; ignore sourceRoot -->
    <add key="syntheticOnly"        value="true"  />
  </settings>

  <!-- ... syntheticFileList and fileContentTemplates below ... -->

</configuration>
```

---

## 7. Synthetic File List

The `<syntheticFileList>` section defines the virtual directory tree. Each `<folder>` maps to a subdirectory under the virtual root. Each `<file>` entry defines a projected file.

```xml
<syntheticFileList>
  <folder name="\Documents">
    <file name="Q4_Financial_Report_2024.pdf"       size="8192"  template="pdf"   />
    <file name="Employee_Salaries_2024.xlsx"         size="4096"  template="xlsx"  />
    <file name="Board_Meeting_Notes_Confidential.docx" size="6144" template="docx" />
    <file name="Acquisition_NDA_Draft.docx"          size="5120"  template="docx"  />
    <file name="IP_Valuation_Report_2024.pdf"        size="12288" template="pdf"   />
    <file name="Executive_Compensation_2024.xlsx"    size="3840"  template="xlsx"  />
    <file name="Merger_Term_Sheet.pdf"               size="9216"  template="pdf"   />
  </folder>
  <folder name="\IT\Keys">
    <file name="id_rsa"           size="3247"  template="pem"        />
    <file name="deploy_key.pem"   size="3247"  template="pem"        />
    <file name="github_pat.txt"   size="93"    template="github_pat" />
  </folder>
</syntheticFileList>
```

**Attributes:**

| Attribute | Required | Description |
|---|---|---|
| `name` | Yes | Exact filename shown in Explorer |
| `size` | Yes | Reported file size in bytes (does not need to match template byte length exactly) |
| `template` | Yes | Name of a `<template>` entry in `<fileContentTemplates>` |

**Naming tips for convincing decoys:**

- Use realistic years in filenames — `2024`, `2025`, `Q3`, `FY25`
- Mix formats — a directory with only PDFs looks staged; mix XLSX, DOCX, PDF, and TXT
- Use department names — `\HR`, `\Finance`, `\Legal`, `\IT\Keys`
- For developer machines — `\repos\deploy_keys`, `\aws\credentials`, `\.ssh`

---

## 8. Content Templates

Templates define the raw bytes returned when a file is read. They are stored in `<fileContentTemplates>` as CDATA blocks.

### Built-in Templates

| Template name | Mimics | Notes |
|---|---|---|
| `pdf` | PDF 1.4 document | Minimal valid PDF; renders in Edge, Chrome, Acrobat |
| `xlsx` | Excel spreadsheet | HTML with Office namespace headers — Excel opens with format-mismatch prompt, which triggers `GetFileData` |
| `docx` | Word document | HTML with Word namespace headers — same Office prompt behavior |
| `credentials` | AWS credentials file | `[default]` block with fake access key and secret |
| `pem` | RSA/Ed25519 private key | Valid PEM structure with randomized base64 payload |
| `github_pat` | GitHub personal access token | `ghp_` prefixed 40-char token |
| `api_keys` | JSON API key store | Fake Stripe, Twilio, SendGrid keys |
| `csv` | Generic data CSV | Header row + sample rows |
| `json` | Generic JSON config | Key/value config structure |
| `txt` | Plain text | "CONFIDENTIAL" stub |

### Adding a Custom Template

```xml
<fileContentTemplates>
  <template name="vpn_config">
    <![CDATA[
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = vpn.corp-internal.example.com:51820
AllowedIPs = 0.0.0.0/0
    ]]>
  </template>
</fileContentTemplates>
```

Then reference it in `<syntheticFileList>`:

```xml
<file name="corp-vpn.conf" size="312" template="vpn_config" />
```

### Why Office Files Use HTML

The XLSX and DOCX templates are HTML documents with Office XML namespace headers. When Office opens them it displays a format-mismatch warning — the user must click **Yes** to open the file. That click triggers a second `ReadFile` call, which fires the `GetFileData` callback and generates an Event ID 1001 alert. This produces a deliberate two-stage signal: the first `GetPlaceholderInfo` call (1002) tells you a file was browsed, and the subsequent read (1001) tells you someone deliberately opened it despite the warning.

---

## 9. Deployment Patterns

### Workstation Canary

Run PhantomFS as a scheduled task that starts at logon under the `SYSTEM` account. Place the virtual root at a path that looks like a legitimate user directory:

```
C:\Users\Public\Documents\Finance
```

Any lateral movement tool that enumerates shares or user directories will browse the decoys and trigger a 1002. If it reads a file — full alert.

### File Server Share

Create a share alongside your real finance or HR share:

```powershell
New-SmbShare -Name "Finance_Archive" -Path "C:\PhantomFS\Virtual" -ReadAccess "Everyone"
```

Name it something archival — `Finance_Archive`, `HR_2022`, `Legal_Backup`. Legitimate users will not go looking in old archives. Attackers doing reconnaissance will.

### Developer Machine — Credential Canary

Mirror the layout an attacker expects after compromising a developer's machine:

```xml
<folder name="\.aws">
  <file name="credentials"  size="186"  template="credentials" />
</folder>
<folder name="\.ssh">
  <file name="id_rsa"       size="3247" template="pem"         />
  <file name="id_ed25519"   size="411"  template="pem"         />
</folder>
```

Set `virtRoot` to `C:\Users\%USERNAME%\PhantomFS` and expose it as `C:\Users\%USERNAME%\.aws` via a junction:

```cmd
mklink /J C:\Users\%USERNAME%\.aws C:\Users\%USERNAME%\PhantomFS\.aws
```

---

## 10. Building from Source

### Prerequisites

- Windows 10 / 11 (64-bit)
- [.NET Framework 4.8 Developer Pack](https://dotnet.microsoft.com/download/dotnet-framework/net48)
- Visual Studio 2022 (any edition) **or** standalone `csc.exe` from the SDK

### Command-line Build

```powershell
# From the repo root
csc.exe /platform:x64 /r:System.Xml.dll /out:PhantomFS.exe src\PhantomFS.cs
```

`csc.exe` is typically at:
```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
```

### Visual Studio Build

Open `PhantomFS.sln` → **Build → Build Solution**. The output lands in `bin\Release\net48\`.

---

## 11. Troubleshooting

### `HR_ERROR_FILE_SYSTEM_VIRTUALIZATION_PROVIDER_NOT_FOUND` (0x80004005)

ProjFS is not enabled. Run:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Client-ProjFS -NoRestart
```

Then reboot.

### `HR_NOT_A_REPARSE_POINT` (0x80071126)

The virtual root directory exists from a previous run but the reparse point was not cleaned up. PhantomFS normally handles this automatically on startup by wiping and re-marking the root. If it persists:

```powershell
Remove-Item -Recurse -Force C:\PhantomFS\Virtual
New-Item -ItemType Directory -Path C:\PhantomFS\Virtual
```

### Toasts not appearing

- Confirm Windows PowerShell 5.1 is installed: `$PSVersionTable.PSVersion`
- Confirm Do Not Disturb / Focus Assist is not active
- Confirm the session is interactive (Toasts do not fire for non-interactive service sessions)
- Set `verbose=true` in config and check console output for PowerShell error text

### EventLog source not registered

```powershell
New-EventLog -LogName Application -Source PhantomFS
```

Requires elevation.

### Decoy files not visible in Explorer

- Confirm PhantomFS.exe is running
- Confirm the virtual root path matches the path you are browsing
- Try `dir C:\PhantomFS\Virtual\Documents` from an elevated command prompt
- Enable `verbose=true` and check for callback errors

---

## 12. FAQ

**Q: Does PhantomFS write any real data to disk?**

A: No data is written during enumeration or stat operations. When a file is hydrated (read), ProjFS may cache the content in the placeholder on disk. This is controlled by ProjFS — PhantomFS has no option to suppress it — but the cached data is only the synthetic template content, not real sensitive data.

---

**Q: Will antivirus flag PhantomFS?**

A: PhantomFS does not inject code, modify other processes, or write to system locations. The ProjFS API is a documented, signed Microsoft API. Some heuristic engines may flag the PowerShell Toast launcher — add an exclusion for `PhantomFS.exe` if needed.

---

**Q: Can I run multiple instances for different virtual roots?**

A: Yes — each instance needs a unique virtual root path. Run multiple copies of `PhantomFS.exe` with different root arguments. Each instance registers independently with ProjFS.

---

**Q: Does this work on Windows Server?**

A: ProjFS ships as `FS-FileServer-PROJFS` on Windows Server 2019+:

```powershell
Install-WindowsFeature -Name FS-FileServer-PROJFS
```

All other PhantomFS functionality is identical.

---

**Q: Can attackers detect that a file is a ProjFS placeholder?**

A: Technically yes — a process with sufficient privileges can query the reparse point tag on a file and identify it as a ProjFS placeholder. In practice, no standard reconnaissance tool does this check. The files are indistinguishable from real files to Explorer, PowerShell, cmd, Python `os.stat`, and every common attacker toolchain.

---

**Q: Is the honeypot data convincing enough to fool a sophisticated attacker?**

A: The filenames, directory structure, and file sizes are convincing. The content templates are plausible stubs — a sophisticated attacker who reads the full text of a "PDF" will notice it is not a real financial report. The goal is not to fool a human reading the file; it is to trigger the alert the moment the file is opened, before any human review occurs. At that point the attacker has already revealed themselves.
