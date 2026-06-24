# Script version: 2026-06-24-v27-force-generated-wallpaper
#requires -RunAsAdministrator
<#
Purpose:
- Ensure a local administrator account exists
- Set/reset that account password, except when already running as that same target user
- Auto-login as that account
- Unjoin domain if domain joined
- Disable startup items, including Teams and OneDrive startup hooks
- Remove Cisco AnyConnect / Cisco Secure Client, Duo Windows Logon, and ThreatLocker if present
- Run Chrome, Slido, taskbar, desktop, and per-user UI cleanup from the main script when running as the target user; stage only Spotify for a regular non-elevated target-user logon; and install Windows Media Player Legacy
- Disable screensaver
- Apply machine policies for active content now; stage per-user taskbar/Spotlight/default-browser/taskbar-pin cleanup for first target-user logon; keep File Explorer pinned and pin PowerPoint, Windows Media Player Legacy, and Google Chrome
- Create C:\retreat
- Optionally rename the computer with -NewComputerName
- Install the full Roboto font family from Google Fonts
- Generate a static system-information wallpaper using Roboto
- Set AC power: screen stays on, no sleep/hibernate
- Set DC battery power: screen/sleep/hibernate after 4 hours

Run from elevated PowerShell.
A reboot is recommended after completion, and required after domain unjoin.

Important:
- If this script is run while logged in as the same account specified in -LocalAdminUser,
  the script assumes the password passed in -LocalAdminPassword is already that account's
  current password. It will skip resetting the active account password but will still use
  that supplied password for autologon.
- Autologon stores the password in the registry in a recoverable form. Use only on trusted
  or kiosk-style machines.
#>

param(
    [string]$LocalAdminUser = "localadmin",
    [string]$LocalAdminPassword = "ChangeMe-Use-A-Strong-Password!",
    [string]$WorkgroupName = "WORKGROUP",
    [string]$NewComputerName = "",

    # If $true and the script is running as -LocalAdminUser, the script will not reset
    # that user's password during the active session. It will still configure autologon
    # using -LocalAdminPassword.
    [bool]$SkipPasswordResetIfRunningAsTargetUser = $true,

    # Optional. If the machine is domain-joined and current credentials cannot unjoin it,
    # pass a domain credential:
    #   $cred = Get-Credential
    #   .\Prepare-LocalAdminMachine.ps1 -DomainUnjoinCredential $cred
    [System.Management.Automation.PSCredential]$DomainUnjoinCredential
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentSamAccountName {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    return $currentUser.Split("\")[-1]
}

if (-not (Test-IsAdmin)) {
    throw "Run this script from an elevated PowerShell session."
}

function Ensure-LocalAdmin {
    param(
        [string]$Username,
        [string]$Password,
        [bool]$SkipResetIfCurrentUser
    )

    Write-Step "Ensuring local administrator account exists"

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    $currentSam = Get-CurrentSamAccountName
    $isRunningAsTargetUser = ($currentSam -ieq $Username)

    if (-not $user) {
        New-LocalUser `
            -Name $Username `
            -Password $securePassword `
            -FullName "Local Administrator" `
            -Description "Provisioning local admin" `
            -PasswordNeverExpires `
            -UserMayNotChangePassword:$false | Out-Null

        Write-Host "Created local user: $Username"
    }
    else {
        if ($isRunningAsTargetUser -and $SkipResetIfCurrentUser) {
            Write-Warning "Currently running as $Username. Skipping password reset for the active logon account."
            Write-Warning "Assuming the supplied password is already the current password for autologon."
            Enable-LocalUser -Name $Username
        }
        else {
            Set-LocalUser -Name $Username -Password $securePassword
            Enable-LocalUser -Name $Username
            Write-Host "Updated password and enabled local user: $Username"
        }
    }

    Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue
    Write-Host "Ensured $Username is a member of local Administrators."
}

function Configure-AutoLogon {
    param(
        [string]$Username,
        [string]$Password,
        [string]$DefaultDomainName = $env:COMPUTERNAME
    )

    Write-Step "Configuring Windows autologon"

    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

    Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "1" -Type String
    Set-ItemProperty -Path $winlogonPath -Name "DefaultUserName" -Value $Username -Type String
    Set-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -Value $Password -Type String
    Set-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -Value $DefaultDomainName -Type String
    Set-ItemProperty -Path $winlogonPath -Name "ForceAutoLogon" -Value "1" -Type String

    Remove-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogonPath -Name "AutoLogonSID" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogonPath -Name "LastUsedUsername" -ErrorAction SilentlyContinue

    New-Item -Path $systemPolicy -Force | Out-Null
    Set-ItemProperty -Path $systemPolicy -Name "DisableCAD" -Value 1 -Type DWord
    Set-ItemProperty -Path $systemPolicy -Name "LegalNoticeCaption" -Value "" -Type String
    Set-ItemProperty -Path $systemPolicy -Name "LegalNoticeText" -Value "" -Type String

    $confirm = Get-ItemProperty -Path $winlogonPath
    Write-Host "Autologon set for: $($confirm.DefaultDomainName)\$($confirm.DefaultUserName)"
    if (-not $confirm.DefaultPassword) {
        Write-Warning "DefaultPassword was not found after writing autologon settings. A policy or security product may have blocked it."
    }

    Write-Warning "Autologon stores the password in the registry in a recoverable form. Use only on trusted/kiosk-style machines."
}


function Rename-ComputerIfRequested {
    param([string]$RequestedName)

    if ([string]::IsNullOrWhiteSpace($RequestedName)) {
        return $env:COMPUTERNAME
    }

    Write-Step "Checking requested computer rename"

    $cleanName = $RequestedName.Trim()
    if ($cleanName.Length -gt 15) {
        throw "Computer name '$cleanName' is too long. Windows computer names should be 15 characters or fewer."
    }

    if ($cleanName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $cleanName.EndsWith('-')) {
        throw "Computer name '$cleanName' is invalid. Use letters, numbers, and hyphens; do not end with a hyphen."
    }

    if ($env:COMPUTERNAME -ieq $cleanName) {
        Write-Host "Computer name is already $cleanName."
        return $env:COMPUTERNAME
    }

    try {
        Rename-Computer -NewName $cleanName -Force -ErrorAction Stop
        Write-Warning "Computer rename requested: $env:COMPUTERNAME -> $cleanName. A reboot is required before the new name is active."
        return $cleanName
    }
    catch {
        Write-Warning "Could not rename computer to ${cleanName}: $($_.Exception.Message)"
        return $env:COMPUTERNAME
    }
}

function Remove-FromDomainIfJoined {
    param(
        [string]$Workgroup,
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-Step "Checking domain membership"

    $computerSystem = Get-CimInstance Win32_ComputerSystem

    if (-not $computerSystem.PartOfDomain) {
        Write-Host "Computer is not domain joined."
        return
    }

    Write-Warning "Computer is domain joined to: $($computerSystem.Domain)"
    Write-Host "Attempting to unjoin domain and move to workgroup: $Workgroup"

    if ($Credential) {
        Remove-Computer `
            -UnjoinDomainCredential $Credential `
            -WorkgroupName $Workgroup `
            -Force `
            -PassThru
    }
    else {
        Remove-Computer `
            -WorkgroupName $Workgroup `
            -Force `
            -PassThru
    }

    Write-Warning "Domain unjoin requested. A reboot is required."
}

function Disable-StartupItems {
    param([string]$Username)

    Write-Step "Disabling startup items"

    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )

    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key
            $props.PSObject.Properties |
                Where-Object {
                    $_.Name -notmatch "^PS" -and
                    $_.Name -notin @("SecurityHealth", "RTHDVCPL")
                } |
                ForEach-Object {
                    Write-Host "Removing startup entry: $key\$($_.Name)"
                    Remove-ItemProperty -Path $key -Name $_.Name -ErrorAction SilentlyContinue
                }
        }
    }

    $commonStartup = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $commonStartup) {
        Get-ChildItem $commonStartup -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Removing common startup item: $($_.FullName)"
                Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
    }

    # Disable common scheduled startup/update tasks for Teams and OneDrive.
    $taskNamePatterns = @(
        "*Teams*",
        "*OneDrive*"
    )

    foreach ($pattern in $taskNamePatterns) {
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like $pattern -or $_.TaskPath -like $pattern } |
            ForEach-Object {
                try {
                    Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null
                    Write-Host "Disabled scheduled task: $($_.TaskPath)$($_.TaskName)"
                }
                catch {
                    Write-Warning "Could not disable task $($_.TaskPath)$($_.TaskName): $($_.Exception.Message)"
                }
            }
    }

    # OneDrive policy that suppresses sync client use/startup.
    $oneDrivePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    New-Item -Path $oneDrivePolicy -Force | Out-Null
    New-ItemProperty -Path $oneDrivePolicy -Name "DisableFileSyncNGSC" -PropertyType DWord -Value 1 -Force | Out-Null

    $teamsMachineInstaller = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $teamsMachineInstaller) {
        Remove-ItemProperty -Path $teamsMachineInstaller -Name "TeamsMachineInstaller" -ErrorAction SilentlyContinue
    }

    Write-Host "Startup items disabled where accessible."
}

function Get-UninstallEntries {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $paths) {
        Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.UninstallString }
    }
}

function Invoke-SilentUninstall {
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    $name = $Entry.DisplayName
    $uninstallString = $Entry.UninstallString

    Write-Host "Attempting uninstall: $name"

    try {
        if ($uninstallString -match "MsiExec\.exe" -or $uninstallString -match "\{[0-9A-Fa-f-]{36}\}") {
            $productCode = [regex]::Match($uninstallString, "\{[0-9A-Fa-f-]{36}\}").Value

            if ($productCode) {
                Start-Process "msiexec.exe" `
                    -ArgumentList "/x $productCode /qn /norestart" `
                    -Wait `
                    -NoNewWindow
            }
            else {
                Write-Warning "Could not find MSI product code for $name."
            }
        }
        else {
            $exe = $null
            $args = ""

            if ($uninstallString.StartsWith('"')) {
                $exe = ($uninstallString -split '"')[1]
                $args = $uninstallString.Substring($exe.Length + 2).Trim()
            }
            else {
                $parts = $uninstallString.Split(" ", 2)
                $exe = $parts[0]
                if ($parts.Count -gt 1) {
                    $args = $parts[1]
                }
            }

            $silentArgs = "$args /quiet /silent /norestart"
            Start-Process $exe -ArgumentList $silentArgs -Wait -NoNewWindow
        }

        Write-Host "Uninstall command completed for: $name"
    }
    catch {
        Write-Warning "Failed uninstall for ${name}: $($_.Exception.Message)"
    }
}

function Disable-And-RequestStopServiceFast {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        [string]$DisplayName = $ServiceName
    )

    try {
        Write-Host "Disabling service without waiting: $DisplayName ($ServiceName)"
        Start-Process sc.exe -ArgumentList @("config", $ServiceName, "start=", "disabled") -Wait -NoNewWindow | Out-Null
    }
    catch {
        Write-Warning "Could not disable service ${ServiceName}: $($_.Exception.Message)"
    }

    try {
        Write-Host "Requesting service stop without waiting: $DisplayName ($ServiceName)"
        Start-Process sc.exe -ArgumentList @("stop", $ServiceName) -Wait -NoNewWindow | Out-Null
    }
    catch {
        Write-Warning "Could not request stop for service ${ServiceName}: $($_.Exception.Message)"
    }
}

