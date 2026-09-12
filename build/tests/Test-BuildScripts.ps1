#requires -Version 5.1
<#
.SYNOPSIS
    Local checks for the Windows x64 MSVC build configuration.

.DESCRIPTION
    This script is safe to run on any machine: it only reads files, and the one
    process it starts is the build script in -DryRun mode. It performs:

      1. PowerShell syntax parsing of every script under build/.
      2. Structural checks on build/pins.json.
      3. A digest check on patches/codex-native-provider.patch.
      4. Checks on verification/official-downloads.json for the companion binaries.
      5. Structural checks on the workflow, plus a full YAML parse when a Python
         interpreter with PyYAML is available.
      6. A dry run of Build-NativeRuntime.ps1, checking the resolved plan.

    It does not build Rust code, download anything, or touch the network.

.PARAMETER SkipDryRun
    Skip step 6. Useful on a machine without rustup or git.

.PARAMETER IncludeFixtureRun
    Also exercise the packaging guards end to end against -FixtureWorkRoot: a
    -SkipBuild run must fail for lack of a build receipt, and a -FixtureBinary run
    must produce a bundle explicitly marked non-publishable. These runs touch the
    filesystem and may download the pinned companion executables, so they are
    opt-in and are not part of the read-only default pass.

.PARAMETER FixtureWorkRoot
    Work root used by -IncludeFixtureRun. Default C:\build.

.EXAMPLE
    pwsh -File build/tests/Test-BuildScripts.ps1

.EXAMPLE
    pwsh -File build/tests/Test-BuildScripts.ps1 -IncludeFixtureRun
#>
[CmdletBinding()]
param(
    [switch] $SkipDryRun,
    [switch] $IncludeFixtureRun,
    [string] $FixtureWorkRoot = 'C:\build'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = New-Object System.Collections.Generic.List[string]

function Write-Head {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host ''
    Write-Host ("== " + $Message)
}

function Write-Ok {
    param([Parameter(Mandatory)] [string] $Message)
    $script:Passed++
    Write-Host ("  PASS  " + $Message)
}

function Write-Fail {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Detail = ''
    )
    $script:Failed++
    Write-Host ("  FAIL  " + $Message)
    if ($Detail) {
        foreach ($line in ($Detail -split "`n")) {
            Write-Host ("        " + $line)
        }
    }
}

function Write-Skip {
    param([Parameter(Mandatory)] [string] $Message)
    $script:Skipped.Add($Message)
    Write-Host ("  SKIP  " + $Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message,
        [string] $Detail = ''
    )
    if ($Condition) { Write-Ok $Message } else { Write-Fail $Message -Detail $Detail }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual
    )
    $expectedText = [string] $Expected
    $actualText = [string] $Actual
    if ($expectedText -eq $actualText) {
        Write-Ok $Name
    } else {
        Write-Fail $Name -Detail ("expected: " + $expectedText + "`nactual  : " + $actualText)
    }
}

function Get-PinnedValue {
    param(
        [Parameter(Mandatory)] [object] $Pins,
        [Parameter(Mandatory)] [string] $Path
    )
    $node = $Pins
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        $property = $node.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $node = $property.Value
    }
    return $node
}

