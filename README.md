# Prepare-LocalAdminMachine.ps1

PowerShell provisioning script for preparing a Windows machine for a dedicated local administrator/autologon user, with kiosk/presentation-style cleanup.

Current script version documented here: `2026-06-23-v13-taskbar-layout-policy`.

## What the script does

### 1. Requires elevation

The script requires an elevated PowerShell session and will stop if it is not running as an administrator.

### 2. Ensures a local administrator account exists

The script accepts a target local administrator username and password.

Default parameters:

```powershell
-LocalAdminUser "localadmin"
-LocalAdminPassword "ChangeMe-Use-A-Strong-Password!"
-WorkgroupName "WORKGROUP"
-SkipPasswordResetIfRunningAsTargetUser $true
```

For the target local user, it will:

- Create the user if it does not exist.
- Enable the user if it exists but is disabled.
- Set or reset the password, unless the script is already running as that same target user and `-SkipPasswordResetIfRunningAsTargetUser` is `$true`.
- Add the user to the local `Administrators` group.
- Set the local-user description to `Provisioning local admin`.

If the script is already running as the target user, it assumes the supplied `-LocalAdminPassword` is already that account's current password and uses it for autologon.

### 3. Configures Windows autologon

The script configures classic Windows autologon for the target local administrator account by writing to:

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
```

It sets:

- `AutoAdminLogon = 1`
- `ForceAutoLogon = 1`
- `DefaultUserName = <target user>`
- `DefaultPassword = <target password>`
- `DefaultDomainName = <computer name>`

It also removes potentially interfering values:

- `AutoLogonCount`
- `AutoLogonSID`
- `LastUsedUsername`

It sets local system policy values to:

- Disable the Ctrl+Alt+Del logon requirement.
- Clear legal notice caption text.
- Clear legal notice body text.

Important: Windows autologon stores the password in the registry in a recoverable form. This script is intended for trusted, controlled, kiosk, presentation, or retreat-style devices.

### 4. Checks whether the computer is domain joined

The script checks `Win32_ComputerSystem.PartOfDomain`.

If the computer is not domain joined, it logs that no action is needed.

If the computer is domain joined, it attempts to remove the computer from the domain and place it into the configured workgroup.

If domain unjoin credentials are required, the script supports:

```powershell
-DomainUnjoinCredential $cred
```

where `$cred` is created with:

```powershell
$cred = Get-Credential
```

A reboot is required after a successful domain unjoin.

### 5. Disables machine and current-user startup items

The script removes startup entries from:

```text
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
```

It intentionally skips a small allowlist of common system entries:

- `SecurityHealth`
- `RTHDVCPL`

It removes files from the common Startup folder:

```text
C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup
```

It disables scheduled tasks whose task name or task path matches:

- `*Teams*`
- `*OneDrive*`

It also sets the OneDrive machine policy:

```text
HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive\DisableFileSyncNGSC = 1
```

### 6. Creates `C:\retreat`

The script creates this folder if it does not already exist:

```text
C:\retreat
```

### 7. Applies machine-level policies to reduce active Windows content

The script applies machine-level policy settings under `HKLM` to reduce or disable dynamic/active Windows content.

It disables or suppresses:

- Widgets / News and Interests.
- Search highlights.
- Search box suggestions.
- Cloud search.
- Web search integration for Windows Search.
- Windows consumer features.
- Windows Spotlight features.
- Spotlight desktop collection.
- Spotlight content in Action Center.
- Spotlight content in Settings.
- Windows welcome experience Spotlight content.
- Third-party suggestions.
- Tailored experiences based on diagnostic data.
- Soft landing content.
- Lock screen slideshow.
- Lock screen changing.
- Recommended section content where supported.
- Notification Center where configured.
- Windows Copilot.
- Windows Chat taskbar icon.

The machine policy phase writes under paths including:

```text
HKLM\SOFTWARE\Policies\Microsoft\Dsh
HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search
HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent
HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization
HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot
HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat
```

### 8. Stages Chrome as the default browser for new user profiles

The script creates a default-app association XML file at:

```text
C:\ProgramData\DeltaProvisioning\ChromeDefaultAssociations.xml
```

It configures `.htm`, `.html`, `http`, and `https` to use Chrome.

It imports the association file with:

```cmd
dism.exe /Online /Import-DefaultAppAssociations:<xml path>
```

It also sets a Chrome policy nudge:

```text
HKLM\SOFTWARE\Policies\Google\Chrome\DefaultBrowserSettingEnabled = 1
```

Note: Windows protects per-user default-browser hashes. This reliably stages Chrome defaults for new profiles. Existing user profiles may still require setting Chrome manually once in Windows Settings.

### 9. Stages a first-logon provisioning script for the target user

The script creates a second PowerShell script for target-user context work:

```text
C:\ProgramData\DeltaProvisioning\FirstLogon-For-<username>.ps1
```

It creates a common Startup trigger:

```text
C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Run-FirstLogon-Provisioning-For-<username>.cmd
```

The first-logon script writes a log to:

```text
C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
```

The Startup trigger only runs the first-logon script when the logged-in user matches the configured target username.

If the main script is already running as the target user, it runs the first-logon script immediately at the end of the bootstrap phase. If the first-logon script exits successfully, the Startup trigger is removed.

### 10. Removes Cisco AnyConnect / Cisco Secure Client, Duo Windows Logon, and ThreatLocker where possible

The script searches uninstall registry entries under:

```text
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*
```

It targets display names matching:

- Cisco AnyConnect
- Cisco Secure Client
- Duo Authentication for Windows Logon
- Duo Security
- ThreatLocker

For uninstall entries, it attempts silent uninstall. MSI-based entries are uninstalled with:

```cmd
msiexec.exe /x <product-code> /qn /norestart
```

For EXE uninstall strings, it attempts to run the uninstall command with quiet/silent/norestart arguments.

For services matching Cisco, Duo, or ThreatLocker patterns, it attempts to stop them first.

### 11. Attempts Duo Windows Logon cleanup

The script checks for Duo credential-provider DLLs and attempts to unregister them if present:

```text
C:\Program Files\Duo Security\WindowsLogon\DuoCredProv.dll
C:\Program Files\Duo Security\WindowsLogon\DuoCredFilter.dll
C:\Program Files (x86)\Duo Security\WindowsLogon\DuoCredProv.dll
C:\Program Files (x86)\Duo Security\WindowsLogon\DuoCredFilter.dll
```

It uses:

```cmd
regsvr32.exe /s /u <dll>
```

It also attempts to set Duo to RDP-only mode if the Duo registry path exists:

```text
HKLM\SOFTWARE\Duo Security\DuoCredProv\RdpOnly = 1
```

Duo Windows Logon may require Safe Mode or vendor recovery steps if credential provider removal is blocked.

### 12. Attempts aggressive ThreatLocker disable/removal

If ThreatLocker is present, the script attempts to:

- Stop ThreatLocker processes.
- Stop ThreatLocker services.
- Disable ThreatLocker services.
- Delete ThreatLocker services with `sc.exe delete`.
- Rename ThreatLocker folders to `.disabled`.
- Remove ThreatLocker registry keys where accessible.

Targeted folders include:

```text
C:\Program Files\ThreatLocker
C:\Program Files (x86)\ThreatLocker
C:\ProgramData\ThreatLocker
```

Targeted registry keys include:

```text
HKLM\SOFTWARE\ThreatLocker
HKLM\SOFTWARE\WOW6432Node\ThreatLocker
```

Important: ThreatLocker tamper protection may prevent local removal. Full removal may require disabling protection from the ThreatLocker portal or using the vendor-approved uninstall method.

### 13. Checks for winget

The script checks that `winget.exe` is available before any winget-based app installation logic.

If `winget.exe` is missing, the main script stops with an error.

### 14. Ensures Windows Media Player Legacy is installed

The script attempts to enable the Windows optional feature:

```text
WindowsMediaPlayer
```

If that feature is not present, it searches Windows capabilities for a Windows Media Player capability and installs it if available.

On Windows N editions or systems without the required media feature pack, Windows Media Player may not be available through these methods.

### 15. Disables screensavers and configures power settings

The script disables screensaver behavior for the current user and via local machine policy.

It sets plugged-in AC power behavior:

- Display timeout: never.
- Sleep timeout: never.
- Hibernate timeout: never.

It sets unplugged DC/battery behavior:

- Display timeout: 240 minutes.
- Sleep timeout: 240 minutes.
- Hibernate timeout: 240 minutes.

It also disables hibernation:

```cmd
powercfg /hibernate off
```

Group Policy power settings may override these local settings.

## What the first-logon script does

The first-logon script runs under the target user account, not the initial elevated bootstrap account, unless the bootstrap script is already running as the target user. This is where user-profile-specific cleanup happens.

### 1. Verifies the current user

The first-logon script exits without changes unless:

```text
%USERNAME% == <target username>
```

### 2. Removes Microsoft Edge desktop shortcuts

It removes Edge shortcuts from:

- The current user's desktop.
- The public desktop.
- The default user desktop.

### 3. Applies Chrome default-browser best-effort settings

It checks for Chrome in common install locations and sets the current-user Chrome default-browser policy nudge:

```text
HKCU\Software\Policies\Google\Chrome\DefaultBrowserSettingEnabled = 1
```

It logs a note that Windows may still require manual confirmation for existing user profiles.

### 4. Resets taskbar pins and keeps File Explorer plus PowerPoint

The first-logon script attempts to reset the user's taskbar pins so the intended final taskbar state is:

- File Explorer
- PowerPoint

It removes other `.lnk` files from the user's taskbar pinned folder:

```text
%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar
```

It recreates or refreshes:

- `File Explorer.lnk`
- `PowerPoint.lnk`

It removes the current user's Taskband cache:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband
```