function Delete-ServiceFast {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    try {
        Start-Process sc.exe -ArgumentList @("delete", $ServiceName) -Wait -NoNewWindow | Out-Null
        Write-Host "Requested service deletion: $ServiceName"
    }
    catch {
        Write-Warning "Could not request deletion for service ${ServiceName}: $($_.Exception.Message)"
    }
}


function Disable-And-RemoveThreatLockerRemnants {
    Write-Step "Disabling and removing ThreatLocker remnants if present"

    $foundSomething = $false

    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "*ThreatLocker*" -or $_.Path -like "*ThreatLocker*" } |
        ForEach-Object {
            $foundSomething = $true
            try {
                Write-Host "Stopping ThreatLocker process: $($_.ProcessName) [$($_.Id)]"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warning "Could not stop ThreatLocker process $($_.ProcessName): $($_.Exception.Message)"
            }
        }

    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*ThreatLocker*" -or $_.Name -like "*ThreatLocker*" } |
        ForEach-Object {
            $foundSomething = $true
            try {
                Write-Host "Disabling/deleting ThreatLocker service without waiting: $($_.Name)"
                Disable-And-RequestStopServiceFast -ServiceName $_.Name -DisplayName $_.DisplayName
                Delete-ServiceFast -ServiceName $_.Name
            }
            catch {
                Write-Warning "Could not disable/delete ThreatLocker service $($_.Name): $($_.Exception.Message)"
            }
        }

    $threatLockerPaths = @(
        "$env:ProgramFiles\ThreatLocker",
        "${env:ProgramFiles(x86)}\ThreatLocker",
        "$env:ProgramData\ThreatLocker"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($path in $threatLockerPaths) {
        $foundSomething = $true
        try {
            $disabledPath = "$path.disabled"
            Write-Host "Renaming ThreatLocker folder: $path -> $disabledPath"
            Rename-Item -Path $path -NewName (Split-Path $disabledPath -Leaf) -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not rename ThreatLocker folder ${path}: $($_.Exception.Message)"
        }
    }

    $tlRegPaths = @(
        "HKLM:\SOFTWARE\ThreatLocker",
        "HKLM:\SOFTWARE\WOW6432Node\ThreatLocker"
    )

    foreach ($regPath in $tlRegPaths) {
        if (Test-Path $regPath) {
            $foundSomething = $true
            try {
                Write-Host "Removing ThreatLocker registry key: $regPath"
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove ThreatLocker registry key ${regPath}: $($_.Exception.Message)"
            }
        }
    }

    if (-not $foundSomething) {
        Write-Host "No additional ThreatLocker services, processes, folders, or registry keys found."
    }

    Write-Warning "If ThreatLocker tamper protection is active, full removal may require disabling it from the ThreatLocker portal or using the vendor-approved uninstall method."
}

