# Prepare-LocalAdminMachine-v28.ps1

PowerShell provisioning script for preparing a Windows computer for a local `retreat`-style administrator/autologon user profile.

This script is designed for kiosk, presentation, event, retreat, or shared-use machines where the goal is to create a clean local admin experience with minimal startup noise, controlled power settings, required media/presentation apps, a simplified desktop/taskbar, and a generated desktop wallpaper showing machine details.

> **Important:** Run from an elevated PowerShell session. Autologon stores the configured password in the Windows registry in a recoverable form. Use this only on trusted machines where that tradeoff is acceptable.

---

## Current version

```text
Prepare-LocalAdminMachine-v28.ps1
```

Matching README:

```text
README-Prepare-LocalAdminMachine-v28.md
```

---

## v28 temp-folder and compact-wallpaper update

Version v28 addresses the latest cleanup pass:

- Keeps provisioning-generated/staged files under `C:\Temp` instead of `C:\ProgramData\DeltaProvisioning`.
- Stages user-context Spotify through an HKCU `RunOnce` value that points to a command file stored under `C:\Temp\DeltaProvisioning`.
- Moves the retreat working folder to `C:\Temp\retreat`.
- Updates the File Explorer shortcut target to open `C:\Temp\retreat`.
- Fixes the wallpaper reapply path bug that could produce an illegal path such as `C:\Tempetreat-system-info-wallpaper.jpg`.
- Updates the wallpaper design:
  - removes the `Retreat Computer` heading,
  - removes the background box/panel,
  - moves system information toward the lower-right of the screen,
  - reduces the text size by roughly one third.
- Updates Roboto download logic to resolve the latest GitHub release package before falling back to a pinned release asset.

The generated wallpaper path is:

```text
C:\Temp\retreat-system-info-wallpaper.jpg
```

The user-context log path is:

```text
C:\Temp\first-logon-<username>.log
```

Provisioning support files are staged under:

```text
C:\Temp\DeltaProvisioning
```

---

## Basic usage

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v28.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"
```

With a computer rename:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v28.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere" `
  -NewComputerName "RETREAT-001"
```

Optional domain-unjoin credential:

```powershell
$cred = Get-Credential

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Downloads\Prepare-LocalAdminMachine-v28.ps1" `
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
| `-NewComputerName` | Optional new Windows computer name. If supplied and different, the script requests a rename. | empty |
| `-SkipPasswordResetIfRunningAsTargetUser` | If running as the target user, skip resetting that active user's password but still use the supplied password for autologon. | `$true` |
| `-DomainUnjoinCredential` | Optional credential used when removing the computer from a domain. | none |

---

## High-level design

The script has two main areas of responsibility:

1. **Bootstrap/system phase**
   Runs elevated and handles machine-level configuration.

2. **User/profile provisioning phase**
   A helper script is staged under `C:\Temp\DeltaProvisioning`. If the bootstrap script is already running as the target user, the script runs the user/profile cleanup immediately from the elevated session. This includes taskbar layout, desktop shortcut cleanup/rebuild, Chrome/Slido checks, Teams cleanup, per-user UI cleanup, and generated wallpaper setup.

Spotify is handled differently because the Spotify installer often does not behave correctly from an elevated Administrator context. Spotify is staged to run later from the target user's normal non-elevated Startup context. If Spotify is already installed, the RunOnce trigger is removed. If Spotify is not installed, the RunOnce trigger remains and retries at the next normal sign-in.

---

## Files and folders created

The script may create the following files and folders:

```text
C:\Temp\retreat
C:\Temp\first-logon-<username>.log
C:\Temp\retreat-computer-name.txt
C:\Temp\retreat-system-info-wallpaper.jpg
C:\Temp\RobotoFontInstall\
C:\Temp\DeltaProvisioning\FirstLogon-For-<username>.ps1
C:\Temp\DeltaProvisioning\TaskbarLayout-<username>.xml
C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Run-FirstLogon-Provisioning-For-<username>.cmd
```

The RunOnce trigger is primarily for the Spotify user-context install/retry path. It is removed when Spotify is already installed or after Spotify installs successfully from a normal non-elevated target-user logon.

---

## What the bootstrap/system phase does

### Local administrator account

- Ensures the specified local user exists.
- Enables the account.
- Adds the account to the local `Administrators` group.
- Sets or resets the password unless the script is currently running as that same user.
- If already running as the target user, it assumes the supplied password is already correct and uses it for autologon.

### Computer rename

- Accepts `-NewComputerName`.
- If the requested name is different from the current name, calls Windows rename functionality.
- Writes the requested computer name to:

```text
C:\Temp\retreat-computer-name.txt
```

- A reboot is required before the rename is fully applied.
- The generated wallpaper uses the intended new name when available, so the wallpaper can show the desired name before reboot.

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

### Domain/workgroup handling

