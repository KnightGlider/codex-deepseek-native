#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only health check for the native DeepSeek subagent setup.

.DESCRIPTION
    Checks four things without changing anything:

      1. The runtime folder and the version of codex.exe.
      2. The model configuration: the managed block in config.toml and the
         deepseek_flash role file.
      3. The codex-router service the role depends on (a small HTTP health call
         to localhost).
      4. Whether the Codex desktop app is installed and currently running.

    IMPORTANT: these checks prove the wiring, the configuration and the router
    service only. They do not prove that a subagent call is really routed to
    DeepSeek. That needs one live run in the app; the exact steps are printed at
    the end of every run and included in the report.

.PARAMETER RouterBaseUrl
    Base address of the codex-router service. Default: http://127.0.0.1:4202

.PARAMETER SkipDesktopCheck
    Do not look for the installed Codex desktop app. Useful on a build machine
    or in an automated check.

.PARAMETER ReportPath
    Optional. Write a JSON report to this path. Without it the script writes
    nothing at all.

.PARAMETER AsJson
    Print the machine-readable report to the screen instead of the readable text.

.EXAMPLE
    .\Test-DeepSeekNative.ps1

.EXAMPLE
    .\Test-DeepSeekNative.ps1 -AsJson -ReportPath "$env:USERPROFILE\.codex-deepseek-native\logs\verification.json"

.NOTES
    Exit codes: 0 all checks passed, 1 at least one check failed.
#>

[CmdletBinding()]
param(
    [string]$RuntimeDirectory,
    [string]$InstallRoot,
    [string]$CodexHome,
    [string]$RouterBaseUrl,
    [string]$RuntimeManifest,
    [switch]$SkipManifestVerification,
    [switch]$SkipRouterHealth,
    [switch]$SkipDesktopCheck,
    [switch]$SkipVersionProbe,
    [string]$ReportPath,
    [switch]$AsJson,
    [int]$RouterTimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeepSeekNative.Common.ps1')

function New-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [string]$Detail = ''
    )
    [pscustomobject]@{ Section = $Section; Name = $Name; Status = $Status; Detail = $Detail }
}

