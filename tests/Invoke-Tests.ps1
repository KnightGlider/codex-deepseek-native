#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the codex-deepseek-native test suite.

.DESCRIPTION
    Every test runs inside a private folder under the user's temp directory. The
    real %USERPROFILE%\.codex, the installed runtime, the desktop and the Codex
    desktop app are never modified. The only sub-processes started are extra
    PowerShell instances running the project's own scripts against temp folders.

.PARAMETER Filter
    Only run tests whose group or name contains this text.

.PARAMETER SandboxRoot
    Use a specific sandbox folder instead of a fresh temp folder.

.PARAMETER KeepSandbox
    Do not delete the sandbox folder afterwards (useful when a test fails).

.PARAMETER RealRuntimeDirectory
    Opt-in real runtime folder for one smoke test that asks codex.exe for its
    version. The environment variable DEEPSEEK_NATIVE_TEST_RUNTIME is used when
    this parameter is not given. There is no fallback, so a normal run never
    inspects or executes anything outside the temp sandbox.

.EXAMPLE
    .\Invoke-Tests.ps1

.EXAMPLE
    .\Invoke-Tests.ps1 -Filter Uninstall -KeepSandbox

.NOTES
    Exit codes: 0 all tests passed (skips are allowed), 1 at least one failed.
#>

[CmdletBinding()]
param(
    [string]$Filter = '',
    [string]$SandboxRoot,
    [switch]$KeepSandbox,
    [switch]$Quiet,
    [string]$RealRuntimeDirectory,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptsDirectory = Join-Path $script:RepositoryRoot 'scripts'
$script:InstallScript = Join-Path $script:ScriptsDirectory 'Install-DeepSeekNative.ps1'
$script:StartScript = Join-Path $script:ScriptsDirectory 'Start-DeepSeekNative.ps1'
$script:TestScript = Join-Path $script:ScriptsDirectory 'Test-DeepSeekNative.ps1'
$script:UninstallScript = Join-Path $script:ScriptsDirectory 'Uninstall-DeepSeekNative.ps1'
$script:CommonScript = Join-Path $script:ScriptsDirectory 'DeepSeekNative.Common.ps1'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. $script:CommonScript

$script:Defaults = Get-DseDefaults
$script:CreatedSandboxes = New-Object System.Collections.Generic.List[string]

function New-TestEnvironment {
    $parent = $SandboxRoot
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = [System.IO.Path]::GetTempPath() }
    $root = Join-Path $parent ('dse-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    [void](New-TestSandbox -SandboxRoot $root)
    $script:CreatedSandboxes.Add($root)
    return [pscustomobject]@{
        Root        = $root
        CodexHome   = Join-Path $root 'CodexHome'
        InstallRoot = Join-Path $root 'InstallRoot'
        Runtime     = Join-Path $root 'Runtime'
        Protected   = Join-Path $root 'Protected'
        Work        = Join-Path $root 'work'
        ConfigPath  = Join-Path $root 'CodexHome\config.toml'
        RolePath    = Join-Path $root 'CodexHome\agents\deepseek_flash.toml'
        StatePath   = Join-Path $root 'InstallRoot\state\install-state.json'
    }
}

function Get-ScopeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root, [string[]]$Exclude = @())

    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $skip = $false
        foreach ($prefix in $Exclude) {
            if ($item.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if (-not $skip) { $lines.Add("$($item.FullName)|$($item.Length)") }
    }
    return ($lines | Sort-Object)
}

function Get-InstallArguments {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [string[]]$Extra = @(),
        [switch]$WithVersionProbe
    )

    $arguments = @(
        '-RuntimeDirectory', $Environment.Runtime,
        '-CodexHome', $Environment.CodexHome,
        '-InstallRoot', $Environment.InstallRoot
    )
    if (-not $WithVersionProbe) { $arguments += '-SkipVersionProbe' }
    $arguments += $Extra
    return $arguments
}

function Invoke-InstallScript {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [string[]]$Extra = @(),
        [switch]$WithVersionProbe
    )
    return Invoke-ChildScript -ScriptPath $script:InstallScript -Arguments (Get-InstallArguments -Environment $Environment -Extra $Extra -WithVersionProbe:$WithVersionProbe)
}

function Invoke-UninstallScript {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [string[]]$Extra = @(),
        [switch]$AllowShortcutRemoval
    )
    $arguments = @(
        '-CodexHome', $Environment.CodexHome,
        '-InstallRoot', $Environment.InstallRoot
    )
    # Unless a test explicitly wants the shortcut logic, keep the real desktop
    # out of the picture completely.
    if (-not $AllowShortcutRemoval) { $arguments += '-KeepDesktopShortcut' }
    $arguments += $Extra
    return Invoke-ChildScript -ScriptPath $script:UninstallScript -Arguments $arguments
}

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ProjectScriptFiles {
    return @(Get-ChildItem -LiteralPath $script:ScriptsDirectory -Filter *.ps1 -File)
}

# --------------------------------------------------------------- static checks

Describe-Group 'Static checks'

Register-Test 'Every PowerShell file in scripts and tests parses' {
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($directory in @($script:ScriptsDirectory, $PSScriptRoot)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter *.ps1 -File)) {
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
            foreach ($parseError in @($parseErrors)) {
                $failures.Add("$($file.Name):$($parseError.Extent.StartLineNumber) $($parseError.Message)")
            }
        }
    }
    Assert-Equal 0 $failures.Count ("Parser errors: " + ($failures -join '; '))
}

Register-Test 'Every script requires PowerShell 5.1 or newer' {
    foreach ($script in @($script:InstallScript, $script:StartScript, $script:TestScript, $script:UninstallScript, $script:CommonScript)) {
        $head = (Get-Content -LiteralPath $script -TotalCount 6) -join "`n"
        Assert-Match $head '#Requires -Version 5\.1' "Missing the version requirement in $(Split-Path -Leaf $script)"
    }
}

Register-Test 'The launcher only sets CODEX_CLI_PATH for the child process' {
    $launcher = Read-Text $script:StartScript
    Assert-Match $launcher 'UseShellExecute\s*=\s*\$false'
    Assert-Match $launcher 'EnvironmentVariables\[.CODEX_CLI_PATH.\]\s*='
    Assert-NotMatch $launcher 'SetEnvironmentVariable'
}

Register-Test 'No script mutates the user environment' {
    foreach ($file in Get-ProjectScriptFiles) {
        $text = Read-Text $file.FullName
        Assert-NotMatch $text 'SetEnvironmentVariable' "Environment mutation found in $($file.Name)"
        Assert-NotMatch $text '(?m)^\s*setx\s' "setx usage found in $($file.Name)"
        Assert-NotMatch $text '\$env:CODEX_HOME\s*=' "CODEX_HOME assignment found in $($file.Name)"
        Assert-NotMatch $text '\$env:USERPROFILE\s*=' "USERPROFILE assignment found in $($file.Name)"
    }
}

Register-Test 'No script deletes anything recursively' {
    foreach ($file in Get-ProjectScriptFiles) {
        $text = Read-Text $file.FullName
        Assert-NotMatch $text '-Recurse' "Recursive deletion found in $($file.Name)"
    }
}

Register-Test 'No script prompts for a secret' {
    foreach ($file in Get-ProjectScriptFiles) {
        $text = Read-Text $file.FullName
        Assert-NotMatch $text 'Read-Host[^\r\n]*(?i)(api[_-]?key|token|secret|password)' "Secret prompt found in $($file.Name)"
    }
}

Register-Test 'The defaults file has every required property and value' {
    $defaults = Get-DseDefaults
    Assert-Equal 'deepseek_flash' $defaults.roleName
    Assert-Equal 'codex-router' $defaults.providerId
    Assert-Equal 'deepseek/deepseek-v4-flash' $defaults.model
    Assert-Equal 'high' $defaults.reasoningEffort
    Assert-Equal '0.153.4' $defaults.minimumRuntimeVersion
    Assert-Equal 4 @($defaults.requiredRuntimeFiles).Count
    Assert-Contains $defaults.requiredRuntimeFiles 'codex.exe'
    Assert-Contains $defaults.requiredRuntimeFiles 'codex-command-runner.exe'
    Assert-Contains $defaults.requiredRuntimeFiles 'codex-windows-sandbox-setup.exe'
    Assert-Contains $defaults.requiredRuntimeFiles 'codex-code-mode-host.exe'
}