function Unregister-DuoCredentialProvider {
    Write-Step "Checking for Duo credential provider DLLs"

    $duoDllPaths = @(
        "$env:ProgramFiles\Duo Security\WindowsLogon\DuoCredProv.dll",
        "$env:ProgramFiles\Duo Security\WindowsLogon\DuoCredFilter.dll",
        "${env:ProgramFiles(x86)}\Duo Security\WindowsLogon\DuoCredProv.dll",
        "${env:ProgramFiles(x86)}\Duo Security\WindowsLogon\DuoCredFilter.dll"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($dll in $duoDllPaths) {
        try {
            Write-Host "Unregistering Duo DLL: $dll"
            Start-Process regsvr32.exe -ArgumentList "/u /s `"$dll`"" -Wait -NoNewWindow
        }
        catch {
            Write-Warning "Could not unregister Duo DLL ${dll}: $($_.Exception.Message)"
        }
    }

    $duoRegPath = "HKLM:\SOFTWARE\Duo Security\DuoCredProv"
    if (Test-Path $duoRegPath) {
        try {
            New-ItemProperty -Path $duoRegPath -Name "RdpOnly" -PropertyType DWord -Value 1 -Force | Out-Null
            Write-Host "Set Duo RdpOnly=1 as a temporary local-console bypass fallback."
        }
        catch {
            Write-Warning "Could not set Duo RdpOnly fallback value: $($_.Exception.Message)"
        }
    }
}

function Remove-SecurityAndVpnApps {
    Write-Step "Removing Cisco AnyConnect / Cisco Secure Client, Duo Windows Logon, and ThreatLocker if present"

    $servicePatterns = @(
        "*AnyConnect*",
        "*Cisco Secure Client*",
        "*Duo*",
        "*ThreatLocker*"
    )

    foreach ($pattern in $servicePatterns) {
        Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern -or $_.Name -like $pattern } |
            ForEach-Object {
                try {
                    Disable-And-RequestStopServiceFast -ServiceName $_.Name -DisplayName $_.DisplayName
                }
                catch {
                    Write-Warning "Could not stop service $($_.DisplayName): $($_.Exception.Message)"
                }
            }
    }

    $targets = Get-UninstallEntries |
        Where-Object {
            $_.DisplayName -match "Cisco AnyConnect|Cisco Secure Client|Duo Authentication for Windows Logon|Duo Security|ThreatLocker"
        }

    if (-not $targets) {
        Write-Host "No matching Cisco AnyConnect / Cisco Secure Client / Duo Windows Logon / ThreatLocker uninstall entries found."
    }
    else {
        foreach ($entry in $targets) {
            Invoke-SilentUninstall -Entry $entry
        }
    }

    Unregister-DuoCredentialProvider
    Disable-And-RemoveThreatLockerRemnants

    Write-Warning "ThreatLocker may have tamper protection. If uninstall fails, use the vendor/admin portal uninstall method."
    Write-Warning "Duo Windows Logon may require Safe Mode or vendor-specific recovery steps if credential provider removal is blocked."
}

function Ensure-Winget {
    Write-Step "Checking winget"

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue

    if (-not $winget) {
        throw "winget.exe was not found. Install or repair App Installer from Microsoft Store, then rerun."
    }

    Write-Host "winget found: $($winget.Source)"
}

function Test-AppInstalledByDisplayName {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayNamePattern
    )

    $matches = Get-UninstallEntries |
        Where-Object { $_.DisplayName -match $DisplayNamePattern }

    if ($matches) {
        Write-Host "Found installed application matching pattern '$DisplayNamePattern':"
        $matches |
            Select-Object DisplayName, DisplayVersion, Publisher |
            Format-Table -AutoSize | Out-String | Write-Host
        return $true
    }

    return $false
}

function Install-WingetPackage {
    param(
        [string]$PackageId,
        [string]$FriendlyName,
        [string]$InstalledDisplayNamePattern,
        [int]$InstallTimeoutSeconds = 1800
    )

    Write-Host "Ensuring $FriendlyName is installed via winget package ID: $PackageId"

    if (-not [string]::IsNullOrWhiteSpace($InstalledDisplayNamePattern)) {
        if (Test-AppInstalledByDisplayName -DisplayNamePattern $InstalledDisplayNamePattern) {
            Write-Host "$FriendlyName already appears to be installed based on uninstall registry entries. Skipping winget install."
            return
        }
    }

    $listOutput = winget list --id $PackageId --exact --accept-source-agreements 2>$null

    if ($LASTEXITCODE -eq 0 -and ($listOutput -join "`n") -match [regex]::Escape($PackageId)) {
        Write-Host "$FriendlyName already appears to be installed according to winget."
        return
    }

    $wingetArgs = @(
        "install",
        "--id", $PackageId,
        "--exact",
        "--silent",
        "--accept-source-agreements",
        "--accept-package-agreements"
    )

    Write-Host "Starting winget install for $FriendlyName. Timeout: $InstallTimeoutSeconds seconds."
    $process = Start-Process -FilePath "winget.exe" -ArgumentList $wingetArgs -PassThru -NoNewWindow

    if (-not $process.WaitForExit($InstallTimeoutSeconds * 1000)) {
        Write-Warning "winget install for $FriendlyName exceeded timeout. Stopping winget process ID $($process.Id)."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return
    }

    if ($process.ExitCode -ne 0) {
        Write-Warning "winget install may have failed for $FriendlyName. Exit code: $($process.ExitCode)"
    }
}


function Ensure-WindowsMediaPlayerLegacy {
    Write-Step "Ensuring Windows Media Player Legacy is installed"

    $feature = Get-WindowsOptionalFeature -Online -FeatureName "WindowsMediaPlayer" -ErrorAction SilentlyContinue

    if ($feature -and $feature.State -ne "Enabled") {
        Enable-WindowsOptionalFeature -Online -FeatureName "WindowsMediaPlayer" -All -NoRestart | Out-Null
        Write-Host "Enabled WindowsMediaPlayer optional feature."
        return
    }

    if ($feature -and $feature.State -eq "Enabled") {
        Write-Host "WindowsMediaPlayer optional feature is already enabled."
        return
    }

    $capability = Get-WindowsCapability -Online |
        Where-Object { $_.Name -like "Media.WindowsMediaPlayer*" -or $_.Name -like "*WindowsMediaPlayer*" } |
        Select-Object -First 1

    if ($capability -and $capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Host "Installed Windows Media Player capability: $($capability.Name)"
    }
    elseif ($capability) {
        Write-Host "Windows Media Player capability already installed."
    }
    else {
        Write-Warning "Could not locate Windows Media Player Legacy feature/capability. This can happen on Windows N editions without the Media Feature Pack."
    }
}


function Set-RegistryDWordValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-RegistryStringValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    New-Item -Path $Path -Force | Out-Null
    New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
}

function Set-TaskbarPreferencesInRegistryRoot {
    param([Parameter(Mandatory)][string]$RootPath)

    $advancedPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $searchPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Search"
    $searchSettingsPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\SearchSettings"
    $feedsPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Feeds"
    $contentDeliveryPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $desktopPath = Join-Path $RootPath "Control Panel\Desktop"
    $desktopIconsPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    $desktopIconsClassicPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"
    $advertisingInfoPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    $privacyPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Privacy"
    $startPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $phoneLinkStartCompanionPath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"
    $cloudStorePath = Join-Path $RootPath "Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"

    # Windows 11 taskbar alignment and taskbar buttons.
    # TaskbarAl: 0 = left, 1 = center.
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarAl" -Value 0

    # Hide Widgets, Chat/Teams personal, Copilot, and Task View buttons where supported.
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarDa" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarMn" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "ShowTaskViewButton" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "ShowCopilotButton" -Value 0

    # Hide the taskbar search box/icon.
    # SearchboxTaskbarMode: 0 = hidden, 1 = icon only, 2 = search box.
    $null = Set-RegistryDWordValue -Path $searchPath -Name "SearchboxTaskbarMode" -Value 0

    # Disable dynamic/highlighted content in the search box where supported.
    $null = Set-RegistryDWordValue -Path $searchSettingsPath -Name "IsDynamicSearchBoxEnabled" -Value 0

    # Windows 10 News and Interests: 2 = hidden.
    $null = Set-RegistryDWordValue -Path $feedsPath -Name "ShellFeedsTaskbarViewMode" -Value 2

    # Disable Windows Spotlight, active backgrounds, tips, suggestions, and other content delivery for this user.
    $contentDeliveryValues = @{
        "ContentDeliveryAllowed" = 0
        "FeatureManagementEnabled" = 0
        "OemPreInstalledAppsEnabled" = 0
        "PreInstalledAppsEnabled" = 0
        "PreInstalledAppsEverEnabled" = 0
        "SilentInstalledAppsEnabled" = 0
        "SoftLandingEnabled" = 0
        "SystemPaneSuggestionsEnabled" = 0
        "RotatingLockScreenEnabled" = 0
        "RotatingLockScreenOverlayEnabled" = 0
        "SubscribedContentEnabled" = 0
        "SubscribedContent-310093Enabled" = 0
        "SubscribedContent-314559Enabled" = 0
        "SubscribedContent-338387Enabled" = 0
        "SubscribedContent-338388Enabled" = 0
        "SubscribedContent-338389Enabled" = 0
        "SubscribedContent-338393Enabled" = 0
        "SubscribedContent-353694Enabled" = 0
        "SubscribedContent-353696Enabled" = 0
        "SubscribedContent-88000326Enabled" = 0
        "SubscribedContent-88000327Enabled" = 0
    }

    foreach ($item in $contentDeliveryValues.GetEnumerator()) {
        $null = Set-RegistryDWordValue -Path $contentDeliveryPath -Name $item.Key -Value $item.Value
    }

    # Stop Windows Spotlight desktop wallpaper and remove the "Learn about this picture" desktop icon.
    $null = Set-RegistryStringValue -Path $desktopPath -Name "Wallpaper" -Value ""
    $null = Set-RegistryStringValue -Path $desktopPath -Name "WallpaperStyle" -Value "0"
    $null = Set-RegistryStringValue -Path $desktopPath -Name "TileWallpaper" -Value "0"
    $null = Set-RegistryDWordValue -Path $desktopIconsPath -Name "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" -Value 1
    $null = Set-RegistryDWordValue -Path $desktopIconsClassicPath -Name "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" -Value 1

    # Disable advertising ID, tailored experiences, and Start recommendations/suggestions where supported.
    $null = Set-RegistryDWordValue -Path $advertisingInfoPath -Name "Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path $privacyPath -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0
    $null = Set-RegistryDWordValue -Path $startPath -Name "Start_IrisRecommendations" -Value 0
    $null = Set-RegistryDWordValue -Path $startPath -Name "Start_AccountNotifications" -Value 0
    $null = Set-RegistryDWordValue -Path $startPath -Name "ShowSyncProviderNotifications" -Value 0

    # Disable Phone Link / "Show mobile device in Start" companion content where supported.
    $null = Set-RegistryDWordValue -Path $phoneLinkStartCompanionPath -Name "IsEnabled" -Value 0

    # Clear per-user CloudStore content cache that can resurrect Widgets/Spotlight/taskbar state.
    if (Test-Path $cloudStorePath) {
        Remove-Item -Path $cloudStorePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Load-UserHiveIfNeeded {
    param(
        [Parameter(Mandatory)][string]$HiveFile,
        [Parameter(Mandatory)][string]$TempHiveName
    )

    $hkuPath = "Registry::HKEY_USERS\$TempHiveName"

    if (Test-Path $hkuPath) {
        return @{ RootPath = $hkuPath; LoadedByScript = $false }
    }

    if (-not (Test-Path $HiveFile)) {
        return $null
    }

    $result = Start-Process reg.exe -ArgumentList "load HKU\$TempHiveName `"$HiveFile`"" -Wait -NoNewWindow -PassThru
    if ($result.ExitCode -ne 0) {
        Write-Warning "Could not load user hive: $HiveFile. reg.exe exit code: $($result.ExitCode)"
        return $null
    }

    return @{ RootPath = $hkuPath; LoadedByScript = $true }
}

function Unload-UserHiveIfLoadedByScript {
    param(
        [Parameter(Mandatory)][string]$TempHiveName,
        [bool]$LoadedByScript
    )

    if ($LoadedByScript) {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        $result = Start-Process reg.exe -ArgumentList "unload HKU\$TempHiveName" -Wait -NoNewWindow -PassThru
        if ($result.ExitCode -ne 0) {
            Write-Warning "Could not unload temporary user hive HKU\$TempHiveName. A reboot will usually release it. reg.exe exit code: $($result.ExitCode)"
        }
    }
}

function Configure-MachineActiveContentPolicies {
    Write-Step "Configuring machine policies for widgets, news, search, Spotlight, Copilot, Phone Link, and active content"

    # These HKLM policy settings are applied during the elevated bootstrap run.
    # Per-user HKCU taskbar/desktop settings are staged into the first-logon script.
    $dshPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    $null = Set-RegistryDWordValue -Path $dshPolicy -Name "AllowNewsAndInterests" -Value 0

    $windowsSearchPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    $null = Set-RegistryDWordValue -Path $windowsSearchPolicy -Name "AllowSearchHighlights" -Value 0
    $null = Set-RegistryDWordValue -Path $windowsSearchPolicy -Name "DisableSearchBoxSuggestions" -Value 1
    $null = Set-RegistryDWordValue -Path $windowsSearchPolicy -Name "AllowCloudSearch" -Value 0
    $null = Set-RegistryDWordValue -Path $windowsSearchPolicy -Name "ConnectedSearchUseWeb" -Value 0
    $null = Set-RegistryDWordValue -Path $windowsSearchPolicy -Name "ConnectedSearchUseWebOverMeteredConnections" -Value 0

    $cloudContentPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableWindowsConsumerFeatures" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableWindowsSpotlightFeatures" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableSpotlightCollectionOnDesktop" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableWindowsSpotlightOnActionCenter" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableWindowsSpotlightOnSettings" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableWindowsSpotlightWindowsWelcomeExperience" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableThirdPartySuggestions" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableTailoredExperiencesWithDiagnosticData" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "DisableSoftLanding" -Value 1
    $null = Set-RegistryDWordValue -Path $cloudContentPolicy -Name "ConfigureWindowsSpotlight" -Value 2

    $personalizationPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    $null = Set-RegistryDWordValue -Path $personalizationPolicy -Name "NoLockScreenSlideshow" -Value 1
    $null = Set-RegistryDWordValue -Path $personalizationPolicy -Name "NoChangingLockScreen" -Value 1

    $explorerPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    $null = Set-RegistryDWordValue -Path $explorerPolicy -Name "DisableSearchBoxSuggestions" -Value 1
    $null = Set-RegistryDWordValue -Path $explorerPolicy -Name "HideRecommendedSection" -Value 1
    $null = Set-RegistryDWordValue -Path $explorerPolicy -Name "DisableNotificationCenter" -Value 1

    $windowsCopilotPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
    $null = Set-RegistryDWordValue -Path $windowsCopilotPolicy -Name "TurnOffWindowsCopilot" -Value 1

    $windowsChatPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat"
    $null = Set-RegistryDWordValue -Path $windowsChatPolicy -Name "ChatIcon" -Value 3

    $systemPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    $null = Set-RegistryDWordValue -Path $systemPolicy -Name "EnableCdp" -Value 0

    Write-Host "Machine active-content policies applied. Per-user cleanup is staged for first logon."
}


function Ensure-RetreatFolder {
    Write-Step "Creating C:\retreat folder"
    New-Item -Path "C:\retreat" -ItemType Directory -Force | Out-Null
    Write-Host "Ensured folder exists: C:\retreat"
}

function Test-RobotoFontFamilyComplete {
    $fontFolder = Join-Path $env:WINDIR "Fonts"
    $robotoFiles = Get-ChildItem -Path $fontFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Roboto*.ttf" -or $_.Name -like "Roboto*.otf" }

    if (-not $robotoFiles) {
        return $false
    }

    $fileNames = $robotoFiles.Name

    # Newer Google Fonts downloads may include variable font files instead of one file per weight.
    $hasVariableRegular = $fileNames | Where-Object { $_ -like "Roboto*VariableFont*.ttf" -and $_ -notlike "*Italic*" }
    $hasVariableItalic = $fileNames | Where-Object { $_ -like "Roboto*Italic*VariableFont*.ttf" }
    if ($hasVariableRegular -and $hasVariableItalic) {
        return $true
    }

    # Static font-family check. If only Roboto Regular exists, do not treat the family as complete.
    $requiredPatterns = @(
        "Roboto-Regular.*",
        "Roboto-Bold.*",
        "Roboto-Italic.*",
        "Roboto-BoldItalic.*",
        "Roboto-Light.*",
        "Roboto-Medium.*",
        "Roboto-Black.*"
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not ($fileNames | Where-Object { $_ -like $pattern })) {
            return $false
        }
    }

    return $true
}

function Ensure-RobotoFontFamily {
    Write-Step "Ensuring full Roboto font family is installed"

    try {
        if (Test-RobotoFontFamilyComplete) {
            $count = @(Get-ChildItem -Path (Join-Path $env:WINDIR "Fonts") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Roboto*.ttf" -or $_.Name -like "Roboto*.otf" }).Count
            Write-Host "Roboto font family appears complete. Found $count Roboto font file(s)."
            return
        }
        else {
            Write-Host "Roboto font family is missing or incomplete. Installing full Google Fonts package."
        }
    }
    catch {
        Write-Warning "Could not verify Roboto completeness before install: $($_.Exception.Message)"
    }

    $tempRoot = "C:\Temp\RobotoFontInstall"
    $zipPath = Join-Path $tempRoot "roboto.zip"
    $extractPath = Join-Path $tempRoot "extracted"
    $fontRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    $fontDownloadUrl = "https://fonts.google.com/download?family=Roboto"

    try {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null

        Write-Host "Downloading Roboto from Google Fonts."
        $oldProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $fontDownloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $oldProgressPreference
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $fontFiles = Get-ChildItem -Path $extractPath -Recurse -Include *.ttf,*.otf -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like "Roboto*" }

        if (-not $fontFiles) {
            throw "No Roboto .ttf or .otf files were found in the downloaded archive."
        }

        New-Item -Path $fontRegistryPath -Force | Out-Null

        foreach ($fontFile in $fontFiles) {
            $destination = Join-Path $env:WINDIR "Fonts\$($fontFile.Name)"
            Copy-Item -Path $fontFile.FullName -Destination $destination -Force

            $registryName = "$($fontFile.BaseName) (TrueType)"
            if ($fontFile.Extension -ieq ".otf") {
                $registryName = "$($fontFile.BaseName) (OpenType)"
            }

            New-ItemProperty `
                -Path $fontRegistryPath `
                -Name $registryName `
                -PropertyType String `
                -Value $fontFile.Name `
                -Force | Out-Null

            Write-Host "Installed font: $($fontFile.Name)"
        }

        try {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FontBroadcastTools {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue
            $result = [UIntPtr]::Zero
            [FontBroadcastTools]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, $null, 0x0002, 5000, [ref]$result) | Out-Null
        }
        catch {
            Write-Warning "Could not broadcast font-change notification: $($_.Exception.Message)"
        }

        Write-Host "Roboto font family installation completed."
    }
    catch {
        Write-Warning "Could not install Roboto font family: $($_.Exception.Message)"
        Write-Warning "Wallpaper generation will fall back to an available system font if Roboto is unavailable."
    }
}

function Configure-WindowsHelloAndSetupExperienceSuppression {
    Write-Step "Disabling Windows Hello, biometric prompts, PIN provisioning, and setup experience prompts"

    $passportPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
    New-Item -Path $passportPolicy -Force | Out-Null
    New-ItemProperty -Path $passportPolicy -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $passportPolicy -Name "DisablePostLogonProvisioning" -PropertyType DWord -Value 1 -Force | Out-Null

    $biometricsPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics"
    New-Item -Path $biometricsPolicy -Force | Out-Null
    New-ItemProperty -Path $biometricsPolicy -Name "Enabled" -PropertyType DWord -Value 0 -Force | Out-Null

    $systemPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    New-Item -Path $systemPolicy -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name "AllowDomainPINLogon" -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name "EnableCdp" -PropertyType DWord -Value 0 -Force | Out-Null

    $cloudContentPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    New-Item -Path $cloudContentPolicy -Force | Out-Null
    New-ItemProperty -Path $cloudContentPolicy -Name "DisableWindowsConsumerFeatures" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $cloudContentPolicy -Name "DisableSoftLanding" -PropertyType DWord -Value 1 -Force | Out-Null

    Write-Host "Windows Hello/PIN/biometric provisioning prompts disabled where policy allows. Existing sign-in methods are not deleted."
}

function Configure-ChromeDefaultBrowserForNewUsers {
    Write-Step "Staging Chrome as default browser for new user profiles"

    $provisioningFolder = Join-Path $env:ProgramData "DeltaProvisioning"
    New-Item -Path $provisioningFolder -ItemType Directory -Force | Out-Null

    $assocPath = Join-Path $provisioningFolder "ChromeDefaultAssociations.xml"
    $assocXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".htm" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".html" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="http" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="https" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
</DefaultAssociations>
"@

    Set-Content -Path $assocPath -Value $assocXml -Encoding UTF8 -Force

    try {
        $process = Start-Process -FilePath "dism.exe" -ArgumentList "/Online", "/Import-DefaultAppAssociations:$assocPath" -Wait -NoNewWindow -PassThru
        Write-Host "DISM default app association import exited with code $($process.ExitCode)."
    }
    catch {
        Write-Warning "Could not import Chrome default app associations for new users: $($_.Exception.Message)"
    }

    # Policy nudge: when Chrome is present and launched, allow it to check/offer default browser behavior.
    $chromePolicy = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    $null = Set-RegistryDWordValue -Path $chromePolicy -Name "DefaultBrowserSettingEnabled" -Value 1

    Write-Warning "Windows protects per-user default-browser hashes. This reliably stages Chrome defaults for new profiles; existing profiles may still require confirmation in Settings."
}

function Stage-FirstLogonProvisioning {
    param([Parameter(Mandatory)][string]$Username)

    Write-Step "Staging first-logon provisioning for target user"

    $provisioningFolder = Join-Path $env:ProgramData "DeltaProvisioning"
    $startupFolder = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    $firstLogonScript = Join-Path $provisioningFolder "FirstLogon-For-$Username.ps1"
    $firstLogonCmd = Join-Path $startupFolder "Run-FirstLogon-Provisioning-For-$Username.cmd"
    $tempFolder = "C:\Temp"
    $logPath = Join-Path $tempFolder "first-logon-$Username.log"

    New-Item -Path $provisioningFolder -ItemType Directory -Force | Out-Null
    New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
    New-Item -Path $startupFolder -ItemType Directory -Force | Out-Null

    $firstLogonContent = @'
param(
    [Parameter(Mandatory)][string]$TargetUsername,
    [Parameter(Mandatory)][string]$LogPath
)

$ErrorActionPreference = "Continue"
$RetreatFolder = "C:\retreat"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    $logFolder = Split-Path -Path $LogPath -Parent
    if ($logFolder -and -not (Test-Path $logFolder)) {
        New-Item -Path $logFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Convert-RegistryPathForRegExe {
    param([string]$Path)
    return ($Path -replace '^HKCU:', 'HKCU' -replace '^HKLM:', 'HKLM') -replace '/', '\'
}

function Ensure-RegistryKeyExists {
    param([string]$Path)
    if (Test-Path $Path) {
        return $true
    }

    try {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log "PowerShell could not create registry key $Path. Trying reg.exe fallback. $($_.Exception.Message)"
        $regPath = Convert-RegistryPathForRegExe -Path $Path
        & reg.exe add $regPath /f | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Write-Log "Could not create registry key $Path. reg.exe exit code: $LASTEXITCODE"
        return $false
    }
}

function Set-RegistryDWordValue {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Ensure-RegistryKeyExists -Path $Path)) {
        return $false
    }

    try {
        Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "PowerShell could not set $Path\$Name. Trying reg.exe fallback. $($_.Exception.Message)"
        $regPath = Convert-RegistryPathForRegExe -Path $Path
        & reg.exe add $regPath /v $Name /t REG_DWORD /d $Value /f | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Write-Log "Could not set $Path\$Name. reg.exe exit code: $LASTEXITCODE"
        return $false
    }
}

function Set-RegistryStringValue {
    param([string]$Path, [string]$Name, [string]$Value)

    if (-not (Ensure-RegistryKeyExists -Path $Path)) {
        return $false
    }

    try {
        Set-ItemProperty -Path $Path -Name $Name -Type String -Value $Value -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "PowerShell could not set $Path\$Name. Trying reg.exe fallback. $($_.Exception.Message)"
        $regPath = Convert-RegistryPathForRegExe -Path $Path
        & reg.exe add $regPath /v $Name /t REG_SZ /d $Value /f | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Write-Log "Could not set $Path\$Name. reg.exe exit code: $LASTEXITCODE"
        return $false
    }
}

function Get-UninstallEntries {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $paths) {
        Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
    }
}