function Write-CheckLine {
    param($Check)
    $colour = switch ($Check.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  [{0}] {1}" -f $Check.Status, $Check.Name) -ForegroundColor $colour
    if ($Check.Detail) { Write-Host "         $($Check.Detail)" -ForegroundColor DarkGray }
}

$defaults = Get-DseDefaults
$checks = New-Object System.Collections.Generic.List[object]

$resolvedInstallRoot = Get-DseInstallRoot -InstallRoot $InstallRoot
$resolvedCodexHome = Get-DseCodexHome -CodexHome $CodexHome
$state = Read-DseInstallState -InstallRoot $resolvedInstallRoot

if ([string]::IsNullOrWhiteSpace($RouterBaseUrl)) {
    $RouterBaseUrl = $defaults.defaultRouterBaseUrl
}
$RouterBaseUrl = $RouterBaseUrl.TrimEnd('/')

$liveTest = @(
    'These checks verify wiring, configuration and the router service. They do not',
    'prove that a subagent call is routed to DeepSeek. Do this one live test:',
    '',
    '  1. Close the Codex desktop app, then start it with the launcher:',
    '       powershell -File .\Start-DeepSeekNative.ps1',
    '  2. Keep your normal OpenAI model selected in the app.',
    '  3. In a task, send one message that asks for both at the same time, for',
    '     example: "Answer <small question> yourself, and in parallel use the',
    '     deepseek_flash subagent to <small bounded task>."',
    '  4. Confirm the main answer comes from your model and, in the subagents',
    '     panel, a deepseek_flash child runs at the same time.',
    '  5. Send one more message to that same child to confirm follow-ups work.',
    '  6. Check the router log has a request for the DeepSeek model at the time of',
    '     the test: <InstallRoot>\logs\ is not that log, the router keeps its own.'
)

# ------------------------------------------------------------------- runtime
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
if ($runtimeCheck.IsValid) {
    $checks.Add((New-Check -Section 'Runtime' -Name 'Runtime folder contains codex.exe and all helper executables' -Status 'PASS' -Detail $resolvedRuntime))
}
else {
    $missing = @($runtimeCheck.MissingRequired) + @($runtimeCheck.MissingRecommended)
    $checks.Add((New-Check -Section 'Runtime' -Name 'Runtime folder is complete' -Status 'FAIL' -Detail ("$resolvedRuntime" + [Environment]::NewLine + '         missing: ' + ($missing -join ', '))))
}

if (-not $SkipManifestVerification) {
    try {
        $manifest = Test-DseRuntimeManifest -RuntimeDirectory $resolvedRuntime -ManifestPath $RuntimeManifest -Defaults $defaults
        if (-not $manifest.Present) {
            $checks.Add((New-Check -Section 'Runtime' -Name 'Release hash manifest' -Status 'INFO' -Detail 'none supplied; hashes are not required for a source build'))
        }
        elseif ($manifest.Verified) {
            $checks.Add((New-Check -Section 'Runtime' -Name 'Release hash manifest matches the runtime files' -Status 'PASS' -Detail $manifest.ManifestPath))
        }
        else {
            $manifestDetail = "$($manifest.ManifestPath)"
            foreach ($problem in $manifest.Problems) { $manifestDetail += [Environment]::NewLine + "         $problem" }
            foreach ($name in $manifest.MissingFiles) { $manifestDetail += [Environment]::NewLine + "         missing: $name" }
            foreach ($name in $manifest.Mismatches) { $manifestDetail += [Environment]::NewLine + "         hash mismatch: $name" }
            $checks.Add((New-Check -Section 'Runtime' -Name 'Release hash manifest matches the runtime files' -Status 'FAIL' -Detail $manifestDetail))
        }
    }
    catch {
        $checks.Add((New-Check -Section 'Runtime' -Name 'Release hash manifest could be read' -Status 'FAIL' -Detail $_.Exception.Message))
    }
}

if ($SkipVersionProbe) {
    $checks.Add((New-Check -Section 'Runtime' -Name 'codex.exe version' -Status 'INFO' -Detail 'check skipped (-SkipVersionProbe)'))
}
elseif (Test-Path -LiteralPath $codexExe -PathType Leaf) {
    try {
        $probe = Invoke-DseVersionProbe -ExePath $codexExe
        if (($probe.ExitCode -eq 0) -and $probe.Version -and (Test-DseMinimumVersion -Text $probe.Raw -MinimumVersion $defaults.minimumRuntimeVersion)) {
            $checks.Add((New-Check -Section 'Runtime' -Name "codex.exe reports version $($probe.Version)" -Status 'PASS' -Detail $probe.Raw))
        }
        elseif ($probe.ExitCode -ne 0) {
            $checks.Add((New-Check -Section 'Runtime' -Name 'codex.exe starts' -Status 'FAIL' -Detail ("exit code $($probe.ExitCode): $($probe.Raw)")))
        }
        else {
            $checks.Add((New-Check -Section 'Runtime' -Name "codex.exe reports at least version $($defaults.minimumRuntimeVersion)" -Status 'FAIL' -Detail $probe.Raw))
        }
    }
    catch {
        $checks.Add((New-Check -Section 'Runtime' -Name 'codex.exe starts' -Status 'FAIL' -Detail $_.Exception.Message))
    }
}
else {
    $checks.Add((New-Check -Section 'Runtime' -Name 'codex.exe exists' -Status 'FAIL' -Detail $codexExe))
}

# -------------------------------------------------------------------- config
$configPath = Join-Path $resolvedCodexHome 'config.toml'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $configText = (Read-DseTextFile -Path $configPath).Text
    $block = Find-DseManagedBlock -Text $configText -Marker $defaults.marker
    if ($block.IsWellFormed) {
        $checks.Add((New-Check -Section 'Config' -Name 'config.toml has exactly one complete managed block' -Status 'PASS' -Detail $configPath))
    }
    elseif ($block.Found) {
        $checks.Add((New-Check -Section 'Config' -Name 'config.toml has exactly one complete managed block' -Status 'FAIL' -Detail ("found $($block.BeginCount) BEGIN and $($block.EndCount) END markers in $configPath")))
    }
    else {
        $checks.Add((New-Check -Section 'Config' -Name 'config.toml has the managed block' -Status 'FAIL' -Detail "no '$($defaults.marker)' markers found in $configPath"))
    }

    $hasRoleTable = ($configText -match ('(?m)^\s*\[' + [regex]::Escape($defaults.roleTable) + '\]\s*$'))
    $checks.Add((New-Check -Section 'Config' -Name "config.toml registers [$($defaults.roleTable)]" -Status $(if ($hasRoleTable) { 'PASS' } else { 'FAIL' }) -Detail $configPath))

    $hasProvider = ($configText -match ('(?m)^\s*\[' + [regex]::Escape($defaults.providerTable) + '\]\s*$'))
    $checks.Add((New-Check -Section 'Config' -Name "config.toml defines [$($defaults.providerTable)]" -Status $(if ($hasProvider) { 'PASS' } else { 'WARN' }) -Detail 'the external-model provider must exist for the role to work'))

    $mainModel = [regex]::Match($configText, '(?m)^\s*model\s*=\s*"([^"]+)"')
    if ($mainModel.Success) {
        $checks.Add((New-Check -Section 'Config' -Name 'top-level model (your main selected model)' -Status 'INFO' -Detail $mainModel.Groups[1].Value))
    }
    if ($configText -match '(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)\s*=') {
        $checks.Add((New-Check -Section 'Config' -Name 'config.toml contains no obvious secret values' -Status 'WARN' -Detail 'a key-like setting was found; this script never prints its value'))
    }
}
else {
    $checks.Add((New-Check -Section 'Config' -Name 'config.toml exists' -Status 'FAIL' -Detail $configPath))
}

