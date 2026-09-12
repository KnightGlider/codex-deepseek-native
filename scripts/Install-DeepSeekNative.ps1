#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the native DeepSeek subagent role for the Codex desktop app.

.DESCRIPTION
    This script does three small, reversible things:

      1. Adds a clearly marked, managed block to the Codex config file
         (<CodexHome>\config.toml) that registers a "deepseek_flash" subagent role.
      2. Writes the role definition file (<CodexHome>\agents\deepseek_flash.toml).
      3. Optionally creates a desktop shortcut that launches the Codex desktop app
         with the patched backend (see Start-DeepSeekNative.ps1).

    It backs up every file it touches before changing it, keeps an install state
    file, and never touches unrelated settings, credentials or environment
    variables. Running it twice is safe: the second run reports "up to date".

    The runtime itself (the patched codex.exe plus its helper executables) is not
    built or downloaded by this script. You point at a folder you already have.

.PARAMETER RuntimeDirectory
    Folder containing codex.exe, codex-command-runner.exe,
    codex-windows-sandbox-setup.exe and codex-code-mode-host.exe.
    Required the first time. Later runs remember the location.

.PARAMETER CodexHome
    Optional. Overrides the Codex home folder used for config.toml.
    Default: %CODEX_HOME% if set, otherwise <UserProfile>\.codex.

.PARAMETER InstallRoot
    Optional. Base folder for state, logs and backups.
    Default: <UserProfile>\.codex-deepseek-native.

.PARAMETER RuntimeManifest
    Optional JSON file listing SHA256 hashes of the runtime files, for release
    verification. If omitted, a runtime-manifest.json next to codex.exe is used
    when present. No hash is ever required.

.PARAMETER CreateDesktopShortcut
    Also create a "DeepSeek Native Codex" shortcut on the desktop.

.EXAMPLE
    .\Install-DeepSeekNative.ps1 -RuntimeDirectory "$env:USERPROFILE\.codex-deepseek-native\runtime"

.EXAMPLE
    .\Install-DeepSeekNative.ps1 -RuntimeDirectory D:\codex-runtime -CreateDesktopShortcut -WhatIf

.NOTES
    Exit codes: 0 success, 1 failed, 2 there is a damaged managed block; nothing
    was changed and a human must look at config.toml.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RuntimeDirectory,
    [string]$CodexHome,
    [string]$InstallRoot,
    [string]$RuntimeManifest,
    [switch]$SkipManifestVerification,
    [switch]$SkipVersionProbe,
    [string]$MinimumVersion,
    [switch]$CreateDesktopShortcut,
    [switch]$AllowMissingRecommendedHelpers
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0
$script:LogPath = $null

. (Join-Path $PSScriptRoot 'DeepSeekNative.Common.ps1')

function Write-Step {
    param([string]$Message)
    Write-Host "  $Message"
}

function Write-Head {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message
}

function Fail {
    param([string]$Message, [int]$Code = 1)
    Write-Host ''
    Write-Host "SETUP FAILED: $Message" -ForegroundColor Red
    if ($script:LogPath) {
        Write-DseLog -Message $Message -LogPath $script:LogPath -Level 'FAIL' | Out-Null
    }
    exit $Code
}

