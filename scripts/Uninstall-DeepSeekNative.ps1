#Requires -Version 5.1
<#
.SYNOPSIS
    Undoes everything Install-DeepSeekNative.ps1 added.

.DESCRIPTION
    This is a careful rollback, not a cleanup tool. It removes only things this
    product created:

      * the marker-delimited managed block in <CodexHome>\config.toml,
      * <CodexHome>\agents\deepseek_flash.toml, but only while it still matches
        what setup wrote,
      * the "DeepSeek Native Codex" desktop shortcut, but only if it points at
        this product's launcher.

    It never deletes folders, never deletes the runtime folder, never touches
    auth.json or environment variables, and never overwrites a config file that
    changed after install without taking a fresh copy first.

    Restoring the pre-install config file is opt-in (-RestoreBackup) because your
    config may have gained unrelated changes since then.

.PARAMETER RestoreBackup
    Replace config.toml with the backup taken by setup. The current file is first
    copied into the backup folder, so nothing is lost.

.PARAMETER RemoveBackups
    Also delete the backup files that setup recorded. Off by default.

.PARAMETER KeepDesktopShortcut
    Leave the desktop shortcut in place.

.EXAMPLE
    .\Uninstall-DeepSeekNative.ps1 -WhatIf

.EXAMPLE
    .\Uninstall-DeepSeekNative.ps1

.NOTES
    Exit codes: 0 done, 1 failed, 2 a damaged managed block was found; nothing
    was changed in config.toml and a human must look at it.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome,
    [string]$InstallRoot,
    [string]$ShortcutPath,
    [switch]$RestoreBackup,
    [switch]$RemoveBackups,
    [switch]$KeepDesktopShortcut
)

$ErrorActionPreference = 'Stop'
$script:LogPath = $null
$script:Problems = 0

. (Join-Path $PSScriptRoot 'DeepSeekNative.Common.ps1')

function Write-Step {
    param([string]$Message)
    Write-Host "  $Message"
}

function Add-Problem {
    param([string]$Message)
    $script:Problems++
    Write-Host "  PROBLEM: $Message" -ForegroundColor Red
    if ($script:LogPath) {
        Write-DseLog -Message $Message -LogPath $script:LogPath -Level 'FAIL' | Out-Null
    }
}