It attempts to invoke the legacy shell `Pin to taskbar` verb where available. On newer Windows builds this shell verb may not be exposed.

### 5. Applies a taskbar layout policy

Because newer Windows builds often ignore manual `.lnk` taskbar pin staging, v13 also writes a taskbar layout XML file:

```text
C:\ProgramData\DeltaProvisioning\TaskbarLayout-<username>.xml
```

The XML uses taskbar layout replacement so the intended taskbar pin list is:

- File Explorer
- PowerPoint

It then sets policy registry values under both current-user and local-machine policy paths to point to the taskbar layout file.

It runs:

```cmd
gpupdate /target:user /force
```

A sign out/sign in or reboot may be required for the policy-driven taskbar replacement to appear.

### 6. Disables Teams startup for the current user

The first-logon script attempts to stop Teams and prevent it from auto-starting.

It stops Teams-related processes whose process name or path matches Teams patterns.

It removes Teams startup entries from:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32
HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder
```

It removes Teams shortcuts/files from:

- The user's Startup folder.
- The common Startup folder.

It sets current-user Teams policy-style values:

```text
HKCU\Software\Microsoft\Office\Teams\PreventFirstLaunchAfterInstall = 1
HKCU\Software\Microsoft\Office\Teams\AutoStart = 0
```

It updates Teams config files where present to set:

- `openAtLogin: false`
- `runningOnClose: false`

It disables scheduled tasks matching Teams.

The script runs this Teams cleanup twice: once before app installation checks and once again afterward.

### 7. Configures taskbar, desktop, Spotlight, screensaver, and active content for the current user

The first-logon script sets current-user registry values to:

- Align the Start button/taskbar left.
- Hide the search box.
- Hide Widgets.
- Hide Chat/Teams personal taskbar button where supported.
- Hide Task View.
- Hide Copilot button.
- Disable Start recommendations/account notifications where supported.
- Disable Search dynamic content.
- Disable News and Interests/Feeds.
- Disable Windows Spotlight and content delivery settings.
- Hide the `Learn about this picture` desktop icon.
- Disable advertising ID.
- Disable tailored privacy/diagnostic experiences where supported.
- Disable screensaver for the current user.
- Clear the configured screensaver executable.

It also removes the user's CloudStore cache under:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount
```