Register-Test 'A defaults file with a missing property is rejected' {
    $path = Join-Path $env:TEMP ('dse-bad-defaults-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-Utf8NoBom -Path $path -Text '{ "product": "x" }'
        Assert-Throws { Get-DseDefaults -DefaultsPath $path } 'missing the required property'
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'config/interface.json matches the real script parameters' {
    $interfacePath = Join-Path $script:RepositoryRoot 'config\interface.json'
    $interface = Read-Text $interfacePath | ConvertFrom-Json

    Assert-True (@($interface.scripts).Count -ge 4) 'The interface must describe every script'

    foreach ($entry in @($interface.scripts)) {
        $scriptPath = Join-Path $script:RepositoryRoot ($entry.path -replace '/', '\')
        Assert-FileExists $scriptPath "interface.json points at a missing file: $($entry.path)"

        if (-not $entry.keyParameters) { continue }
        $text = Read-Text $scriptPath

        # Read the real parameter list from the script's syntax tree, so helper
        # functions inside the file cannot be mistaken for script parameters.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count "Parser errors in $($entry.path)"

        $declared = @()
        if ($ast.ParamBlock) {
            $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        if ($declared.Count -eq 0) { continue }

        foreach ($parameter in @($entry.keyParameters)) {
            $name = $parameter.TrimStart('-')
            # WhatIf and friends come from SupportsShouldProcess, not a real param.
            if ($name -eq 'WhatIf') { continue }
            Assert-Contains $declared $name "interface.json lists '$parameter' but $(Split-Path -Leaf $scriptPath) does not declare it"
        }

        $documented = @($entry.keyParameters | ForEach-Object { $_.TrimStart('-') })
        $undocumented = @($declared | Where-Object { $documented -notcontains $_ })
        Assert-Equal 0 $undocumented.Count ("$(Split-Path -Leaf $scriptPath) declares parameters missing from interface.json: " + ($undocumented -join ', '))
    }
}

Register-Test 'No shipped file contains a personal user path or a built artifact name' {
    $roots = @($script:ScriptsDirectory, (Join-Path $script:RepositoryRoot 'config'), $PSScriptRoot)
    # Patterns are assembled at run time from parts, so this guard file does not
    # match itself and no personal path literal is stored in the repository.
    $thisUser = $env:USERNAME
    $forbidden = @(
        @{ Pattern = ('(?i)' + [regex]::Escape('C:\Users\' + $thisUser)); Why = 'this machine user profile path' },
        @{ Pattern = ('(?i)' + [regex]::Escape('C:\Users\' + $thisUser + '\AppData\Local\Packages\')); Why = 'this machine packaged-app path' },
        @{ Pattern = ('(?i)' + [regex]::Escape('AppData\Local\' + 'Temp\' + 'dse-selftest')); Why = 'a test sandbox path' },
        @{ Pattern = ('(?i)' + [regex]::Escape('candidate' + '-runtime')); Why = 'a build output folder name' },
        @{ Pattern = ('(?i)' + [regex]::Escape('codex-deepseek' + '-build')); Why = 'a local build folder name' }
    )
    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
            if ($file.Extension -in @('.png', '.jpg', '.zip', '.exe', '.dll')) { continue }
            $text = Read-Text $file.FullName
            foreach ($rule in $forbidden) {
                if ($text -match $rule.Pattern) {
                    $problems.Add("$($file.FullName) contains $($rule.Why)")
                }
            }
        }
    }

    Assert-Equal 0 $problems.Count ($problems -join '; ')
}

# --------------------------------------------------------- defaults and paths

Describe-Group 'Defaults and paths'

Register-Test 'The default install root is a normal folder under the user profile' {
    $root = Get-DseInstallRoot
    $profile = Get-DseUserProfile
    Assert-True ($root.StartsWith($profile, [System.StringComparison]::OrdinalIgnoreCase)) "Install root was '$root'"
    Assert-Equal '.codex-deepseek-native' (Split-Path -Leaf $root)
    Assert-NotMatch $root '(?i)\\AppData\\' 'The default install root must not live under AppData'
}

Register-Test 'The default runtime folder sits inside the install root' {
    $root = Get-DseInstallRoot
    $runtime = Get-DseRuntimeDirectory -InstallRoot $root
    Assert-Equal (Join-Path $root 'runtime') $runtime
    Assert-Equal (Join-Path $root 'state') (Get-DseStateDirectory -InstallRoot $root)
    Assert-Equal (Join-Path $root 'logs') (Get-DseLogDirectory -InstallRoot $root)
    Assert-Equal (Join-Path $root 'backups') (Get-DseBackupDirectory -InstallRoot $root)
}

Register-Test 'Codex home resolution prefers the parameter, then CODEX_HOME, then the user profile' {
    $temporary = Join-Path $env:TEMP ('dse-home-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $original = $env:CODEX_HOME
    try {
        $explicit = Join-Path $temporary 'explicit'
        Assert-Equal $explicit (Get-DseCodexHome -CodexHome $explicit)

        $env:CODEX_HOME = $temporary
        Assert-Equal $temporary (Get-DseCodexHome)

        $env:CODEX_HOME = $null
        Assert-Equal (Join-Path (Get-DseUserProfile) '.codex') (Get-DseCodexHome)
    }
    finally {
        $env:CODEX_HOME = $original
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Virtualized package paths are recognised and normal paths are not' {
    Assert-True (Test-DseVirtualizedPath 'C:\Users\x\AppData\Local\Packages\Contoso.App_abc\LocalCache\Local\x')
    Assert-True (Test-DseVirtualizedPath 'C:\Users\x\AppData\Local\Temp\x')
    Assert-False (Test-DseVirtualizedPath 'C:\Users\x\.codex-deepseek-native')
    Assert-False (Test-DseVirtualizedPath 'D:\codex-runtime')
}

Register-Test 'Path containment recognises the folder itself and its children only' {
    $parent = Join-Path $env:TEMP 'dse-contains-parent'
    Assert-True (Test-DsePathInside -Path $parent -Parent $parent) 'The folder itself counts as inside'
    Assert-True (Test-DsePathInside -Path (Join-Path $parent 'child') -Parent $parent) 'A child folder counts as inside'
    Assert-True (Test-DsePathInside -Path (Join-Path $parent 'a\b\c') -Parent $parent) 'A nested child counts as inside'
    Assert-True (Test-DsePathInside -Path (Join-Path $parent 'child') -Parent ($parent + '\')) 'A trailing separator must not matter'
    Assert-False (Test-DsePathInside -Path ($parent + '-other') -Parent $parent) 'A sibling with the same prefix is not inside'
    Assert-False (Test-DsePathInside -Path (Join-Path (Split-Path -Parent $parent) 'elsewhere') -Parent $parent) 'A sibling folder is not inside'
}

Register-Test 'The kit folder is the parent of the scripts folder' {
    Assert-Equal $script:RepositoryRoot (Get-DseKitRoot)
    Assert-True (Test-Path -LiteralPath (Join-Path (Get-DseKitRoot) 'scripts') -PathType Container)
}

Register-Test 'The default Codex home ignores a redirected USERPROFILE' {
    $persisted = [System.Environment]::GetEnvironmentVariable('USERPROFILE', 'User')
    if ([string]::IsNullOrWhiteSpace($persisted)) {
        throw (New-SkipException 'no persisted USERPROFILE value on this machine to compare against')
    }

    $originalHome = $env:CODEX_HOME
    $originalProfile = $env:USERPROFILE
    try {
        $env:CODEX_HOME = $null
        # Screenshot what a packaged app sees: a per-package redirected profile.
        $env:USERPROFILE = Join-Path $env:TEMP 'AppData\Local\Packages\Contoso.App_abc\LocalCache\Local'

        $resolved = Get-DseCodexHome
        Assert-Equal (Join-Path $persisted '.codex') $resolved
        Assert-NotMatch $resolved '(?i)AppData' 'The default Codex home must not land in an AppData alias'
    }
    finally {
        $env:CODEX_HOME = $originalHome
        $env:USERPROFILE = $originalProfile
    }
}

Register-Test 'A file that is not valid UTF-8 is refused instead of silently changed' {
    $path = Join-Path $env:TEMP ('dse-encoding-bad-' + [Guid]::NewGuid().ToString('N') + '.toml')
    try {
        # 0xFF is never valid UTF-8. A legacy ANSI save would look like this.
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0x22, 0xFF, 0x22, 0x0A))
        $before = Get-DseFileSha256 -Path $path

        Assert-Throws { Read-DseTextFile -Path $path } '(?i)not valid UTF-8'
        Assert-Equal $before (Get-DseFileSha256 -Path $path) 'The file must not be rewritten'
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Setup refuses an ANSI config file and leaves it byte for byte' {
    $environment = New-TestEnvironment
    $ansiBytes = [byte[]](0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0x22, 0xFF, 0x22, 0x0A)
    [System.IO.File]::WriteAllBytes($environment.ConfigPath, $ansiBytes)
    $before = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected setup to refuse`n$($result.All)"
    Assert-Match $result.All '(?i)not valid UTF-8'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath)
    Assert-FileMissing $environment.StatePath
}

Register-Test 'Writing a file leaves no temporary file behind' {
    $root = Join-Path $env:TEMP ('dse-atomic-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $path = Join-Path $root 'config.toml'
        Write-Utf8NoBom -Path $path -Text "a = 1`r`n"
        Write-DseTextFile -Path $path -Text "a = 1`r`nb = 2`r`n" | Out-Null
        Write-DseTextFile -Path $path -Text "a = 1`r`nb = 3`r`n" | Out-Null

        Assert-Equal "a = 1`r`nb = 3`r`n" (Read-Text $path)
        $leftovers = @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name -like '*dse-tmp-*' })
        Assert-Equal 0 $leftovers.Count "Temporary files were left behind: $(($leftovers | ForEach-Object { $_.Name }) -join ', ')"
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $root -File -Force).Count 'Only the target file should exist'
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Setup refuses an install root inside this kit and changes nothing' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath

    foreach ($badRoot in @($script:RepositoryRoot, (Join-Path $script:RepositoryRoot 'state'))) {
        $arguments = @(
            '-RuntimeDirectory', $environment.Runtime,
            '-CodexHome', $environment.CodexHome,
            '-InstallRoot', $badRoot,
            '-SkipVersionProbe'
        )
        $result = Invoke-ChildScript -ScriptPath $script:InstallScript -Arguments $arguments
        Assert-Equal 1 $result.ExitCode "Expected a refusal for '$badRoot'`n$($result.All)"
        Assert-Match $result.All '(?i)inside this kit'
        Assert-Match $result.All '(?i)Nothing was changed'
        Assert-Match $result.All '(?i)backups'
    }

    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
    Assert-NotMatch (Read-Text $environment.ConfigPath) 'codex-deepseek-native-managed'
    Assert-FileMissing (Join-Path $script:RepositoryRoot 'state\install-state.json')
}

Register-Test 'The real repository has no state, logs, backups or runtime folders committed' {
    foreach ($folder in @('state', 'logs', 'backups', 'runtime')) {
        Assert-FileMissing (Join-Path $script:RepositoryRoot $folder)
    }
}

# --------------------------------------------------------------- managed block

Describe-Group 'Managed block editing'

Register-Test 'A managed block is added once, is stable and is removed cleanly with CRLF' {
    $marker = 'dse-selftest-managed'
    $blockPath = Join-Path $env:TEMP ('dse-block-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        Write-Utf8NoBom -Path $blockPath -Text "# BEGIN $marker`r`nbody`r`n# END $marker`r`n"
        $original = "model = `"keep-me`"`r`n[projects.'C:\x']`r`ntrust_level = `"trusted`"`r`n"

        $once = Add-DseManagedBlock -Text $original -Marker $marker -Block (Read-DseTextFile $blockPath).Text
        Assert-True ($once.StartsWith($original)) 'The original text must stay at the top'
        $twice = Add-DseManagedBlock -Text $once -Marker $marker -Block (Read-DseTextFile $blockPath).Text
        Assert-Equal $once $twice 'Adding the block twice must not change anything'

        $found = Find-DseManagedBlock -Text $twice -Marker $marker
        Assert-True $found.IsWellFormed
        Assert-Equal 1 $found.BeginCount

        $restored = Remove-DseManagedBlock -Text $twice -Marker $marker
        Assert-Equal $original $restored 'Removing the block must restore the file exactly'
    }
    finally {
        Remove-Item -LiteralPath $blockPath -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Managed block round-trips with LF line endings and no trailing newline' {
    $marker = 'dse-selftest-lf'
    $block = "# BEGIN $marker`nbody`n# END $marker`n"
    $original = "a = 1`nb = 2"
    $added = Add-DseManagedBlock -Text $original -Marker $marker -Block $block
    $restored = Remove-DseManagedBlock -Text $added -Marker $marker
    Assert-Equal $original $restored
    Assert-Match $added '# BEGIN dse-selftest-lf'
}

Register-Test 'Marker text that is not its own line is ignored' {
    $marker = 'dse-selftest-inline'
    $text = "# note: do not write # BEGIN $marker like this`nmodel = `"x`"`n"
    $found = Find-DseManagedBlock -Text $text -Marker $marker
    Assert-False $found.Found
    Assert-Equal $text (Remove-DseManagedBlock -Text $text -Marker $marker)
}

Register-Test 'A damaged or duplicated block is refused instead of guessed' {
    $marker = 'dse-selftest-damaged'
    $missingEnd = "# BEGIN $marker`nbody`n"
    Assert-Throws { Remove-DseManagedBlock -Text $missingEnd -Marker $marker } 'damaged'

    $duplicated = "# BEGIN $marker`na`n# END $marker`n# BEGIN $marker`nb`n# END $marker`n"
    Assert-Throws { Remove-DseManagedBlock -Text $duplicated -Marker $marker } 'damaged'
}

Register-Test 'File encoding, byte order mark and line endings survive a rewrite' {
    $path = Join-Path $env:TEMP ('dse-encoding-' + [Guid]::NewGuid().ToString('N') + '.toml')
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($path, "x = 1`r`ny = 2`r`n", $utf8Bom)

        $read = Read-DseTextFile -Path $path
        Assert-True $read.HasBom 'The byte order mark must be detected'
        Assert-Match $read.Text "`r`n" 'The CRLF line ending must be detected'

        Write-DseTextFile -Path $path -Text ($read.Text + "z = 3`r`n") -Encoding $read.Encoding | Out-Null
        $again = Read-DseTextFile -Path $path
        Assert-True $again.HasBom 'The byte order mark must be preserved'
        Assert-Match $again.Text 'z = 3'
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Log text redacts key-shaped values' {
    # Built at run time so a secret scanner does not flag this test file itself.
    $secret = 'sk-' + ('x' * 24)
    $redacted = Protect-DseLogText "using $secret and api_key = `"another-secret-value`" and Bearer abcdefghijklmnop"
    Assert-NotMatch $redacted ([regex]::Escape($secret))
    Assert-NotMatch $redacted 'another-secret-value'
    Assert-Match $redacted 'redacted'
}

Register-Test 'TOML basic strings escape backslashes and quotes' {
    $value = Get-DseTomlBasicString 'C:\Users\x\agents\deepseek_flash.toml'
    Assert-Equal '"C:\\Users\\x\\agents\\deepseek_flash.toml"' $value
    Assert-Equal '"a\"b"' (Get-DseTomlBasicString 'a"b')
}

Register-Test 'Backups are timestamped copies that never overwrite each other' {
    $root = Join-Path $env:TEMP ('dse-backup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $source = Join-Path $root 'config.toml'
        Write-Utf8NoBom -Path $source -Text 'a = 1'
        $backupDirectory = Join-Path $root 'backups'

        $first = Copy-DseBackup -Path $source -BackupDirectory $backupDirectory -Label 'config.toml'
        Start-Sleep -Milliseconds 20
        $second = Copy-DseBackup -Path $source -BackupDirectory $backupDirectory -Label 'config.toml'

        Assert-FileExists $first
        Assert-FileExists $second
        Assert-NotEqual $first $second
        Assert-Equal 'a = 1' (Read-Text $first)
        Assert-Equal (Get-DseFileSha256 -Path $first) (Get-DseFileSha256 -Path $second)
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'Set-DseManagedBlock writes once and then reports no change' {
    $root = Join-Path $env:TEMP ('dse-setblock-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $marker = 'dse-selftest-setblock'
        $config = Join-Path $root 'config.toml'
        $blockFile = Join-Path $root 'block.toml'
        Write-Utf8NoBom -Path $config -Text "model = `"keep`"`r`n"
        Write-Utf8NoBom -Path $blockFile -Text "# BEGIN $marker`r`nbody`r`n# END $marker`r`n"

        $first = Set-DseManagedBlock -Path $config -Marker $marker -BlockPath $blockFile
        Assert-True $first.Changed 'The first call must change the file'
        $afterFirst = Read-Text $config
        Assert-Match $afterFirst "# BEGIN $marker"
        Assert-Match $afterFirst 'model = "keep"'

        $second = Set-DseManagedBlock -Path $config -Marker $marker -BlockPath $blockFile
        Assert-False $second.Changed 'The second call must be a no-op'
        Assert-Equal $afterFirst (Read-Text $config)
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------- runtime checks

Describe-Group 'Runtime checks'

Register-Test 'Runtime layout validation accepts the full set of files' {
    $environment = New-TestEnvironment
    $result = Test-DseRuntimeDirectory -RuntimeDirectory $environment.Runtime
    Assert-True $result.IsValid 'A complete runtime folder must be valid'
    Assert-Equal 0 @($result.MissingRequired).Count
    Assert-Equal 4 @($result.Present).Count
}

Register-Test 'Runtime layout validation names every missing file' {
    $environment = New-TestEnvironment
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'codex-command-runner.exe') -Force
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'codex-code-mode-host.exe') -Force

    $result = Test-DseRuntimeDirectory -RuntimeDirectory $environment.Runtime
    Assert-False $result.IsValid
    Assert-Contains $result.MissingRequired 'codex-command-runner.exe'
    Assert-Contains $result.MissingRequired 'codex-code-mode-host.exe'
}

Register-Test 'Runtime layout validation fails on a missing folder' {
    $environment = New-TestEnvironment
    $result = Test-DseRuntimeDirectory -RuntimeDirectory (Join-Path $environment.Root 'does-not-exist')
    Assert-False $result.IsValid
    Assert-False $result.Exists
}

Register-Test 'Release manifest verification accepts good hashes' {
    $environment = New-TestEnvironment
    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-True $result.Present
    Assert-True $result.Verified
    Assert-Equal '0.153.4' $result.Version
}

Register-Test 'Release manifest verification reports a changed file' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path (Join-Path $environment.Runtime 'codex.exe') -Text 'tampered'
    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-True $result.Present
    Assert-False $result.Verified
    Assert-Contains $result.Mismatches 'codex.exe'
}

Register-Test 'Release manifest verification reports a missing file' {
    $environment = New-TestEnvironment
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'codex-command-runner.exe') -Force
    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $result.Verified
    Assert-Contains $result.MissingFiles 'codex-command-runner.exe'
}

Register-Test 'A manifest file that cannot be parsed is rejected' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path (Join-Path $environment.Runtime 'runtime-manifest.json') -Text '{ not json'
    Assert-Throws { Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime } 'not valid JSON'
}

Register-Test 'A missing manifest is reported as absent, not as a failure' {
    $environment = New-TestEnvironment
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'runtime-manifest.json') -Force
    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $result.Present
    Assert-False $result.Verified
}

Register-Test 'A fixture-manifest marker is rejected even when the hashes match' {
    $markerCases = @(
        @{ Name = 'fixtureOnly = true'; Apply = { param($m) $m | Add-Member -NotePropertyName fixtureOnly -NotePropertyValue $true -Force } },
        @{ Name = 'isFixture = true'; Apply = { param($m) $m | Add-Member -NotePropertyName isFixture -NotePropertyValue $true -Force } },
        @{ Name = 'publishable = false'; Apply = { param($m) $m | Add-Member -NotePropertyName publishable -NotePropertyValue $false -Force } },
        @{ Name = 'kind = fixture'; Apply = { param($m) $m | Add-Member -NotePropertyName kind -NotePropertyValue 'fixture' -Force } }
    )

    foreach ($case in $markerCases) {
        $environment = New-TestEnvironment
        $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
        $manifest = Read-Text $manifestPath | ConvertFrom-Json
        & $case.Apply $manifest
        Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

        Assert-Throws { Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime } '(?i)not a usable release'
        Assert-Throws { Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime } '(?i)fixture|publishable'
    }
}

Register-Test 'A fixture-marked runtime is refused by setup even with hashes skipped' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath

    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $manifest = Read-Text $manifestPath | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName fixtureOnly -NotePropertyValue $true -Force
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected the fixture guard to stop setup`n$($result.All)"
    Assert-Match $result.All '(?i)not a usable release'
    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'A fixture-marked runtime supplied through -RuntimeManifest is refused' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Work 'release-manifest.json'
    $manifest = Read-Text (Join-Path $environment.Runtime 'runtime-manifest.json') | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName publishable -NotePropertyValue $false -Force
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Invoke-InstallScript -Environment $environment -Extra @(
        '-RuntimeManifest', $manifestPath,
        '-SkipManifestVerification'
    )
    Assert-Equal 1 $result.ExitCode "Expected the fixture guard to stop setup`n$($result.All)"
    Assert-Match $result.All '(?i)publishable'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'A normal release manifest is still accepted' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $manifest = Read-Text $manifestPath | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName publishable -NotePropertyValue $true -Force
    $manifest | Add-Member -NotePropertyName kind -NotePropertyValue 'release' -Force
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-True $result.Present
    Assert-True $result.Verified
}

Register-Test 'A manifest that hashes only extra files does not verify the runtime' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $readme = Join-Path $environment.Runtime 'README.md'
    Write-Utf8NoBom -Path $readme -Text 'not a runtime'

    $manifest = [ordered]@{
        version = '0.153.4'
        files   = [ordered]@{ 'README.md' = (Get-DseFileSha256 -Path $readme) }
    }
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $result.Verified 'A README hash must not count as a verified runtime'
    Assert-True (@($result.Problems) -join ' ' -match '(?i)unexpected file')
    Assert-True (@($result.Problems) -join ' ' -match '(?i)missing required file')
}

Register-Test 'A manifest must list all four runtime files' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $manifest = Read-Text $manifestPath | ConvertFrom-Json
    $manifest.files.PSObject.Properties.Remove('codex-code-mode-host.exe')
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $result.Verified
    Assert-True (@($result.Problems) -join ' ' -match '(?i)missing required file.*codex-code-mode-host')
}

Register-Test 'The array form of a manifest is understood' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $objectForm = Read-Text $manifestPath | ConvertFrom-Json

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($property in $objectForm.files.PSObject.Properties) {
        $list.Add([pscustomobject]@{ name = "$($property.Name)"; sha256 = "$($property.Value)" })
    }
    $manifest = [ordered]@{ version = '0.153.4'; files = $list.ToArray() }
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-True $result.Present
    Assert-True $result.Verified ("The array form must verify`nProblems: " + (@($result.Problems) -join '; '))
    Assert-Equal 4 @($result.Results).Count

    # A tampered file must still be caught in the array form.
    Write-Utf8NoBom -Path (Join-Path $environment.Runtime 'codex.exe') -Text 'tampered'
    $tampered = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $tampered.Verified
    Assert-Contains $tampered.Mismatches 'codex.exe'
}

Register-Test 'Bad manifest hashes and names are rejected' {
    $cases = @(
        @{ Why = 'a hash that is not a sha256'; Edit = { param($m) $m.files.'codex.exe' = 'not-a-hash' } },
        @{ Why = 'a path traversal name'; Edit = { param($m) $m.files | Add-Member -NotePropertyName '..\..\evil.exe' -NotePropertyValue ('a' * 64) -Force } },
        @{ Why = 'a subfolder name'; Edit = { param($m) $m.files | Add-Member -NotePropertyName 'sub\codex.exe' -NotePropertyValue ('a' * 64) -Force } },
        @{ Why = 'a duplicate entry'; Edit = { param($m) $m.files | Add-Member -NotePropertyName 'codex.exe ' -NotePropertyValue ('a' * 64) -Force } }
    )

    foreach ($case in $cases) {
        $environment = New-TestEnvironment
        $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
        $manifest = Read-Text $manifestPath | ConvertFrom-Json
        & $case.Edit $manifest
        Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 5)

        $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
        Assert-False $result.Verified "A manifest with $($case.Why) must not verify"
        Assert-True (@($result.Problems).Count -ge 1) "Expected a problem to be reported for $($case.Why)"
    }
}

Register-Test 'A manifest with no files section is rejected' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    Write-Utf8NoBom -Path $manifestPath -Text (@{ version = '0.153.4' } | ConvertTo-Json)

    $result = Test-DseRuntimeManifest -RuntimeDirectory $environment.Runtime
    Assert-False $result.Verified
    Assert-True (@($result.Problems) -join ' ' -match "(?i)no 'files' section")
}

Register-Test 'A partial manifest is refused by setup and leaves config.toml alone' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath

    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $readme = Join-Path $environment.Runtime 'README.md'
    Write-Utf8NoBom -Path $readme -Text 'docs only'
    Write-Utf8NoBom -Path $manifestPath -Text ([ordered]@{
        version = '0.153.4'
        files   = [ordered]@{ 'README.md' = (Get-DseFileSha256 -Path $readme) }
    } | ConvertTo-Json -Depth 5)

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected the manifest guard to stop setup`n$($result.All)"
    Assert-Match $result.All '(?i)unexpected file|missing required file'
    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'Version text parsing and the minimum version rule' {
    Assert-Equal ([version]'0.153.4') (Get-DseVersionFromText 'codex 0.153.4')
    Assert-Equal ([version]'0.153.4') (Get-DseVersionFromText "codex-cli 0.153.4`r`n")
    Assert-Equal $null (Get-DseVersionFromText 'no version here')
    Assert-True (Test-DseMinimumVersion -Text 'codex 0.154.0' -MinimumVersion '0.153.4')
    Assert-True (Test-DseMinimumVersion -Text 'codex 0.153.4' -MinimumVersion '0.153.4')
    Assert-False (Test-DseMinimumVersion -Text 'codex 0.152.9' -MinimumVersion '0.153.4')
    Assert-False (Test-DseMinimumVersion -Text 'nothing' -MinimumVersion '0.153.4')
}

Register-Test 'The version probe fails with a clear error for a file that cannot run' {
    $environment = New-TestEnvironment
    Assert-Throws { Invoke-DseVersionProbe -ExePath (Join-Path $environment.Runtime 'codex.exe') -TimeoutSeconds 10 }
}

Register-Test 'The version probe reads a real codex.exe version (opt-in only)' {
    # Opt-in: set DEEPSEEK_NATIVE_TEST_RUNTIME (or pass -RealRuntimeDirectory) to
    # a folder containing codex.exe. There is deliberately no fallback to any
    # installed or live runtime, so a normal test run never looks at, or runs,
    # anything outside the temp sandbox.
    $candidate = $RealRuntimeDirectory
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $env:DEEPSEEK_NATIVE_TEST_RUNTIME }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw (New-SkipException 'opt-in: set DEEPSEEK_NATIVE_TEST_RUNTIME or pass -RealRuntimeDirectory to run this')
    }
    $exe = Join-Path $candidate 'codex.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw (New-SkipException "no codex.exe in the opt-in runtime folder '$candidate'")
    }
    $probe = Invoke-DseVersionProbe -ExePath $exe -TimeoutSeconds 60
    Assert-Equal 0 $probe.ExitCode "codex.exe --version output: $($probe.Raw)"
    Assert-True ($null -ne $probe.Version) "No version found in: $($probe.Raw)"
    Assert-True (Test-DseMinimumVersion -Text $probe.Raw -MinimumVersion $script:Defaults.minimumRuntimeVersion) "Runtime reported $($probe.Version)"
}

# ------------------------------------------------------- installer (isolated)

Describe-Group 'Installer in an isolated folder'

$script:UnrelatedConfig = @"
model = "gpt-6-astra"
model_reasoning_effort = "low"

# BEGIN codex-router-managed
openai_base_url = "http://127.0.0.1:4202/v1"
# END codex-router-managed

api_key = "super-secret-value-123"

[projects.'C:\some\folder']
trust_level = "trusted"

[model_providers.codex-router]
name = "Codex Router"
base_url = "http://127.0.0.1:4202/v1"
wire_api = "responses"
"@

Register-Test 'A fresh install writes the managed block, the role file and the state file' {
    $environment = New-TestEnvironment
    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    Assert-FileExists $environment.ConfigPath
    $config = Read-Text $environment.ConfigPath
    Assert-Match $config '# BEGIN codex-deepseek-native-managed'
    Assert-Match $config '# END codex-deepseek-native-managed'
    Assert-Match $config '\[agents\.deepseek_flash\]'
    Assert-True ($config.Contains((Get-DseTomlBasicString $environment.RolePath))) 'The managed block must point at the role file'

    Assert-FileExists $environment.RolePath
    Assert-Match (Read-Text $environment.RolePath) 'model_provider = "codex-router"'
    Assert-Match (Read-Text $environment.RolePath) 'model = "deepseek/deepseek-v4-flash"'
    Assert-Match (Read-Text $environment.RolePath) 'model_reasoning_effort = "high"'

    Assert-FileExists $environment.StatePath
    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    Assert-Equal $environment.Runtime $state.runtimeDirectory
    Assert-Equal '0.153.4' $state.runtimeVersion
    Assert-Equal 4 @($state.runtimeFiles).Count
    foreach ($entry in @($state.runtimeFiles)) { Assert-True ($entry.sha256.Length -eq 64) "Missing sha256 for $($entry.name)" }
    Assert-Equal 0 @($state.backups).Count 'A fresh config file needs no backup'
    Assert-Equal $script:Defaults.marker $state.marker
}

Register-Test 'A second install changes nothing at all' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $configHash = Get-DseFileSha256 -Path $environment.ConfigPath
    $roleHash = Get-DseFileSha256 -Path $environment.RolePath
    $manages = @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'backups') -File -ErrorAction SilentlyContinue)

    $second = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $second.ExitCode ("exit $($second.ExitCode)`n$($second.All)")
    Assert-Equal $configHash (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must be byte-identical after a second install'
    Assert-Equal $roleHash (Get-DseFileSha256 -Path $environment.RolePath) 'The role file must be byte-identical after a second install'
    Assert-Match $second.All '(?i)no change|already'

    $after = @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'backups') -File -ErrorAction SilentlyContinue)
    Assert-Equal $manages.Count $after.Count 'A second install must not add backups'
}

Register-Test 'Existing unrelated settings are preserved exactly and only the block is added' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Read-Text $environment.ConfigPath
    $beforeKeyCount = ([regex]::Matches($before, 'api_key')).Count

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    $after = Read-Text $environment.ConfigPath
    Assert-True ($after.StartsWith($before)) 'Every original line must stay in place, unchanged, at the top'
    Assert-Equal $beforeKeyCount ([regex]::Matches($after, 'api_key')).Count
    Assert-Match $after '# BEGIN codex-router-managed'
    Assert-Match $after '\[projects\.''C:\\some\\folder''\]'
    Assert-Match $after '\[model_providers\.codex-router\]'
    Assert-Match $after '# BEGIN codex-deepseek-native-managed'

    $backups = @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'backups') -File)
    Assert-Equal 1 $backups.Count 'The original config file must be backed up once'
    Assert-Equal $before (Read-Text $backups[0].FullName)
}

