#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the installed Codex desktop app with the patched native DeepSeek backend.

.DESCRIPTION
    The Codex desktop app finds its backend through the CODEX_CLI_PATH environment
    variable. This launcher:

      * locates the installed OpenAI.Codex app package and its app\ChatGPT.exe,
      * refuses to start while the app is already running (nothing is ever killed),
      * starts app\ChatGPT.exe as a child process with CODEX_CLI_PATH set for that
        child process only. Your Windows environment variables are not touched.

    Your saved OpenAI model selection is not changed. The only thing added to the
    app is a subagent role, so the main task keeps the model you picked.

.PARAMETER RuntimeDirectory
    Folder with the patched codex.exe. Defaults to the location recorded by
    Install-DeepSeekNative.ps1, otherwise <InstallRoot>\runtime.

.PARAMETER CheckOnly
    Read-only. Reports every check as PASS or FAIL and exits without starting
    anything. Nothing is written unless -LogPath is supplied.

.PARAMETER DesktopExePath
    Override for the app executable. Intended for tests and unusual installs.

.PARAMETER AllowRunningDesktop
    Launch anyway while the app is running. Not recommended: the running window
    keeps the backend it started with, so the two can disagree.

.PARAMETER SkipVersionProbe
    Do not run codex.exe --version. Useful for a read-only check on a machine
    where the runtime must not be executed.

.EXAMPLE
    .\Start-DeepSeekNative.ps1 -CheckOnly

.EXAMPLE
    .\Start-DeepSeekNative.ps1

.NOTES
    Exit codes: 0 started or passed the check, 1 failed, 3 the app is already
    running and -AllowRunningDesktop was not given.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RuntimeDirectory,
    [string]$InstallRoot,
    [string]$CodexHome,
    [string]$DesktopExePath,
    [string]$LogPath,
    [switch]$CheckOnly,
    [switch]$NoPause,
    [switch]$AllowRunningDesktop,
    [switch]$SkipVersionProbe,
    [switch]$WaitForExit,
    [int]$ExitWatchSeconds = 5
)

$ErrorActionPreference = 'Stop'
$script:LogPath = $LogPath
$script:Summary = New-Object System.Collections.Generic.List[object]

. (Join-Path $PSScriptRoot 'DeepSeekNative.Common.ps1')

function Add-CheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Detail = ''
    )
    $script:Summary.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
    $colour = 'Gray'
    if (-not $Passed) { $colour = 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
    if ($script:LogPath) {
        Write-DseLog -Message "$(if ($Passed) { 'PASS' } else { 'FAIL' }) $Name $Detail" -LogPath $script:LogPath -Level $(if ($Passed) { 'PASS' } else { 'FAIL' }) | Out-Null
    }
}

function Stop-WithFailure {
    param([string]$Message, [int]$Code = 1)

    Write-Host ''
    Write-Host "LAUNCH FAILED: $Message" -ForegroundColor Red
    if ($script:LogPath) {
        Write-DseLog -Message $Message -LogPath $script:LogPath -Level 'ERROR' | Out-Null
    }
    if (-not $CheckOnly -and -not $NoPause) {
        try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
    }
    exit $Code
}