function Test-AppInstalledByDisplayName {
    param([string]$DisplayNamePattern)
    $matches = Get-UninstallEntries | Where-Object { $_.DisplayName -match $DisplayNamePattern }
    if ($matches) {
        Write-Log "Found installed app matching '$DisplayNamePattern'."
        return $true
    }
    return $false
}

function Test-CurrentProcessIsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Log "Could not determine elevation state: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WingetInstallWithTimeout {
    param(
        [string]$PackageId,
        [string]$FriendlyName,
        [string]$InstalledDisplayNamePattern,
        [bool]$Silent = $true,
        [int]$TimeoutSeconds = 1800
    )

    Write-Log "Checking $FriendlyName."

    if ($InstalledDisplayNamePattern -and (Test-AppInstalledByDisplayName -DisplayNamePattern $InstalledDisplayNamePattern)) {
        Write-Log "$FriendlyName already appears installed. Skipping."
        return
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Log "winget.exe not found. Cannot install $FriendlyName."
        return
    }

    $args = @("install", "--id", $PackageId, "--exact", "--accept-source-agreements", "--accept-package-agreements")
    if ($Silent) { $args += "--silent" }

    Write-Log "Starting winget install for $FriendlyName."
    $process = Start-Process -FilePath "winget.exe" -ArgumentList $args -PassThru -NoNewWindow

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "winget install for $FriendlyName exceeded timeout. Stopping process ID $($process.Id)."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Log "winget install for $FriendlyName exited with code $($process.ExitCode)."
}


function Disable-TeamsStartupForCurrentUser {
    Write-Log "Disabling Teams startup for current user."

    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match "^(Teams|ms-teams|msteams)$" -or
            ($_.ProcessName -eq "Update" -and $_.Path -like "*Teams*") -or
            $_.Path -like "*Teams*"
        } |
        ForEach-Object {
            try {
                Write-Log "Stopping Teams-related process: $($_.ProcessName) [$($_.Id)]"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "Could not stop Teams process $($_.ProcessName): $($_.Exception.Message)"
            }
        }

    $runLikeKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    )

    foreach ($key in $runLikeKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            $props.PSObject.Properties |
                Where-Object { $_.Name -notmatch "^PS" -and $_.Name -match "Teams|MSTeams|com\.squirrel\.Teams" } |
                ForEach-Object {
                    try {
                        Write-Log "Removing Teams startup registry value: $key\$($_.Name)"
                        Remove-ItemProperty -Path $key -Name $_.Name -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-Log "Could not remove Teams startup registry value $($_.Name): $($_.Exception.Message)"
                    }
                }
        }
    }

    $startupFolders = @(
        [Environment]::GetFolderPath("Startup"),
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )

    foreach ($folder in $startupFolders) {
        if (Test-Path $folder) {
            Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "Teams|MSTeams" } |
                ForEach-Object {
                    try {
                        Write-Log "Removing Teams startup shortcut/file: $($_.FullName)"
                        Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-Log "Could not remove Teams startup file $($_.FullName): $($_.Exception.Message)"
                    }
                }
        }
    }

    $teamsPolicyPath = "HKCU:\Software\Microsoft\Office\Teams"
    $null = Set-RegistryDWordValue -Path $teamsPolicyPath -Name "PreventFirstLaunchAfterInstall" -Value 1
    $null = Set-RegistryDWordValue -Path $teamsPolicyPath -Name "AutoStart" -Value 0

    $teamsConfigCandidates = @(
        "$env:APPDATA\Microsoft\Teams\desktop-config.json",
        "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\app_settings.json"
    )

    foreach ($configPath in $teamsConfigCandidates) {
        if (Test-Path $configPath) {
            try {
                $text = Get-Content -Path $configPath -Raw -ErrorAction Stop
                $text = $text -replace '"openAtLogin"\s*:\s*true', '"openAtLogin": false'
                $text = $text -replace '"runningOnClose"\s*:\s*true', '"runningOnClose": false'
                Set-Content -Path $configPath -Value $text -Encoding UTF8 -Force
                Write-Log "Updated Teams config: $configPath"
            }
            catch {
                Write-Log "Could not update Teams config ${configPath}: $($_.Exception.Message)"
            }
        }
    }

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like "*Teams*" -or $_.TaskPath -like "*Teams*" } |
        ForEach-Object {
            try {
                Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Disabled Teams scheduled task: $($_.TaskPath)$($_.TaskName)"
            }
            catch {
                Write-Log "Could not disable Teams scheduled task $($_.TaskName): $($_.Exception.Message)"
            }
        }
}

