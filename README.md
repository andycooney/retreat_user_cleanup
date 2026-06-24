# Prepare-LocalAdminMachine-v21.ps1

PowerShell provisioning script for preparing a Windows computer for a local `retreat`-style administrator/autologon user profile.

This script is designed for kiosk, presentation, event, retreat, or shared-use machines where the goal is to create a clean local admin experience with minimal startup noise, controlled power settings, required media/presentation apps, and a simplified desktop/taskbar.

> **Important:** Run from an elevated PowerShell session. Autologon stores the configured password in the Windows registry in a recoverable form. Use this only on trusted machines where that tradeoff is acceptable.

---

## Current version

```text
Prepare-LocalAdminMachine-v21.ps1
```

---

## Basic usage

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v21.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"
```

Optional domain-unjoin credential:

```powershell
$cred = Get-Credential

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v21.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere" `
  -DomainUnjoinCredential $cred
```

Optional workgroup name:

```powershell
-WorkgroupName "WORKGROUP"
```

---

## Parameters

| Parameter | Purpose | Default |
|---|---|---|
| `-LocalAdminUser` | Local administrator account to create/update and configure for autologon. | `localadmin` |
| `-LocalAdminPassword` | Password for the local administrator account and autologon. | `ChangeMe-Use-A-Strong-Password!` |
| `-WorkgroupName` | Workgroup to move the computer to if it is domain joined. | `WORKGROUP` |
| `-DomainUnjoinCredential` | Optional credential used when removing the computer from a domain. | none |

---

## High-level design

The script has two phases:

1. **Bootstrap/system phase**  
   Runs elevated and handles machine-level configuration.

2. **First-logon/user phase**  
   A second script is staged under `C:\ProgramData\DeltaProvisioning` and runs in the target user's context. This handles per-user settings that do not reliably apply from another account or from an elevated/system context.

If the bootstrap script is already being run as the target user, it creates and starts a least-privilege scheduled task so the first-logon script runs as the regular interactive user rather than inside the elevated Administrator process. If that user-context run cannot complete, the Startup trigger remains in place and retries at the next normal sign-in. If the bootstrap is not being run as the target user, it stages the Startup trigger so the first-logon script runs when the target user next signs in.

---

## Files created

The script may create the following files and folders:

```text
C:\retreat
C:\ProgramData\DeltaProvisioning\FirstLogon-For-<username>.ps1
C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
C:\ProgramData\DeltaProvisioning\TaskbarLayout-<username>.xml
C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Run-FirstLogon-Provisioning-For-<username>.cmd
Scheduled task: \DeltaProvisioning\DeltaProvisioning-FirstLogon-<username>
```

The Startup trigger is removed only after successful first-logon provisioning. When the bootstrap is run as the target user, the scheduled task is used to run the first-logon script as that regular interactive user with least privilege.

---

## What the bootstrap/system phase does

### Local administrator account

- Ensures the specified local user exists.
- Enables the account.
- Adds the account to the local `Administrators` group.
- Sets or resets the password unless the script is currently running as that same user.
- If already running as the target user, it assumes the supplied password is already correct and uses it for autologon.

### Autologon

Configures classic Windows autologon for the target local account by setting Winlogon registry values, including:

- `AutoAdminLogon`
- `ForceAutoLogon`
- `DefaultUserName`
- `DefaultPassword`
- `DefaultDomainName`

It also clears values that may interfere with autologon:

- `AutoLogonCount`
- `AutoLogonSID`
- `LastUsedUsername`

It also clears logon banner text and disables Ctrl+Alt+Del requirement where local policy allows.

### Domain membership

- Checks whether the computer is domain joined.
- If domain joined, attempts to remove it from the domain and move it to the configured workgroup.
- A reboot is required after domain removal.

### Startup cleanup

Disables/removes common startup entries from:

- `HKLM\Software\Microsoft\Windows\CurrentVersion\Run`
- `HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- Common Startup folder
- OneDrive/Teams/Microsoft Edge update-related scheduled tasks where found

### Required folder

Creates:

```text
C:\retreat
```

### Machine-level active content policies

Applies machine-level policy/registry settings to reduce or disable:

- Widgets
- News and Interests
- Search Highlights
- Windows Spotlight suggestions
- Consumer suggestions
- Tailored experiences
- Advertising ID
- Copilot taskbar exposure where supported
- Windows Hello/PIN/biometric provisioning prompts where supported
- Phone Link / mobile-device companion integrations where supported