function Get-NormalizedPatchText {
    param([Parameter(Mandatory)] [string] $Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    $normalized = ($raw -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n")) { $normalized += "`n" }
    return $normalized
}

function Get-Sha256OfText {
    param([Parameter(Mandatory)] [string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Write-Host ("Repository root: " + $repositoryRoot)

# ---------------------------------------------------------------------------
# 1. PowerShell syntax
# ---------------------------------------------------------------------------

Write-Head 'PowerShell syntax'
$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'build') -Recurse -File -Filter '*.ps1' | Sort-Object FullName)
Assert-True -Condition ($scriptFiles.Count -gt 0) -Message "Found $($scriptFiles.Count) PowerShell script(s) under build/"

foreach ($file in $scriptFiles) {
    $relative = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\', '/')
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $detail = ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        Write-Fail "$relative parses" -Detail $detail
    } else {
        Write-Ok "$relative parses"
    }
}

# ---------------------------------------------------------------------------
# 2. Pins
# ---------------------------------------------------------------------------

Write-Head 'build/pins.json'
$pinsPath = Join-Path $repositoryRoot 'build/pins.json'
$pins = $null
if (-not (Test-Path -LiteralPath $pinsPath)) {
    Write-Fail 'build/pins.json exists'
} else {
    Write-Ok 'build/pins.json exists'
    try {
        $pins = Get-Content -Raw -LiteralPath $pinsPath | ConvertFrom-Json
        Write-Ok 'build/pins.json is valid JSON'
    } catch {
        Write-Fail 'build/pins.json is valid JSON' -Detail $_.Exception.Message
    }
}

if ($pins) {
    $requiredPaths = @(
        'source.repositoryUrl',
        'source.tag',
        'source.tagObjectSha',
        'source.commitSha',
        'source.workspaceVersion',
        'patch.path',
        'patch.sha256',
        'patch.expectedChangedFiles',
        'toolchain.rustupToolchain',
        'toolchain.rustVersion',
        'toolchain.targetTriple',
        'buildProfile.default',
        'buildProfile.allowed',
        'runner.runsOn',
        'paths.workRootDefault',
        'paths.virtualRootDefault',
        'tests.unitFilters',
        'tests.unitFilterSourceFiles',
        'tests.integrationFilters',
        'tests.testThreads',
        'tests.noTestsAction',
        'buildReceipt.fileName',
        'paths.layout.state',
        'nextest.url',
        'nextest.sha256',
        'nextest.sizeBytes',
        'helperManifest.path',
        'helperManifest.requiredAssets',
        'helperManifest.bundleNameWithoutTargetSuffix',
        'runtimeManifest.fileName',
        'runtimeManifest.files',
        'bundle.nameTemplate',
        'bundle.cliBinaryName',
        'githubActions.actions/checkout.sha',
        'githubActions.actions/upload-artifact.sha'
    )
    foreach ($path in $requiredPaths) {
        $value = Get-PinnedValue -Pins $pins -Path $path
        Assert-True -Condition ($null -ne $value -and (($value -isnot [string]) -or $value.Length -gt 0)) -Message "pins.$path is set"
    }

    Assert-True -Condition (([string] (Get-PinnedValue -Pins $pins -Path 'source.commitSha')) -match '^[0-9a-f]{40}$') -Message 'pinned commit is a full SHA'
    Assert-True -Condition (([string] (Get-PinnedValue -Pins $pins -Path 'source.tagObjectSha')) -match '^[0-9a-f]{40}$') -Message 'pinned tag object is a full SHA'
    Assert-True -Condition (([string] (Get-PinnedValue -Pins $pins -Path 'nextest.sha256')) -match '^[0-9a-f]{64}$') -Message 'nextest digest is a SHA256'
}

# ---------------------------------------------------------------------------
# 3. Patch
# ---------------------------------------------------------------------------

Write-Head 'Native provider patch'
if ($pins) {
    $patchRelative = [string] (Get-PinnedValue -Pins $pins -Path 'patch.path')
    $patchPath = Join-Path $repositoryRoot ($patchRelative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $patchPath)) {
        Write-Fail "patch exists ($patchRelative)"
    } else {
        Write-Ok "patch exists ($patchRelative)"
        $normalizedText = Get-NormalizedPatchText -Path $patchPath
        $normalizedDigest = Get-Sha256OfText -Text $normalizedText
        $pinnedDigest = [string] (Get-PinnedValue -Pins $pins -Path 'patch.sha256')
        Assert-Equal -Name 'patch digest matches build/pins.json' -Expected $pinnedDigest -Actual $normalizedDigest

        $patchFiles = @()
        foreach ($line in ($normalizedText -split "`n")) {
            if ($line.StartsWith('diff --git ')) {
                $parts = $line.Split(' ')
                if ($parts.Count -ge 4) {
                    $candidate = $parts[3]
                    if ($candidate.StartsWith('b/')) { $patchFiles += $candidate.Substring(2) }
                }
            }
        }
        $expectedFiles = @(Get-PinnedValue -Pins $pins -Path 'patch.expectedChangedFiles')
        Assert-Equal -Name 'pins.expectedChangedFiles matches the patch' -Expected ($expectedFiles -join '|') -Actual ($patchFiles -join '|')
    }
}

# ---------------------------------------------------------------------------
# 4. Companion binary manifest
# ---------------------------------------------------------------------------