try {
    $defaults = Get-DseDefaults
    $resolvedCodexHome = Get-DseCodexHome -CodexHome $CodexHome
    $resolvedInstallRoot = Get-DseInstallRoot -InstallRoot $InstallRoot
    $backupDirectory = Get-DseBackupDirectory -InstallRoot $resolvedInstallRoot
    $logDirectory = Get-DseLogDirectory -InstallRoot $resolvedInstallRoot
    $script:LogPath = Join-Path $logDirectory 'uninstall.log'

    $state = Read-DseInstallState -InstallRoot $resolvedInstallRoot

    Write-Host 'Removing the native DeepSeek subagent role'
    Write-Host '-----------------------------------------'
    Write-Step "Codex home : $resolvedCodexHome"
    Write-Step "Install root: $resolvedInstallRoot"
    if (-not $state) {
        Write-Host '  NOTE: no install state file was found. Only marker-based changes can be removed.' -ForegroundColor Yellow
    }

    $configPath = Join-Path $resolvedCodexHome 'config.toml'
    $roleConfigPath = Join-Path $resolvedCodexHome ($defaults.roleConfigRelativePath -replace '/', '\')

    # Capture the state of config.toml before anything is changed. The restore
    # path uses this to tell "unchanged since setup" from "edited afterwards".
    $configShaAtStart = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configShaAtStart = Get-DseFileSha256 -Path $configPath
    }

    # ---------------------------------------------------- restore preflight
    # Decide the restore before touching anything. If -RestoreBackup was asked
    # for but cannot be done safely, stop here: changing the file first and only
    # then refusing would leave a half-applied rollback behind.
    $restoreChosen = $null
    if ($RestoreBackup) {
        $configBackups = @()
        if ($state -and $state.backups) {
            $configBackups = @($state.backups | Where-Object { $_.source -eq $configPath -and $_.backup })
        }

        if ($configBackups.Count -eq 0) {
            Add-Problem 'No recorded config.toml backup exists, so -RestoreBackup cannot be honoured. Nothing was changed.'
            exit 2
        }

        # Prefer the restore point recorded by the install that is still in
        # place: it pairs one backup with the exact content that replaced it.
        # Using "the newest backup" instead could match an older backup with a
        # newer baseline and overwrite edits made after the first install.
        if ($state -and $state.restorePoint -and $state.restorePoint.backup) {
            $restoreChosen = $state.restorePoint
        }
        else {
            $candidates = @($configBackups | Where-Object { $_.replacedWithSha })
            if ($candidates.Count -gt 0) {
                $restoreChosen = $candidates | Sort-Object { $_.backup } | Select-Object -Last 1
            }
            else {
                $restoreChosen = $configBackups | Sort-Object { $_.backup } | Select-Object -Last 1
            }
            Write-Host '  WARNING: this install has no paired restore point, so the newest backup was used.' -ForegroundColor Yellow
        }

        $restoreProblem = $null
        if (-not (Test-Path -LiteralPath $restoreChosen.backup -PathType Leaf)) {
            $restoreProblem = "The recorded backup file is missing: $($restoreChosen.backup)"
        }
        elseif ($restoreChosen.sha256 -and ((Get-DseFileSha256 -Path $restoreChosen.backup) -cne "$($restoreChosen.sha256)")) {
            $restoreProblem = "The backup file changed on disk, so it was not restored: $($restoreChosen.backup)"
        }
        elseif ($null -eq $configShaAtStart) {
            # Nothing to overwrite; the rollback can simply continue.
            $restoreChosen = $null
        }
        else {
            $expectedInstalledSha = $null
            if ($state -and $state.configSha256AfterInstall) {
                $expectedInstalledSha = "$($state.configSha256AfterInstall)"
            }
            $backupReplacedSha = $null
            if ($restoreChosen.replacedWithSha) { $backupReplacedSha = "$($restoreChosen.replacedWithSha)" }

            if (-not $expectedInstalledSha) {
                $restoreProblem = ('The install state does not record what config.toml looked like after setup, ' +
                                   'so a safe restore cannot be verified.')
            }
            elseif (-not $backupReplacedSha) {
                $restoreProblem = ('The recorded backup is not paired with the content that replaced it, ' +
                                   'so a safe restore cannot be verified.')
            }
            elseif ($backupReplacedSha -cne $expectedInstalledSha) {
                $restoreProblem = ('The recorded backup belongs to an earlier install, so restoring it would ' +
                                   'discard changes made since. The backup was kept.')
            }
            elseif ($configShaAtStart -cne $expectedInstalledSha) {
                $restoreProblem = ('config.toml was edited after setup, so restoring the backup would discard ' +
                                   'those edits. Nothing was changed and the backup was kept.')
            }
        }

        if ($restoreProblem) {
            Add-Problem ("$restoreProblem" + [Environment]::NewLine +
                         "           Rollback stopped before changing anything. The backup is here if you want it by hand:" + [Environment]::NewLine +
                         "             $($restoreChosen.backup)" + [Environment]::NewLine +
                         '           Run this script again without -RestoreBackup to remove only the managed additions.')
            exit 2
        }
    }

    # -------------------------------------------------- managed block removal
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $current = Read-DseTextFile -Path $configPath
        $block = Find-DseManagedBlock -Text $current.Text -Marker $defaults.marker

        if (-not $block.Found) {
            Write-Step 'Config      : no managed block is present (nothing to remove)'
        }
        elseif (-not $block.IsWellFormed) {
            Add-Problem ("config.toml has a damaged '$($defaults.marker)' block " +
                         "($($block.BeginCount) BEGIN and $($block.EndCount) END markers). " +
                         'Nothing was changed. Fix or delete those lines by hand, then run this again.')
        }
        else {
            $safetyBackup = Copy-DseBackup -Path $configPath -BackupDirectory $backupDirectory -Label 'config.toml.pre-uninstall'
            if ($safetyBackup) {
                Write-Step "Backed up   : $configPath"
                Write-Step "              -> $safetyBackup"
            }

            $expectedBlockPath = $null
            if ($state -and $state.managedBlockPath) { $expectedBlockPath = $state.managedBlockPath }
            $blockWasEdited = $true
            if ($expectedBlockPath -and (Test-Path -LiteralPath $expectedBlockPath -PathType Leaf)) {
                $expected = Read-DseTextFile -Path $expectedBlockPath
                $eol = Get-DseLineEnding $current.Text
                $expectedText = ($expected.Text -replace "`r`n", "`n") -replace "`n", $eol
                if (-not $expectedText.EndsWith($eol)) { $expectedText += $eol }
                $endTokenLength = ("# END $($defaults.marker)").Length
                $actual = $current.Text.Substring($block.BeginIndex, (($block.EndIndex + $endTokenLength) - $block.BeginIndex))
                $blockWasEdited = ($actual.TrimEnd() -cne $expectedText.TrimEnd())
            }
            if ($blockWasEdited) {
                Write-Host '  WARNING: the managed block does not match the file setup wrote (it was edited).' -ForegroundColor Yellow
                Write-Host '           A backup was taken first, so the previous content is still recoverable.' -ForegroundColor Yellow
            }

            if ($PSCmdlet.ShouldProcess($configPath, 'Remove the managed block')) {
                try {
                    $updated = Remove-DseManagedBlock -Text $current.Text -Marker $defaults.marker
                }
                catch {
                    Add-Problem $_.Exception.Message
                    $updated = $null
                }
                if ($null -ne $updated) {
                    Write-DseTextFile -Path $configPath -Text $updated -Encoding $current.Encoding | Out-Null
                    Write-Step 'Config      : managed block removed; all unrelated settings were left alone'
                    if ($script:LogPath) {
                        Write-DseLog -Message "Managed block removed from $configPath" -LogPath $script:LogPath -Level 'PASS' | Out-Null
                    }
                }
            }
        }
    }
    else {
        Write-Step "Config      : $configPath does not exist (nothing to remove)"
    }

    # ------------------------------------------------------- managed role file
    $roleTemplatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.deepseek_flash.toml'
    $roleFileOwned = [bool]($state -and $state.roleFileOwnedByProduct)
    if (-not (Test-Path -LiteralPath $roleConfigPath -PathType Leaf)) {
        Write-Step 'Role file   : not present (nothing to remove)'
    }
    elseif (-not $roleFileOwned) {
        # The file existed before setup, or setup never recorded creating it.
        # Either way it belongs to the user and is left alone.
        Write-Host '  NOTE: the role file was not created by this product, so it was kept:' -ForegroundColor Yellow
        Write-Host "        $roleConfigPath" -ForegroundColor Yellow
    }
    else {
        $roleText = (Read-DseTextFile -Path $roleConfigPath).Text
        $templateText = (Read-DseTextFile -Path $roleTemplatePath).Text
        if ($roleText -ceq $templateText) {
            if ($PSCmdlet.ShouldProcess($roleConfigPath, 'Remove the generated role file')) {
                Remove-Item -LiteralPath $roleConfigPath -Force
                Write-Step 'Role file   : removed (this product created it and it was unchanged)'
            }
        }
        else {
            Write-Host '  WARNING: the role file was changed after setup, so it was kept.' -ForegroundColor Yellow
            Write-Host "           Review it yourself if you no longer want it: $roleConfigPath" -ForegroundColor Yellow
        }
    }

    # ---------------------------------------------------------------- shortcut
    if (-not $KeepDesktopShortcut) {
        if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
            $desktopFolder = [System.Environment]::GetFolderPath('Desktop')
            if (-not [string]::IsNullOrWhiteSpace($desktopFolder)) {
                $ShortcutPath = Join-Path $desktopFolder 'DeepSeek Native Codex.lnk'
            }
        }
        $launcherPath = Join-Path $PSScriptRoot 'Start-DeepSeekNative.ps1'

        if ($ShortcutPath -and (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
            $result = Remove-DseDesktopShortcut -ShortcutPath $ShortcutPath -LauncherPath $launcherPath
            if ($result.Removed) {
                Write-Step "Shortcut    : removed $ShortcutPath"
            }
            else {
                Write-Host "  WARNING: the shortcut was kept: $($result.Reason)" -ForegroundColor Yellow
                Write-Host "           $ShortcutPath" -ForegroundColor Yellow
            }
        }
        else {
            Write-Step 'Shortcut    : not present (nothing to remove)'
        }
    }

    # ----------------------------------------------------------- backup restore
    if ($RestoreBackup) {
        $configBackups = @()
        if ($state -and $state.backups) {
            $configBackups = @($state.backups | Where-Object { $_.source -eq $configPath -and $_.backup })
        }

        if ($configBackups.Count -eq 0) {
            Add-Problem 'No recorded config.toml backup exists, so -RestoreBackup did nothing.'
        }
        else {
            # Prefer the restore point recorded by the install that is still in
            # place: it pairs one backup with the exact content that replaced it.
            # Falling back to "newest backup" could match an older backup with a
            # newer baseline and overwrite edits made after the first install.
            $chosen = $null
            if ($state -and $state.restorePoint -and $state.restorePoint.backup) {
                $chosen = $state.restorePoint
            }
            if (-not $chosen) {
                $candidates = @($configBackups | Where-Object { $_.replacedWithSha })
                if ($candidates.Count -gt 0) {
                    $chosen = $candidates | Sort-Object { $_.backup } | Select-Object -Last 1
                }
                else {
                    $chosen = $configBackups | Sort-Object { $_.backup } | Select-Object -Last 1
                }
                Write-Host '  WARNING: this install has no paired restore point, so the newest backup was used.' -ForegroundColor Yellow
            }
            if (-not (Test-Path -LiteralPath $chosen.backup -PathType Leaf)) {
                Add-Problem "The recorded backup file is missing: $($chosen.backup)"
            }
            else {
                $integrity = 'not recorded'
                if ($chosen.sha256) {
                    $actualHash = Get-DseFileSha256 -Path $chosen.backup
                    $integrity = 'matches the recorded hash'
                    if ($actualHash -cne $chosen.sha256) {
                        $integrity = 'DOES NOT match the recorded hash'
                    }
                }
                Write-Step "Restore     : $($chosen.backup) ($integrity)"

                # Only replace config.toml when it is byte for byte what setup
                # left behind. If the user changed it after install, their file
                # wins and the backup is kept for them to use by hand.
                $driftReason = $null
                $expectedInstalledSha = $null
                if ($state -and $state.configSha256AfterInstall) {
                    $expectedInstalledSha = "$($state.configSha256AfterInstall)"
                }
                # A backup is only the right restore source when it also recorded
                # what replaced it, and that replacement is what is on disk now.
                $backupReplacedSha = $null
                if ($chosen.replacedWithSha) { $backupReplacedSha = "$($chosen.replacedWithSha)" }
                if ($null -eq $configShaAtStart) {
                    Write-Step '              config.toml is not present, so there is nothing to overwrite'
                }
                elseif (-not $expectedInstalledSha) {
                    $driftReason = ('The install state does not record what config.toml looked like after setup, ' +
                                    'so a safe restore cannot be verified.')
                }
                elseif (-not $backupReplacedSha) {
                    $driftReason = ('The recorded backup is not paired with the content that replaced it, ' +
                                    'so a safe restore cannot be verified.')
                }
                elseif ($backupReplacedSha -cne $expectedInstalledSha) {
                    $driftReason = ('The recorded backup belongs to an earlier install, so restoring it would ' +
                                    'discard later changes. The backup was kept.')
                }
                elseif ($configShaAtStart -cne $expectedInstalledSha) {
                    $driftReason = ('config.toml was edited after setup, so it was not restored and your current ' +
                                    'file is untouched.')
                }

                if ($integrity -eq 'DOES NOT match the recorded hash') {
                    Add-Problem 'The backup file changed on disk, so it was not restored.'
                }
                elseif ($driftReason) {
                    Add-Problem ("$driftReason The setup backup is still available at: $($chosen.backup)")
                }
                else {
                    if ($PSCmdlet.ShouldProcess($configPath, "Restore from $($chosen.backup)")) {
                        $preRestore = $null
                        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                            $preRestore = Copy-DseBackup -Path $configPath -BackupDirectory $backupDirectory -Label 'config.toml.pre-restore'
                            if ($preRestore) { Write-Step "              current file saved as $preRestore" }
                        }
                        Copy-Item -LiteralPath $chosen.backup -Destination $configPath -Force
                        Write-Step '              config.toml restored from the setup backup'
                        if ($script:LogPath) {
                            Write-DseLog -Message "Restored $configPath from $($chosen.backup)" -LogPath $script:LogPath -Level 'PASS' | Out-Null
                        }
                    }
                }
            }
        }
    }

    # ---------------------------------------------------------- backup cleanup
    if ($RemoveBackups) {
        $recorded = @()
        if ($state -and $state.backups) { $recorded = @($state.backups | Where-Object { $_.backup }) }
        $resolvedBackupRoot = Resolve-DseFullPath $backupDirectory

        foreach ($entry in $recorded) {
            $candidate = Resolve-DseFullPath $entry.backup
            if (-not $candidate.StartsWith($resolvedBackupRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "  WARNING: refusing to delete a file outside the backup folder: $candidate" -ForegroundColor Yellow
                continue
            }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                if ($PSCmdlet.ShouldProcess($candidate, 'Delete backup file')) {
                    Remove-Item -LiteralPath $candidate -Force
                    Write-Step "Backups     : deleted $candidate"
                }
            }
        }
    }

    # ------------------------------------------------------------------- state
    if ($state) {
        $state | Add-Member -NotePropertyName 'uninstalledAtUtc' -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $state | Add-Member -NotePropertyName 'uninstallProblemCount' -NotePropertyValue $script:Problems -Force
        if ($PSCmdlet.ShouldProcess($resolvedInstallRoot, 'Update the install state file')) {
            Write-DseInstallState -State $state -InstallRoot $resolvedInstallRoot | Out-Null
        }
    }

    Write-Host ''
    if ($script:Problems -gt 0) {
        Write-Host "Rollback finished with $($script:Problems) problem(s). See the messages above." -ForegroundColor Red
        if ($script:LogPath) { Write-DseLog -Message "Rollback finished with $($script:Problems) problem(s)." -LogPath $script:LogPath -Level 'FAIL' | Out-Null }
        exit 2
    }

    Write-Host 'Rollback complete. The runtime folder, your logs and any backups were left in place.' -ForegroundColor Green
    Write-Host "Logs and backups live under: $resolvedInstallRoot"
    if ($script:LogPath) { Write-DseLog -Message 'Rollback complete.' -LogPath $script:LogPath -Level 'PASS' | Out-Null }
    exit 0
}
catch {
    Write-Host ''
    Write-Host "ROLLBACK FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:LogPath) {
        Write-DseLog -Message $_.Exception.Message -LogPath $script:LogPath -Level 'ERROR' | Out-Null
    }
    exit 1
}