function Configure-CurrentUserTaskbarAndActiveContent {
    Write-Log "Configuring taskbar, desktop, Spotlight, Phone Link Start companion, screensaver, and active content for current user."

    $advancedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $searchPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    $searchSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"
    $feedsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"
    $contentDeliveryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $desktopPath = "HKCU:\Control Panel\Desktop"
    $desktopIconsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    $desktopIconsClassicPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"
    $advertisingInfoPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    $privacyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
    $phoneLinkStartCompanionPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"
    $cloudStorePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"

    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarAl" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarDa" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "TaskbarMn" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "ShowTaskViewButton" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "ShowCopilotButton" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "Start_IrisRecommendations" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "Start_AccountNotifications" -Value 0
    $null = Set-RegistryDWordValue -Path $advancedPath -Name "ShowSyncProviderNotifications" -Value 0

    # Disable Phone Link / "Show mobile device in Start" companion content for this user.
    $null = Set-RegistryDWordValue -Path $phoneLinkStartCompanionPath -Name "IsEnabled" -Value 0

    $null = Set-RegistryDWordValue -Path $searchPath -Name "SearchboxTaskbarMode" -Value 0
    $null = Set-RegistryDWordValue -Path $searchSettingsPath -Name "IsDynamicSearchBoxEnabled" -Value 0
    $null = Set-RegistryDWordValue -Path $feedsPath -Name "ShellFeedsTaskbarViewMode" -Value 2

    $contentDeliveryValues = @{
        "ContentDeliveryAllowed" = 0
        "FeatureManagementEnabled" = 0
        "OemPreInstalledAppsEnabled" = 0
        "PreInstalledAppsEnabled" = 0
        "PreInstalledAppsEverEnabled" = 0
        "SilentInstalledAppsEnabled" = 0
        "SoftLandingEnabled" = 0
        "SystemPaneSuggestionsEnabled" = 0
        "RotatingLockScreenEnabled" = 0
        "RotatingLockScreenOverlayEnabled" = 0
        "SubscribedContentEnabled" = 0
        "SubscribedContent-310093Enabled" = 0
        "SubscribedContent-314559Enabled" = 0
        "SubscribedContent-338387Enabled" = 0
        "SubscribedContent-338388Enabled" = 0
        "SubscribedContent-338389Enabled" = 0
        "SubscribedContent-338393Enabled" = 0
        "SubscribedContent-353694Enabled" = 0
        "SubscribedContent-353696Enabled" = 0
        "SubscribedContent-88000326Enabled" = 0
        "SubscribedContent-88000327Enabled" = 0
    }
    foreach ($item in $contentDeliveryValues.GetEnumerator()) {
        $null = Set-RegistryDWordValue -Path $contentDeliveryPath -Name $item.Key -Value $item.Value
    }

    $null = Set-RegistryStringValue -Path $desktopPath -Name "Wallpaper" -Value ""
    $null = Set-RegistryStringValue -Path $desktopPath -Name "WallpaperStyle" -Value "0"
    $null = Set-RegistryStringValue -Path $desktopPath -Name "TileWallpaper" -Value "0"
    $null = Set-RegistryStringValue -Path $desktopPath -Name "ScreenSaveActive" -Value "0"
    $null = Set-RegistryStringValue -Path $desktopPath -Name "ScreenSaverIsSecure" -Value "0"
    Remove-ItemProperty -Path $desktopPath -Name "SCRNSAVE.EXE" -ErrorAction SilentlyContinue

    $null = Set-RegistryDWordValue -Path $desktopIconsPath -Name "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" -Value 1
    $null = Set-RegistryDWordValue -Path $desktopIconsClassicPath -Name "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" -Value 1
    $null = Set-RegistryDWordValue -Path $advertisingInfoPath -Name "Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path $privacyPath -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0

    if (Test-Path $cloudStorePath) {
        Remove-Item -Path $cloudStorePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WallpaperTools {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@ -ErrorAction SilentlyContinue
        [WallpaperTools]::SystemParametersInfo(20, 0, "", 3) | Out-Null
    }
    catch {
        Write-Log "Could not immediately clear wallpaper: $($_.Exception.Message)"
    }
}


function Remove-EdgeDesktopShortcuts {
    Write-Log "Removing Edge desktop shortcuts."
    $desktopFolders = @(
        [Environment]::GetFolderPath("Desktop"),
        "$env:PUBLIC\Desktop",
        "$env:SystemDrive\Users\Default\Desktop"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($folder in $desktopFolders) {
        Get-ChildItem -Path $folder -Filter "*.lnk" -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "Edge" -or $_.Name -match "Microsoft Edge" } |
            ForEach-Object {
                try {
                    Write-Log "Removing Edge shortcut: $($_.FullName)"
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "Could not remove Edge shortcut $($_.FullName): $($_.Exception.Message)"
                }
            }
    }
}

function Find-PowerPointExe {
    $candidates = @(
        "$env:ProgramFiles\Microsoft Office\root\Office16\POWERPNT.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\POWERPNT.EXE",
        "$env:ProgramFiles\Microsoft Office\Office16\POWERPNT.EXE",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\POWERPNT.EXE"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $found = Get-ChildItem -Path $root -Filter "POWERPNT.EXE" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}


function Find-WindowsMediaPlayerExe {
    $candidates = @(
        "$env:ProgramFiles\Windows Media Player\wmplayer.exe",
        "${env:ProgramFiles(x86)}\Windows Media Player\wmplayer.exe",
        "$env:WINDIR\System32\wmplayer.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:WINDIR\System32") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $found = Get-ChildItem -Path $root -Filter "wmplayer.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Find-ChromeExe {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    return $null
}

function New-OrUpdateShortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
        [string]$Description = ""
    )

    try {
        $parent = Split-Path $ShortcutPath -Parent
        New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
        if ($Description) { $shortcut.Description = $Description }
        $shortcut.Save()
        Write-Log "Created shortcut: $ShortcutPath"
        return $true
    }
    catch {
        Write-Log "Could not create shortcut ${ShortcutPath}: $($_.Exception.Message)"
        return $false
    }
}

function Reset-DesktopIconsAndCreateProvisionedShortcuts {
    Write-Log "Removing desktop icons and creating provisioned desktop shortcuts."

    $desktopFolders = @(
        [Environment]::GetFolderPath("Desktop"),
        "$env:PUBLIC\Desktop"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($folder in $desktopFolders) {
        Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "desktop.ini" } |
            ForEach-Object {
                try {
                    Write-Log "Removing desktop item: $($_.FullName)"
                    Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "Could not remove desktop item $($_.FullName): $($_.Exception.Message)"
                }
            }
    }

    $userDesktop = [Environment]::GetFolderPath("Desktop")
    if (-not $userDesktop) {
        Write-Log "Could not resolve current user desktop path. Desktop shortcuts were not created."
        return
    }

    New-Item -Path $RetreatFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $explorerExe = "$env:WINDIR\explorer.exe"
    if (Test-Path $explorerExe) {
        New-OrUpdateShortcut -ShortcutPath (Join-Path $userDesktop "File Explorer.lnk") -TargetPath $explorerExe -Arguments '"C:\retreat"' -WorkingDirectory $RetreatFolder -IconLocation "$explorerExe,0" -Description "File Explorer" | Out-Null
    }

    $powerPointExe = Find-PowerPointExe
    if ($powerPointExe) { New-OrUpdateShortcut -ShortcutPath (Join-Path $userDesktop "PowerPoint.lnk") -TargetPath $powerPointExe -WorkingDirectory (Split-Path $powerPointExe -Parent) -IconLocation "$powerPointExe,0" -Description "PowerPoint" | Out-Null }
    else { Write-Log "PowerPoint executable not found. Desktop shortcut was not created." }

    $wmpExe = Find-WindowsMediaPlayerExe
    if ($wmpExe) { New-OrUpdateShortcut -ShortcutPath (Join-Path $userDesktop "Windows Media Player Legacy.lnk") -TargetPath $wmpExe -WorkingDirectory (Split-Path $wmpExe -Parent) -IconLocation "$wmpExe,0" -Description "Windows Media Player Legacy" | Out-Null }
    else { Write-Log "Windows Media Player Legacy executable not found. Desktop shortcut was not created." }

    $chromeExe = Find-ChromeExe
    if ($chromeExe) { New-OrUpdateShortcut -ShortcutPath (Join-Path $userDesktop "Google Chrome.lnk") -TargetPath $chromeExe -WorkingDirectory (Split-Path $chromeExe -Parent) -IconLocation "$chromeExe,0" -Description "Google Chrome" | Out-Null }
    else { Write-Log "Google Chrome executable not found. Desktop shortcut was not created." }
}

function Disable-WindowsHelloAndSetupPromptsForCurrentUser {
    Write-Log "Disabling Windows Hello/setup prompts for current user where policy allows."

    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" -Name "ScoobeSystemSettingEnabled" -Value 0
    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-310093Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338389Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338393Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353694Enabled" -Value 0
    $null = Set-RegistryDWordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353696Enabled" -Value 0
}

function Configure-TaskbarLayoutPolicyForProvisionedApps {
    Write-Log "Configuring taskbar layout policy for File Explorer, PowerPoint, Windows Media Player Legacy, and Google Chrome."

    $programDataStartMenu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
    New-Item -Path $programDataStartMenu -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $RetreatFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $fileExplorerPolicyShortcut = Join-Path $programDataStartMenu "File Explorer.lnk"
    try {
        $wshForExplorerPolicy = New-Object -ComObject WScript.Shell
        $explorerPolicyShortcut = $wshForExplorerPolicy.CreateShortcut($fileExplorerPolicyShortcut)
        $explorerPolicyShortcut.TargetPath = "$env:WINDIR\explorer.exe"
        $explorerPolicyShortcut.Arguments = '"C:\retreat"'
        $explorerPolicyShortcut.WorkingDirectory = $RetreatFolder
        $explorerPolicyShortcut.IconLocation = "$env:WINDIR\explorer.exe,0"
        $explorerPolicyShortcut.Description = "File Explorer"
        $explorerPolicyShortcut.Save()
        Write-Log "Created Start Menu File Explorer shortcut targeting $RetreatFolder for taskbar policy: $fileExplorerPolicyShortcut"
    }
    catch {
        Write-Log "Could not create Start Menu File Explorer shortcut targeting ${RetreatFolder}: $($_.Exception.Message)"
    }

    # Best-effort Explorer preference. Windows supports LaunchTo values such as Home/This PC,
    # but not a native per-user default of an arbitrary folder. The pinned shortcut above is
    # therefore the reliable way to make the taskbar Explorer button open C:\retreat.
    $advancedPathForExplorer = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegistryDWordValue -Path $advancedPathForExplorer -Name "LaunchTo" -Value 1 | Out-Null
    Write-Log "Set File Explorer launch preference to This PC where supported; taskbar shortcut directly targets $RetreatFolder."

    $powerPointExe = Find-PowerPointExe
    $powerPointShortcut = Join-Path $programDataStartMenu "PowerPoint.lnk"

    Get-ChildItem -Path $programDataStartMenu -Filter "PowerPoint*.lnk" -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "PowerPoint.lnk" } | ForEach-Object {
        try {
            Write-Log "Removing duplicate Start Menu PowerPoint shortcut before creating canonical taskbar layout link: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate Start Menu PowerPoint shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    if ($powerPointExe) {
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $shortcut = $wsh.CreateShortcut($powerPointShortcut)
            $shortcut.TargetPath = $powerPointExe
            $shortcut.WorkingDirectory = Split-Path $powerPointExe -Parent
            $shortcut.IconLocation = "$powerPointExe,0"
            $shortcut.Description = "PowerPoint"
            $shortcut.Save()
            Write-Log "Created Start Menu PowerPoint shortcut for taskbar policy: $powerPointShortcut"
        }
        catch {
            Write-Log "Could not create Start Menu PowerPoint shortcut: $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "PowerPoint executable not found. Taskbar policy will include File Explorer only."
    }

    $wmpExe = Find-WindowsMediaPlayerExe
    $wmpShortcut = Join-Path $programDataStartMenu "Windows Media Player Legacy.lnk"

    Get-ChildItem -Path $programDataStartMenu -Filter "Windows Media Player*.lnk" -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Windows Media Player Legacy.lnk" } | ForEach-Object {
        try {
            Write-Log "Removing duplicate Start Menu Windows Media Player shortcut before creating canonical taskbar layout link: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate Start Menu Windows Media Player shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    if ($wmpExe) {
        try {
            $wshWmp = New-Object -ComObject WScript.Shell
            $wmpLink = $wshWmp.CreateShortcut($wmpShortcut)
            $wmpLink.TargetPath = $wmpExe
            $wmpLink.WorkingDirectory = Split-Path $wmpExe -Parent
            $wmpLink.IconLocation = "$wmpExe,0"
            $wmpLink.Description = "Windows Media Player Legacy"
            $wmpLink.Save()
            Write-Log "Created Start Menu Windows Media Player Legacy shortcut for taskbar policy: $wmpShortcut"
        }
        catch {
            Write-Log "Could not create Windows Media Player Legacy shortcut: $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "Windows Media Player Legacy executable not found. Taskbar policy will not include Windows Media Player."
    }

    $chromeExe = Find-ChromeExe
    $chromeShortcut = Join-Path $programDataStartMenu "Google Chrome.lnk"

    Get-ChildItem -Path $programDataStartMenu -Filter "Google Chrome*.lnk" -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Google Chrome.lnk" } | ForEach-Object {
        try {
            Write-Log "Removing duplicate Start Menu Google Chrome shortcut before creating canonical taskbar layout link: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate Start Menu Google Chrome shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    if ($chromeExe) {
        New-OrUpdateShortcut -ShortcutPath $chromeShortcut -TargetPath $chromeExe -WorkingDirectory (Split-Path $chromeExe -Parent) -IconLocation "$chromeExe,0" -Description "Google Chrome" | Out-Null
    }
    else {
        Write-Log "Google Chrome executable not found. Taskbar policy will not include Google Chrome."
    }

    $taskbarAppLines = @(
        '        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\File Explorer.lnk" />'
    )
    if ($powerPointExe -and (Test-Path $powerPointShortcut)) {
        $taskbarAppLines += '        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\PowerPoint.lnk" />'
    }
    if ($wmpExe -and (Test-Path $wmpShortcut)) {
        $taskbarAppLines += '        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Windows Media Player Legacy.lnk" />'
    }
    if ($chromeExe -and (Test-Path $chromeShortcut)) {
        $taskbarAppLines += '        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk" />'
    }
    $taskbarPinsXml = $taskbarAppLines -join "`r`n"

    $layoutPath = Join-Path $env:ProgramData "DeltaProvisioning\TaskbarLayout-$TargetUsername.xml"
    New-Item -Path (Split-Path $layoutPath -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$taskbarPinsXml
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@

    try {
        Set-Content -Path $layoutPath -Value $xml -Encoding UTF8 -Force
        Write-Log "Wrote taskbar layout XML: $layoutPath"
    }
    catch {
        Write-Log "Could not write taskbar layout XML: $($_.Exception.Message)"
        return
    }

    # Apply via local policy registry. This is more reliable on Windows 11 than manually seeding Taskband .lnk files.
    foreach ($policyPath in @(
        "HKCU:\Software\Policies\Microsoft\Windows\Explorer",
        "HKLM:\Software\Policies\Microsoft\Windows\Explorer"
    )) {
        Set-RegistryStringValue -Path $policyPath -Name "StartLayoutFile" -Value $layoutPath | Out-Null
        Set-RegistryDWordValue -Path $policyPath -Name "LockedStartLayout" -Value 1 | Out-Null
        Write-Log "Set taskbar layout policy path at $policyPath."
    }

    try {
        $gp = Start-Process -FilePath "gpupdate.exe" -ArgumentList "/target:user", "/force" -Wait -NoNewWindow -PassThru -ErrorAction Stop
        Write-Log "gpupdate /target:user /force exited with code $($gp.ExitCode)."
    }
    catch {
        Write-Log "Could not run gpupdate for taskbar layout policy: $($_.Exception.Message)"
    }

    Write-Log "Taskbar policy is staged. A sign-out/sign-in or reboot may be required before Windows replaces the visible pins."
}


function Reset-TaskbarPinsForProvisionedApps {
    Write-Log "Resetting taskbar pinned items and staging File Explorer, PowerPoint, Windows Media Player Legacy, and Google Chrome."

    $taskbarPinnedFolder = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    New-Item -Path $taskbarPinnedFolder -ItemType Directory -Force | Out-Null
    New-Item -Path $RetreatFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    Get-ChildItem -Path $taskbarPinnedFolder -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $keepItem = $false
            if ($_.Name -match "^(File Explorer|Explorer)\.lnk$") {
                $keepItem = $true
            }
            elseif ($_.Extension -ieq ".lnk") {
                try {
                    $wshForRead = New-Object -ComObject WScript.Shell
                    $existingShortcut = $wshForRead.CreateShortcut($_.FullName)
                    if ($existingShortcut.TargetPath -and ((Split-Path $existingShortcut.TargetPath -Leaf) -ieq "explorer.exe")) {
                        $keepItem = $true
                    }
                }
                catch { }
            }

            if ($keepItem) {
                Write-Log "Keeping taskbar pinned item: $($_.FullName)"
            }
            else {
                Write-Log "Removing taskbar pinned item file: $($_.FullName)"
                Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log "Could not process pinned item file $($_.FullName): $($_.Exception.Message)"
        }
    }

    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    if (Test-Path $taskbandPath) {
        try {
            Remove-Item -Path $taskbandPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed HKCU Taskband cache so the refreshed pins can apply."
        }
        catch {
            Write-Log "Could not remove HKCU Taskband cache: $($_.Exception.Message)"
        }
    }

    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
    }
    catch {
        Write-Log "Could not create WScript.Shell COM object for taskbar shortcuts: $($_.Exception.Message)"
    }

    $fileExplorerShortcutPath = Join-Path $taskbarPinnedFolder "File Explorer.lnk"
    if ($wsh) {
        try {
            $fileExplorerShortcut = $wsh.CreateShortcut($fileExplorerShortcutPath)
            $fileExplorerShortcut.TargetPath = "$env:WINDIR\explorer.exe"
            $fileExplorerShortcut.Arguments = '"C:\retreat"'
            $fileExplorerShortcut.WorkingDirectory = $RetreatFolder
            $fileExplorerShortcut.IconLocation = "$env:WINDIR\explorer.exe,0"
            $fileExplorerShortcut.Description = "File Explorer"
            $fileExplorerShortcut.Save()
            Write-Log "Created or refreshed File Explorer shortcut in taskbar pinned folder targeting ${RetreatFolder}: $fileExplorerShortcutPath"
        }
        catch {
            Write-Log "Could not create File Explorer taskbar shortcut: $($_.Exception.Message)"
        }
    }

    $powerPointExe = Find-PowerPointExe
    if (-not $powerPointExe) {
        Write-Log "PowerPoint executable not found. Could not pin PowerPoint."
    }

    # Normalize PowerPoint taskbar shortcuts so the taskbar hover text is "PowerPoint", not
    # "PowerPoint (2)" or another duplicate shortcut name. Windows often uses the .lnk file
    # name for the taskbar tooltip/title.
    Get-ChildItem -Path $taskbarPinnedFolder -Filter "PowerPoint*.lnk" -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Write-Log "Removing duplicate PowerPoint taskbar shortcut before recreating canonical shortcut: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate PowerPoint shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    $shortcutPath = Join-Path $taskbarPinnedFolder "PowerPoint.lnk"
    if ($wsh -and $powerPointExe) {
        try {
            $shortcut = $wsh.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $powerPointExe
            $shortcut.WorkingDirectory = Split-Path $powerPointExe -Parent
            $shortcut.IconLocation = "$powerPointExe,0"
            $shortcut.Description = "PowerPoint"
            $shortcut.Save()
            Write-Log "Created canonical PowerPoint shortcut in taskbar pinned folder: $shortcutPath"
        }
        catch {
            Write-Log "Could not create PowerPoint taskbar shortcut: $($_.Exception.Message)"
        }
    }

    $wmpExe = Find-WindowsMediaPlayerExe
    if (-not $wmpExe) {
        Write-Log "Windows Media Player Legacy executable not found. Could not pin Windows Media Player."
    }

    Get-ChildItem -Path $taskbarPinnedFolder -Filter "Windows Media Player*.lnk" -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Write-Log "Removing duplicate Windows Media Player taskbar shortcut before recreating canonical shortcut: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate Windows Media Player shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    $wmpShortcutPath = Join-Path $taskbarPinnedFolder "Windows Media Player Legacy.lnk"
    if ($wsh -and $wmpExe) {
        try {
            $wmpShortcut = $wsh.CreateShortcut($wmpShortcutPath)
            $wmpShortcut.TargetPath = $wmpExe
            $wmpShortcut.WorkingDirectory = Split-Path $wmpExe -Parent
            $wmpShortcut.IconLocation = "$wmpExe,0"
            $wmpShortcut.Description = "Windows Media Player Legacy"
            $wmpShortcut.Save()
            Write-Log "Created canonical Windows Media Player Legacy shortcut in taskbar pinned folder: $wmpShortcutPath"
        }
        catch {
            Write-Log "Could not create Windows Media Player Legacy taskbar shortcut: $($_.Exception.Message)"
        }
    }

    $chromeExe = Find-ChromeExe
    if (-not $chromeExe) {
        Write-Log "Google Chrome executable not found. Could not pin Google Chrome."
    }

    Get-ChildItem -Path $taskbarPinnedFolder -Filter "Google Chrome*.lnk" -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Write-Log "Removing duplicate Google Chrome taskbar shortcut before recreating canonical shortcut: $($_.FullName)"
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Could not remove duplicate Google Chrome shortcut $($_.FullName): $($_.Exception.Message)"
        }
    }

    $chromeShortcutPath = Join-Path $taskbarPinnedFolder "Google Chrome.lnk"
    if ($wsh -and $chromeExe) {
        New-OrUpdateShortcut -ShortcutPath $chromeShortcutPath -TargetPath $chromeExe -WorkingDirectory (Split-Path $chromeExe -Parent) -IconLocation "$chromeExe,0" -Description "Google Chrome" | Out-Null
    }

    # Best-effort shell verb pin. On newer Windows 10/11 builds this verb is often hidden/blocked.
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($pinPath in @($fileExplorerShortcutPath, $shortcutPath, $wmpShortcutPath, $chromeShortcutPath)) {
            if (-not (Test-Path $pinPath)) { continue }
            $folder = $shell.Namespace((Split-Path $pinPath -Parent))
            $item = $folder.ParseName((Split-Path $pinPath -Leaf))
            $pinVerb = $item.Verbs() | Where-Object { ($_.Name -replace "&", "") -match "Pin to taskbar" } | Select-Object -First 1
            if ($pinVerb) {
                $pinVerb.DoIt()
                Write-Log "Invoked 'Pin to taskbar' shell verb for: $pinPath"
            }
            else {
                Write-Log "Pin-to-taskbar shell verb was not available for $pinPath. Shortcut was staged, but Windows may not show it as pinned until manually pinned."
            }
        }
    }
    catch {
        Write-Log "Could not invoke taskbar pin shell verb: $($_.Exception.Message)"
    }
}