$rolePath = Join-Path $resolvedCodexHome ($defaults.roleConfigRelativePath -replace '/', '\')
if (Test-Path -LiteralPath $rolePath -PathType Leaf) {
    $roleText = (Read-DseTextFile -Path $rolePath).Text
    $providerOk = ($roleText -match ('(?m)^\s*model_provider\s*=\s*"' + [regex]::Escape($defaults.providerId) + '"\s*$'))
    $modelOk = ($roleText -match ('(?m)^\s*model\s*=\s*"' + [regex]::Escape($defaults.model) + '"\s*$'))
    $effortOk = ($roleText -match ('(?m)^\s*model_reasoning_effort\s*=\s*"' + [regex]::Escape($defaults.reasoningEffort) + '"\s*$'))

    $checks.Add((New-Check -Section 'Config' -Name "role file selects provider '$($defaults.providerId)'" -Status $(if ($providerOk) { 'PASS' } else { 'FAIL' }) -Detail $rolePath))
    $checks.Add((New-Check -Section 'Config' -Name "role file selects model '$($defaults.model)'" -Status $(if ($modelOk) { 'PASS' } else { 'FAIL' }) -Detail $rolePath))
    $checks.Add((New-Check -Section 'Config' -Name "role file requests reasoning effort '$($defaults.reasoningEffort)'" -Status $(if ($effortOk) { 'PASS' } else { 'FAIL' }) -Detail $rolePath))
}
else {
    $checks.Add((New-Check -Section 'Config' -Name 'role file exists' -Status 'FAIL' -Detail $rolePath))
}

# -------------------------------------------------------------------- router
if ($SkipRouterHealth) {
    $checks.Add((New-Check -Section 'Router' -Name 'codex-router health' -Status 'INFO' -Detail 'check skipped (-SkipRouterHealth)'))
}
else {
    $healthUrl = "$RouterBaseUrl$($defaults.routerHealthPath)"
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec $RouterTimeoutSeconds -UseBasicParsing -ErrorAction Stop
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $checks.Add((New-Check -Section 'Router' -Name "codex-router responds at $healthUrl" -Status 'PASS' -Detail "HTTP $($response.StatusCode)"))
        }
        else {
            $checks.Add((New-Check -Section 'Router' -Name "codex-router responds at $healthUrl" -Status 'FAIL' -Detail "HTTP $($response.StatusCode)"))
        }
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.Exception.Response) { $detail = "HTTP $([int]$_.Exception.Response.StatusCode) for $healthUrl" }
        $checks.Add((New-Check -Section 'Router' -Name "codex-router responds at $healthUrl" -Status 'FAIL' -Detail ("$detail" + [Environment]::NewLine + '         Start the codex-router service (its own start script), then run this check again.')))
    }
}