### Security/VPN app removal attempts

Attempts to stop, disable, uninstall, or remove remnants of:

- Cisco AnyConnect
- Cisco Secure Client
- Duo Authentication for Windows Logon
- ThreatLocker

For ThreatLocker specifically, the script attempts to:

- Stop ThreatLocker processes.
- Disable ThreatLocker services.
- Request service stop/delete using `sc.exe` without waiting indefinitely.
- Delete ThreatLocker services using `sc delete`.
- Rename ThreatLocker folders to `.disabled`.
- Remove ThreatLocker registry keys where accessible.

Version 21 intentionally avoids blocking `Stop-Service` waits because partly removed ThreatLocker service entries can remain in a stuck stopping/deleted state.

> **Limit:** If ThreatLocker tamper protection is active, full removal may require the ThreatLocker portal or vendor-approved uninstall method.

For Duo, the script attempts uninstall via registry uninstall entries and checks for Duo credential provider DLLs.

> **Limit:** Duo Windows Logon may require Safe Mode or vendor recovery steps if credential provider removal is blocked.

### Windows Media Player Legacy

Ensures Windows Media Player Legacy is installed/enabled using Windows optional feature/capability handling.

### Power and screensaver settings

Configures power behavior:

- Plugged in / AC:
  - Display timeout: never
  - Sleep timeout: never
  - Hibernate timeout: never

- Battery / DC:
  - Display timeout: 240 minutes
  - Sleep timeout: 240 minutes
  - Hibernate timeout: 240 minutes

Also disables hibernation and screensaver where policy allows.

---

## What the first-logon/user phase does

The first-logon script runs as the target user, either immediately if the bootstrap is already running as that user or at the next user sign-in.

### Desktop cleanup

- Removes existing desktop items from the current user desktop.
- Removes existing desktop items from the Public Desktop.
- Creates a clean set of shortcuts:
  - File Explorer, opening `C:\retreat`
  - PowerPoint
  - Windows Media Player Legacy
  - Google Chrome

### Taskbar layout

Attempts to configure the taskbar to include only:

- File Explorer, opening `C:\retreat`
- PowerPoint
- Windows Media Player Legacy
- Google Chrome

The script uses a taskbar layout XML with `PinListPlacement="Replace"` and also stages canonical `.lnk` files for the pinned apps.

> **Limit:** On some Windows 10/11 builds, Microsoft restricts programmatic taskbar pinning for existing users. The script uses the strongest built-in/best-effort method, but a sign out/sign in or reboot may be required before the layout applies. Some builds may still require manual pinning.

### File Explorer shortcut behavior

The File Explorer taskbar and desktop shortcuts target:

```text
C:\retreat
```

The script also sets Explorer's built-in `LaunchTo` preference where supported, but Windows does not natively support setting all new Explorer windows to an arbitrary custom folder. The custom shortcut is the reliable behavior.

### Chrome

- Ensures Google Chrome is installed where possible.
- Adds Google Chrome to the taskbar and desktop shortcut set.
- Stages Chrome as the default browser for new profiles using default app associations.
- Applies best-effort Chrome default-browser nudges for the current user.

> **Limit:** Windows protects default-browser choices for existing users using per-user hashes. For existing profiles, Chrome may still need to be selected once under Settings > Apps > Default apps > Google Chrome.

### Spotify

- Checks whether Spotify is already installed.
- If not installed, attempts to install it using `winget` in the target user's context.

Spotify is intentionally handled in the first-logon/user phase because per-user app installs often do not behave correctly from an elevated bootstrap context. In v21, if the bootstrap is already running as the target user, Spotify is handled through a least-privilege scheduled task so it runs as the regular interactive user, not the elevated Administrator process. If Spotify is still not detected afterward, the Startup trigger remains so it retries at the next normal logon.

### Slido for PowerPoint

- Checks uninstall registry entries for Slido.
- Skips installation if Slido is already found.
- If not found, attempts installation using `winget`.

This avoids re-downloading or hanging on a Slido install when Slido is already present.

### Teams cleanup

- Kills running Teams processes.
- Removes Teams startup entries from current-user Run/RunOnce/StartupApproved locations.
- Removes Teams startup shortcuts.
- Disables Teams scheduled tasks where found.
- Updates Teams configuration files where found to suppress open-at-login behavior.