Register-Test 'No value from the config file leaks into logs, state or output' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig

    $first = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $first.ExitCode ("exit $($first.ExitCode)`n$($first.All)")
    $second = Invoke-InstallScript -Environment $environment

    $written = @()
    $written += @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'logs') -File -ErrorAction SilentlyContinue)
    $written += @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'state') -File -ErrorAction SilentlyContinue)
    Assert-True ($written.Count -gt 0) 'The install must write a log or state file for this check to mean anything'

    foreach ($file in $written) {
        $text = Read-Text $file.FullName
        Assert-NotMatch $text 'super-secret-value-123' "A secret value leaked into $($file.Name)"
    }
    Assert-NotMatch $first.All 'super-secret-value-123' 'A secret value leaked into the setup output'
    Assert-NotMatch $second.All 'super-secret-value-123' 'A secret value leaked into the setup output'
}

Register-Test 'Install writes nothing outside the chosen config and install folders' {
    $environment = New-TestEnvironment
    $exclude = @($environment.CodexHome, $environment.InstallRoot)
    $before = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude
    $canaryBefore = Read-Text (Join-Path $environment.Protected 'canary.txt')

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    $after = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude
    Assert-Equal $before.Count $after.Count 'No file outside the two chosen folders may be created'
    Assert-Equal ($before -join '|') ($after -join '|')
    Assert-Equal $canaryBefore (Read-Text (Join-Path $environment.Protected 'canary.txt'))
}