This helps prevent Windows from restoring previous taskbar or Spotlight state.

### 8. Installs Spotify at user logon if needed

The first-logon script checks uninstall registry entries for a display name matching:

```text
^Spotify
```

If Spotify is already installed, it skips installation.

If Spotify is not installed and `winget.exe` is available, it runs:

```cmd
winget install --id Spotify.Spotify --exact --accept-source-agreements --accept-package-agreements --silent
```

The winget process is given a 30-minute timeout.

### 9. Installs Slido for PowerPoint at user logon if needed

The first-logon script checks uninstall registry entries for a display name matching:

```text
^Slido
```

If Slido is already installed, it skips installation.

If Slido is not installed and `winget.exe` is available, it runs:

```cmd
winget install --id Slido.Slido --exact --accept-source-agreements --accept-package-agreements
```

Slido is intentionally not forced silent in the first-logon script because the installer may hang when forced silent on some systems.

The winget process is given a 30-minute timeout.

### 10. Restarts Explorer

At the end of first-logon provisioning, the script stops Explorer so that taskbar, desktop, and active-content changes can reload.

## Files and folders created by the script

The script may create or modify:

```text
C:\retreat
C:\ProgramData\DeltaProvisioning
C:\ProgramData\DeltaProvisioning\ChromeDefaultAssociations.xml
C:\ProgramData\DeltaProvisioning\FirstLogon-For-<username>.ps1
C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
C:\ProgramData\DeltaProvisioning\TaskbarLayout-<username>.xml
C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Run-FirstLogon-Provisioning-For-<username>.cmd
```

