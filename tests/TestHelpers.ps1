#Requires -Version 5.1
<#
    Small self-contained test harness for the codex-deepseek-native scripts.
    No Pester version is required, so this runs on a stock Windows PowerShell 5.1
    or PowerShell 7 install.

    Everything here works inside a private temporary sandbox. The real user
    profile, config.toml, desktop and installed runtime are never touched.
#>

$ErrorActionPreference = 'Stop'

$script:TestRegistry = New-Object System.Collections.Generic.List[object]
$script:CurrentGroup = 'General'

function Describe-Group {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:CurrentGroup = $Name
}

function Register-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )
    $script:TestRegistry.Add([pscustomobject]@{
        Group  = $script:CurrentGroup
        Name   = $Name
        Script = $Script
    })
}

function New-SkipException {
    param([string]$Reason)
    return (New-Object System.InvalidOperationException("SKIP: $Reason"))
}

function Assert-True {
    param([Parameter(Mandatory = $true)]$Condition, [string]$Because = '')
    if (-not $Condition) { throw "Expected true. $Because" }
}

function Assert-False {
    param([Parameter(Mandatory = $true)]$Condition, [string]$Because = '')
    if ($Condition) { throw "Expected false. $Because" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    # -cne: assertions must be exact. PowerShell's default -ne is case
    # insensitive, which would hide real differences in these tests.
    if ($Expected -cne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-NotEqual {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ceq $Actual) { throw "Expected a value different from '$Expected'. $Because" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -notmatch $Pattern) {
        throw "Text did not match /$Pattern/. $Because`nActual text: $Text"
    }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -match $Pattern) {
        throw "Text unexpectedly matched /$Pattern/. $Because`nActual text: $Text"
    }
}

function Assert-Contains {
    param($Collection, $Item, [string]$Because = '')
    if (@($Collection) -notcontains $Item) {
        throw "Collection did not contain '$Item'. $Because`nActual: $(@($Collection) -join ', ')"
    }
}

function Assert-FileExists {
    param([string]$Path, [string]$Because = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected file to exist: $Path. $Because"
    }
}

function Assert-FileMissing {
    param([string]$Path, [string]$Because = '')
    if (Test-Path -LiteralPath $Path) {
        throw "Expected no file at: $Path. $Because"
    }
}

function Assert-FileContains {
    param([string]$Path, [string]$Text, [string]$Because = '')
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notlike "*$Text*") {
        throw "File $Path does not contain '$Text'. $Because"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [string]$Pattern = ''
    )
    $threw = $false
    $message = ''
    try { & $Script } catch { $threw = $true; $message = $_.Exception.Message }
    if (-not $threw) { throw 'Expected the script block to throw, but it did not.' }
    if ($Pattern -and ($message -notmatch $Pattern)) {
        throw "The thrown message did not match /$Pattern/. Message: $message"
    }
}

function New-TestSandbox {
    param([string]$SandboxRoot)

    if ([string]::IsNullOrWhiteSpace($SandboxRoot)) {
        $SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dse-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    }
    $SandboxRoot = [System.IO.Path]::GetFullPath($SandboxRoot)
    foreach ($child in @('CodexHome', 'InstallRoot', 'Runtime', 'Protected', 'work')) {
        New-Item -ItemType Directory -Path (Join-Path $SandboxRoot $child) -Force | Out-Null
    }

    # A runtime folder that satisfies the file layout checks without needing a
    # real executable, plus a release manifest with correct hashes.
    $runtime = Join-Path $SandboxRoot 'Runtime'
    $files = @('codex.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe', 'codex-code-mode-host.exe')
    $manifestFiles = [ordered]@{}
    foreach ($name in $files) {
        $path = Join-Path $runtime $name
        [System.IO.File]::WriteAllText($path, "placeholder for $name", (New-Object System.Text.UTF8Encoding($false)))
        $manifestFiles[$name] = Get-DseFileSha256 -Path $path
    }
    $manifest = [ordered]@{ version = '0.153.4'; files = $manifestFiles }
    [System.IO.File]::WriteAllText(
        (Join-Path $runtime 'runtime-manifest.json'),
        ($manifest | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($false)))

    # A canary file in a folder that no script under test should ever write to.
    Set-Content -LiteralPath (Join-Path $SandboxRoot 'Protected\canary.txt') -Value 'do not touch' -Encoding UTF8

    return $SandboxRoot
}

function Get-DirectorySnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.FullName)|$($_.Length)" } | Sort-Object)
}

function Get-TestPowerShellPath {
    return (Get-Process -Id $PID).Path
}

function ConvertTo-CommandLineArgument {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append('\' * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append('\' * ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 180
    )

    $argumentParts = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    foreach ($argument in $Arguments) { $argumentParts += $argument }

    $commandLine = ($argumentParts | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Get-TestPowerShellPath
    $startInfo.Arguments = $commandLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Split-Path -Parent $ScriptPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.Close()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "The child script did not finish within $TimeoutSeconds seconds: $ScriptPath"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        All      = ($stdout + "`n" + $stderr)
    }
}

function Invoke-TestSuite {
    param(
        [string]$Filter = '',
        [switch]$Quiet
    )

    $results = New-Object System.Collections.Generic.List[object]
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $group = $null

    foreach ($test in $script:TestRegistry) {
        if ($Filter -and ($test.Name -notlike "*$Filter*") -and ($test.Group -notlike "*$Filter*")) { continue }

        if ($group -ne $test.Group) {
            $group = $test.Group
            if (-not $Quiet) { Write-Host ''; Write-Host $group -ForegroundColor White }
        }

        $testWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'PASS'
        $message = ''
        try {
            & $test.Script
        }
        catch {
            $message = $_.Exception.Message
            if ($message -like 'SKIP:*') {
                $status = 'SKIP'
                $message = $message.Substring(5).Trim()
            }
            else {
                $status = 'FAIL'
            }
        }
        $testWatch.Stop()

        if (-not $Quiet) {
            $colour = switch ($status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
            Write-Host ("  [{0}] {1} ({2:n0} ms)" -f $status, $test.Name, $testWatch.Elapsed.TotalMilliseconds) -ForegroundColor $colour
            if ($message) {
                $messageColour = 'DarkGray'
                if ($status -eq 'FAIL') { $messageColour = 'Red' }
                Write-Host "         $message" -ForegroundColor $messageColour
            }
        }

        $results.Add([pscustomobject]@{
            Group    = $test.Group
            Name     = $test.Name
            Status   = $status
            Message  = $message
            Duration = [math]::Round($testWatch.Elapsed.TotalMilliseconds)
        })
    }

    $stopwatch.Stop()
    $failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
    $passed = @($results | Where-Object { $_.Status -eq 'PASS' })
    $skipped = @($results | Where-Object { $_.Status -eq 'SKIP' })

    [pscustomobject]@{
        Results  = $results
        Passed   = $passed.Count
        Failed   = $failed.Count
        Skipped  = $skipped.Count
        Duration = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        Success  = ($failed.Count -eq 0)
    }
}

function Remove-TestSandbox {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxRoot,
        [switch]$Keep
    )

    if ($Keep) {
        Write-Host "  sandbox kept: $SandboxRoot" -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path -LiteralPath $SandboxRoot)) { return }

    # Only ever delete our own sandbox: it must live under the temp folder and
    # carry our prefix.
    $resolved = [System.IO.Path]::GetFullPath($SandboxRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $leaf = Split-Path -Leaf $resolved
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('dse-selftest-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete a folder that is not a test sandbox: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