Register-Test 'An incomplete runtime fails the setup and leaves config.toml alone' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Get-DseFileSha256 -Path $environment.ConfigPath
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'codex-command-runner.exe') -Force

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected a failure`n$($result.All)"
    Assert-Match $result.All 'codex-command-runner\.exe'
    Assert-Match $result.All '(?i)missing'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'A runtime folder that does not exist fails with instructions' {
    $environment = New-TestEnvironment
    $arguments = @(
        '-RuntimeDirectory', (Join-Path $environment.Root 'nope'),
        '-CodexHome', $environment.CodexHome,
        '-InstallRoot', $environment.InstallRoot,
        '-SkipVersionProbe'
    )
    $result = Invoke-ChildScript -ScriptPath $script:InstallScript -Arguments $arguments
    Assert-Equal 1 $result.ExitCode
    Assert-Match $result.All '(?i)does not exist'
    Assert-FileMissing $environment.ConfigPath
}

Register-Test 'A runtime that cannot be executed fails the setup and leaves config.toml alone' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-InstallScript -Environment $environment -WithVersionProbe
    Assert-Equal 1 $result.ExitCode "Expected the version probe to fail the setup`n$($result.All)"
    Assert-Match $result.All '(?i)could not run'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
}

Register-Test 'A release manifest that does not match fails the setup and leaves config.toml alone' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Get-DseFileSha256 -Path $environment.ConfigPath
    Write-Utf8NoBom -Path (Join-Path $environment.Runtime 'codex.exe') -Text 'tampered after release'

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected the manifest check to fail the setup`n$($result.All)"
    Assert-Match $result.All '(?i)hash mismatch|did not match'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be touched'
}

Register-Test 'A release manifest with an older version fails even when the probe is skipped' {
    $environment = New-TestEnvironment
    $manifestPath = Join-Path $environment.Runtime 'runtime-manifest.json'
    $manifest = Read-Text $manifestPath | ConvertFrom-Json
    $manifest.version = '0.150.0'
    Write-Utf8NoBom -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 4)

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected the version rule to fail the setup`n$($result.All)"
    Assert-Match $result.All '0\.150\.0'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'A path inside a packaged app folder is called out as risky' {
    $root = New-TestSandbox
    try {
        $virtualized = Join-Path $root 'work\AppData\Local\Packages\Fake.Codex_abc\LocalCache\Local\install'
        New-Item -ItemType Directory -Path $virtualized -Force | Out-Null
        $arguments = @(
            '-RuntimeDirectory', (Join-Path $root 'Runtime'),
            '-CodexHome', (Join-Path $root 'CodexHome'),
            '-InstallRoot', $virtualized,
            '-SkipVersionProbe'
        )
        $result = Invoke-ChildScript -ScriptPath $script:InstallScript -Arguments $arguments
        Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
        Assert-Match $result.All '(?i)warning'
        Assert-Match $result.All 'virtual'
    }
    finally {
        Remove-TestSandbox -SandboxRoot $root
    }
}