Write-Head 'verification/official-downloads.json'
if ($pins) {
    $manifestRelative = [string] (Get-PinnedValue -Pins $pins -Path 'helperManifest.path')
    $manifestPath = Join-Path $repositoryRoot ($manifestRelative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Fail "download manifest exists ($manifestRelative)"
    } else {
        Write-Ok "download manifest exists ($manifestRelative)"
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            Write-Ok 'download manifest is valid JSON'
        } catch {
            $manifest = $null
            Write-Fail 'download manifest is valid JSON' -Detail $_.Exception.Message
        }

        if ($manifest) {
            $requiredAssets = @(Get-PinnedValue -Pins $pins -Path 'helperManifest.requiredAssets')
            $renameMap = Get-PinnedValue -Pins $pins -Path 'helperManifest.bundleNameWithoutTargetSuffix'
            foreach ($name in $requiredAssets) {
                $matches = @($manifest | Where-Object { $_.name -eq $name })
                if ($matches.Count -ne 1) {
                    Write-Fail "manifest has exactly one entry for $name" -Detail "found $($matches.Count)"
                    continue
                }
                $entry = $matches[0]
                Assert-True -Condition (([string] $entry.digest) -match '^sha256:[0-9a-f]{64}$') -Message "manifest digest for $name is a SHA256"
                Assert-True -Condition ([long] $entry.size -gt 0) -Message "manifest size for $name is positive"
                Assert-True -Condition (([string] $entry.browser_download_url).StartsWith('https://github.com/openai/codex/releases/download/')) -Message "manifest url for $name points at the official release"
                Assert-True -Condition ($null -ne $renameMap.PSObject.Properties[$name]) -Message "pins.json renames $name for the bundle"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Runtime manifest contract
# ---------------------------------------------------------------------------

Write-Head 'runtime manifest contract'
$defaultsPath = Join-Path $repositoryRoot 'config\defaults.json'
$installerCommon = Join-Path $repositoryRoot 'scripts\DeepSeekNative.Common.ps1'
$defaults = $null
if (Test-Path -LiteralPath $defaultsPath) {
    try {
        $defaults = Get-Content -Raw -LiteralPath $defaultsPath | ConvertFrom-Json
    } catch {
        Write-Fail 'config/defaults.json is valid JSON' -Detail $_.Exception.Message
    }
} else {
    Write-Skip 'runtime manifest contract (config/defaults.json not present)'
}

if ($pins -and $defaults) {
    $manifestFileNames = @(Get-PinnedValue -Pins $pins -Path 'runtimeManifest.files')
    $requiredRuntimeFiles = @($defaults.requiredRuntimeFiles)
    Assert-Equal -Name 'pins runtime manifest files match config/defaults.json requiredRuntimeFiles' -Expected (($requiredRuntimeFiles | Sort-Object) -join '|') -Actual (($manifestFileNames | Sort-Object) -join '|')
    Assert-Equal -Name 'pins runtime manifest file name matches config/defaults.json' -Expected ([string] $defaults.runtimeManifestFileName) -Actual ([string] (Get-PinnedValue -Pins $pins -Path 'runtimeManifest.fileName'))

    if (-not (Test-Path -LiteralPath $installerCommon)) {
        Write-Skip 'installer verification round trip (scripts/DeepSeekNative.Common.ps1 not present)'
    } else {
        $fixture = Join-Path $env:TEMP ("codex-manifest-contract-" + [guid]::NewGuid().ToString('N'))
        $verifierScript = Join-Path $fixture 'verify.ps1'
        New-Item -ItemType Directory -Force -Path $fixture | Out-Null
        $runtimeDir = Join-Path $fixture 'runtime'
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

        $index = 0
        foreach ($name in $requiredRuntimeFiles) {
            $index++
            [System.IO.File]::WriteAllText((Join-Path $runtimeDir $name), ("fixture runtime file {0} for {1}`n" -f $index, $name))
        }

        $manifestWriter = Join-Path $repositoryRoot 'build\New-RuntimeManifest.ps1'
        $version = [string] (Get-PinnedValue -Pins $pins -Path 'source.workspaceVersion')
        $commit = [string] (Get-PinnedValue -Pins $pins -Path 'source.commitSha')
        $patchSha = [string] (Get-PinnedValue -Pins $pins -Path 'patch.sha256')

        $writerLog = Join-Path $fixture 'writer.log'
        & $manifestWriter -RuntimeDirectory $runtimeDir -Version $version `
            -BundleName 'fixture-bundle' -BuildProfile 'dev-small' -Toolchain '1.95.0-x86_64-pc-windows-msvc' `
            -SourceCommit $commit -SourceTag 'rust-v0.153.4' `
            -PatchPath 'source/codex-native-provider.patch' -PatchSha256 $patchSha `
            -SourceRepositoryUrl 'https://github.com/openai/codex.git' > $writerLog 2>&1
        $manifestPath = Join-Path $runtimeDir 'runtime-manifest.json'
        $writerDetail = ''
        if (Test-Path -LiteralPath $writerLog) { $writerDetail = Get-Content -Raw $writerLog }
        Assert-True -Condition (Test-Path -LiteralPath $manifestPath) -Message 'manifest writer creates runtime-manifest.json' -Detail $writerDetail

        $childScript = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepositoryRoot,
    [Parameter(Mandatory)] [string] $RuntimeDirectory,
    [Parameter(Mandatory)] [string] $DefaultsPath,
    [string] $CorruptFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepositoryRoot 'scripts\DeepSeekNative.Common.ps1')
$defaults = Get-DseDefaults -DefaultsPath $DefaultsPath
if ($CorruptFile) {
    Add-Content -LiteralPath (Join-Path $RuntimeDirectory $CorruptFile) -Value 'tampered'
}
$result = Test-DseRuntimeManifest -RuntimeDirectory $RuntimeDirectory -Defaults $defaults
$manifest = Get-Content -LiteralPath (Join-Path $RuntimeDirectory 'runtime-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$payload = [ordered]@{
    Present    = [bool] $result.Present
    Verified   = [bool] $result.Verified
    Version    = [string] $result.Version
    Missing    = @($result.MissingFiles)
    Mismatches = @($result.Mismatches)
    EntryCount = @($result.Results).Count
    SourceCommit = [string] $manifest.source.commit
    PatchSha256  = [string] $manifest.source.patchSha256
}
$payload | ConvertTo-Json -Depth 5
'@
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($verifierScript, $childScript, $encoding)

        $hostExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
        $hostPath = if ($hostExe) { $hostExe.Source } else { (Get-Command powershell -ErrorAction SilentlyContinue).Source }

        if (-not $hostPath) {
            Write-Fail 'a PowerShell host is available for the manifest round trip'
        } else {
            $goodRaw = (& $hostPath -NoProfile -NonInteractive -File $verifierScript -RepositoryRoot $repositoryRoot -RuntimeDirectory $runtimeDir -DefaultsPath $defaultsPath) -join "`n"
            $good = $null
            try { $good = $goodRaw | ConvertFrom-Json } catch { }
            if (-not $good) {
                Write-Fail 'installer verification accepts the generated manifest' -Detail $goodRaw
            } else {
                Assert-True -Condition ($good.Present -and $good.Verified) -Message 'installer verification accepts the generated manifest' -Detail $goodRaw
                Assert-Equal -Name 'installer reads the expected version from the manifest' -Expected $version -Actual ([string] $good.Version)
                Assert-Equal -Name 'manifest carries the patched upstream commit' -Expected $commit -Actual ([string] $good.SourceCommit)
                Assert-Equal -Name 'manifest carries the patch SHA256' -Expected $patchSha -Actual ([string] $good.PatchSha256)

                # Extra bundle files must not disturb verification.
                [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'LICENSE'), "license text`n")
                [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'PROVENANCE.txt'), "provenance`n")
                $extraRaw = (& $hostPath -NoProfile -NonInteractive -File $verifierScript -RepositoryRoot $repositoryRoot -RuntimeDirectory $runtimeDir -DefaultsPath $defaultsPath) -join "`n"
                $extra = $null
                try { $extra = $extraRaw | ConvertFrom-Json } catch { }
                Assert-True -Condition ($extra -and $extra.Verified) -Message 'extra bundle files do not break verification' -Detail $extraRaw
                Remove-Item -LiteralPath (Join-Path $runtimeDir 'LICENSE'), (Join-Path $runtimeDir 'PROVENANCE.txt') -Force -ErrorAction SilentlyContinue

                # A tampered runtime file must be rejected, otherwise the check above proves nothing.
                $badRaw = (& $hostPath -NoProfile -NonInteractive -File $verifierScript -RepositoryRoot $repositoryRoot -RuntimeDirectory $runtimeDir -DefaultsPath $defaultsPath -CorruptFile (Get-PinnedValue -Pins $pins -Path 'bundle.cliBinaryName')) -join "`n"
                $bad = $null
                try { $bad = $badRaw | ConvertFrom-Json } catch { }
                Assert-True -Condition ($bad -and -not $bad.Verified -and @($bad.Mismatches).Count -eq 1) -Message 'a tampered runtime file fails verification' -Detail $badRaw
            }
        }

        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 6. Test selection, build receipt and packaging guards
# ---------------------------------------------------------------------------

Write-Head 'test selection and packaging guards'
$buildScriptPath = Join-Path $repositoryRoot 'build\Build-NativeRuntime.ps1'
$buildScriptText = if (Test-Path -LiteralPath $buildScriptPath) { Get-Content -Raw -LiteralPath $buildScriptPath } else { '' }

if ($pins -and $buildScriptText) {
    # Filters must be compiled module paths (they end in ::tests), not file names.
    $unitFilters = @(Get-PinnedValue -Pins $pins -Path 'tests.unitFilters')
    $sourceMap = Get-PinnedValue -Pins $pins -Path 'tests.unitFilterSourceFiles'
    foreach ($filter in $unitFilters) {
        Assert-True -Condition ($filter -match '::tests$') -Message "unit filter is a module path ending in ::tests ($filter)"

        # Use the PowerShell -split operator, not String.Split. On Windows
        # PowerShell 5.1, "a::b::c".Split('::') binds to Split(char[]) and splits
        # on each ':' separately, yielding empty segments and a wrong path.
        $segments = @($filter -split '::')
        Assert-True -Condition ($segments -notcontains '') -Message "filter splits cleanly into module segments ($filter)" -Detail ("segments: [" + ($segments -join '|') + "]")

        $mapped = $null
        if ($sourceMap) { $mapped = $sourceMap.PSObject.Properties[$filter] }
        Assert-True -Condition ($null -ne $mapped) -Message "pins.json maps $filter to its source file"
        if ($null -ne $mapped -and $segments.Count -ge 3) {
            # Drop the trailing 'tests' segment; what remains is the module path,
            # whose last segment is the file and whose parent is the folder.
            $moduleSegments = @($segments[0..($segments.Count - 2)])
            $baseName = $moduleSegments[$moduleSegments.Count - 1]
            $parentName = $moduleSegments[$moduleSegments.Count - 2]

            $mappedPath = ([string] $mapped.Value).Replace('\', '/')
            $mappedBase = [System.IO.Path]::GetFileNameWithoutExtension($mappedPath)
            $mappedParent = Split-Path (Split-Path $mappedPath -Parent) -Leaf
            Assert-Equal -Name "mapping for $filter names the declaring file" -Expected ($parentName + '/' + $baseName) -Actual ($mappedParent + '/' + $mappedBase)
        }
    }

    # A released binary is only trustworthy if a real compile produced it.
    $buildReceiptName = [string] (Get-PinnedValue -Pins $pins -Path 'buildReceipt.fileName')
    Assert-True -Condition ($buildReceiptName -eq 'build-receipt.json') -Message 'pins.json names the build receipt'
    Assert-True -Condition ($buildScriptText -match 'Assert-BuildReceipt') -Message 'build script verifies a build receipt before packaging'
    Assert-True -Condition ($buildScriptText -match 'Refusing to package: no build receipt') -Message 'build script refuses to package without a receipt'
    Assert-True -Condition ($buildScriptText -match "ValidateSet\('source-build', 'fixture'\)") -Message 'build script records a receipt kind (source-build or fixture)'
    Assert-True -Condition ($buildScriptText -match "-fixture'") -Message 'fixture bundles get a -fixture name suffix'
    Assert-True -Condition ($buildScriptText -match 'Refusing to publish: the embedded-path scan did not run') -Message 'packaging fails closed when the embedded-path scan is skipped'

    # Test invocation hardening.
    Assert-Equal -Name 'nextest thread limit is pinned' -Expected '2' -Actual ([string] (Get-PinnedValue -Pins $pins -Path 'tests.testThreads'))
    Assert-Equal -Name 'nextest zero-match behaviour is pinned' -Expected 'fail' -Actual ([string] (Get-PinnedValue -Pins $pins -Path 'tests.noTestsAction'))
    # Single-quoted pattern on purpose: a double-quoted string would expand
    # $noTestsAction (undefined here) and on 5.1 that raises VariableIsUndefined,
    # so the check would never actually evaluate.
    Assert-True -Condition ($buildScriptText -match "'--no-tests'") -Message 'build script passes --no-tests to nextest'
    Assert-True -Condition ($buildScriptText -match [regex]::Escape("'--no-tests', " + '$noTestsAction')) -Message 'build script passes the pinned --no-tests action through the variable'
    Assert-True -Condition ($buildScriptText -match "'--test-threads'") -Message 'build script passes --test-threads to nextest'
    Assert-True -Condition ($buildScriptText -match 'Assert-TestFilterModulesExist') -Message 'build script resolves each test filter against the source before running nextest'
}

if ($IncludeFixtureRun) {
    Write-Head 'fixture run: receipt guards'
    $hostExeFixture = (Get-Command pwsh -ErrorAction SilentlyContinue)
    $hostFixture = if ($hostExeFixture) { $hostExeFixture.Source } else { (Get-Command powershell -ErrorAction SilentlyContinue).Source }

    if (-not $hostFixture) {
        Write-Fail 'a PowerShell host is available for the fixture run'
    } elseif (-not $buildScriptText) {
        Write-Fail 'build script is available for the fixture run'
    } else {
        $fixtureSource = Join-Path $FixtureWorkRoot 'target\x86_64-pc-windows-msvc\dev-small\codex.exe'
        $fixtureBinary = Join-Path $env:TEMP ("fixture-codex-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".exe")
        if (-not (Test-Path -LiteralPath $fixtureSource)) {
            Write-Skip "fixture run (no staged binary at $fixtureSource to use as a fixture)"
        } else {
            Copy-Item -LiteralPath $fixtureSource -Destination $fixtureBinary -Force

            # 1. Packaging without a receipt must fail.
            $receiptPath = Join-Path $FixtureWorkRoot 'state\build-receipt.json'
            if (Test-Path -LiteralPath $receiptPath) {
                Remove-Item -LiteralPath $receiptPath -Force
            }
            $noReceiptLog = Join-Path $env:TEMP ("no-receipt-" + [guid]::NewGuid().ToString('N') + ".log")
            & $hostFixture -NoProfile -NonInteractive -File $buildScriptPath -WorkRoot $FixtureWorkRoot `
                -SkipToolchainInstall -SkipMsvcEnvironment -SkipBuild -SkipTests > $noReceiptLog 2>&1
            $noReceiptExit = $LASTEXITCODE
            $noReceiptText = if (Test-Path -LiteralPath $noReceiptLog) { Get-Content -Raw -LiteralPath $noReceiptLog } else { '' }
            Remove-Item -LiteralPath $noReceiptLog -Force -ErrorAction SilentlyContinue
            Assert-True -Condition ($noReceiptExit -ne 0) -Message 'packaging without a build receipt fails' -Detail $noReceiptText
            Assert-True -Condition ($noReceiptText -match 'no build receipt') -Message 'the failure names the missing receipt' -Detail $noReceiptText

            # 2. The fixture route must succeed and stay explicitly non-publishable.
            $fixtureLog = Join-Path $env:TEMP ("fixture-" + [guid]::NewGuid().ToString('N') + ".log")
            & $hostFixture -NoProfile -NonInteractive -File $buildScriptPath -WorkRoot $FixtureWorkRoot `
                -SkipToolchainInstall -SkipMsvcEnvironment -SkipTests -FixtureBinary $fixtureBinary > $fixtureLog 2>&1
            $fixtureExit = $LASTEXITCODE
            $fixtureText = if (Test-Path -LiteralPath $fixtureLog) { Get-Content -Raw -LiteralPath $fixtureLog } else { '' }
            Remove-Item -LiteralPath $fixtureLog -Force -ErrorAction SilentlyContinue
            Assert-Equal -Name 'fixture route exits successfully' -Expected '0' -Actual ([string] $fixtureExit)

            $fixtureReceiptPath = Join-Path $FixtureWorkRoot 'state\build-receipt.json'
            if (Test-Path -LiteralPath $fixtureReceiptPath) {
                $fixtureReceipt = Get-Content -Raw -LiteralPath $fixtureReceiptPath | ConvertFrom-Json
                Assert-Equal -Name 'fixture receipt is marked kind fixture' -Expected 'fixture' -Actual ([string] $fixtureReceipt.kind)
                Assert-True -Condition (-not [bool] $fixtureReceipt.publishable) -Message 'fixture receipt is not publishable'
                Assert-Equal -Name 'fixture receipt records the patched commit' -Expected ([string] (Get-PinnedValue -Pins $pins -Path 'source.commitSha')) -Actual ([string] $fixtureReceipt.sourceCommit)
                Assert-Equal -Name 'fixture receipt records the patch digest' -Expected ([string] (Get-PinnedValue -Pins $pins -Path 'patch.sha256')) -Actual ([string] $fixtureReceipt.patchSha256)
            } else {
                Write-Fail 'fixture run wrote a build receipt' -Detail $fixtureText
            }

            $fixtureStage = Get-ChildItem -LiteralPath (Join-Path $FixtureWorkRoot 'stage') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*-fixture' } | Select-Object -First 1
            if (-not $fixtureStage) {
                Write-Fail 'fixture run produced a -fixture stage directory' -Detail $fixtureText
            } else {
                Assert-True -Condition ($true) -Message ("fixture stage directory is clearly named (" + $fixtureStage.Name + ')')
                $fixtureManifestPath = Join-Path $fixtureStage.FullName 'runtime-manifest.json'
                if (Test-Path -LiteralPath $fixtureManifestPath) {
                    $fixtureManifest = Get-Content -Raw -LiteralPath $fixtureManifestPath | ConvertFrom-Json
                    Assert-Equal -Name 'fixture manifest is marked kind fixture' -Expected 'fixture' -Actual ([string] $fixtureManifest.kind)
                    Assert-True -Condition (-not [bool] $fixtureManifest.publishable) -Message 'fixture manifest is marked publishable=false'
                } else {
                    Write-Fail 'fixture run wrote runtime-manifest.json'
                }
            }

            Remove-Item -LiteralPath $fixtureBinary -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Workflow
# ---------------------------------------------------------------------------

Write-Head 'workflow definition'
$workflowPath = Join-Path $repositoryRoot '.github\workflows\build-windows-msvc.yml'
if (-not (Test-Path -LiteralPath $workflowPath)) {
    Write-Fail 'workflow exists (.github/workflows/build-windows-msvc.yml)'
} else {
    Write-Ok 'workflow exists (.github/workflows/build-windows-msvc.yml)'
    $workflowText = Get-Content -Raw -LiteralPath $workflowPath
    $workflowLines = $workflowText -split "`n"

    Assert-True -Condition ($workflowText -match '(?m)^on:\s*$') -Message 'workflow declares triggers'
    Assert-True -Condition ($workflowText -match '(?m)^\s{2}workflow_dispatch:\s*$') -Message 'workflow supports workflow_dispatch'
    Assert-True -Condition ($workflowText -notmatch '(?m)^\s{2}(push|pull_request|schedule|release):') -Message 'workflow does not run on push, pull_request, schedule or release'
    Assert-True -Condition ($workflowText -match '(?m)^permissions:\s*$' -and $workflowText -match '(?m)^\s{2}contents:\s*read\s*$') -Message 'workflow requests only contents: read'
    Assert-True -Condition ($workflowText -notmatch 'contents:\s*write') -Message 'workflow never requests contents: write'
    Assert-True -Condition ($workflowText -notmatch 'secrets\.') -Message 'workflow does not use repository secrets'
    Assert-True -Condition ($workflowText -match '(?m)^\s{4}runs-on:\s*windows-2022\s*$') -Message 'job runs on the windows-2022 GitHub-hosted runner'
    Assert-True -Condition ($workflowText -match 'if-no-files-found:\s*error') -Message 'artifact upload fails when the bundle is missing'

    $usesList = @()
    foreach ($line in $workflowLines) {
        if ($line -match '^\s*uses:\s*(\S+)') { $usesList += $Matches[1].Trim() }
    }
    Assert-True -Condition ($usesList.Count -gt 0) -Message "workflow uses $($usesList.Count) action(s)"
    foreach ($use in $usesList) {
        $isPinned = $use -match '@[0-9a-f]{40}$'
        Assert-True -Condition $isPinned -Message "action is pinned to a commit SHA ($use)"
    }

    if ($pins) {
        $checkoutLine = 'actions/checkout@' + [string] (Get-PinnedValue -Pins $pins -Path 'githubActions.actions/checkout.sha')
        $uploadLine = 'actions/upload-artifact@' + [string] (Get-PinnedValue -Pins $pins -Path 'githubActions.actions/upload-artifact.sha')
        Assert-True -Condition ($usesList -contains $checkoutLine) -Message "workflow uses the pinned checkout SHA from pins.json"
        Assert-True -Condition ($usesList -contains $uploadLine) -Message "workflow uses the pinned upload-artifact SHA from pins.json"
    }

    $python = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        $probe = & $command.Source -c "import yaml; print('ok')" 2>$null
        if ($LASTEXITCODE -eq 0 -and (($probe -join '') -match 'ok')) {
            $python = $command.Source
            break
        }
    }

    if (-not $python) {
        Write-Skip 'full YAML parse (no Python interpreter with PyYAML was found)'
    } else {
        $snippetPath = Join-Path $env:TEMP ("codex-workflow-check-" + [guid]::NewGuid().ToString('N') + ".py")
        $snippet = @'
import json
import re
import sys

import yaml

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
doc = yaml.safe_load(text)
problems = []

triggers = doc.get("on")
if triggers is None and True in doc:
    triggers = doc[True]
if not isinstance(triggers, dict):
    problems.append("no trigger mapping found")
else:
    if "workflow_dispatch" not in triggers:
        problems.append("workflow_dispatch trigger missing")
    for forbidden in ("push", "pull_request", "schedule", "release"):
        if forbidden in triggers:
            problems.append("unexpected trigger: " + forbidden)

jobs = doc.get("jobs")
if not isinstance(jobs, dict) or not jobs:
    problems.append("no jobs defined")
else:
    for name, job in jobs.items():
        if job.get("runs-on") != "windows-2022":
            problems.append("job %s runs on %r" % (name, job.get("runs-on")))
        for step in job.get("steps", []):
            uses = step.get("uses")
            if uses and not re.search(r"@[0-9a-f]{40}$", uses):
                problems.append("unpinned action: " + uses)

print(json.dumps({"problems": problems, "jobCount": len(jobs or {})}))
'@
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($snippetPath, $snippet, $encoding)
        try {
            $rawResult = (& $python $snippetPath $workflowPath) -join ''
            $exit = $LASTEXITCODE
        } finally {
            Remove-Item -LiteralPath $snippetPath -Force -ErrorAction SilentlyContinue
        }

        if ($exit -ne 0 -or -not $rawResult) {
            Write-Fail 'PyYAML could parse the workflow' -Detail ([string] $rawResult)
        } else {
            $parsed = $rawResult | ConvertFrom-Json
            Assert-True -Condition ($parsed.problems.Count -eq 0) -Message 'workflow parses as YAML with the expected shape' -Detail (($parsed.problems) -join "`n")
        }
    }
}

# ---------------------------------------------------------------------------
# 8. Dry run of the build script
# ---------------------------------------------------------------------------

Write-Head 'build script dry run'
if ($SkipDryRun) {
    Write-Skip 'dry run (-SkipDryRun was given)'
} else {
    $buildScript = Join-Path $repositoryRoot 'build\Build-NativeRuntime.ps1'
    $hostExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
    $hostPath = if ($hostExe) { $hostExe.Source } else { (Get-Command powershell -ErrorAction SilentlyContinue).Source }

    if (-not $hostPath) {
        Write-Fail 'a PowerShell host is available for the dry run'
    } else {
        $dryRunRoot = Join-Path $env:TEMP 'codex-native-build-dryrun'
        $logPath = Join-Path $env:TEMP ("codex-build-dryrun-" + [guid]::NewGuid().ToString('N') + ".log")
        & $hostPath -NoProfile -NonInteractive -File $buildScript -DryRun -WorkRoot $dryRunRoot > $logPath 2>&1
        $dryExit = $LASTEXITCODE
        $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -Raw -LiteralPath $logPath } else { '' }
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

        Assert-Equal -Name 'dry run exits successfully' -Expected '0' -Actual ([string] $dryExit)
        foreach ($marker in @('PLAN', 'pinned commit', 'DRY RUN', 'codex-cli', 'dev-small', 'steps planned')) {
            Assert-True -Condition ($logText -match [regex]::Escape($marker)) -Message "dry run reports '$marker'" -Detail $logText
        }
        if ($pins) {
            $commit = [string] (Get-PinnedValue -Pins $pins -Path 'source.commitSha')
            Assert-True -Condition ($logText -match [regex]::Escape($commit)) -Message 'dry run resolves the pinned commit' -Detail $logText
            $workRootDefault = [string] (Get-PinnedValue -Pins $pins -Path 'paths.workRootDefault')
            Assert-True -Condition ($workRootDefault -eq 'C:/build') -Message 'default work root is the neutral C:/build prefix'
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('Summary: ' + $script:Passed + ' passed, ' + $script:Failed + ' failed, ' + $script:Skipped.Count + ' skipped')
foreach ($note in $script:Skipped) {
    Write-Host ('  skipped: ' + $note)
}

if ($script:Failed -gt 0) {
    Write-Host ''
    Write-Host 'FAILED'
    exit 1
}

Write-Host ''
Write-Host 'PASSED'
exit 0