try {
    $defaults = Get-DseDefaults
    if ([string]::IsNullOrWhiteSpace($MinimumVersion)) {
        $MinimumVersion = $defaults.minimumRuntimeVersion
    }

    $resolvedCodexHome = Get-DseCodexHome -CodexHome $CodexHome
    $resolvedInstallRoot = Get-DseInstallRoot -InstallRoot $InstallRoot

    # Refuse to keep state, logs and config backups inside this kit's own folder.
    # Backups can hold credentials copied out of config.toml, and they must never
    # end up in a source checkout that might be shared or committed.
    #
    # This check runs before the log path is set, so the refusal itself cannot
    # create a file inside the folder it is refusing.
    $kitRoot = Get-DseKitRoot
    if (Test-DsePathInside -Path $resolvedInstallRoot -Parent $kitRoot) {
        Fail ("The install root is inside this kit's own folder:`n" +
              "         install root: $resolvedInstallRoot`n" +
              "         kit folder  : $kitRoot`n" +
              '         Setup keeps config backups, logs and state under the install root, and' + [Environment]::NewLine +
              '         those can contain credentials. Choose a folder outside the kit, for example:' + [Environment]::NewLine +
              "           -InstallRoot `"`$env:USERPROFILE\.codex-deepseek-native`"" + [Environment]::NewLine +
              '         Nothing was changed.')
    }

    $stateDirectory = Get-DseStateDirectory -InstallRoot $resolvedInstallRoot
    $logDirectory = Get-DseLogDirectory -InstallRoot $resolvedInstallRoot
    $backupDirectory = Get-DseBackupDirectory -InstallRoot $resolvedInstallRoot
    $script:LogPath = Join-Path $logDirectory 'install.log'

    $previousState = Read-DseInstallState -InstallRoot $resolvedInstallRoot

    Write-Host 'Setting up the native DeepSeek subagent role for Codex'
    Write-Host '---------------------------------------------------'
    Write-Step "Codex home : $resolvedCodexHome"
    Write-Step "Install root: $resolvedInstallRoot"

    foreach ($pair in @(
        @{ Name = 'Codex home'; Path = $resolvedCodexHome },
        @{ Name = 'Install root'; Path = $resolvedInstallRoot }
    )) {
        if (Test-DseVirtualizedPath $pair.Path) {
            Write-Host ("  WARNING: the {0} path looks like a packaged-app virtual folder: {1}" -f $pair.Name, $pair.Path) -ForegroundColor Yellow
            Write-Host '           Codex and other apps may see a different folder than Explorer and shortcuts do.' -ForegroundColor Yellow
        }
    }

    # ---------------------------------------------------------------- runtime
    $runtimeWasExplicit = -not [string]::IsNullOrWhiteSpace($RuntimeDirectory)
    if (-not $runtimeWasExplicit) {
        if ($previousState -and -not [string]::IsNullOrWhiteSpace($previousState.runtimeDirectory)) {
            $RuntimeDirectory = $previousState.runtimeDirectory
            Write-Step 'Runtime     : reusing the location recorded by the previous install'
        }
        else {
            $RuntimeDirectory = Get-DseSubdirectory -InstallRoot $resolvedInstallRoot -Name 'runtime'
        }
    }
    $resolvedRuntime = Get-DseRuntimeDirectory -RuntimeDirectory $RuntimeDirectory -InstallRoot $resolvedInstallRoot
    $runtimeIsDefaultFolder = ($resolvedRuntime -eq (Get-DseSubdirectory -InstallRoot $resolvedInstallRoot -Name 'runtime'))

    Write-Step "Runtime     : $resolvedRuntime"

    $runtimeCheck = Test-DseRuntimeDirectory -RuntimeDirectory $resolvedRuntime -Defaults $defaults -AllowMissingRecommendedHelpers:$AllowMissingRecommendedHelpers
    if (-not $runtimeCheck.Exists) {
        Fail ("The runtime folder does not exist: $resolvedRuntime`n" +
              "         Put codex.exe and its three helper executables there, or pass -RuntimeDirectory <folder>.`n" +
              '         The runtime comes from the build/release archive; this setup script never downloads it.')
    }
    if (-not $runtimeCheck.IsValid) {
        $lines = @("The runtime folder is missing required files: $resolvedRuntime")
        foreach ($name in $runtimeCheck.MissingRequired) { $lines += "           missing: $name" }
        foreach ($name in $runtimeCheck.MissingRecommended) { $lines += "           missing: $name" }
        $lines += '         Expected files: ' + ($defaults.requiredRuntimeFiles -join ', ')
        Fail ($lines -join [Environment]::NewLine)
    }

    Write-DseLog -Message "Runtime validated: $resolvedRuntime" -LogPath $script:LogPath -Level 'PASS' | Out-Null

    # ---------------------------------------------------------------- manifest
    $manifestResult = [pscustomobject]@{ Present = $false; Verified = $false; ManifestPath = $null; Version = $null }
    if (-not $SkipManifestVerification) {
        $manifestResult = Test-DseRuntimeManifest -RuntimeDirectory $resolvedRuntime -ManifestPath $RuntimeManifest -Defaults $defaults
        if ($manifestResult.Present -and -not $manifestResult.Verified) {
            $lines = @("The release hash manifest did not match the runtime files: $($manifestResult.ManifestPath)")
            foreach ($name in $manifestResult.MissingFiles) { $lines += "           missing: $name" }
            foreach ($name in $manifestResult.Mismatches) { $lines += "           hash mismatch: $name" }
            foreach ($problem in $manifestResult.Problems) { $lines += "           $problem" }
            $lines += '         Use -SkipManifestVerification only if you trust this runtime.'
            Fail ($lines -join [Environment]::NewLine)
        }
        if ($manifestResult.Present -and $manifestResult.Verified) {
            Write-Step "Manifest    : verified ($($manifestResult.ManifestPath))"
            Write-DseLog -Message "Release manifest verified: $($manifestResult.ManifestPath)" -LogPath $script:LogPath -Level 'PASS' | Out-Null
        }
        else {
            Write-Step 'Manifest    : none supplied (no hashes required for a source build)'
        }
    }
    else {
        # -SkipManifestVerification skips the hash comparison only. A bundle that
        # declares itself a fixture is still refused, so a test stub can never be
        # installed as a working runtime.
        $candidateManifest = $RuntimeManifest
        if ([string]::IsNullOrWhiteSpace($candidateManifest)) {
            $candidateManifest = Join-Path $resolvedRuntime $defaults.runtimeManifestFileName
        }
        if (Test-Path -LiteralPath $candidateManifest -PathType Leaf) {
            try {
                $parsedManifest = Get-Content -LiteralPath $candidateManifest -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                Fail ("The runtime manifest is not valid JSON ($candidateManifest): $($_.Exception.Message)")
            }
            try {
                Assert-DseManifestNotFixture -Manifest $parsedManifest -Path $candidateManifest
            }
            catch {
                Fail $_.Exception.Message
            }
        }
        Write-Step 'Manifest    : hashes not checked (-SkipManifestVerification)'
    }

    # ----------------------------------------------------------- version probe
    $runtimeVersion = $null
    if ($SkipVersionProbe) {
        if ($manifestResult.Version) {
            $runtimeVersion = $manifestResult.Version
            Write-Step "Version     : $runtimeVersion (from the manifest; the check was skipped)"
            if (-not (Test-DseMinimumVersion -Text $manifestResult.Version -MinimumVersion $MinimumVersion)) {
                Fail ("The release manifest reports version $($manifestResult.Version), but this workflow needs $MinimumVersion or newer.`n" +
                      "         Manifest: $($manifestResult.ManifestPath)")
            }
        }
        else {
            Write-Step 'Version     : not checked (-SkipVersionProbe)'
        }
    }
    else {
        $codexExe = Join-Path $resolvedRuntime 'codex.exe'
        Write-Step 'Version     : running codex.exe --version ...'
        try {
            $probe = Invoke-DseVersionProbe -ExePath $codexExe
        }
        catch {
            Fail ("Could not run the runtime to check its version: $codexExe`n" +
                  "         Reason: $($_.Exception.Message)`n" +
                  '         Check that the file is not blocked by antivirus, then retry.')
        }

        if ($probe.ExitCode -ne 0) {
            Fail ("codex.exe --version exited with code $($probe.ExitCode).`n" +
                  "         Output: $($probe.Raw)`n" +
                  '         This does not look like a working Codex runtime.')
        }
        if ($null -eq $probe.Version) {
            Fail ("codex.exe --version did not report a version number.`n" +
                  "         Output: $($probe.Raw)")
        }
        if (-not (Test-DseMinimumVersion -Text $probe.Raw -MinimumVersion $MinimumVersion)) {
            Fail ("The runtime reports version $($probe.Version), but this workflow needs $MinimumVersion or newer.`n" +
                  "         Output: $($probe.Raw)`n" +
                  '         Use the runtime archive built by the project CI, which pins the expected version.')
        }

        $runtimeVersion = "$($probe.Version)"
        Write-Step "Version     : $runtimeVersion (checked, needs $MinimumVersion or newer)"
        Write-DseLog -Message "Runtime version $runtimeVersion (exit $($probe.ExitCode))" -LogPath $script:LogPath -Level 'PASS' | Out-Null
    }

    # -------------------------------------------------- render the managed block
    $configPath = Join-Path $resolvedCodexHome 'config.toml'
    $roleConfigPath = Join-Path $resolvedCodexHome ($defaults.roleConfigRelativePath -replace '/', '\')
    $fragmentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\managed-block.toml.fragment'

    if (-not (Test-Path -LiteralPath $fragmentPath -PathType Leaf)) {
        Fail "The managed-block template is missing: $fragmentPath"
    }

    $fragment = Read-DseTextFile -Path $fragmentPath
    $renderedBlock = $fragment.Text.Replace('{{CONFIG_FILE}}', (Get-DseTomlBasicString $roleConfigPath))
    $renderedBlockPath = Join-Path $stateDirectory 'managed-block.rendered.toml'

    $roleTemplatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.deepseek_flash.toml'
    if (-not (Test-Path -LiteralPath $roleTemplatePath -PathType Leaf)) {
        Fail "The role template is missing: $roleTemplatePath"
    }
    $roleTemplate = Read-DseTextFile -Path $roleTemplatePath

    # --------------------------------------------------------------- planning
    # Decide everything before writing anything, so a collision or a damaged
    # block can never leave a half-finished setup behind.
    $backups = New-Object System.Collections.Generic.List[object]
    $configHasContent = $false

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $currentConfig = Read-DseTextFile -Path $configPath
        $configHasContent = $true
    }
    else {
        Write-Step "Config      : $configPath does not exist yet; it will be created with only the managed block"
        $currentConfig = [pscustomobject]@{
            Path     = $configPath
            Text     = ''
            Encoding = (New-Object System.Text.UTF8Encoding($false))
            HasBom   = $false
            Length   = 0
        }
    }

    # Work out the new file content first, so a run that changes nothing writes
    # nothing and does not create a pointless backup.
    $eol = Get-DseLineEnding $currentConfig.Text
    $normalizedBlock = ($renderedBlock -replace "`r`n", "`n") -replace "`n", $eol
    if (-not $normalizedBlock.EndsWith($eol)) { $normalizedBlock += $eol }

    try {
        $updatedConfigText = Add-DseManagedBlock -Text $currentConfig.Text -Marker $defaults.marker -Block $normalizedBlock
    }
    catch {
        Fail ("$($_.Exception.Message)`n" +
              "         Your config file was not changed. Existing backups are in $backupDirectory") 2
    }
    # -cne: compare case sensitively. A change that differs only in letter case is
    # still a different file, and must not be reported as "already correct".
    $configNeedsWrite = ($updatedConfigText -cne $currentConfig.Text)

    # Ownership of the role file. We only replace a role file that this product
    # created and that is still exactly as we wrote it. A different file is
    # refused rather than silently overwritten, and rollback never deletes a
    # file this product did not create.
    $previousRoleOwned = $false
    $previousRoleSha = $null
    if ($previousState -and $previousState.roleFileOwnedByProduct) {
        $previousRoleOwned = $true
        if ($previousState.roleFileSha256) { $previousRoleSha = "$($previousState.roleFileSha256)" }
    }

    $rolePlan = 'create'
    $roleFileOwnedByProduct = $true
    if (Test-Path -LiteralPath $roleConfigPath -PathType Leaf) {
        $existingRoleText = (Read-DseTextFile -Path $roleConfigPath).Text
        $existingRoleSha = Get-DseFileSha256 -Path $roleConfigPath
        if ($existingRoleText -ceq $roleTemplate.Text) {
            $rolePlan = 'keep'
            $roleFileOwnedByProduct = $previousRoleOwned
        }
        elseif ($previousRoleOwned -and $previousRoleSha -and ($existingRoleSha -eq $previousRoleSha)) {
            $rolePlan = 'refresh'
        }
        else {
            $rolePlan = 'collision'
            $roleFileOwnedByProduct = $false
        }
    }

    if ($rolePlan -eq 'collision') {
        Fail ("A different subagent role file already exists:`n" +
              "         $roleConfigPath`n" +
              '         Setup will not overwrite a file it did not create. Move or rename that file,' + [Environment]::NewLine +
              '         then run setup again. Nothing was changed.')
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedInstallRoot, 'Create setup folders and register the deepseek_flash role')) {
        Write-Host ''
        Write-Host 'WhatIf: nothing was written.'
        exit 0
    }

    foreach ($directory in @($stateDirectory, $logDirectory, $backupDirectory, (Join-Path $resolvedCodexHome 'agents'))) {
        New-DseDirectory $directory | Out-Null
    }
    Write-DseTextFile -Path $renderedBlockPath -Text $renderedBlock -HasBom:$false | Out-Null

    # ------------------------------------------------------------- config.toml
    Write-Head 'Applying changes'
    if ($configNeedsWrite) {

        # Every restore point pairs one backup file with the exact hash of the
        # file that replaced it. Keeping them together means a reinstall can
        # never leave an old backup matched with a newer baseline, which would
        # let -RestoreBackup overwrite edits made after the first install.
        if ($configHasContent) {
            $configBackup = Copy-DseBackup -Path $configPath -BackupDirectory $backupDirectory -Label 'config.toml'
            if ($configBackup) {
                $backups.Add([pscustomobject]@{
                    source          = $configPath
                    backup          = $configBackup
                    sha256          = (Get-DseFileSha256 -Path $configBackup)
                    replacedWithSha = $null   # filled in below, after the write
                })
                Write-Step "Backed up   : $configPath"
                Write-Step "              -> $configBackup"
            }
        }
        Write-DseTextFile -Path $configPath -Text $updatedConfigText -Encoding $currentConfig.Encoding | Out-Null
        if ($backups.Count -gt 0) {
            $lastBackup = $backups[$backups.Count - 1]
            if ($lastBackup.source -eq $configPath) {
                $lastBackup.replacedWithSha = Get-DseFileSha256 -Path $configPath
            }
        }
        Write-Step 'Config      : registered the deepseek_flash subagent role'
        Write-DseLog -Message "Managed block written to $configPath" -LogPath $script:LogPath -Level 'PASS' | Out-Null
    }
    else {
        Write-Step 'Config      : the managed block was already present and correct (no change)'
    }

    # ------------------------------------------------------------- role file
    $roleBackup = $null
    switch ($rolePlan) {
        'create' {
            Write-DseTextFile -Path $roleConfigPath -Text $roleTemplate.Text -HasBom:$false | Out-Null
            Write-Step 'Role file   : created the deepseek_flash role definition'
        }
        'refresh' {
            $roleBackup = Copy-DseBackup -Path $roleConfigPath -BackupDirectory $backupDirectory -Label 'deepseek_flash.toml'
            if ($roleBackup) {
                $backups.Add([pscustomobject]@{
                    source = $roleConfigPath
                    backup = $roleBackup
                    sha256 = (Get-DseFileSha256 -Path $roleBackup)
                })
                Write-Step "Backed up   : $roleConfigPath"
                Write-Step "              -> $roleBackup"
            }
            Write-DseTextFile -Path $roleConfigPath -Text $roleTemplate.Text -HasBom:$false | Out-Null
            Write-Step 'Role file   : refreshed the deepseek_flash role definition this product created'
        }
        'keep' {
            if ($roleFileOwnedByProduct) {
                Write-Step 'Role file   : already up to date (no change)'
            }
            else {
                Write-Step 'Role file   : an identical file already existed; kept, and it stays yours'
            }
        }
    }

    # ------------------------------------------------------------- shortcut
    $shortcutPath = $null
    $shortcutCreated = $false
    $desktopExe = $null
    $launcherPath = Join-Path $PSScriptRoot 'Start-DeepSeekNative.ps1'

    if ($CreateDesktopShortcut) {
        $desktopFolder = [System.Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktopFolder) -or -not (Test-Path -LiteralPath $desktopFolder -PathType Container)) {
            Write-Host '  WARNING: the desktop folder could not be found, so no shortcut was created.' -ForegroundColor Yellow
        }
        else {
            try {
                $desktopInfo = Get-DseDesktopExecutable -Defaults $defaults
                $desktopExe = $desktopInfo.ExecutablePath
            }
            catch {
                Write-Host "  WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '           The shortcut is still created; it will look for the app when it runs.' -ForegroundColor Yellow
            }

            $shortcutPath = Join-Path $desktopFolder 'DeepSeek Native Codex.lnk'
            if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                if (-not (Test-DseDesktopShortcut -ShortcutPath $shortcutPath -LauncherPath $launcherPath)) {
                    Fail ("A different shortcut already exists at:`n         $shortcutPath`n" +
                          '         Move or rename it, then run setup again with -CreateDesktopShortcut.')
                }
            }
            New-DseDesktopShortcut -ShortcutPath $shortcutPath -LauncherPath $launcherPath -IconPath $desktopExe | Out-Null
            $shortcutCreated = $true
            Write-Step "Shortcut    : $shortcutPath"
            Write-DseLog -Message "Desktop shortcut created: $shortcutPath" -LogPath $script:LogPath -Level 'PASS' | Out-Null
        }
    }

    # ---------------------------------------------------------------- state
    $runtimeFiles = @()
    foreach ($name in @($defaults.requiredRuntimeFiles)) {
        $runtimeFiles += [pscustomobject]@{
            name   = "$name"
            sha256 = (Get-DseFileSha256 -Path (Join-Path $resolvedRuntime $name))
        }
    }

    # The restore point is the newest config.toml backup that recorded both its
    # own hash and the hash of the file that replaced it. Both are needed, and
    # pairing them in one record is what makes -RestoreBackup safe after a
    # reinstall.
    $restorePoint = $null
    foreach ($record in $backups.ToArray()) {
        if ($record.source -eq $configPath -and $record.sha256 -and $record.replacedWithSha) {
            $restorePoint = $record
        }
    }
    if (-not $restorePoint -and $previousState -and $previousState.restorePoint) {
        # Nothing was written this run, so the previous pairing is still exact.
        if ($previousState.restorePoint.replacedWithSha -eq (Get-DseFileSha256 -Path $configPath)) {
            $restorePoint = $previousState.restorePoint
        }
    }

    $state = [ordered]@{
        schemaVersion         = 1
        product               = $defaults.product
        marker                = $defaults.marker
        installedAtUtc        = [DateTime]::UtcNow.ToString('o')
        updatedAtUtc          = [DateTime]::UtcNow.ToString('o')
        installRoot           = $resolvedInstallRoot
        codexHome             = $resolvedCodexHome
        configPath            = $configPath
        # Hash of config.toml straight after this run. Rollback compares the
        # current file against it, so it can tell "unchanged since setup" from
        # "the user edited this afterwards".
        configSha256AfterInstall = (Get-DseFileSha256 -Path $configPath)
        restorePoint          = $restorePoint
        roleName              = $defaults.roleName
        roleConfigPath        = $roleConfigPath
        # True only when this product created the role file. Rollback deletes the
        # file only in that case.
        roleFileOwnedByProduct = [bool]$roleFileOwnedByProduct
        roleFileSha256        = (Get-DseFileSha256 -Path $roleConfigPath)
        providerId            = $defaults.providerId
        model                 = $defaults.model
        reasoningEffort       = $defaults.reasoningEffort
        runtimeDirectory      = $resolvedRuntime
        runtimeIsDefaultFolder = $runtimeIsDefaultFolder
        runtimeVersion        = $runtimeVersion
        minimumVersion        = $MinimumVersion
        manifestPath          = $manifestResult.ManifestPath
        manifestVerified      = [bool]$manifestResult.Verified
        runtimeFiles          = $runtimeFiles
        managedBlockPath      = $renderedBlockPath
        managedBlockSha256    = (Get-DseFileSha256 -Path $renderedBlockPath)
        launcherPath          = $launcherPath
        shortcutPath          = $shortcutPath
        # Note: do not wrap a generic List in @( ... ) on this line. PowerShell's
        # enumerable binder throws "Argument types do not match" for a
        # List[object] holding PSCustomObjects. ToArray() is safe.
        backups               = $backups.ToArray()
    }

    if ($previousState -and $previousState.installedAtUtc) {
        $state.installedAtUtc = $previousState.installedAtUtc
    }

    $statePath = Write-DseInstallState -State ([pscustomobject]$state) -InstallRoot $resolvedInstallRoot
    Write-Step "State       : $statePath"

    Write-Head 'Setup complete'
    Write-Host ''
    Write-Host 'Next steps'
    Write-Host "  1. Start the app with the patched backend:"
    Write-Host "       powershell -File `"$launcherPath`""
    Write-Host '  2. Check everything read-only:'
    Write-Host "       powershell -File `"$(Join-Path $PSScriptRoot 'Test-DeepSeekNative.ps1')`""
    Write-Host '  3. In the app, run a small task on your normal OpenAI model and ask it to use the'
    Write-Host '     deepseek_flash subagent. Only that live run proves the routing end to end.'
    Write-Host ''
    Write-Host 'To undo everything this script changed:'
    Write-Host "       powershell -File `"$(Join-Path $PSScriptRoot 'Uninstall-DeepSeekNative.ps1')`""
    Write-Host ''

    Write-DseLog -Message 'Setup complete.' -LogPath $script:LogPath -Level 'PASS' | Out-Null
    exit 0
}
catch {
    $details = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
    if ($script:LogPath) {
        Write-DseLog -Message ("Unhandled error: " + $_.Exception.ToString()) -LogPath $script:LogPath -Level 'ERROR' | Out-Null
    }
    if ($_.ScriptStackTrace) {
        $trace = (($_.ScriptStackTrace -replace "`r?`n", ' <- ') -replace '^at ', '')
        $details = "$details`n         at $trace"
    }
    Fail $details 1
}