# ------------------------------------------------------- role file ownership

Describe-Group 'Role file ownership'

Register-Test 'An unowned role file is never overwritten, and setup changes nothing' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Write-Utf8NoBom -Path $environment.RolePath -Text "# my own notes about deepseek_flash`nname = `"my_role`"`n"
    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath
    $roleBefore = Get-DseFileSha256 -Path $environment.RolePath

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected setup to refuse`n$($result.All)"
    Assert-Match $result.All '(?i)will not overwrite'
    Assert-Match $result.All '(?i)Nothing was changed'

    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be registered'
    Assert-Equal $roleBefore (Get-DseFileSha256 -Path $environment.RolePath) 'The user file must be untouched'
    Assert-NotMatch (Read-Text $environment.ConfigPath) 'codex-deepseek-native-managed'
    Assert-FileMissing $environment.StatePath
}

Register-Test 'An identical pre-existing role file is kept and stays unowned' {
    $environment = New-TestEnvironment
    $template = Read-Text (Join-Path $script:RepositoryRoot 'config\agents.deepseek_flash.toml')
    Write-Utf8NoBom -Path $environment.RolePath -Text $template
    $roleBefore = Get-DseFileSha256 -Path $environment.RolePath

    $result = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-Match $result.All '(?i)stays yours'
    Assert-Equal $roleBefore (Get-DseFileSha256 -Path $environment.RolePath)

    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    Assert-False $state.roleFileOwnedByProduct 'A file that already existed must not be claimed'

    # Rollback must therefore leave it alone even though it is byte-identical.
    $uninstall = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $uninstall.ExitCode ("exit $($uninstall.ExitCode)`n$($uninstall.All)")
    Assert-FileExists $environment.RolePath
    Assert-Match $uninstall.All '(?i)not created by this product'
    Assert-Equal $roleBefore (Get-DseFileSha256 -Path $environment.RolePath)
}