- Checks whether the machine is domain joined.
- If domain joined, attempts to remove the computer from the domain and place it in the configured workgroup.
- Uses `-DomainUnjoinCredential` if supplied.
- Requires a reboot after successful domain unjoin.

### Startup item cleanup

- Removes common Run-key startup items from HKLM and HKCU.
- Disables Teams and OneDrive startup tasks.
- Removes common Startup folder entries where accessible.
- Applies OneDrive/Teams-related startup suppression policies where applicable.

### Application removal

Attempts to remove or disable remnants of:

- Cisco AnyConnect
- Cisco Secure Client
- Duo Authentication for Windows Logon
- ThreatLocker

ThreatLocker handling is intentionally non-blocking. The script requests service disable/stop/delete and moves on instead of waiting indefinitely if the service is stuck or partially removed.

> ThreatLocker may have tamper protection. Full removal may require disabling protection from the ThreatLocker portal or using the vendor-approved uninstall method.

### Windows Media Player Legacy

- Ensures the Windows Media Player Legacy optional feature/capability is enabled where available.
- Handles both optional feature and optional capability paths.
- Notes that Windows N editions may require Media Feature Pack support.

### Roboto font family

- Verifies that the Roboto family is complete before skipping installation.
- Treats Roboto as complete when either:
  - Google variable-font files for regular and italic Roboto are present, or
  - the core static Roboto weights are present, including Regular, Bold, Italic, BoldItalic, Light, Medium, and Black.
- If only a partial Roboto install is detected, for example only `Roboto Regular`, the script downloads and reinstalls the full Google Fonts Roboto package.
- Downloads the Roboto font family from Google Fonts.
- Extracts all matching `.ttf` / `.otf` files beginning with `Roboto`.
- Copies the Roboto fonts into:

```text
C:\Windows\Fonts
```

- Registers the fonts under:

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts
```

- Broadcasts a font-change notification so Windows can pick up the new fonts.
- If Roboto installation fails, wallpaper generation falls back to an available system font.

### Machine-level active content policies

Applies policy-level cleanup for items such as:

- Widgets
- News and Interests
- Search Highlights
- Windows Spotlight
- Consumer suggestions
- Windows tips and welcome experiences
- Tailored experiences
- Advertising ID
- Copilot taskbar button/policy where supported
- Phone Link / mobile device integration where supported
- Windows Hello / PIN / biometric provisioning prompts where policy allows

### Power and screensaver

- Disables screensaver where accessible.
- AC/plugged in:
  - monitor timeout: never
  - sleep timeout: never
  - hibernate timeout: never
- DC/unplugged:
  - monitor timeout: 240 minutes
  - sleep timeout: 240 minutes
  - hibernate timeout: 240 minutes
- Disables hibernation with `powercfg /hibernate off`.

Group Policy can override some power settings. If Group Policy controls a setting, PowerShell may report that an override exists.

---

## What the user/profile provisioning phase does

When run for the target user, the staged user/profile script handles:

### Desktop cleanup and shortcuts

- Removes existing desktop icons/items from the current user's desktop and the Public Desktop.
- Creates clean desktop shortcuts for:
  - File Explorer, opening `C:\Temp\retreat`
  - PowerPoint
  - Windows Media Player Legacy
  - Google Chrome

### Taskbar layout

Applies a taskbar layout intended to show:

```text
File Explorer -> opens C:\Temp\retreat
PowerPoint
Windows Media Player Legacy
Google Chrome
```

The script:

- Clears existing pinned taskbar items where possible.
- Creates canonical shortcuts with clean hover text.
- Removes duplicate shortcut names such as `PowerPoint (2).lnk`.
- Writes a taskbar layout XML to:

```text
C:\Temp\DeltaProvisioning\TaskbarLayout-<username>.xml
```

- Uses a taskbar layout policy with `PinListPlacement="Replace"`.
- Restarts Explorer.

Some Windows 10/11 builds do not apply taskbar layout changes until sign out/sign in or reboot.

### File Explorer behavior

- Creates the File Explorer taskbar and desktop shortcut so it opens:

```text
C:\Temp\retreat
```

Windows does not natively support setting every new Explorer window to an arbitrary folder such as `C:\Temp\retreat`, so the shortcut target is the reliable behavior.

### Chrome

- Ensures Google Chrome is installed where possible.
- Adds Chrome to desktop shortcuts and the intended taskbar layout.
- Attempts to stage Chrome as the default browser for new profiles.

> Existing Windows user profiles have protected default-browser hash values. Chrome may still need to be manually selected once under Settings > Apps > Default apps > Google Chrome.

### Slido for PowerPoint

- Checks uninstall registry entries for existing Slido installs.
- If Slido is already detected, skips reinstalling.
- If missing, attempts installation via `winget`.
- Avoids repeatedly installing Slido when an MSI/EXE has already registered the app.

### Spotify

Spotify is special-cased:

- It is not installed from the elevated Administrator process.
- A RunOnce trigger runs Spotify installation from the target user's normal, non-elevated logon context.
- If Spotify installs successfully, the RunOnce trigger removes itself.
- If Spotify is already installed, the trigger is removed.

### Teams cleanup

- Stops running Teams processes.
- Removes Teams startup entries from HKCU Run/RunOnce and StartupApproved locations where possible.
- Removes Teams startup shortcuts.
- Updates Teams config to suppress auto-start where possible.
- Runs Teams cleanup before and after app/user cleanup to catch early-starting Teams instances.

### Per-user active content cleanup

Attempts to disable or hide:

- Taskbar search box
- Widgets
- News and Interests
- Task View button
- Chat / Teams personal button
- Copilot taskbar button where supported
- Search Highlights
- Windows Spotlight desktop background
- `Learn about this picture`
- Start recommendations
- Account notifications
- Phone Link mobile device companion / "Show mobile device in Start"
- Tips, suggestions, and consumer content
- Windows Hello / finish setting up your device prompts where policy allows

### System-information wallpaper

Generates a static desktop wallpaper at:

```text
C:\Temp\retreat-system-info-wallpaper.jpg
```

The wallpaper includes:

- Computer name
- Serial number
- Asset tag
- Manufacturer and model
- IP address
- Logged-in user
- OS version
- Generated timestamp

The wallpaper uses Roboto when installed. If Roboto is unavailable, the script falls back to an available system font.

---

## Logs

The primary user-context log is written to:

```text
C:\Temp\first-logon-<username>.log
```

For the standard `retreat` user:

```text
C:\Temp\first-logon-retreat.log
```

The script may also write supporting provisioning files under:

```text
C:\Temp\DeltaProvisioning
```

---

## Expected reboot/sign-in behavior

A reboot is recommended after the script completes.

A reboot is required for:

- Computer rename
- Domain unjoin
- Some autologon changes
- Some taskbar layout policy changes
- Some Windows Spotlight / Start / Explorer UI changes

After reboot, the machine should autologon as the configured local user if the password and Winlogon settings are correct and no security policy blocks autologon.

---

## Known limitations

- Autologon stores the password in the registry in a recoverable form.
- ThreatLocker may require portal/vendor authorization for full removal.
- Some Windows taskbar pinning behavior is intentionally restricted by Microsoft and may require sign out/sign in or reboot.
- Existing-user default browser changes may not fully apply because Windows protects per-user default-browser hash values.
- Windows does not provide a native supported setting to make every Explorer window open to an arbitrary custom folder; the script handles this through the pinned/desktop shortcut target.
- Group Policy can override power, Start, taskbar, Windows Hello, or active-content settings.
- Roboto installation requires network access to Google Fonts unless the fonts are already installed.

---

## Quick post-run checks

### Confirm local admin account

```powershell
Get-LocalUser retreat
Get-LocalGroupMember Administrators | Where-Object Name -match "retreat"
```

### Confirm autologon keys without displaying the password

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" |
  Select-Object AutoAdminLogon, ForceAutoLogon, DefaultUserName, DefaultDomainName
```