function Get-PrimaryIPv4AddressForWallpaper {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike "169.254.*" -and
                $_.IPAddress -ne "127.0.0.1" -and
                $_.PrefixOrigin -ne "WellKnown"
            } |
            Sort-Object InterfaceMetric, InterfaceIndex |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    }
    catch { }
    return "Unavailable"
}


function Test-RobotoFontFamilyCompleteForWallpaper {
    $fontFolder = Join-Path $env:WINDIR "Fonts"
    $robotoFiles = Get-ChildItem -Path $fontFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Roboto*.ttf" -or $_.Name -like "Roboto*.otf" }

    if (-not $robotoFiles) { return $false }

    $fileNames = $robotoFiles.Name
    $hasVariableRegular = $fileNames | Where-Object { $_ -like "Roboto*VariableFont*.ttf" -and $_ -notlike "*Italic*" }
    $hasVariableItalic = $fileNames | Where-Object { $_ -like "Roboto*Italic*VariableFont*.ttf" }
    if ($hasVariableRegular -and $hasVariableItalic) { return $true }

    $requiredPatterns = @(
        "Roboto-Regular.*",
        "Roboto-Bold.*",
        "Roboto-Italic.*",
        "Roboto-BoldItalic.*",
        "Roboto-Light.*",
        "Roboto-Medium.*",
        "Roboto-Black.*"
    )

    foreach ($pattern in $requiredPatterns) {
        if (-not ($fileNames | Where-Object { $_ -like $pattern })) { return $false }
    }

    return $true
}