Register-Test 'A role file this product created is marked owned and removed on rollback' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    Assert-True $state.roleFileOwnedByProduct 'setup created this file, so it must claim ownership'
    Assert-Equal (Get-DseFileSha256 -Path $environment.RolePath) $state.roleFileSha256

    $uninstall = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $uninstall.ExitCode ("exit $($uninstall.ExitCode)`n$($uninstall.All)")
    Assert-FileMissing $environment.RolePath
}

Register-Test 'An owned role file is refreshed when the template moves on' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    # Simulate "setup previously wrote an older template": the file content and
    # the recorded hash still agree with each other, but not with today's
    # template. That is the one case where replacing it is safe.
    $stale = "# older template written by setup`nname = `"deepseek_flash`"`n"
    Write-Utf8NoBom -Path $environment.RolePath -Text $stale
    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    $state.roleFileSha256 = Get-DseFileSha256 -Path $environment.RolePath
    Write-Utf8NoBom -Path $environment.StatePath -Text ($state | ConvertTo-Json -Depth 8)

    $second = Invoke-InstallScript -Environment $environment
    Assert-Equal 0 $second.ExitCode ("exit $($second.ExitCode)`n$($second.All)")
    Assert-Match $second.All '(?i)refreshed'
    Assert-Match (Read-Text $environment.RolePath) 'model_provider = "codex-router"'

    # The old content must have been preserved as a backup.
    $roleBackups = @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'backups') -File |
        Where-Object { $_.Name -like 'deepseek_flash.toml.*' })
    Assert-True ($roleBackups.Count -ge 1) 'The replaced role file must be backed up'
    Assert-Equal $stale (Read-Text $roleBackups[0].FullName)
}

Register-Test 'An owned role file edited by hand is refused, not overwritten' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Write-Utf8NoBom -Path $environment.RolePath -Text "# the user edited this`nname = `"mine`"`n"
    $before = Get-DseFileSha256 -Path $environment.RolePath

    $second = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $second.ExitCode "Expected the collision to be refused`n$($second.All)"
    Assert-Match $second.All '(?i)will not overwrite'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.RolePath)
}

Register-Test 'A foreign role file is refused but config.toml is left untouched' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath
    Write-Utf8NoBom -Path $environment.RolePath -Text "# someone else's file`nname = `"other`"`n"

    $third = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $third.ExitCode "Expected the collision to be refused`n$($third.All)"
    Assert-Match (Read-Text $environment.RolePath) 'someone else'
    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'The collision must be found before config.toml is written'
}

Register-Test 'A role file that differs only in letter case counts as different' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    # Same characters, different case. This is a different file, so setup must
    # not treat it as "already correct" and must not overwrite it.
    $template = Read-Text (Join-Path $script:RepositoryRoot 'config\agents.deepseek_flash.toml')
    $cased = $template.Replace('name = "deepseek_flash"', 'name = "DEEPSEEK_FLASH"')
    Assert-NotEqual $template $cased
    Write-Utf8NoBom -Path $environment.RolePath -Text $cased
    $before = Get-DseFileSha256 -Path $environment.RolePath

    $second = Invoke-InstallScript -Environment $environment
    Assert-Equal 1 $second.ExitCode "Expected a case-only difference to be refused`n$($second.All)"
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.RolePath)

    # Rollback must also treat it as edited and keep the file.
    $uninstall = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $uninstall.ExitCode ("exit $($uninstall.ExitCode)`n$($uninstall.All)")
    Assert-FileExists $environment.RolePath
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.RolePath)
}

# --------------------------------------------------------------- launcher checks

Describe-Group 'Launcher checks'

function New-FakeDesktopExe {
    param([Parameter(Mandatory = $true)]$Environment)

    # A stand-in app executable used with -DesktopExePath. Created before the
    # caller takes its file snapshot, so a check-only run is measured fairly.
    $fakeDesktop = Join-Path $Environment.Work 'ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $fakeDesktop -PathType Leaf)) {
        Write-Utf8NoBom -Path $fakeDesktop -Text 'not a real app'
    }
    return $fakeDesktop
}

function Invoke-LauncherCheck {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [string[]]$Extra = @()
    )
    $fakeDesktop = New-FakeDesktopExe -Environment $Environment
    $arguments = @(
        '-CodexHome', $Environment.CodexHome,
        '-InstallRoot', $Environment.InstallRoot,
        '-RuntimeDirectory', $Environment.Runtime,
        '-DesktopExePath', $fakeDesktop,
        '-CheckOnly',
        '-SkipVersionProbe'
    ) + $Extra
    return Invoke-ChildScript -ScriptPath $script:StartScript -Arguments $arguments
}

Register-Test 'The read-only launcher check passes on a good setup and starts nothing' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $result = Invoke-LauncherCheck -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-Match $result.All '\[PASS\] Runtime folder'
    Assert-Match $result.All '\[PASS\] config\.toml registers'
    Assert-Match $result.All '\[PASS\].*subagent role'
    Assert-Match $result.All '(?i)nothing was started'
}

Register-Test 'The read-only launcher check fails when the role is not registered' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Remove-Item -LiteralPath $environment.ConfigPath -Force

    $result = Invoke-LauncherCheck -Environment $environment
    Assert-Equal 1 $result.ExitCode "Expected the check to fail`n$($result.All)"
    Assert-Match $result.All '\[FAIL\]'
}

Register-Test 'The read-only launcher check fails when the runtime is incomplete' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Remove-Item -LiteralPath (Join-Path $environment.Runtime 'codex-windows-sandbox-setup.exe') -Force

    $result = Invoke-LauncherCheck -Environment $environment
    Assert-Equal 1 $result.ExitCode ("Expected the check to fail`n$($result.All)")
    Assert-Match $result.All 'codex-windows-sandbox-setup\.exe'
}

Register-Test 'A running app is detected by process name and install location' {
    $temporary = Join-Path $env:TEMP ('dse-defaults-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $defaults = Read-Text (Join-Path $script:RepositoryRoot 'config\defaults.json') | ConvertFrom-Json
        $defaults.desktopProcessName = (Get-Process -Id $PID).ProcessName
        Write-Utf8NoBom -Path $temporary -Text ($defaults | ConvertTo-Json -Depth 6)
        $probeDefaults = Read-Text $temporary | ConvertFrom-Json

        $here = Split-Path -Parent (Get-Process -Id $PID).Path
        $match = @(Get-DseRunningDesktopProcesses -Defaults $probeDefaults -InstallLocation $here)
        Assert-True ($match.Count -ge 1) 'This very process should be detected'
        Assert-True (@($match | Where-Object { $_.IsInstalledApp }).Count -ge 1) 'The path check should match the install folder'

        $elsewhere = @(Get-DseRunningDesktopProcesses -Defaults $probeDefaults -InstallLocation 'C:\definitely-not-here')
        Assert-True ($elsewhere.Count -ge 1) 'A process with that name is still detected'
        Assert-Equal 0 @($elsewhere | Where-Object { $_.IsInstalledApp }).Count 'It must not match a different install folder'
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'The launcher refuses to start while the app is running' {
    $launcher = Read-Text $script:StartScript
    Assert-Match $launcher 'isRunning -and -not \$AllowRunningDesktop'
    Assert-Match $launcher '\) 3'
    Assert-Match $launcher '(?i)No process was stopped'
}

Register-Test 'The launcher -CheckOnly run writes nothing at all' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    # Create the stand-in app first, so the snapshot below is the true baseline.
    [void](New-FakeDesktopExe -Environment $environment)
    $exclude = @($environment.CodexHome, $environment.InstallRoot)
    $before = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude
    $logsBefore = @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'logs') -File -Force -ErrorAction SilentlyContinue)

    $result = Invoke-LauncherCheck -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    $after = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude
    Assert-Equal ($before -join '|') ($after -join '|') 'A check-only run must not create files'
    Assert-FileMissing (Join-Path $environment.InstallRoot 'logs\launch.log')
    Assert-Equal $logsBefore.Count @(Get-ChildItem -LiteralPath (Join-Path $environment.InstallRoot 'logs') -File -Force -ErrorAction SilentlyContinue).Count
}

Register-Test 'The launcher does write a log when one is asked for' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $logPath = Join-Path $environment.Work 'launch-check.log'
    $result = Invoke-LauncherCheck -Environment $environment -Extra @('-LogPath', $logPath)
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-FileExists $logPath
    Assert-Match (Read-Text $logPath) 'PASS'
}