### Active content and Start cleanup

Applies per-user cleanup for:

- Taskbar search box
- Widgets
- News and Interests
- Task View button
- Chat/Teams personal taskbar button
- Copilot taskbar button where supported
- Windows Spotlight desktop/lock screen content
- “Learn about this picture” style Spotlight desktop content
- Tips/suggestions/welcome experience
- Start recommendations/account notifications
- Phone Link / “Show mobile device in Start” companion setting

### Windows Hello and setup prompts

Attempts to suppress:

- Windows Hello provisioning prompts
- PIN setup prompts
- Biometric prompts where policy allows
- “Finish setting up your device” style prompts

---

## Winget packages used

Where installation is needed and `winget` is available, the script uses package IDs such as:

```text
Google.Chrome
Spotify.Spotify
Slido.Slido
```

The script checks for installed applications before installing when possible.

---

## Logs

First-logon actions are logged to:

```text
C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
```

Review this log if taskbar, desktop, Chrome, Spotify, Slido, Teams, or user-interface cleanup does not apply as expected. Also check Task Scheduler under `\DeltaProvisioning` for `DeltaProvisioning-FirstLogon-<username>` when troubleshooting the user-context run.

---

## Recommended run sequence

1. Download the script to the machine.
2. Open PowerShell as Administrator.
3. Run the script with the target username and password.
4. Reboot.
5. Confirm the machine autologs into the target user.
6. Confirm the first-logon script runs or has already run.
7. If running as `retreat`, confirm the least-privilege scheduled task starts the first-logon script.
8. Confirm the desktop/taskbar layout after sign out/sign in or reboot.

Example:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v21.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"

Restart-Computer -Force
```

---

## Running from a GitHub raw URL

Recommended method: download first, then run from disk.

```powershell
mkdir C:\Temp -Force

Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/<owner>/<repo>/<tag-or-branch>/Prepare-LocalAdminMachine-v21.ps1" `
  -OutFile "C:\Temp\Prepare-LocalAdminMachine-v21.ps1"

Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Temp\Prepare-LocalAdminMachine-v21.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"
```

For a persistent URL, prefer a release tag instead of `main`:

```text
https://raw.githubusercontent.com/<owner>/<repo>/v21/Prepare-LocalAdminMachine-v21.ps1
```

---

## Known limitations

### Autologon security

Autologon stores the configured password in the registry in a recoverable form. This is a Windows design limitation of classic AutoAdminLogon.

### Existing default browser

Windows may block scripted changes to the default browser for an existing user profile. The script stages and nudges Chrome defaults, but manual confirmation may still be required.

### Taskbar pinning

Modern Windows builds restrict direct taskbar pinning. The script uses taskbar layout XML and shortcut staging, but some systems may require sign out/sign in, reboot, or manual correction.

### ThreatLocker

ThreatLocker may have tamper protection. Full removal may require portal authorization or vendor-approved removal tooling. v21 avoids waiting indefinitely on stuck services, but local cleanup still cannot bypass tamper protection.

### Duo Windows Logon

Duo credential provider removal may require Safe Mode or vendor recovery guidance if blocked.

### Group Policy overrides

Domain or local policies can override power settings, Windows Hello settings, taskbar behavior, widgets, Spotlight, and other UI settings.

---

## Post-run verification checklist

After reboot/sign-in, verify:

- The target user autologs in.
- `C:\retreat` exists.
- Desktop has only:
  - File Explorer
  - PowerPoint
  - Windows Media Player Legacy
  - Google Chrome
- File Explorer shortcut opens `C:\retreat`.
- Taskbar contains the intended app set.
- Teams does not start automatically.
- OneDrive does not start automatically.
- Spotify is installed or staged to install.
- Slido for PowerPoint is installed.
- Windows Media Player Legacy is installed.
- Screen stays on when plugged in.
- Screen/sleep timeout is 4 hours on battery.
- Widgets, search highlights, Spotlight active content, and mobile device Start companion are disabled.
- Windows Hello/PIN setup prompts no longer appear, where policy allows.

---

## Maintenance notes

- Increment the script filename each time it is changed, for example:

```text
Prepare-LocalAdminMachine-v21.ps1
Prepare-LocalAdminMachine-v21.ps1
```

- Keep the README version aligned with the script version.
- Review the first-logon log after changes:

```text
C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
```