try {
    $defaults = Get-DseDefaults
    $resolvedInstallRoot = Get-DseInstallRoot -InstallRoot $InstallRoot
    $resolvedCodexHome = Get-DseCodexHome -CodexHome $CodexHome
    $state = Read-DseInstallState -InstallRoot $resolvedInstallRoot

    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        # -CheckOnly must stay read-only, so only a real launch gets a default log
        # file. Pass -LogPath explicitly if a check run should be logged.
        if (-not $CheckOnly) {
            $script:LogPath = Join-Path (Get-DseLogDirectory -InstallRoot $resolvedInstallRoot) 'launch.log'
        }
    }
    elseif (-not (Test-Path -LiteralPath (Split-Path -Parent $script:LogPath) -PathType Container)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:LogPath) -Force | Out-Null
    }

    Write-Host 'Native DeepSeek launcher'
    Write-Host '------------------------'

    # ---------------------------------------------------------------- runtime
    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        if ($state -and -not [string]::IsNullOrWhiteSpace($state.runtimeDirectory)) {
            $RuntimeDirectory = $state.runtimeDirectory
        }
        else {
            $RuntimeDirectory = Get-DseSubdirectory -InstallRoot $resolvedInstallRoot -Name 'runtime'
        }
    }
    $resolvedRuntime = Get-DseRuntimeDirectory -RuntimeDirectory $RuntimeDirectory -InstallRoot $resolvedInstallRoot
    $codexExe = Join-Path $resolvedRuntime 'codex.exe'

    $runtimeCheck = Test-DseRuntimeDirectory -RuntimeDirectory $resolvedRuntime -Defaults $defaults
    if (-not $runtimeCheck.IsValid) {
        $missing = @($runtimeCheck.MissingRequired) + @($runtimeCheck.MissingRecommended)
        Stop-WithFailure ("The runtime folder is not ready: $resolvedRuntime`n" +
                          "         missing: $($missing -join ', ')`n" +
                          '         Run Install-DeepSeekNative.ps1 -RuntimeDirectory <folder> first.') 1
    }
    Add-CheckResult -Name 'Runtime folder has codex.exe and all helper executables' -Passed $true -Detail $resolvedRuntime

    if ($SkipVersionProbe) {
        Add-CheckResult -Name 'codex.exe responds to --version' -Passed $true -Detail 'check skipped (-SkipVersionProbe)'
    }
    else {
        try {
            $probe = Invoke-DseVersionProbe -ExePath $codexExe
            $probeOk = ($probe.ExitCode -eq 0) -and ($null -ne $probe.Version)
            Add-CheckResult -Name 'codex.exe responds to --version' -Passed $probeOk -Detail $probe.Raw
        }
        catch {
            Add-CheckResult -Name 'codex.exe responds to --version' -Passed $false -Detail $_.Exception.Message
        }
    }

    # ------------------------------------------------------------- role config
    $configPath = Join-Path $resolvedCodexHome 'config.toml'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configText = (Read-DseTextFile -Path $configPath).Text
        $block = Find-DseManagedBlock -Text $configText -Marker $defaults.marker
        $hasRole = ($block.IsWellFormed) -and ($configText -match [regex]::Escape("[$($defaults.roleTable)]"))
        Add-CheckResult -Name "config.toml registers the $($defaults.roleName) subagent role" -Passed $hasRole -Detail $configPath
    }
    else {
        Add-CheckResult -Name "config.toml registers the $($defaults.roleName) subagent role" -Passed $false -Detail "not found: $configPath"
    }

    $rolePath = Join-Path $resolvedCodexHome ($defaults.roleConfigRelativePath -replace '/', '\')
    $roleOk = $false
    if (Test-Path -LiteralPath $rolePath -PathType Leaf) {
        $roleText = (Read-DseTextFile -Path $rolePath).Text
        $roleOk = ($roleText -match [regex]::Escape("model_provider = `"$($defaults.providerId)`"")) -and
                  ($roleText -match [regex]::Escape("model = `"$($defaults.model)`""))
    }
    Add-CheckResult -Name 'role file points at the codex-router provider' -Passed $roleOk -Detail $rolePath

    # --------------------------------------------------------- desktop package
    if (-not [string]::IsNullOrWhiteSpace($DesktopExePath)) {
        $desktopExe = Resolve-DseFullPath $DesktopExePath
        $desktopInfo = [pscustomobject]@{
            PackageName    = '(override)'
            PackageVersion = $null
            InstallLocation = Split-Path -Parent (Split-Path -Parent $desktopExe)
            ExecutablePath = $desktopExe
            Exists         = (Test-Path -LiteralPath $desktopExe -PathType Leaf)
        }
    }
    else {
        try {
            $desktopInfo = Get-DseDesktopExecutable -Defaults $defaults
        }
        catch {
            Stop-WithFailure $_.Exception.Message 1
        }
    }
    Add-CheckResult -Name 'Codex desktop app executable found' -Passed $desktopInfo.Exists -Detail $desktopInfo.ExecutablePath

    # -------------------------------------------------------- running process
    $running = @(Get-DseRunningDesktopProcesses -Defaults $defaults -InstallLocation $desktopInfo.InstallLocation)
    $runningInstalled = @($running | Where-Object { $_.IsInstalledApp })
    $runningUnknown = @($running | Where-Object { -not $_.PathKnown })
    $isRunning = ($running.Count -gt 0)

    if ($runningInstalled.Count -gt 0) {
        Add-CheckResult -Name 'Codex desktop app is not already running' -Passed $false -Detail ("running process IDs: " + (($runningInstalled | ForEach-Object { $_.Id }) -join ', '))
    }
    elseif ($runningUnknown.Count -gt 0) {
        Add-CheckResult -Name 'Codex desktop app is not already running' -Passed $false -Detail ("a process named '$($defaults.desktopProcessName)' is running but its file path could not be read (IDs: " + (($runningUnknown | ForEach-Object { $_.Id }) -join ', ') + '). Close it if it is Codex.')
    }
    else {
        Add-CheckResult -Name 'Codex desktop app is not already running' -Passed $true
    }

    if ($CheckOnly) {
        Write-Host ''
        $failed = @($script:Summary | Where-Object { -not $_.Passed })
        if ($failed.Count -gt 0) {
            Write-Host "Check finished: $($failed.Count) problem(s) found. Nothing was started." -ForegroundColor Yellow
            exit 1
        }
        Write-Host 'Check finished: everything looks ready. Nothing was started.' -ForegroundColor Green
        exit 0
    }

    # A normal launch must also stop when an earlier check failed. Starting the
    # app with a broken runtime or config would only look like a working setup.
    $failedBeforeLaunch = @($script:Summary | Where-Object { -not $_.Passed } | Where-Object { $_.Name -ne 'Codex desktop app is not already running' })
    if ($failedBeforeLaunch.Count -gt 0) {
        $names = ($failedBeforeLaunch | ForEach-Object { $_.Name }) -join '; '
        Stop-WithFailure ("These checks failed, so the app was not started: $names`n" +
                          '         Fix the problems above, or run with -CheckOnly to see the full list.') 1
    }

    if ($isRunning -and -not $AllowRunningDesktop) {
        Stop-WithFailure ('The Codex desktop app is already running. Close it normally first, then run this launcher again. ' +
                          'No process was stopped. (Use -AllowRunningDesktop to override, but the running window will keep its old backend.)') 3
    }

    if (-not $PSCmdlet.ShouldProcess($desktopInfo.ExecutablePath, 'Start the Codex desktop app with CODEX_CLI_PATH set for the child process')) {
        Write-Host ''
        Write-Host 'WhatIf: the app was not started.'
        exit 0
    }

    # Pass the override directly to the new app process, without shell activation
    # or changing the user's saved environment.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $desktopInfo.ExecutablePath
    $startInfo.WorkingDirectory = Split-Path -Parent $desktopInfo.ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_CLI_PATH'] = $codexExe
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        # An explicit configuration folder must reach the app we just checked.
        # This changes only the child's environment, not the user's settings.
        $startInfo.EnvironmentVariables['CODEX_HOME'] = $resolvedCodexHome
    }

    if ($script:LogPath) {
        Write-DseLog -Message "Launching desktop=$($desktopInfo.ExecutablePath) backend=$codexExe" -LogPath $script:LogPath | Out-Null
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    Write-Host ''
    Write-Host "Started the Codex desktop app (PID $($process.Id)) with the native backend:" -ForegroundColor Green
    Write-Host "  backend : $codexExe"
    Write-Host "  app     : $($desktopInfo.ExecutablePath)"
    if ($desktopInfo.PackageVersion) { Write-Host "  version : $($desktopInfo.PackageVersion)" }
    if ($script:LogPath) { Write-Host "  log     : $script:LogPath" }
    Write-DseLog -Message "Desktop launch returned PID=$($process.Id)" -LogPath $script:LogPath | Out-Null

    if (-not $WaitForExit -and $ExitWatchSeconds -gt 0) {
        # Catch an immediate failure (for example a missing dependency) instead of
        # reporting success for a process that died right away.
        if ($process.WaitForExit($ExitWatchSeconds * 1000)) {
            Write-Host ''
            Write-Host "The app exited again immediately with code $($process.ExitCode)." -ForegroundColor Red
            Write-DseLog -Message "Desktop process exited immediately with code $($process.ExitCode)" -LogPath $script:LogPath -Level 'ERROR' | Out-Null
            if (-not $NoPause) {
                try { Read-Host 'Press Enter to close this window' | Out-Null } catch { }
            }
            exit 1
        }
    }
    elseif ($WaitForExit) {
        Write-Host 'Waiting for the app to close ...'
        $process.WaitForExit()
        Write-Host "The app closed with code $($process.ExitCode)."
    }

    Write-Host ''
    Write-Host 'You can close this window. In the app, keep your normal model selected and'
    Write-Host 'ask the main task to delegate work to the deepseek_flash subagent.'
    exit 0
}
catch {
    Stop-WithFailure $_.Exception.Message 1
}