### Confirm computer rename target

```powershell
hostname
Get-Content C:\Temp\retreat-computer-name.txt -ErrorAction SilentlyContinue
```

### Confirm serial number and asset tag

```powershell
[PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    Model        = (Get-CimInstance Win32_ComputerSystem).Model
    SerialNumber = (Get-CimInstance Win32_BIOS).SerialNumber
    AssetTag     = (Get-CimInstance Win32_SystemEnclosure).SMBIOSAssetTag
}
```

### Confirm wallpaper file

```powershell
Test-Path C:\Temp\retreat-system-info-wallpaper.jpg
```

### Confirm Roboto fonts

```powershell
Get-ChildItem C:\Windows\Fonts\Roboto* -ErrorAction SilentlyContinue |
    Select-Object Name, Length
```

v28 does not skip Roboto installation merely because the `Roboto` family name exists. It checks for a complete variable-font pair or the core static weights before considering the family complete.

### Check first-logon/user-context log

```powershell
Get-Content C:\Temp\first-logon-retreat.log -Tail 100
```

### Confirm installed apps

```powershell
Get-ItemProperty `
  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", `
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", `
  "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" `
  -ErrorAction SilentlyContinue |
Where-Object { $_.DisplayName -match "Spotify|Slido|Chrome" } |
Select-Object DisplayName, DisplayVersion, Publisher
```

---

## Repository versioning note

When this script is iterated, keep the script and README versions in sync. For example:

```text
Prepare-LocalAdminMachine-v28.ps1
README-Prepare-LocalAdminMachine-v28.md
```


## v28 notes

If the wallpaper still does not show after running v28, check:

```powershell
Test-Path C:\Temp\retreat-system-info-wallpaper.jpg
Get-Content C:\Temp\first-logon-retreat.log -Tail 80
reg query "HKCU\Control Panel\Desktop" /v Wallpaper
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper
```

A sign out/sign in or reboot may still be needed on some Windows 11 builds if Explorer or policy refresh delays the visible desktop update.