function Ensure-RobotoFontFamilyForWallpaper {
    Write-Log "Ensuring Roboto is installed before wallpaper generation."

    try {
        if (Test-RobotoFontFamilyCompleteForWallpaper) {
            $count = @(Get-ChildItem -Path (Join-Path $env:WINDIR "Fonts") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Roboto*.ttf" -or $_.Name -like "Roboto*.otf" }).Count
            Write-Log "Roboto font family appears complete. Found $count Roboto font file(s)."
            return
        }
        else {
            Write-Log "Roboto font family is missing or incomplete. Installing full Google Fonts package."
        }
    }
    catch {
        Write-Log "Could not verify Roboto completeness before install: $($_.Exception.Message)"
    }

    if (-not (Test-CurrentProcessIsElevated)) {
        Write-Log "Current process is not elevated; cannot install Roboto system-wide."
        return
    }

    $tempRoot = "C:\Temp\RobotoFontInstall"
    $zipPath = Join-Path $tempRoot "roboto.zip"
    $extractPath = Join-Path $tempRoot "extracted"
    $fontRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    $fontDownloadUrl = "https://fonts.google.com/download?family=Roboto"

    try {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null

        $oldProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $fontDownloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $oldProgressPreference
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $fontFiles = Get-ChildItem -Path $extractPath -Recurse -Include *.ttf,*.otf -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like "Roboto*" }

        if (-not $fontFiles) {
            throw "No Roboto .ttf or .otf files were found in the downloaded archive."
        }

        New-Item -Path $fontRegistryPath -Force | Out-Null

        foreach ($fontFile in $fontFiles) {
            $destination = Join-Path $env:WINDIR "Fonts\$($fontFile.Name)"
            Copy-Item -Path $fontFile.FullName -Destination $destination -Force
            $registryName = "$($fontFile.BaseName) (TrueType)"
            if ($fontFile.Extension -ieq ".otf") {
                $registryName = "$($fontFile.BaseName) (OpenType)"
            }
            New-ItemProperty -Path $fontRegistryPath -Name $registryName -PropertyType String -Value $fontFile.Name -Force | Out-Null
            Write-Log "Installed font: $($fontFile.Name)"
        }

        try {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FontBroadcastTools {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue
            $result = [UIntPtr]::Zero
            [FontBroadcastTools]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, $null, 0x0002, 5000, [ref]$result) | Out-Null
        }
        catch {
            Write-Log "Could not broadcast font-change notification: $($_.Exception.Message)"
        }

        Write-Log "Roboto font family installation completed."
    }
    catch {
        Write-Log "Could not install Roboto font family: $($_.Exception.Message)"
    }
}

function Get-PreferredWallpaperFontName {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $installed = New-Object System.Drawing.Text.InstalledFontCollection
        $families = $installed.Families | Select-Object -ExpandProperty Name
        if ($families -contains "Roboto") { return "Roboto" }
        if ($families -contains "Arial") { return "Arial" }
    }
    catch { }
    return "Microsoft Sans Serif"
}


function Get-ComputerNameForWallpaper {
    $nameFile = "C:\Temp\retreat-computer-name.txt"
    try {
        if (Test-Path $nameFile) {
            $name = (Get-Content -Path $nameFile -Raw -ErrorAction SilentlyContinue).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
        }
    }
    catch { }
    return $env:COMPUTERNAME
}

function Apply-RetreatInfoWallpaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WallpaperPath
    )

    Write-Log "Applying generated wallpaper explicitly: $WallpaperPath"

    if (-not (Test-Path $WallpaperPath)) {
        Write-Log "Wallpaper file does not exist, cannot apply: $WallpaperPath"
        return $false
    }

    $success = $true
    $desktopPath = "HKCU:\Control Panel\Desktop"
    $policyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    $contentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"

    try {
        $null = Set-RegistryStringValue -Path $desktopPath -Name "Wallpaper" -Value $WallpaperPath
        $null = Set-RegistryStringValue -Path $desktopPath -Name "WallpaperStyle" -Value "10"
        $null = Set-RegistryStringValue -Path $desktopPath -Name "TileWallpaper" -Value "0"
    }
    catch {
        Write-Log "PowerShell wallpaper registry write failed: $($_.Exception.Message)"
        $success = $false
    }

    try {
        & reg.exe add "HKCU\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d $WallpaperPath /f | Out-Null
        & reg.exe add "HKCU\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
        & reg.exe add "HKCU\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
    }
    catch {
        Write-Log "reg.exe wallpaper registry fallback failed: $($_.Exception.Message)"
        $success = $false
    }

    # Force the generated wallpaper through the per-user policy path as well. This is intentional for a managed retreat/kiosk profile.
    try {
        $null = Set-RegistryStringValue -Path $policyPath -Name "Wallpaper" -Value $WallpaperPath
        $null = Set-RegistryStringValue -Path $policyPath -Name "WallpaperStyle" -Value "4"
        & reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v Wallpaper /t REG_SZ /d $WallpaperPath /f | Out-Null
        & reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v WallpaperStyle /t REG_SZ /d 4 /f | Out-Null
    }
    catch {
        Write-Log "Could not set wallpaper policy fallback: $($_.Exception.Message)"
    }

    # Keep Spotlight/active content from immediately replacing the generated wallpaper.
    try {
        $null = Set-RegistryDWordValue -Path $contentPath -Name "RotatingLockScreenEnabled" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "RotatingLockScreenOverlayEnabled" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "ContentDeliveryAllowed" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "SubscribedContent-338388Enabled" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "SubscribedContent-338389Enabled" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "SubscribedContent-338393Enabled" -Value 0
        $null = Set-RegistryDWordValue -Path $contentPath -Name "SubscribedContent-353698Enabled" -Value 0
    }
    catch {
        Write-Log "Could not reinforce Spotlight disablement before wallpaper apply: $($_.Exception.Message)"
    }

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class RetreatWallpaperTools {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@ -ErrorAction SilentlyContinue
        $spiResult = [RetreatWallpaperTools]::SystemParametersInfo(20, 0, $WallpaperPath, 3)
        Write-Log "SystemParametersInfo wallpaper apply returned: $spiResult"
        if (-not $spiResult) { $success = $false }
    }
    catch {
        Write-Log "Could not immediately apply generated wallpaper with SystemParametersInfo: $($_.Exception.Message)"
        $success = $false
    }

    try {
        Start-Process -FilePath rundll32.exe -ArgumentList "user32.dll,UpdatePerUserSystemParameters" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        Write-Log "Requested UpdatePerUserSystemParameters refresh."
    }
    catch {
        Write-Log "Could not run UpdatePerUserSystemParameters refresh: $($_.Exception.Message)"
    }

    return $success
}

function New-RetreatInfoWallpaper {
    Write-Log "Generating system-information wallpaper."

    $wallpaperPath = "C:\Temp\retreat-system-info-wallpaper.jpg"
    $wallpaperFolder = Split-Path -Path $wallpaperPath -Parent
    if (-not (Test-Path $wallpaperFolder)) {
        New-Item -Path $wallpaperFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $width = 1920
        $height = 1080
        try {
            $video = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } |
                Select-Object -First 1
            if ($video) {
                $width = [int]$video.CurrentHorizontalResolution
                $height = [int]$video.CurrentVerticalResolution
            }
        }
        catch { }

        if ($width -lt 1024) { $width = 1920 }
        if ($height -lt 768) { $height = 1080 }

        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

        $serial = if ($bios.SerialNumber) { $bios.SerialNumber.Trim() } else { "Unavailable" }
        $assetTag = if ($enclosure.SMBIOSAssetTag) { $enclosure.SMBIOSAssetTag.Trim() } else { "Unavailable" }
        if ([string]::IsNullOrWhiteSpace($assetTag) -or $assetTag -match "(?i)no asset|none|default|string") { $assetTag = "Unavailable" }
        $manufacturer = if ($computerSystem.Manufacturer) { $computerSystem.Manufacturer.Trim() } else { "Unavailable" }
        $model = if ($computerSystem.Model) { $computerSystem.Model.Trim() } else { "Unavailable" }
        $osCaption = if ($os.Caption) { $os.Caption.Trim() } else { "Unavailable" }
        $ip = Get-PrimaryIPv4AddressForWallpaper
        $fontName = Get-PreferredWallpaperFontName

        Write-Log "Wallpaper target file: $wallpaperPath"
        Write-Log "Wallpaper canvas: ${width}x${height}; font: $fontName"

        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        $background = [System.Drawing.Color]::FromArgb(18, 22, 28)
        $panel = [System.Drawing.Color]::FromArgb(36, 42, 52)
        $accent = [System.Drawing.Color]::FromArgb(120, 160, 220)
        $white = [System.Drawing.Color]::FromArgb(245, 247, 250)
        $muted = [System.Drawing.Color]::FromArgb(190, 198, 210)

        $graphics.Clear($background)
        $brushPanel = New-Object System.Drawing.SolidBrush($panel)
        $brushAccent = New-Object System.Drawing.SolidBrush($accent)
        $brushWhite = New-Object System.Drawing.SolidBrush($white)
        $brushMuted = New-Object System.Drawing.SolidBrush($muted)

        $margin = [Math]::Max(60, [int]($width * 0.045))
        $panelWidth = [Math]::Min(820, [int]($width * 0.48))
        $panelHeight = 520
        $x = $margin
        $y = [Math]::Max(70, [int]($height * 0.12))

        $graphics.FillRectangle($brushPanel, $x, $y, $panelWidth, $panelHeight)
        $graphics.FillRectangle($brushAccent, $x, $y, 8, $panelHeight)

        $titleFont = New-Object System.Drawing.Font($fontName, 32, [System.Drawing.FontStyle]::Bold)
        $labelFont = New-Object System.Drawing.Font($fontName, 14, [System.Drawing.FontStyle]::Regular)
        $valueFont = New-Object System.Drawing.Font($fontName, 20, [System.Drawing.FontStyle]::Regular)
        $smallFont = New-Object System.Drawing.Font($fontName, 11, [System.Drawing.FontStyle]::Regular)

        $cursorY = $y + 38
        $graphics.DrawString("Retreat Computer", $titleFont, $brushWhite, $x + 36, $cursorY)
        $cursorY += 70

        $rows = @(
            @{ Label = "Computer Name"; Value = (Get-ComputerNameForWallpaper) },
            @{ Label = "Serial Number"; Value = $serial },
            @{ Label = "Asset Tag"; Value = $assetTag },
            @{ Label = "Model"; Value = "$manufacturer $model" },
            @{ Label = "IP Address"; Value = $ip },
            @{ Label = "Logged-in User"; Value = $env:USERNAME },
            @{ Label = "Operating System"; Value = $osCaption }
        )

        foreach ($row in $rows) {
            $graphics.DrawString($row.Label, $labelFont, $brushMuted, $x + 40, $cursorY)
            $graphics.DrawString([string]$row.Value, $valueFont, $brushWhite, $x + 40, $cursorY + 22)
            $cursorY += 62
        }

        $stamp = "Generated {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm")
        $graphics.DrawString($stamp, $smallFont, $brushMuted, $x + 40, $y + $panelHeight - 34)

        $bitmap.Save($wallpaperPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)

        $graphics.Dispose()
        $bitmap.Dispose()
        $brushPanel.Dispose()
        $brushAccent.Dispose()
        $brushWhite.Dispose()
        $brushMuted.Dispose()
        $titleFont.Dispose()
        $labelFont.Dispose()
        $valueFont.Dispose()
        $smallFont.Dispose()

        if (Test-Path $wallpaperPath) {
            $size = (Get-Item $wallpaperPath).Length
            Write-Log "Wallpaper file created: $wallpaperPath ($size bytes)"
        }
        else {
            Write-Log "Wallpaper file was not created: $wallpaperPath"
            return
        }

        $applied = Apply-RetreatInfoWallpaper -WallpaperPath $wallpaperPath
        if ($applied) {
            Write-Log "Generated and applied wallpaper: $wallpaperPath"
        }
        else {
            Write-Log "Generated wallpaper but one or more apply methods reported failure: $wallpaperPath"
        }
    }
    catch {
        Write-Log "Could not generate wallpaper: $($_.Exception.Message)"
    }
}