The Startup `.cmd` trigger is removed after successful first-logon provisioning.

## Example usage

Run from an elevated PowerShell session:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Prepare-LocalAdminMachine-v13.ps1 `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"
```

If domain unjoin credentials are needed:

```powershell
$cred = Get-Credential

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Prepare-LocalAdminMachine-v13.ps1 `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere" `
  -DomainUnjoinCredential $cred
```

Run directly from a GitHub raw URL by downloading to `C:\Temp` first:

```powershell
mkdir C:\Temp -Force

Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/<owner>/<repo>/<tag-or-branch>/Prepare-LocalAdminMachine-v13.ps1" `
  -OutFile "C:\Temp\Prepare-LocalAdminMachine-v13.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Temp\Prepare-LocalAdminMachine-v13.ps1" `
  -LocalAdminUser "retreat" `
  -LocalAdminPassword "YourPasswordHere"
```

## Important limitations and notes

- Autologon stores the supplied password in the registry in a recoverable form.
- Existing-user default browser settings may not fully change because Windows protects per-user default-app hashes.
- Taskbar pinning behavior varies by Windows version. v13 uses both best-effort shortcut staging and a taskbar layout policy, but a reboot or sign out/sign in may still be required.
- ThreatLocker may resist local removal if tamper protection is enabled.
- Duo Windows Logon may require Safe Mode or vendor-specific recovery steps if credential provider removal is blocked.
- Domain unjoin requires a reboot and may require domain credentials.
- Power settings may be overridden by domain, MDM, or local Group Policy.
- winget app installations require network access and working App Installer/winget support.
- Slido is checked by uninstall display name before installing to avoid repeated install attempts or stuck winget sessions.

## Recommended post-run steps

1. Review console output for warnings.
2. Review the first-logon log:

   ```text
   C:\ProgramData\DeltaProvisioning\first-logon-<username>.log
   ```

3. Reboot the machine.
4. Confirm the target account autologs in.
5. Confirm Teams does not start.
6. Confirm Spotify, Slido, and Windows Media Player Legacy are installed.
7. Confirm Chrome default-browser behavior.
8. Confirm taskbar state after sign out/sign in or reboot.
9. Confirm ThreatLocker, Duo, and Cisco removal status if those products were present.