Register-Test 'A normal launch is refused when an earlier check failed' {
    $launcher = Read-Text $script:StartScript
    Assert-Match $launcher 'failedBeforeLaunch' 'The launcher must inspect the accumulated check results before starting'
    Assert-Match $launcher '(?i)so the app was not started'

    # Prove it at run time: a broken role file fails a check, so a real launch
    # attempt must stop and never call Process.Start.
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Remove-Item -LiteralPath $environment.ConfigPath -Force
    $fakeDesktop = New-FakeDesktopExe -Environment $environment

    $arguments = @(
        '-CodexHome', $environment.CodexHome,
        '-InstallRoot', $environment.InstallRoot,
        '-RuntimeDirectory', $environment.Runtime,
        '-DesktopExePath', $fakeDesktop,
        '-SkipVersionProbe',
        '-NoPause'
    )
    $result = Invoke-ChildScript -ScriptPath $script:StartScript -Arguments $arguments
    Assert-Equal 1 $result.ExitCode "Expected the launch to be refused`n$($result.All)"
    Assert-Match $result.All '(?i)so the app was not started'
    Assert-Match $result.All '\[FAIL\]'
}

# ------------------------------------------------------------------- shortcuts

Describe-Group 'Desktop shortcut'

function New-ShortcutFixture {
    $root = Join-Path $env:TEMP ('dse-shortcut-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $launcher = Join-Path $root 'Start-DeepSeekNative.ps1'
    Write-Utf8NoBom -Path $launcher -Text '# placeholder launcher'
    return [pscustomobject]@{
        Root      = $root
        Launcher  = $launcher
        Shortcut  = Join-Path $root 'DeepSeek Native Codex.lnk'
        Icon      = Join-Path $root 'icon.exe'
    }
}

Register-Test 'A shortcut can be created, recognised as ours and removed' {
    $fixture = New-ShortcutFixture
    try {
        Write-Utf8NoBom -Path $fixture.Icon -Text 'icon'
        try {
            New-DseDesktopShortcut -ShortcutPath $fixture.Shortcut -LauncherPath $fixture.Launcher -IconPath $fixture.Icon | Out-Null
        }
        catch {
            throw (New-SkipException "shortcut COM component unavailable: $($_.Exception.Message)")
        }
        Assert-FileExists $fixture.Shortcut
        Assert-True (Test-DseDesktopShortcut -ShortcutPath $fixture.Shortcut -LauncherPath $fixture.Launcher)

        $removed = Remove-DseDesktopShortcut -ShortcutPath $fixture.Shortcut -LauncherPath $fixture.Launcher
        Assert-True $removed.Removed
        Assert-FileMissing $fixture.Shortcut
    }
    finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Register-Test 'A shortcut that belongs to something else is never deleted' {
    $fixture = New-ShortcutFixture
    try {
        try {
            New-DseDesktopShortcut -ShortcutPath $fixture.Shortcut -LauncherPath (Join-Path $fixture.Root 'Other.ps1') | Out-Null
        }
        catch {
            throw (New-SkipException "shortcut COM component unavailable: $($_.Exception.Message)")
        }
        $result = Remove-DseDesktopShortcut -ShortcutPath $fixture.Shortcut -LauncherPath $fixture.Launcher
        Assert-False $result.Removed
        Assert-FileExists $fixture.Shortcut
    }
    finally {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------- uninstall

Describe-Group 'Rollback'

Register-Test 'Rollback restores config.toml byte for byte and removes the role file' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Read-Text $environment.ConfigPath
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Assert-Match (Read-Text $environment.ConfigPath) '# BEGIN codex-deepseek-native-managed'

    $result = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-Equal $before (Read-Text $environment.ConfigPath) 'config.toml must be exactly what it was before setup'
    Assert-FileMissing $environment.RolePath
    Assert-Match $result.All '(?i)complete'
}

Register-Test 'Rollback twice is safe and changes nothing the second time' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    $before = Read-Text $environment.ConfigPath
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Assert-Equal 0 (Invoke-UninstallScript -Environment $environment).ExitCode
    $hash = Get-DseFileSha256 -Path $environment.ConfigPath

    $second = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $second.ExitCode ("exit $($second.ExitCode)`n$($second.All)")
    Assert-Equal $hash (Get-DseFileSha256 -Path $environment.ConfigPath)
    Assert-Equal $before (Read-Text $environment.ConfigPath)
}

Register-Test 'Rollback refuses a damaged managed block and leaves config.toml untouched' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $damaged = (Read-Text $environment.ConfigPath) -replace '(?m)^# END codex-deepseek-native-managed\r?\n', ''
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $damaged
    $hash = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-UninstallScript -Environment $environment
    Assert-Equal 2 $result.ExitCode "Expected the damaged-marker exit code`n$($result.All)"
    Assert-Match $result.All '(?i)damaged'
    Assert-Equal $hash (Get-DseFileSha256 -Path $environment.ConfigPath) 'config.toml must not be changed'
}

Register-Test 'Rollback keeps a role file that was edited after setup' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Add-Content -LiteralPath $environment.RolePath -Value '# edited by the user'

    $result = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-FileExists $environment.RolePath
    Assert-Match $result.All '(?i)changed after setup'
}

Register-Test 'Rollback -RestoreBackup restores the config when nothing changed after setup' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-Equal $script:UnrelatedConfig (Read-Text $environment.ConfigPath)
    Assert-Match $result.All '(?i)restored'
}

Register-Test 'Rollback -RestoreBackup refuses to overwrite config edited after setup' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    # The user adds an unrelated setting after setup. That edit must survive.
    $edited = (Read-Text $environment.ConfigPath) + "`n[tui]`ntheme = `"dark`"`n"
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $edited
    $before = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-NotEqual 0 $result.ExitCode "Expected the restore to be refused`n$($result.All)"
    Assert-Match $result.All '(?i)edited after setup'
    Assert-Match $result.All '(?i)Nothing was changed'
    Assert-Match $result.All '(?i)backup was kept'

    # A refused restore stops before ANY change, so the managed block is still
    # present here. That is deliberate: the preflight runs before the rollback
    # touches config.toml, so nothing is ever half-applied.
    $after = Read-Text $environment.ConfigPath
    Assert-Match $after 'theme = "dark"' 'The later user edit must still be there'
    Assert-Match $after 'codex-deepseek-native-managed' 'Nothing may be removed when the restore is refused'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath) 'The file must be byte for byte untouched'
    Assert-Match $result.All '(?i)Rollback stopped before changing anything' 'The refusal must say it stopped before changing anything'
    Assert-Match $result.All '(?i)without -RestoreBackup' 'The refusal must point at the retry that still works'

    # And that retry does clean up the managed additions.
    $retry = Invoke-UninstallScript -Environment $environment
    Assert-Equal 0 $retry.ExitCode ("exit $($retry.ExitCode)`n$($retry.All)")
    Assert-NotMatch (Read-Text $environment.ConfigPath) 'codex-deepseek-native-managed'
    Assert-Match (Read-Text $environment.ConfigPath) 'theme = "dark"'
}

Register-Test 'Rollback -RestoreBackup refuses when the state has no recorded post-install hash' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    $state.PSObject.Properties.Remove('configSha256AfterInstall')
    Write-Utf8NoBom -Path $environment.StatePath -Text ($state | ConvertTo-Json -Depth 8)

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-NotEqual 0 $result.ExitCode "Expected the restore to be refused`n$($result.All)"
    Assert-Match $result.All '(?i)safe restore cannot be verified'
}

Register-Test 'Reinstall after later edits cannot make -RestoreBackup overwrite them' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig

    # Install once (backup 1 pairs the original file with the installed file).
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    # The user then edits config.toml, and setup is run again. This second run
    # creates its own backup and must replace the older restore point, so the
    # recorded baseline always belongs to the newest backup.
    $edited = (Read-Text $environment.ConfigPath) + "`n[tui]`ntheme = `"dark`"`n"
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $edited
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    Assert-Equal (Get-DseFileSha256 -Path $environment.ConfigPath) "$($state.configSha256AfterInstall)"
    Assert-Equal "$($state.restorePoint.replacedWithSha)" "$($state.configSha256AfterInstall)" 'The restore point must pair with the newest baseline'
    Assert-Equal $edited (Read-Text $state.restorePoint.backup) 'The newest backup must hold the file the second install replaced'

    # Now the user edits again and rollback asks to restore.
    $editedAgain = (Read-Text $environment.ConfigPath) + "`n[history]`npersistence = `"none`"`n"
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $editedAgain
    $before = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-NotEqual 0 $result.ExitCode "Expected the restore to be refused`n$($result.All)"
    Assert-Match $result.All '(?i)edited after setup'
    Assert-Match $result.All '(?i)Nothing was changed'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath) 'The later edits must survive untouched'
    Assert-Match (Read-Text $environment.ConfigPath) 'theme = "dark"'
    Assert-Match (Read-Text $environment.ConfigPath) 'persistence = "none"'
}

Register-Test 'An unpaired older backup is refused rather than matched to a new baseline' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    # Simulate a state file written by an older version: a backup with no pairing
    # information. The restore must refuse rather than guess.
    $state = Read-Text $environment.StatePath | ConvertFrom-Json
    $state.PSObject.Properties.Remove('restorePoint')
    foreach ($record in @($state.backups)) {
        $record.PSObject.Properties.Remove('replacedWithSha')
    }
    Write-Utf8NoBom -Path $environment.StatePath -Text ($state | ConvertTo-Json -Depth 8)
    $before = Get-DseFileSha256 -Path $environment.ConfigPath

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-NotEqual 0 $result.ExitCode "Expected the restore to be refused`n$($result.All)"
    Assert-Match $result.All '(?i)not paired'
    Assert-Equal $before (Get-DseFileSha256 -Path $environment.ConfigPath)
    Assert-Match (Read-Text $environment.ConfigPath) 'codex-deepseek-native-managed' 'The refusal must happen before the block is removed'
}