function Set-ChromeDefaultBrowserBestEffort {
    Write-Log "Applying Chrome default browser best-effort settings."

    $chromeExeCandidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chromeExe = $chromeExeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $chromeExe) {
        Write-Log "Chrome executable not found. Cannot set Chrome as default browser."
        return
    }

    try {
        $chromePolicy = "HKCU:\Software\Policies\Google\Chrome"
        $null = Set-RegistryDWordValue -Path $chromePolicy -Name "DefaultBrowserSettingEnabled" -Value 1
        Write-Log "Set Chrome default-browser policy nudge for current user."
    }
    catch {
        Write-Log "Could not set Chrome default-browser policy nudge: $($_.Exception.Message)"
    }

    Write-Log "Windows protects existing users' default-browser UserChoice hash. If Chrome is not default after reboot, set it once in Settings > Apps > Default apps > Google Chrome."
}

$currentUser = $env:USERNAME
if ($currentUser -ine $TargetUsername) {
    Write-Log "Current user '$currentUser' is not target user '$TargetUsername'. Exiting without changes."
    exit 0
}

Write-Log "Provisioning script started for $TargetUsername."

if (-not (Test-CurrentProcessIsElevated)) {
    Write-Log "Regular non-elevated target-user context detected. Running Spotify-only installer."
    Invoke-WingetInstallWithTimeout -PackageId "Spotify.Spotify" -FriendlyName "Spotify" -InstalledDisplayNamePattern "^Spotify" -Silent $true -TimeoutSeconds 1800

    if (-not (Test-AppInstalledByDisplayName -DisplayNamePattern "^Spotify")) {
        Write-Log "Spotify is still not installed. Leaving Startup trigger in place so it can retry at the next normal user logon."
        exit 1
    }

    Write-Log "Spotify user-context provisioning complete."
    exit 0
}

Write-Log "Elevated target-user context detected. Running all user/profile cleanup except Spotify."
Remove-EdgeDesktopShortcuts
Disable-WindowsHelloAndSetupPromptsForCurrentUser
Invoke-WingetInstallWithTimeout -PackageId "Google.Chrome" -FriendlyName "Google Chrome" -InstalledDisplayNamePattern "^Google Chrome" -Silent $true -TimeoutSeconds 1800
Write-Log "Skipping Spotify in elevated context. Spotify is staged separately for normal non-elevated user logon."
Invoke-WingetInstallWithTimeout -PackageId "Slido.Slido" -FriendlyName "Slido for PowerPoint" -InstalledDisplayNamePattern "^Slido" -Silent $false -TimeoutSeconds 1800
Set-ChromeDefaultBrowserBestEffort
Reset-TaskbarPinsForProvisionedApps
Reset-DesktopIconsAndCreateProvisionedShortcuts
Configure-TaskbarLayoutPolicyForProvisionedApps
Disable-TeamsStartupForCurrentUser
Configure-CurrentUserTaskbarAndActiveContent
Ensure-RobotoFontFamilyForWallpaper
New-RetreatInfoWallpaper
Disable-TeamsStartupForCurrentUser

try {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-Log "Explorer restart requested."
}
catch {
    Write-Log "Could not restart Explorer: $($_.Exception.Message)"
}

# Re-apply after Explorer restart request in case shell policy/Spotlight rewrote the desktop settings during cleanup.
try {
    Start-Sleep -Seconds 2
    Apply-RetreatInfoWallpaper -WallpaperPath "C:\Tempetreat-system-info-wallpaper.jpg" | Out-Null
}
catch {
    Write-Log "Could not re-apply wallpaper after Explorer restart: $($_.Exception.Message)"
}

Write-Log "Elevated user/profile provisioning complete. Spotify Startup trigger remains only if Spotify is not installed."
exit 0
'@

    Set-Content -Path $firstLogonScript -Value $firstLogonContent -Encoding UTF8 -Force

    $cmdContent = @"
@echo off
setlocal
if /I not "%USERNAME%"=="$Username" exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$firstLogonScript" -TargetUsername "$Username" -LogPath "$logPath"
if errorlevel 1 exit /b %ERRORLEVEL%
del "%~f0" >nul 2>&1
exit /b 0
"@

    Set-Content -Path $firstLogonCmd -Value $cmdContent -Encoding ASCII -Force

    Write-Host "First-logon PowerShell staged at: $firstLogonScript"
    Write-Host "First-logon Startup trigger staged at: $firstLogonCmd"
    Write-Host "First-logon log will be written to: $logPath"
}


function Invoke-StagedFirstLogonIfCurrentUser {
    param([Parameter(Mandatory)][string]$Username)

    Write-Step "Checking staged user/profile provisioning trigger"

    $currentUser = $env:USERNAME
    $provisioningFolder = Join-Path $env:ProgramData "DeltaProvisioning"
    $startupFolder = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    $firstLogonScript = Join-Path $provisioningFolder "FirstLogon-For-$Username.ps1"
    $firstLogonCmd = Join-Path $startupFolder "Run-FirstLogon-Provisioning-For-$Username.cmd"
    $tempFolder = "C:\Temp"
    $logPath = Join-Path $tempFolder "first-logon-$Username.log"

    if (-not (Test-Path $firstLogonScript)) {
        Write-Warning "Staged user/profile script was not found at $firstLogonScript. It cannot run."
        return
    }

    if (-not (Test-Path $firstLogonCmd)) {
        Write-Warning "Spotify Startup trigger was not found at $firstLogonCmd. Re-stage the script if Spotify user-context install is needed."
        return
    }

    if ($currentUser -ieq $Username) {
        Write-Host "Already running as target user '$Username'. Running user/profile cleanup now from the main elevated process."
        Write-Host "Spotify remains staged separately for the next normal non-elevated user logon."

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $firstLogonScript,
            "-TargetUsername", $Username,
            "-LogPath", $logPath
        )

        try {
            $process = Start-Process -FilePath "powershell.exe" -ArgumentList $args -Wait -NoNewWindow -PassThru
            Write-Host "Immediate user/profile cleanup exited with code $($process.ExitCode)."
        }
        catch {
            Write-Warning "Could not run immediate user/profile cleanup: $($_.Exception.Message)"
        }

        if (Test-AppInstalledByDisplayName -DisplayNamePattern "^Spotify") {
            Remove-Item -Path $firstLogonCmd -Force -ErrorAction SilentlyContinue
            Write-Host "Spotify is already installed. Removed Spotify Startup trigger."
        }
        else {
            Write-Host "Spotify is not installed. Startup trigger remains for the next normal non-elevated logon: $firstLogonCmd"
        }
    }
    else {
        Write-Host "Current user '$currentUser' is not target user '$Username'. User/profile cleanup and Spotify install will run when $Username logs in."
    }
}

function Configure-ScreenSaverAndPower {
    Write-Step "Configuring screensaver and power settings"

    # Disable screensaver for the currently logged-in user context.
    $desktopPath = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopPath -Name "ScreenSaveActive" -Value "0" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $desktopPath -Name "ScreenSaverIsSecure" -Value "0" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $desktopPath -Name "SCRNSAVE.EXE" -ErrorAction SilentlyContinue

    # Enforce no screensaver via local machine policy.
    $systemPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop"
    New-Item -Path $systemPolicy -Force | Out-Null
    New-ItemProperty -Path $systemPolicy -Name "ScreenSaveActive" -PropertyType String -Value "0" -Force | Out-Null

    # AC plugged in: display never turns off, system never sleeps, hibernate disabled.
    powercfg /change monitor-timeout-ac 0
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    # DC battery: 4 hours = 240 minutes.
    powercfg /change monitor-timeout-dc 240
    powercfg /change standby-timeout-dc 240
    powercfg /change hibernate-timeout-dc 240

    # Disable hibernation file if not needed.
    powercfg /hibernate off

    Write-Host "Configured AC: screen/sleep never. DC: screen/sleep after 240 minutes."
}

Ensure-LocalAdmin `
    -Username $LocalAdminUser `
    -Password $LocalAdminPassword `
    -SkipResetIfCurrentUser $SkipPasswordResetIfRunningAsTargetUser

$effectiveComputerNameForAutologon = Rename-ComputerIfRequested -RequestedName $NewComputerName
New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
Set-Content -Path "C:\Temp\retreat-computer-name.txt" -Value $effectiveComputerNameForAutologon -Encoding ASCII -Force

Configure-AutoLogon `
    -Username $LocalAdminUser `
    -Password $LocalAdminPassword `
    -DefaultDomainName $effectiveComputerNameForAutologon

Remove-FromDomainIfJoined `
    -Workgroup $WorkgroupName `
    -Credential $DomainUnjoinCredential

Disable-StartupItems -Username $LocalAdminUser
Ensure-RetreatFolder
Ensure-RobotoFontFamily
Configure-WindowsHelloAndSetupExperienceSuppression
Configure-MachineActiveContentPolicies
Configure-ChromeDefaultBrowserForNewUsers
Stage-FirstLogonProvisioning -Username $LocalAdminUser
Remove-SecurityAndVpnApps

Ensure-Winget
Ensure-WindowsMediaPlayerLegacy

Configure-ScreenSaverAndPower
Invoke-StagedFirstLogonIfCurrentUser -Username $LocalAdminUser

Write-Step "Complete"
Write-Warning "Review output for uninstall or domain-unjoin failures."
Write-Warning "Reboot the computer to apply autologon, domain unjoin, startup, and power-policy changes."