# ------------------------------------------------------------------- desktop
if ($SkipDesktopCheck) {
    $checks.Add((New-Check -Section 'Desktop' -Name 'Codex desktop app package' -Status 'INFO' -Detail 'check skipped (-SkipDesktopCheck)'))
}
else {
try {
    $desktopInfo = Get-DseDesktopExecutable -Defaults $defaults
    $checks.Add((New-Check -Section 'Desktop' -Name "Codex desktop app package found (version $($desktopInfo.PackageVersion))" -Status $(if ($desktopInfo.Exists) { 'PASS' } else { 'FAIL' }) -Detail $desktopInfo.ExecutablePath))

    $running = @(Get-DseRunningDesktopProcesses -Defaults $defaults -InstallLocation $desktopInfo.InstallLocation)
    $installedRunning = @($running | Where-Object { $_.IsInstalledApp })
    if ($installedRunning.Count -gt 0) {
        $checks.Add((New-Check -Section 'Desktop' -Name 'app is currently running' -Status 'INFO' -Detail ("process IDs: " + (($installedRunning | ForEach-Object { $_.Id }) -join ', ') + ' - close it before using the launcher')))
    }
    else {
        $checks.Add((New-Check -Section 'Desktop' -Name 'app is not running (launcher can start it)' -Status 'PASS'))
    }
}
catch {
    $checks.Add((New-Check -Section 'Desktop' -Name 'Codex desktop app package found' -Status 'FAIL' -Detail $_.Exception.Message))
}
}

# -------------------------------------------------------------- other markers
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $otherMarkers = @()
    foreach ($known in @('codex-router-managed', 'codex-router-multi-agent-v2-managed', 'codex-router-provider-managed')) {
        if ($configText) {
            $found = Find-DseManagedBlock -Text $configText -Marker $known
            if ($found.Found) { $otherMarkers += $known }
        }
    }
    if ($otherMarkers.Count -gt 0) {
        $checks.Add((New-Check -Section 'Shared' -Name 'config.toml contains upstream managed blocks' -Status 'INFO' -Detail ($otherMarkers -join ', ')))
    }
}

$stateSummary = 'not installed yet'
if ($state) {
    $stateSummary = "installed $($state.installedAtUtc), runtime $($state.runtimeDirectory)"
}
$checks.Add((New-Check -Section 'Setup' -Name 'install state file' -Status $(if ($state) { 'PASS' } else { 'WARN' }) -Detail $stateSummary))

# ---------------------------------------------------------------- reporting
$failed = @($checks | Where-Object { $_.Status -eq 'FAIL' })
$passed = @($checks | Where-Object { $_.Status -eq 'PASS' })
$warnings = @($checks | Where-Object { $_.Status -eq 'WARN' })

$report = [ordered]@{
    schemaVersion    = 1
    product          = $defaults.product
    generatedAtUtc   = [DateTime]::UtcNow.ToString('o')
    readOnly         = -not [bool]$ReportPath
    installRoot      = $resolvedInstallRoot
    codexHome        = $resolvedCodexHome
    runtimeDirectory = $resolvedRuntime
    routerBaseUrl    = $RouterBaseUrl
    summary          = [ordered]@{
        passed   = $passed.Count
        failed   = $failed.Count
        warnings = $warnings.Count
        result   = $(if ($failed.Count -eq 0) { 'pass' } else { 'fail' })
    }
    # ToArray() avoids a PowerShell binder bug with @(List[object]) here.
    checks           = $checks.ToArray()
    liveTestRequired = @{
        required    = $true
        why         = 'Configuration checks cannot prove that a subagent call is routed to DeepSeek.'
        instructions = $liveTest
    }
    disclaimer       = 'Secrets are never read or printed. Values that look like keys are reported only as present or absent.'
}

if ($ReportPath) {
    $reportDirectory = Split-Path -Parent (Resolve-DseFullPath $ReportPath)
    New-DseDirectory $reportDirectory | Out-Null
    $json = $report | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Resolve-DseFullPath $ReportPath), $json, (New-Object System.Text.UTF8Encoding($false)))
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 10
}
else {
    Write-Host 'Native DeepSeek verification (read-only)'
    Write-Host '---------------------------------------'
    $sections = $checks | Select-Object -ExpandProperty Section -Unique
    foreach ($section in $sections) {
        Write-Host ''
        Write-Host $section
        foreach ($check in ($checks | Where-Object { $_.Section -eq $section })) {
            Write-CheckLine $check
        }
    }
    Write-Host ''
    Write-Host ("Result: {0} passed, {1} failed, {2} warning(s)" -f $passed.Count, $failed.Count, $warnings.Count) -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
    Write-Host ''
    foreach ($line in $liveTest) { Write-Host $line }
    if ($ReportPath) {
        Write-Host ''
        Write-Host "Report written to: $ReportPath"
    }
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