Register-Test 'A refused restore leaves the install completely untouched' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Add-Content -LiteralPath $environment.ConfigPath -Value '# edited after install'

    $configBefore = Get-DseFileSha256 -Path $environment.ConfigPath
    $roleBefore = Get-DseFileSha256 -Path $environment.RolePath

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RestoreBackup')
    Assert-NotEqual 0 $result.ExitCode
    Assert-Equal $configBefore (Get-DseFileSha256 -Path $environment.ConfigPath) 'A refused restore must not change config.toml'
    Assert-Equal $roleBefore (Get-DseFileSha256 -Path $environment.RolePath) 'A refused restore must not change the role file'
    Assert-Match $result.All '(?i)stopped before changing anything'
    Assert-Match $result.All '(?i)without -RestoreBackup'
}

Register-Test 'Rollback never deletes the runtime folder or the install folder contents' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $runtimeBefore = Get-DseFileSha256 -Path (Join-Path $environment.Runtime 'codex.exe')

    $result = Invoke-UninstallScript -Environment $environment -Extra @('-RemoveBackups')
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    Assert-Equal 4 @(Get-ChildItem -LiteralPath $environment.Runtime -File |
        Where-Object { $_.Name -like '*.exe' }).Count
    Assert-Equal $runtimeBefore (Get-DseFileSha256 -Path (Join-Path $environment.Runtime 'codex.exe'))
    Assert-FileExists $environment.StatePath
}

Register-Test 'Rollback removes the launcher shortcut when it owns it' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $shortcut = Join-Path $environment.Work 'DeepSeek Native Codex.lnk'
    try {
        New-DseDesktopShortcut -ShortcutPath $shortcut -LauncherPath $script:StartScript | Out-Null
    }
    catch {
        throw (New-SkipException "shortcut COM component unavailable: $($_.Exception.Message)")
    }
    Assert-FileExists $shortcut

    $result = Invoke-UninstallScript -Environment $environment -AllowShortcutRemoval -Extra @('-ShortcutPath', $shortcut)
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-FileMissing $shortcut
}

# ------------------------------------------------------------------- verifier

Describe-Group 'Read-only verifier'

function Invoke-VerifyScript {
    param(
        [Parameter(Mandatory = $true)]$Environment,
        [string[]]$Extra = @()
    )
    $arguments = @(
        '-CodexHome', $Environment.CodexHome,
        '-InstallRoot', $Environment.InstallRoot,
        '-RuntimeDirectory', $Environment.Runtime,
        '-SkipVersionProbe',
        '-SkipDesktopCheck',
        '-SkipRouterHealth'
    ) + $Extra
    return Invoke-ChildScript -ScriptPath $script:TestScript -Arguments $arguments
}

Register-Test 'The verifier reports a healthy setup as JSON' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $result = Invoke-VerifyScript -Environment $environment -Extra @('-AsJson')
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    $json = $result.StdOut | ConvertFrom-Json
    Assert-Equal 'pass' $json.summary.result
    Assert-Equal 0 $json.summary.failed
    Assert-True (@($json.checks).Count -gt 5) 'The report must contain the individual checks'
    Assert-True $json.liveTestRequired.required 'A live test must always be requested'
    Assert-Match ($json.liveTestRequired.why) '(?i)cannot prove'
    Assert-Match ($json.liveTestRequired.instructions -join "`n") '(?i)deepseek_flash subagent'
    Assert-Match ($json.liveTestRequired.instructions -join "`n") '(?i)follow'
    Assert-Match $json.disclaimer '(?i)secret'
}

Register-Test 'The verifier calls out a missing role file' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    Remove-Item -LiteralPath $environment.RolePath -Force

    $result = Invoke-VerifyScript -Environment $environment -Extra @('-AsJson')
    Assert-Equal 1 $result.ExitCode "Expected the verifier to fail`n$($result.All)"

    $json = $result.StdOut | ConvertFrom-Json
    $failedChecks = @($json.checks | Where-Object { $_.Status -eq 'FAIL' })
    Assert-True ($failedChecks.Count -ge 1)
    Assert-Match ($failedChecks | ForEach-Object { "$($_.Name) $($_.Detail)" }) '(?i)role file'
}

Register-Test 'The verifier fails when the router is not answering, with a next step' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode

    $arguments = @(
        '-CodexHome', $environment.CodexHome,
        '-InstallRoot', $environment.InstallRoot,
        '-RuntimeDirectory', $environment.Runtime,
        '-SkipVersionProbe',
        '-SkipDesktopCheck',
        '-RouterBaseUrl', 'http://127.0.0.1:1',
        '-RouterTimeoutSeconds', '3'
    )
    $result = Invoke-ChildScript -ScriptPath $script:TestScript -Arguments $arguments
    Assert-Equal 1 $result.ExitCode "Expected the router check to fail`n$($result.All)"
    Assert-Match $result.All '(?i)codex-router'
    Assert-Match $result.All '(?i)start the codex-router'
}

Register-Test 'The verifier writes nothing unless a report path is given' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $exclude = @($environment.CodexHome, $environment.InstallRoot)
    $before = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude

    $result = Invoke-VerifyScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")

    $after = Get-ScopeSnapshot -Root $environment.Root -Exclude $exclude
    Assert-Equal ($before -join '|') ($after -join '|')
    Assert-Match $result.All '(?i)result: '
}

Register-Test 'A written report contains the checks but no secret value' {
    $environment = New-TestEnvironment
    Write-Utf8NoBom -Path $environment.ConfigPath -Text $script:UnrelatedConfig
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $reportPath = Join-Path $environment.Work 'verification.json'

    $result = Invoke-VerifyScript -Environment $environment -Extra @('-ReportPath', $reportPath)
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-FileExists $reportPath

    $report = Read-Text $reportPath
    Assert-NotMatch $report 'super-secret-value-123' 'The report must never contain config values that look like keys'
    $json = $report | ConvertFrom-Json
    Assert-False $json.readOnly 'A report path was supplied, so the run was not read-only'
    Assert-Equal $environment.Runtime $json.runtimeDirectory
}

Register-Test 'The readable verifier output explains the live parallel test' {
    $environment = New-TestEnvironment
    Assert-Equal 0 (Invoke-InstallScript -Environment $environment).ExitCode
    $result = Invoke-VerifyScript -Environment $environment
    Assert-Equal 0 $result.ExitCode ("exit $($result.ExitCode)`n$($result.All)")
    Assert-Match $result.All '(?i)do not'
    Assert-Match $result.All '(?i)deepseek_flash subagent'
    Assert-Match $result.All '(?i)main answer comes from your model'
    Assert-Match $result.All '(?i)Start-DeepSeekNative'
}

# ---------------------------------------------------------------------- runner

Write-Host ''
Write-Host 'codex-deepseek-native test suite'
Write-Host '================================'
Write-Host "Repository : $script:RepositoryRoot"
Write-Host "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host 'Note: every test runs in a temp sandbox. The real config, desktop and runtime are not touched.'

$summary = Invoke-TestSuite -Filter $Filter -Quiet:$Quiet

Write-Host ''
Write-Host 'Summary'
Write-Host ("  passed : {0}" -f $summary.Passed)
Write-Host ("  failed : {0}" -f $summary.Failed)
Write-Host ("  skipped: {0}" -f $summary.Skipped)
Write-Host ("  time   : {0}s" -f $summary.Duration)

$failedTests = @($summary.Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failedTests.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failed tests:' -ForegroundColor Red
    foreach ($test in $failedTests) {
        Write-Host ("  - {0} [{1}]" -f $test.Name, $test.Group) -ForegroundColor Red
        Write-Host ("      {0}" -f $test.Message) -ForegroundColor Red
    }
}

if ($ResultPath) {
    $report = [ordered]@{
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        machine        = $env:COMPUTERNAME
        powerShell     = "$($PSVersionTable.PSVersion)"
        repository     = $script:RepositoryRoot
        passed         = $summary.Passed
        failed         = $summary.Failed
        skipped        = $summary.Skipped
        seconds        = $summary.Duration
        success        = $summary.Success
        # ToArray() avoids a PowerShell enumerable-binder bug with @(List[object]).
        tests          = $summary.Results.ToArray()
    }
    $fullResultPath = Resolve-DseFullPath $ResultPath
    $resultDirectory = Split-Path -Parent $fullResultPath
    if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($fullResultPath, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host "Result file: $fullResultPath"
}

foreach ($sandbox in $script:CreatedSandboxes) {
    try {
        Remove-TestSandbox -SandboxRoot $sandbox -Keep:$KeepSandbox
    }
    catch {
        Write-Host "  could not remove sandbox $sandbox : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
if ($summary.Success) {
    Write-Host 'All tests passed.' -ForegroundColor Green
    exit 0
}
Write-Host "There were $($summary.Failed) failing test(s)." -ForegroundColor Red
exit 1
