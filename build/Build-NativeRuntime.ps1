#requires -Version 5.1
<#
.SYNOPSIS
    Builds the patched Codex CLI (native DeepSeek subagent support) for Windows
    x64 MSVC and assembles a shareable zip bundle.

.DESCRIPTION
    Steps, in order:

      1. Guard the build root and check free disk space.
      2. Install the pinned Rust toolchain into an isolated RUSTUP_HOME/CARGO_HOME.
      3. Fetch the pinned openai/codex commit into an isolated source folder.
      4. Apply patches/codex-native-provider.patch (digest checked first).
      5. Build codex.exe with cargo (locked, no registry credentials).
      6. Optionally run the focused codex-core role tests with cargo-nextest.
      7. Verify and stage the official companion executables, then write the
         bundle: binaries, LICENSE, NOTICE, provenance and SHA256SUMS.

    The script never writes to the caller's Codex configuration, never installs a
    machine-wide toolchain, and only deletes paths that are proven to live under
    -WorkRoot.

.PARAMETER WorkRoot
    Isolated build root. Everything this script creates lives here. The default is
    C:\build, which is also the neutral prefix the binaries are remapped to.

.PARAMETER VirtualRoot
    The neutral path prefix written into the binary with --remap-path-prefix, so a
    finished build does not carry the real build paths. Default: C:/build.

.PARAMETER Profile
    Cargo profile. dev-small (opt-level 0, debug 0, symbols stripped) is the cheap
    default; dev keeps limited debug info; release uses thin LTO and is far slower
    and larger to produce. See build/README.md for the trade-off.

.PARAMETER Offline
    Pass --offline to cargo and skip documentation downloads. Everything must
    already be present in -WorkRoot (see build/README.md, "Offline versus
    downloads").

.PARAMETER PruneBuildOutputs
    After a successful package, delete the cargo target directory under -WorkRoot.
    Opt-in, because it removes the ability to rebuild incrementally.

.PARAMETER DryRun
    Resolve and print the plan without touching the network or the filesystem.

.PARAMETER FixtureBinary
    Test-only route. Instead of building, use the given executable as codex.exe and
    write a receipt marked "kind": "fixture", "publishable": false. Packaging then
    only ever produces a clearly marked fixture bundle: the file name gains a
    -fixture suffix and runtime-manifest.json records kind "fixture". This route is
    for exercising the packaging pipeline in tests. It can never produce a bundle
    that looks like a real release, and the workflow never passes it.

.NOTES
    Windows only. Requires git and rustup on PATH. PowerShell 7 (pwsh) is
    recommended; Windows PowerShell 5.1 is supported.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $PinsPath,
    [string] $WorkRoot = 'C:\build',
    [string] $VirtualRoot,
    [ValidateSet('dev-small', 'dev', 'release')]
    [string] $Profile,
    [string] $TargetTriple,
    [string] $Toolchain,
    [string] $OutputRoot,
    [string] $BundleName,
    [int] $MinimumFreeGiB = 45,
    [int] $Jobs = 4,
    [switch] $SkipToolchainInstall,
    [switch] $SkipSourceFetch,
    [switch] $SkipBuild,
    [switch] $SkipTests,
    [switch] $SkipPackage,
    [switch] $SkipMsvcEnvironment,
    [switch] $IncludeIntegrationTests,
    [string] $FixtureBinary,
    [switch] $Offline,
    [switch] $AllowPatchDigestMismatch,
    [switch] $PruneBuildOutputs,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:StepCounter = 0
$script:TotalSteps = 7
$script:IsWindowsHost = if ($PSVersionTable.PSEdition -eq 'Core') { $IsWindows } else { $true }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)] [string] $Message)
    $script:StepCounter++
    Write-Host ''
    Write-Host ("==> [{0}/{1}] {2}" -f $script:StepCounter, $script:TotalSteps, $Message)
}

function Write-Note {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host ("    - " + $Message)
}

function Write-WarnMsg {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host ("WARNING: " + $Message)
}

# ---------------------------------------------------------------------------
# Small path and file helpers
# ---------------------------------------------------------------------------

function Get-NormalizedPath {
    param([Parameter(Mandatory)] [string] $Path)
    return $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
}

function Get-FullPath {
    param([Parameter(Mandatory)] [string] $Path)
    return [System.IO.Path]::GetFullPath((Get-NormalizedPath -Path $Path))
}

function Join-RelPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Relative
    )
    return (Join-Path $Root (Get-NormalizedPath -Path $Relative))
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root
    )
    $candidate = (Get-FullPath -Path $Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $rootFull = (Get-FullPath -Path $Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ($candidate.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $candidate.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Purpose
    )
    if (-not (Test-PathUnderRoot -Path $Path -Root $Root)) {
        throw "$Purpose refused: '$Path' is not inside the build root '$Root'."
    }
}

function Remove-TreeUnderRoot {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-PathUnderRoot -Path $Path -Root $Root -Purpose 'Recursive delete'
    $full = Get-FullPath -Path $Path
    $rootFull = Get-FullPath -Path $Root
    if ($full.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Equals($rootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Recursive delete refused: '$full' is the build root itself."
    }
    Write-Note "Removing $full"
    Remove-Item -LiteralPath $full -Recurse -Force
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Text
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)] [string] $BasePath,
        [Parameter(Mandatory)] [string] $Path
    )
    $base = (Get-FullPath -Path $BasePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $full = Get-FullPath -Path $Path
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot make '$full' relative to '$BasePath'."
    }
    return $full.Substring($base.Length).Replace('\', '/')
}

function Get-PinnedValue {
    param(
        [Parameter(Mandatory)] [object] $Pins,
        [Parameter(Mandatory)] [string] $Path
    )
    $node = $Pins
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node) {
            throw "build/pins.json is missing '$Path'."
        }
        $property = $node.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "build/pins.json is missing '$Path' (no '$segment')."
        }
        $node = $property.Value
    }
    return $node
}

function Get-CommandPathOrNull {
    param([Parameter(Mandatory)] [string] $Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $null }
    return $command.Source
}

function Add-GitHubOutput {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )
    if (-not $env:GITHUB_OUTPUT) { return }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, ("{0}={1}`n" -f $Name, $Value), $encoding)
}

function Add-StepSummary {
    param([Parameter(Mandatory)] [string] $Markdown)
    if (-not $env:GITHUB_STEP_SUMMARY) { return }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, ($Markdown + "`n"), $encoding)
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

function Import-MsvcEnvironment {
    param([Parameter(Mandatory)] [string] $TempDir)

    if (-not $script:IsWindowsHost) {
        Write-WarnMsg 'Not running on Windows; skipping the MSVC environment import.'
        return $false
    }

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) { $programFilesX86 = $env:ProgramFiles }
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        Write-WarnMsg "vswhere.exe was not found at '$vswhere'. Continuing with the current environment."
        return $false
    }

    $installPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) -join "`n"
    $installPath = $installPath.Trim()
    if (-not $installPath) {
        Write-WarnMsg 'vswhere.exe reported no Visual Studio installation with the C++ tools. Continuing with the current environment.'
        return $false
    }

    $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) {
        Write-WarnMsg "vcvars64.bat was not found at '$vcvars'. Continuing with the current environment."
        return $false
    }

    if (-not (Test-Path -LiteralPath $TempDir)) {
        New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    }
    $helperCmd = Join-Path $TempDir ("msvc-env-" + [guid]::NewGuid().ToString('N') + ".cmd")
    $helperText = "@echo off`r`ncall `"$vcvars`" >nul`r`nset`r`n"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($helperCmd, $helperText, $encoding)

    try {
        $rawLines = & $env:ComSpec /c $helperCmd
    } finally {
        Remove-Item -LiteralPath $helperCmd -Force -ErrorAction SilentlyContinue
    }

    $applied = 0
    foreach ($line in @($rawLines)) {
        $text = [string] $line
        $index = $text.IndexOf('=')
        if ($index -lt 1) { continue }
        $key = $text.Substring(0, $index)
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_()]*$') { continue }
        $value = $text.Substring($index + 1)
        Set-Item -Path ("env:" + $key) -Value $value
        $applied++
    }

    if ($applied -eq 0) {
        Write-WarnMsg 'vcvars64.bat produced no environment variables. Continuing with the current environment.'
        return $false
    }

    Write-Note ("MSVC environment imported from $vcvars ($applied variables)")
    return $true
}

function Assert-CleanCargoHome {
    param([Parameter(Mandatory)] [string] $CargoHome)

    foreach ($name in @('credentials.toml', 'credentials')) {
        $path = Join-Path $CargoHome $name
        if (Test-Path -LiteralPath $path) {
            throw "Refusing to build: '$path' exists and could supply registry credentials. Point -WorkRoot at an empty, isolated folder."
        }
    }

    $tokenNames = @(
        'CARGO_REGISTRY_TOKEN',
        'CARGO_REGISTRIES_CRATES_IO_TOKEN',
        'CARGO_REGISTRIES_CRATES_IO_SECRET_KEY',
        'CARGO_HTTP_TOKEN',
        'RUSTUP_TOKEN'
    )
    $cleared = @()
    foreach ($name in $tokenNames) {
        if (Test-Path -LiteralPath ("env:" + $name)) {
            Remove-Item -LiteralPath ("env:" + $name)
            $cleared += $name
        }
    }
    if ($cleared.Count -gt 0) {
        Write-Note ("Cleared credential environment variables for this process: " + ($cleared -join ', '))
    }
}

function Assert-FreeDiskSpace {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int] $MinimumGiB,
        [switch] $InformationalOnly
    )

    $full = Get-FullPath -Path $Path
    try {
        $root = [System.IO.Path]::GetPathRoot($full)
        $drive = New-Object System.IO.DriveInfo($root)
        $freeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
        $totalGiB = [math]::Round($drive.TotalSize / 1GB, 2)
    } catch {
        Write-WarnMsg "Could not read free disk space for '$full': $($_.Exception.Message)"
        return
    }

    Write-Note ("Free space on $root : $freeGiB GiB of $totalGiB GiB (minimum for this build: $MinimumGiB GiB)")
    if ($freeGiB -lt $MinimumGiB) {
        $message = "Only $freeGiB GiB is free on $root, but this build wants at least $MinimumGiB GiB (a debug-style codex-cli build plus registry cache). Use a roomier -WorkRoot, or lower -MinimumFreeGiB if you know what you are trading away."
        if ($InformationalOnly) {
            Write-WarnMsg "$message (dry run: not failing)"
        } else {
            throw $message
        }
    }
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [long] $ExpectedSize = -1
    )

    $expected = $ExpectedSha256.ToLowerInvariant()
    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Sha256 -Path $Destination) -eq $expected) {
            Write-Note ("Using cached download: $([System.IO.Path]::GetFileName($Destination))")
            return
        }
        Write-WarnMsg ("Cached file did not match the expected digest and will be replaced: $Destination")
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $partial = $Destination + '.partial'
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    Write-Note ("Downloading $Url")
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial -TimeoutSec 900

    if ($ExpectedSize -gt 0) {
        $actualSize = (Get-Item -LiteralPath $partial).Length
        if ($actualSize -ne $ExpectedSize) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw "Downloaded '$Url' is $actualSize bytes, but $ExpectedSize bytes were expected."
        }
    }

    $actual = Get-Sha256 -Path $partial
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch for '$Url'. Expected $expected, got $actual."
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
    Write-Note ("Verified SHA256 $actual")
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

function Assert-SafeWorkRoot {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RepositoryRoot
    )

    $full = Get-FullPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Equals($root.TrimEnd([System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a drive root as -WorkRoot: '$full'. Give it a folder, for example C:\build."
    }
    if ($full.Split([System.IO.Path]::DirectorySeparatorChar).Count -lt 2) {
        throw "Refusing to use '$full' as -WorkRoot: it is too close to the drive root to be a safe place to delete things in."
    }
    if (Test-PathUnderRoot -Path $full -Root $RepositoryRoot) {
        throw "Refusing to use '$full' as -WorkRoot: it is inside the repository checkout '$RepositoryRoot'. Keep build output out of the source tree."
    }

    $userProfile = $env:USERPROFILE
    if ($userProfile) {
        $profileFull = (Get-FullPath -Path $userProfile).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($full.TrimEnd([System.IO.Path]::DirectorySeparatorChar).Equals($profileFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use the user profile itself as -WorkRoot: '$full'."
        }
    }
    foreach ($protected in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $protected) { continue }
        if (Test-PathUnderRoot -Path $full -Root $protected) {
            throw "Refusing to use '$full' as -WorkRoot: it is inside '$protected'."
        }
    }
}

function New-BuildPlan {
    param(
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $PinnedFile,
        [Parameter(Mandatory)] [string] $ResolvedWorkRoot,
        [Parameter(Mandatory)] [string] $ResolvedVirtualRoot,
        [Parameter(Mandatory)] [string] $ResolvedProfile,
        [Parameter(Mandatory)] [string] $ResolvedTargetTriple,
        [Parameter(Mandatory)] [string] $ResolvedToolchain,
        [string] $ResolvedOutputRoot,
        [string] $ResolvedBundleName
    )

    if (-not (Test-Path -LiteralPath $PinnedFile)) {
        throw "Pins file not found: $PinnedFile"
    }
    $pins = Get-Content -Raw -LiteralPath $PinnedFile | ConvertFrom-Json

    $layoutSource = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'source.checkoutLayout')
    $cargoHome = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.cargoHome')
    $rustupHome = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.rustupHome')
    $targetDir = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.targetDir')
    $toolRoot = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.tools')
    $downloadRoot = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.downloads')
    $patchRoot = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.patches')
    $stageRoot = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.stage')
    $tempDir = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.temp')
    $stateDir = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.state')
    if (-not $ResolvedOutputRoot) {
        $ResolvedOutputRoot = Join-RelPath -Root $ResolvedWorkRoot -Relative (Get-PinnedValue -Pins $pins -Path 'paths.layout.dist')
    }

    $version = [string] (Get-PinnedValue -Pins $pins -Path 'source.workspaceVersion')
    if (-not $ResolvedBundleName) {
        $template = [string] (Get-PinnedValue -Pins $pins -Path 'bundle.nameTemplate')
        $ResolvedBundleName = $template.Replace('{version}', $version)
    }
    # A fixture run must never produce a bundle that could be mistaken for a
    # real release, so its name and its manifest kind both say "fixture".
    $fixtureMode = [bool] $FixtureBinary
    if ($fixtureMode -and $ResolvedBundleName -notlike '*-fixture') {
        $ResolvedBundleName = $ResolvedBundleName + '-fixture'
    }

    $patchSourcePath = Join-RelPath -Root $RepositoryRoot -Relative (Get-PinnedValue -Pins $pins -Path 'patch.path')
    $manifestPath = Join-RelPath -Root $RepositoryRoot -Relative (Get-PinnedValue -Pins $pins -Path 'helperManifest.path')

    $profileDirName = switch ($ResolvedProfile) {
        'dev' { 'debug' }
        'dev-small' { 'dev-small' }
        'release' { 'release' }
        default { $ResolvedProfile }
    }

    # RUSTFLAGS replaces the repository's target rustflags completely, so the
    # MSVC flags from codex-rs/.cargo/config.toml are restated here and checked
    # again after the checkout.
    $remapPairs = @(
        [pscustomobject]@{ Real = $layoutSource; Virtual = ($ResolvedVirtualRoot.TrimEnd('/') + '/src/codex') },
        [pscustomobject]@{ Real = $cargoHome; Virtual = ($ResolvedVirtualRoot.TrimEnd('/') + '/cargo') },
        [pscustomobject]@{ Real = $rustupHome; Virtual = ($ResolvedVirtualRoot.TrimEnd('/') + '/rustup') },
        [pscustomobject]@{ Real = $targetDir; Virtual = ($ResolvedVirtualRoot.TrimEnd('/') + '/target') },
        [pscustomobject]@{ Real = $RepositoryRoot; Virtual = ($ResolvedVirtualRoot.TrimEnd('/') + '/repo') }
    )

    $rustFlags = @(
        '-C', 'link-arg=/STACK:8388608',
        '-C', 'target-feature=+crt-static'
    )
    foreach ($pair in $remapPairs) {
        $rustFlags += ('--remap-path-prefix=' + $pair.Real + '=' + $pair.Virtual)
    }

    $plan = [pscustomobject]@{
        RepoRoot       = $RepositoryRoot
        PinsPath       = $PinnedFile
        Pins           = $pins
        WorkRoot       = Get-FullPath -Path $ResolvedWorkRoot
        VirtualRoot    = $ResolvedVirtualRoot
        Version        = $version
        BundleName     = $ResolvedBundleName
        BundleZip      = Join-Path $ResolvedOutputRoot ($ResolvedBundleName + '.zip')
        OutputRoot     = Get-FullPath -Path $ResolvedOutputRoot
        SourceUrl      = [string] (Get-PinnedValue -Pins $pins -Path 'source.repositoryUrl')
        SourceTag      = [string] (Get-PinnedValue -Pins $pins -Path 'source.tag')
        SourceTagSha   = [string] (Get-PinnedValue -Pins $pins -Path 'source.tagObjectSha')
        SourceCommit   = [string] (Get-PinnedValue -Pins $pins -Path 'source.commitSha')
        SourceDir      = Get-FullPath -Path $layoutSource
        WorkspaceDir   = Get-FullPath -Path (Join-Path $layoutSource 'codex-rs')
        CargoHome      = Get-FullPath -Path $cargoHome
        RustupHome     = Get-FullPath -Path $rustupHome
        TargetDir      = Get-FullPath -Path $targetDir
        ToolRoot       = Get-FullPath -Path $toolRoot
        DownloadRoot   = Get-FullPath -Path $downloadRoot
        PatchRoot      = Get-FullPath -Path $patchRoot
        StageRoot      = Get-FullPath -Path $stageRoot
        TempDir        = Get-FullPath -Path $tempDir
        StateDir       = Get-FullPath -Path $stateDir
        FixtureMode    = $fixtureMode
        PatchSource    = $patchSourcePath
        ManifestPath   = $manifestPath
        Profile        = $ResolvedProfile
        ProfileDirName = $profileDirName
        TargetTriple   = $ResolvedTargetTriple
        Toolchain      = $ResolvedToolchain
        Jobs           = $Jobs
        RemapPairs     = $remapPairs
        RustFlags      = $rustFlags
        CliBinaryName  = [string] (Get-PinnedValue -Pins $pins -Path 'bundle.cliBinaryName')
    }

    $plan | Add-Member -NotePropertyName CliBinaryPath -NotePropertyValue (Get-FullPath -Path (Join-Path $plan.TargetDir (Join-Path $ResolvedTargetTriple (Join-Path $profileDirName $plan.CliBinaryName))))
    $plan | Add-Member -NotePropertyName ReceiptPath -NotePropertyValue (Get-FullPath -Path (Join-Path $plan.StateDir ([string] (Get-PinnedValue -Pins $pins -Path 'buildReceipt.fileName'))))
    return $plan
}

function Write-BuildPlan {
    param([Parameter(Mandatory)] [object] $Plan)

    Write-Host ''
    Write-Host 'PLAN'
    Write-Note ("repository        : " + $Plan.SourceUrl)
    Write-Note ("pinned tag        : " + $Plan.SourceTag + " (tag object " + $Plan.SourceTagSha + ")")
    Write-Note ("pinned commit     : " + $Plan.SourceCommit)
    Write-Note ("patch             : " + $Plan.PatchSource)
    Write-Note ("build root        : " + $Plan.WorkRoot)
    Write-Note ("source checkout   : " + $Plan.SourceDir)
    Write-Note ("cargo home        : " + $Plan.CargoHome)
    Write-Note ("rustup home       : " + $Plan.RustupHome)
    Write-Note ("target directory  : " + $Plan.TargetDir)
    Write-Note ("cargo profile     : " + $Plan.Profile + " (output folder '" + $Plan.ProfileDirName + "')")
    Write-Note ("toolchain         : " + $Plan.Toolchain + " (rustup profile minimal)")
    Write-Note ("target triple     : " + $Plan.TargetTriple)
    Write-Note ("parallel jobs     : " + $Plan.Jobs)
    Write-Note ("bundle            : " + $Plan.BundleZip)
    foreach ($pair in $Plan.RemapPairs) {
        Write-Note ("remap path prefix : " + $pair.Real + " -> " + $pair.Virtual)
    }
    Write-Note ("expected binary   : " + $Plan.CliBinaryPath)
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Get-NormalizedPatchText {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Patch file not found: $Path"
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    $normalized = ($raw -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n")) {
        $normalized += "`n"
    }
    return $normalized
}

function Step-Toolchain {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    Write-Step "Rust toolchain: $($Plan.Toolchain) into $($Plan.RustupHome)"

    if ($SkipToolchainInstall) {
        Write-Note 'Skipping the toolchain install because -SkipToolchainInstall was given.'
        return
    }

    $rustup = Get-CommandPathOrNull -Name 'rustup'
    if (-not $rustup) {
        if ($DryRun) {
            Write-WarnMsg 'rustup was not found on PATH; the dry run can still show the plan.'
        } else {
            throw 'rustup was not found on PATH. Install rustup, or run this step on a machine that has it.'
        }
    }
    if ($rustup) { Write-Note "rustup: $rustup" }
    if ($DryRun) {
        Write-Note "Dry run: would run 'rustup toolchain install $($Plan.Toolchain) --profile minimal --no-self-update' with RUSTUP_HOME=$($Plan.RustupHome) and CARGO_HOME=$($Plan.CargoHome)."
        return
    }

    & rustup toolchain install $Plan.Toolchain --profile minimal --no-self-update
    if ($LASTEXITCODE -ne 0) {
        throw "rustup toolchain install exited with code $LASTEXITCODE."
    }

    $cargoVersion = (& cargo --version) -join ' '
    $rustcVersion = (& rustc --version) -join ' '
    Write-Note "cargo: $cargoVersion"
    Write-Note "rustc: $rustcVersion"

    $expectedRust = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'toolchain.rustVersion')
    if ($rustcVersion -notmatch [regex]::Escape($expectedRust)) {
        throw "rustc reported '$rustcVersion', which does not contain the pinned version '$expectedRust'."
    }
}

function Step-Source {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    Write-Step "Source checkout at $($Plan.SourceCommit)"
    $git = Get-CommandPathOrNull -Name 'git'
    if (-not $git -and -not $DryRun) {
        throw 'git was not found on PATH.'
    }
    if (-not $git) {
        Write-WarnMsg 'git was not found on PATH; the dry run can still show the plan.'
    }

    $headPath = Join-Path $Plan.SourceDir '.git'
    $currentCommit = $null
    if (Test-Path -LiteralPath $headPath) {
        $currentCommit = (& git -C $Plan.SourceDir rev-parse HEAD 2>$null) -join ''
        if ($currentCommit) { $currentCommit = $currentCommit.Trim() }
    }

    if ($SkipSourceFetch -or ($currentCommit -eq $Plan.SourceCommit)) {
        if ($currentCommit -eq $Plan.SourceCommit) {
            Write-Note "Reusing the existing checkout at $($Plan.SourceDir)"
        } else {
            Write-Note 'Skipping the source fetch because -SkipSourceFetch was given.'
        }
    } elseif ($DryRun) {
        Write-Note "Dry run: would fetch $($Plan.SourceUrl) at $($Plan.SourceCommit) into $($Plan.SourceDir)."
    } else {
        if (Test-Path -LiteralPath $Plan.SourceDir) {
            Remove-TreeUnderRoot -Path $Plan.SourceDir -Root $Plan.WorkRoot
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Plan.SourceDir) | Out-Null

        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        try {
            & git init --quiet $Plan.SourceDir
            if ($LASTEXITCODE -ne 0) { throw "git init failed with code $LASTEXITCODE." }
            & git -C $Plan.SourceDir remote add origin $Plan.SourceUrl
            if ($LASTEXITCODE -ne 0) { throw "git remote add failed with code $LASTEXITCODE." }
            & git -C $Plan.SourceDir config core.autocrlf false
            & git -C $Plan.SourceDir config core.eol lf
            & git -C $Plan.SourceDir config core.longpaths true
            & git -C $Plan.SourceDir config advice.detachedHead false

            # Fetch the pinned commit directly when the server allows it, and
            # fall back to the pinned tag ref. Either way the commit is checked
            # against build/pins.json below.
            $fetchTargets = @($Plan.SourceCommit, ('refs/tags/' + $Plan.SourceTag))
            $fetchLog = Join-Path $Plan.TempDir 'git-fetch.log'
            $fetched = $false
            foreach ($target in $fetchTargets) {
                & git -C $Plan.SourceDir fetch --depth 1 --no-tags origin $target 2> $fetchLog > $null
                if ($LASTEXITCODE -eq 0) {
                    $fetched = $true
                    Write-Note "Fetched '$target'"
                    break
                }
                Write-WarnMsg "Fetching '$target' failed; trying the next pinned reference."
            }
            if (-not $fetched) {
                if (Test-Path -LiteralPath $fetchLog) {
                    foreach ($line in @(Get-Content -LiteralPath $fetchLog)) { Write-Note ([string] $line) }
                }
                throw "git fetch failed for every pinned reference: $($fetchTargets -join ', ')."
            }

            $fetchedCommit = ((& git -C $Plan.SourceDir rev-parse 'FETCH_HEAD^{commit}') -join '').Trim()
            if ($LASTEXITCODE -ne 0 -or -not $fetchedCommit) {
                throw 'Could not resolve FETCH_HEAD to a commit after fetching.'
            }
            & git -C $Plan.SourceDir checkout --detach --quiet $fetchedCommit
            if ($LASTEXITCODE -ne 0) { throw "git checkout failed with code $LASTEXITCODE." }
        } finally {
            Remove-Item -LiteralPath env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
        }
    }

    if ($DryRun) { return }

    $head = (& git -C $Plan.SourceDir rev-parse HEAD) -join ''
    $head = $head.Trim()
    if ($head -ne $Plan.SourceCommit) {
        throw "The checkout at $($Plan.SourceDir) is at $head, but the pinned commit is $($Plan.SourceCommit)."
    }
    Write-Note "HEAD matches the pinned commit."

    # A dirty tree is allowed here because a re-run reuses its work root and the
    # patch from the previous run is still applied. Step-Patch decides whether
    # the modified files are exactly the expected ones.
    $status = @(& git -C $Plan.SourceDir status --porcelain)
    if ($status.Count -ne 0) {
        Write-Note "The checkout has $($status.Count) modified file(s); Step-Patch will confirm they are the expected patch."
    }

    if ($Offline) {
        Write-WarnMsg 'Offline mode: skipping the tag-to-commit check against the remote.'
    } else {
        $remoteTagLines = @(& git ls-remote $Plan.SourceUrl ("refs/tags/" + $Plan.SourceTag) ("refs/tags/" + $Plan.SourceTag + '^{}') 2>$null)
        $peeled = $null
        foreach ($line in $remoteTagLines) {
            if ($line -match ('\^\{' + [regex]::Escape('}') + '\s*$')) {
                $peeled = ($line -split "`t")[0].Trim()
            }
        }
        if (-not $peeled) {
            foreach ($line in $remoteTagLines) {
                if ($line -match '\s+refs/tags/') {
                    $candidate = ($line -split "`t")[0].Trim()
                    if ($candidate -match '^[0-9a-f]{40}$') { $peeled = $candidate }
                }
            }
        }
        if ($peeled -and $peeled -ne $Plan.SourceCommit) {
            throw "Tag $($Plan.SourceTag) currently points at $peeled, but build/pins.json pins $($Plan.SourceCommit). Refresh the pins deliberately if the tag really moved."
        }
        if ($peeled) {
            Write-Note "Tag $($Plan.SourceTag) resolves to the pinned commit."
        } else {
            Write-WarnMsg "Could not resolve tag $($Plan.SourceTag) remotely; the pinned commit itself was verified."
        }
    }
}

function Step-Patch {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    Write-Step "Apply $([System.IO.Path]::GetFileName($Plan.PatchSource))"

    $text = Get-NormalizedPatchText -Path $Plan.PatchSource
    $normalizedPath = Join-Path $Plan.PatchRoot (([System.IO.Path]::GetFileNameWithoutExtension($Plan.PatchSource)) + '.lf.patch')

    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $Plan.PatchRoot)) {
            New-Item -ItemType Directory -Force -Path $Plan.PatchRoot | Out-Null
        }
        Write-Utf8NoBom -Path $normalizedPath -Text $text
    }

    $actualDigest = if ($DryRun) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    } else {
        Get-Sha256 -Path $normalizedPath
    }
    $expectedDigest = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'patch.sha256')
    if ($actualDigest -ne $expectedDigest) {
        $message = "Patch digest mismatch: build/pins.json says $expectedDigest but the normalized patch is $actualDigest. Update build/pins.json if the patch change is intended."
        if ($AllowPatchDigestMismatch) {
            Write-WarnMsg $message
        } else {
            throw $message
        }
    } else {
        Write-Note "Patch SHA256 (normalized) $actualDigest"
    }

    $expectedFiles = @(Get-PinnedValue -Pins $Plan.Pins -Path 'patch.expectedChangedFiles')

    if ($DryRun) {
        Write-Note "Dry run: would run 'git apply --check' and then 'git apply' in $($Plan.SourceDir)."
        Write-Note ("Dry run: expected changed files: " + ($expectedFiles -join ', '))
        return
    }

    $git = Get-CommandPathOrNull -Name 'git'
    if (-not $git) {
        throw 'git was not found on PATH.'
    }

    # Output is captured through files instead of stream merging so the script
    # behaves the same under Windows PowerShell 5.1 and PowerShell 7.
    $checkLog = Join-Path $Plan.TempDir 'git-apply-check.log'
    $reverseLog = Join-Path $Plan.TempDir 'git-apply-reverse.log'
    & git -C $Plan.SourceDir apply --check --whitespace=nowarn $normalizedPath 2> $checkLog > $null
    $checkExit = $LASTEXITCODE
    if ($checkExit -ne 0) {
        $reverseOk = $false
        & git -C $Plan.SourceDir apply --check --reverse --whitespace=nowarn $normalizedPath 2> $reverseLog > $null
        if ($LASTEXITCODE -eq 0) { $reverseOk = $true }
        if ($reverseOk) {
            Write-Note 'The patch is already applied to this checkout; continuing.'
        } else {
            foreach ($logPath in @($checkLog, $reverseLog)) {
                if (Test-Path -LiteralPath $logPath) {
                    foreach ($line in @(Get-Content -LiteralPath $logPath)) { Write-Note ([string] $line) }
                }
            }
            throw "git apply --check failed with code $checkExit. The checkout does not match the expected base state."
        }
    } else {
        & git -C $Plan.SourceDir apply --whitespace=nowarn $normalizedPath 2> $checkLog > $null
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $checkLog) {
                foreach ($line in @(Get-Content -LiteralPath $checkLog)) { Write-Note ([string] $line) }
            }
            throw "git apply failed with code $LASTEXITCODE."
        }
        Write-Note 'Patch applied.'
    }

    $changed = @()
    foreach ($line in @(& git -C $Plan.SourceDir status --porcelain)) {
        if (-not $line) { continue }
        $entry = [string] $line
        if ($entry.StartsWith('??')) {
            throw "Unexpected untracked file after patching: $entry"
        }
        $changed += ($entry.Substring(3).Trim() -replace '\\', '/')
    }
    $expectedSorted = @($expectedFiles | Sort-Object)
    $changedSorted = @($changed | Sort-Object)
    if (($expectedSorted -join '|') -ne ($changedSorted -join '|')) {
        throw "The patched file list is not what build/pins.json expects.`nExpected: $($expectedSorted -join ', ')`nActual  : $($changedSorted -join ', ')"
    }
    Write-Note ("Changed files: " + ($changedSorted -join ', '))
}

function Step-Build {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    Write-Step "Build codex.exe ($($Plan.Profile), $($Plan.TargetTriple))"

    if (-not $DryRun) {
        $cargoConfigPath = Join-Path $Plan.WorkspaceDir '.cargo\config.toml'
        if (Test-Path -LiteralPath $cargoConfigPath) {
            $configText = Get-Content -Raw -LiteralPath $cargoConfigPath
            foreach ($expected in @('crt-static', 'STACK:8388608')) {
                if ($configText -notmatch [regex]::Escape($expected)) {
                    Write-WarnMsg "codex-rs/.cargo/config.toml no longer mentions '$expected'; the RUSTFLAGS list in this script may need updating."
                }
            }
        }
    }

    $cargoArgs = @(
        'build',
        '-p', 'codex-cli',
        '--bin', 'codex',
        '--locked',
        '--profile', $Plan.Profile,
        '--target', $Plan.TargetTriple,
        '--config', ("profile." + $Plan.Profile + ".incremental=false")
    )
    if ($Plan.Profile -eq 'dev') {
        $cargoArgs += @('--config', 'profile.dev.debug=0')
    }
    if ($Offline) {
        $cargoArgs += '--offline'
    }

    if ($DryRun) {
        Write-Note ("Dry run: would run 'cargo " + ($cargoArgs -join ' ') + "' in " + $Plan.WorkspaceDir)
        Write-Note ("Dry run: RUSTFLAGS = " + ($Plan.RustFlags -join ' '))
        return
    }

    Write-Note ("cargo " + ($cargoArgs -join ' '))
    Push-Location $Plan.WorkspaceDir
    try {
        & cargo @cargoArgs
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "cargo build exited with code $exit."
    }

    $binary = Get-BuiltCliBinary -Plan $Plan
    $sizeMiB = [math]::Round((Get-Item -LiteralPath $binary).Length / 1MB, 1)
    Write-Note ("Built $binary ($sizeMiB MiB)")

    # The receipt is written here and nowhere else: cargo exited 0 and the
    # executable was located. Packaging refuses to run without a matching one.
    Write-BuildReceipt -Plan $Plan -BinaryPath $binary -Kind 'source-build' | Out-Null
}

function Get-BuiltCliBinary {
    param([Parameter(Mandatory)] [object] $Plan)

    if (Test-Path -LiteralPath $Plan.CliBinaryPath) {
        return $Plan.CliBinaryPath
    }
    $searchRoot = Join-Path $Plan.TargetDir $Plan.TargetTriple
    if (Test-Path -LiteralPath $searchRoot) {
        $found = @(Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter $Plan.CliBinaryName |
            Where-Object { $_.Directory.Name -in @($Plan.ProfileDirName, $Plan.Profile) })
        $distinct = @($found | Select-Object -ExpandProperty FullName -Unique)
        if ($distinct.Count -eq 1) {
            return $distinct[0]
        }
        if ($distinct.Count -gt 1) {
            throw "More than one $($Plan.CliBinaryName) matched: $($distinct -join ', ')"
        }
    }
    throw "The build finished but $($Plan.CliBinaryName) was not found under $searchRoot."
}

function Install-Nextest {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    $version = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'nextest.version')
    $installDir = Join-Path $Plan.ToolRoot 'nextest'
    $exePath = Join-Path $installDir 'cargo-nextest.exe'

    if (Test-Path -LiteralPath $exePath) {
        Write-Note "Reusing cargo-nextest at $exePath"
        return $exePath
    }

    if ($DryRun) {
        Write-Note "Dry run: would download cargo-nextest $version into $installDir."
        return $exePath
    }

    if ($Offline) {
        throw "cargo-nextest is not present at $exePath and -Offline was given. Pre-stage it, or run without -Offline."
    }

    $url = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'nextest.url')
    $sha = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'nextest.sha256')
    $size = [long] (Get-PinnedValue -Pins $Plan.Pins -Path 'nextest.sizeBytes')
    $asset = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'nextest.assetName')
    $archive = Join-Path $Plan.DownloadRoot $asset

    Invoke-FileDownload -Url $url -Destination $archive -ExpectedSha256 $sha -ExpectedSize $size

    $extractDir = Join-Path $Plan.ToolRoot ("nextest-extract-" + $version)
    Remove-TreeUnderRoot -Path $extractDir -Root $Plan.WorkRoot
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force

    $extracted = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter 'cargo-nextest.exe')
    if ($extracted.Count -ne 1) {
        throw "Expected exactly one cargo-nextest.exe in $archive but found $($extracted.Count)."
    }
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Move-Item -LiteralPath $extracted[0].FullName -Destination $exePath -Force
    Write-Note "cargo-nextest $version installed at $exePath"
    return $exePath
}

function Resolve-RustModuleFile {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Segment
    )
    # A module declared as `mod x;` lives either in <dir>/x.rs or in <dir>/x/mod.rs.
    $flat = Join-Path $Directory ($Segment + '.rs')
    if (Test-Path -LiteralPath $flat -PathType Leaf) {
        return [pscustomobject]@{ File = $flat; ChildDirectory = (Join-Path $Directory $Segment) }
    }
    $nested = Join-Path (Join-Path $Directory $Segment) 'mod.rs'
    if (Test-Path -LiteralPath $nested -PathType Leaf) {
        return [pscustomobject]@{ File = $nested; ChildDirectory = (Join-Path $Directory $Segment) }
    }
    return $null
}

function Assert-TestFilterModulesExist {
    param([Parameter(Mandatory)] [object] $Plan)

    # The nextest filters are compiled module paths. If one is changed back to a
    # file name (for example 'agent::role_tests'), the filter would match zero
    # tests. Resolve every unit filter against the checked-out source first, so a
    # stale filter fails with a clear message instead of a confusing empty run.
    $coreSrcRoot = Join-Path $Plan.WorkspaceDir 'core\src'
    if (-not (Test-Path -LiteralPath $coreSrcRoot)) {
        throw "Cannot verify the test filters: $coreSrcRoot does not exist."
    }

    $filters = @(Get-PinnedValue -Pins $Plan.Pins -Path 'tests.unitFilters')
    foreach ($filter in $filters) {
        # Use the PowerShell -split operator rather than String.Split. On
        # Windows PowerShell 5.1, "a::b::c".Split('::') binds to Split(char[])
        # and splits on each ':' separately, producing empty segments, so the
        # path would be read wrongly. -split takes the two-character delimiter
        # literally and behaves identically on 5.1 and 7.x.
        $segments = @($filter -split '::')
        if ($segments.Count -lt 2) {
            throw "Test filter '$filter' is not a module path of the form a::b::tests."
        }

        $currentFile = Join-Path $coreSrcRoot 'lib.rs'
        $currentDirectory = $coreSrcRoot
        $missing = @()

        for ($index = 0; $index -lt $segments.Count; $index++) {
            $segment = $segments[$index]
            if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) {
                $missing += "$segment (no parent file $currentFile)"
                break
            }
            $text = [System.IO.File]::ReadAllText($currentFile)
            $pattern = '(?m)^\s*(?:pub(?:\((?:crate|super)\))?\s+)?mod\s+' + [regex]::Escape($segment) + '\s*[;{]'
            if ($text -notmatch $pattern) {
                $missing += ("$segment (not declared in " + (Get-RelativePath -BasePath $Plan.WorkspaceDir -Path $currentFile) + ')')
                break
            }

            if ($index -eq ($segments.Count - 1)) { break }

            $resolved = Resolve-RustModuleFile -Directory $currentDirectory -Segment $segment
            if (-not $resolved) {
                $missing += ("$segment (no $segment.rs or $segment/mod.rs under $currentDirectory)")
                break
            }
            $currentFile = $resolved.File
            $currentDirectory = $resolved.ChildDirectory
        }

        if ($missing.Count -gt 0) {
            throw ("Test filter '" + $filter + "' does not resolve to a module in the checked-out source: " + ($missing -join '; ') + ". Filters must be compiled module paths (for example agent::role::tests), not file names.")
        }
        Write-Note "Test filter resolves to a module: $filter"
    }
}

function Get-TestFilterset {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [switch] $IncludeIntegration
    )

    # nextest's test(<pattern>) predicate matches the compiled test name, which is
    # the module path plus the function name. Patterns are OR-ed together.
    $patterns = @(Get-PinnedValue -Pins $Plan.Pins -Path 'tests.unitFilters')
    if ($IncludeIntegration) {
        $patterns += @(Get-PinnedValue -Pins $Plan.Pins -Path 'tests.integrationFilters')
    }
    $terms = @($patterns | ForEach-Object { 'test(' + $_ + ')' })
    return ($terms -join ' | ')
}

function Step-Tests {
    param([Parameter(Mandatory)] [object] $Plan, [switch] $DryRun)

    Write-Step 'Run the focused codex-core tests with cargo-nextest'
    $exePath = Install-Nextest -Plan $Plan -DryRun:$DryRun

    $targetArgs = @('--lib')
    if ($IncludeIntegrationTests) {
        $targetArgs += @('--test', [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'tests.integrationTarget'))
    }

    if (-not $DryRun) {
        Assert-TestFilterModulesExist -Plan $Plan
    }

    $filterset = Get-TestFilterset -Plan $Plan -IncludeIntegration:$IncludeIntegrationTests
    $testThreads = [int] (Get-PinnedValue -Pins $Plan.Pins -Path 'tests.testThreads')
    $noTestsAction = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'tests.noTestsAction')

    $nextestArgs = @(
        'nextest', 'run',
        '-p', 'codex-core'
    ) + $targetArgs + @(
        '--cargo-profile', $Plan.Profile,
        '--target', $Plan.TargetTriple,
        '--target-dir', $Plan.TargetDir,
        '--locked',
        '--no-fail-fast',
        '--test-threads', [string] $testThreads,
        '--no-tests', $noTestsAction,
        '-E', $filterset
    )
    if ($Plan.Profile -eq 'dev') {
        $nextestArgs += @('--config', 'profile.dev.debug=0')
    }
    if ($Offline) {
        $nextestArgs += '--offline'
    }

    if ($DryRun) {
        Write-Note ("Dry run: would run '" + [System.IO.Path]::GetFileName($exePath) + " " + ($nextestArgs -join ' ') + "' in " + $Plan.WorkspaceDir)
        return
    }

    Write-Note ("filter set        : " + $filterset)
    Write-Note ("test threads      : " + $testThreads)
    Write-Note ("zero matches      : " + $noTestsAction + ' (a run that matches no tests is an error)')
    Write-Note ("cargo nextest " + ($nextestArgs[1..($nextestArgs.Count - 1)] -join ' '))
    Push-Location $Plan.WorkspaceDir
    try {
        & $exePath @nextestArgs
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "cargo nextest exited with code $exit."
    }
}

function Test-BinaryForEmbeddedPaths {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Plan
    )

    $result = [pscustomobject]@{
        FatalHits   = @()
        WarningHits = @()
        Scanned     = $false
    }

    $sizeBytes = (Get-Item -LiteralPath $Path).Length
    if ($sizeBytes -gt 400MB) {
        # Not scanned. The caller decides what that means; the returned flag is
        # never treated as "clean".
        $result.Scanned = $false
        Write-WarnMsg "Skipping the embedded-path scan: $Path is $([math]::Round($sizeBytes / 1MB, 1)) MiB, larger than the 400 MiB scan limit."
        return $result
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $utf16 = [System.Text.Encoding]::Unicode.GetString($bytes)
    $result.Scanned = $true

    $fatalNeedles = @($Plan.WorkRoot)
    if ($Plan.RepoRoot -and -not (Test-PathUnderRoot -Path $Plan.RepoRoot -Root $Plan.WorkRoot)) {
        $fatalNeedles += $Plan.RepoRoot
    }
    if ($env:USERNAME) {
        $fatalNeedles += ('C:\Users\' + $env:USERNAME)
    }

    foreach ($needle in $fatalNeedles) {
        if (-not $needle) { continue }
        if ($ascii.Contains($needle) -or $utf16.Contains($needle)) {
            $result.FatalHits += $needle
        }
    }

    $warningNeedles = @()
    if ($env:USERNAME) { $warningNeedles += $env:USERNAME }
    $warningNeedles += 'C:\Users\'
    foreach ($needle in $warningNeedles) {
        if (-not $needle) { continue }
        if ($ascii.Contains($needle) -or $utf16.Contains($needle)) {
            $result.WarningHits += $needle
        }
    }
    return $result
}

function Step-Package {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $BuiltBinary,
        [switch] $DryRun
    )

    Write-Step 'Assemble the bundle'

    # The receipt check is deliberately skipped in a dry run, which never has one.
    if (-not $DryRun) {
        if ($Plan.FixtureMode) {
            Write-WarnMsg 'FIXTURE MODE: the bundle is marked as a fixture and is not a publishable release.'
            $receipt = Assert-BuildReceipt -Plan $Plan -BinaryPath $BuiltBinary -AllowFixture
        } else {
            $receipt = Assert-BuildReceipt -Plan $Plan -BinaryPath $BuiltBinary
            if ([string] $receipt.kind -ne 'source-build') {
                throw "A publishable bundle requires a 'source-build' receipt but found '$($receipt.kind)'."
            }
        }
    }

    $manifest = Get-Content -Raw -LiteralPath $Plan.ManifestPath | ConvertFrom-Json
    $requiredNames = @(Get-PinnedValue -Pins $Plan.Pins -Path 'helperManifest.requiredAssets')
    $renameMap = Get-PinnedValue -Pins $Plan.Pins -Path 'helperManifest.bundleNameWithoutTargetSuffix'

    $entries = @()
    foreach ($name in $requiredNames) {
        $match = @($manifest | Where-Object { $_.name -eq $name })
        if ($match.Count -ne 1) {
            throw "The download manifest $($Plan.ManifestPath) must contain exactly one entry named '$name' (found $($match.Count))."
        }
        $entry = $match[0]
        $digest = ([string] $entry.digest).ToLowerInvariant()
        if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Manifest entry '$name' has an unusable digest: '$($entry.digest)'"
        }
        $targetName = $renameMap.PSObject.Properties[$name]
        if ($null -eq $targetName) {
            throw "build/pins.json does not map '$name' to a bundle file name."
        }
        $entries += [pscustomobject]@{
            Name        = $name
            Url         = [string] $entry.browser_download_url
            Sha256      = $digest.Substring('sha256:'.Length)
            Size        = [long] $entry.size
            BundleName  = [string] $targetName.Value
        }
    }

    if ($DryRun) {
        foreach ($entry in $entries) {
            Write-Note ("Dry run: would download " + $entry.Url + " and stage it as " + $entry.BundleName)
        }
        Write-Note ("Dry run: would write " + $Plan.BundleZip)
        return $null
    }

    $stageDir = Join-Path $Plan.StageRoot $Plan.BundleName
    Remove-TreeUnderRoot -Path $stageDir -Root $Plan.WorkRoot
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'source') | Out-Null

    $cliTarget = Join-Path $stageDir $Plan.CliBinaryName
    Copy-Item -LiteralPath $BuiltBinary -Destination $cliTarget -Force

    $leak = Test-BinaryForEmbeddedPaths -Path $cliTarget -Plan $Plan
    if ($leak.FatalHits.Count -gt 0) {
        throw "The built binary still contains build-machine paths: $($leak.FatalHits -join ', '). Path remapping did not cover them; refusing to publish the bundle."
    }
    if ($leak.WarningHits.Count -gt 0) {
        Write-WarnMsg ("The binary contains strings that often indicate a leftover path: " + ($leak.WarningHits -join ', ') + '. Review before sharing widely.')
    }
    if ($leak.Scanned) {
        Write-Note 'Embedded-path scan: no build root, checkout or user path found.'
    } elseif ($Plan.FixtureMode) {
        Write-WarnMsg 'The embedded-path scan was not performed; keeping this fixture bundle explicitly non-publishable.'
    } else {
        # Fail closed. Without the scan there is no evidence the binary is free
        # of build-machine paths, and the bundle claims it is. Shipping a binary
        # that was never scanned is exactly how a large debug build leaks the
        # builder's folder names.
        throw "Refusing to publish: the embedded-path scan did not run for $cliTarget ($([math]::Round((Get-Item -LiteralPath $cliTarget).Length / 1MB, 1)) MiB). The dev-small profile keeps this binary well under the scan limit; if a larger profile is the goal, raise the scan limit deliberately instead of shipping unscanned bytes."
    }

    $versionLog = Join-Path $Plan.TempDir 'codex-version.log'
    $versionOutput = (& $cliTarget --version 2> $versionLog | Out-String).Trim()
    $versionExit = $LASTEXITCODE
    if (-not $versionOutput -and (Test-Path -LiteralPath $versionLog)) {
        $versionOutput = (Get-Content -Raw -LiteralPath $versionLog).Trim()
    }
    Write-Note "codex --version: $versionOutput"
    if ($versionExit -ne 0) {
        throw "'$cliTarget --version' exited with code $versionExit. Output: $versionOutput"
    }
    if ($versionOutput -notmatch [regex]::Escape($Plan.Version)) {
        throw "The built binary reported '$versionOutput', which does not contain the expected version '$($Plan.Version)'."
    }

    foreach ($entry in $entries) {
        $cached = Join-Path $Plan.DownloadRoot $entry.Name
        Invoke-FileDownload -Url $entry.Url -Destination $cached -ExpectedSha256 $entry.Sha256 -ExpectedSize $entry.Size
        Copy-Item -LiteralPath $cached -Destination (Join-Path $stageDir $entry.BundleName) -Force
        Write-Note ("Staged " + $entry.BundleName)
    }

    $licenseSource = Join-Path $Plan.RepoRoot 'LICENSE'
    if (-not (Test-Path -LiteralPath $licenseSource)) {
        throw "LICENSE not found at $licenseSource."
    }
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $stageDir 'LICENSE') -Force

    $noticeSource = Join-Path $Plan.RepoRoot 'licenses\codex-NOTICE.txt'
    if (-not (Test-Path -LiteralPath $noticeSource)) {
        throw "NOTICE not found at $noticeSource."
    }
    Copy-Item -LiteralPath $noticeSource -Destination (Join-Path $stageDir 'NOTICE.txt') -Force

    Copy-Item -LiteralPath $Plan.PatchSource -Destination (Join-Path $stageDir 'source\codex-native-provider.patch') -Force

    $changedFiles = @(Get-PinnedValue -Pins $Plan.Pins -Path 'patch.expectedChangedFiles')
    $redactions = Get-RedactionMap -Plan $Plan
    $provenance = New-ProvenanceText -Plan $Plan -BuiltBinary $cliTarget -VersionOutput $versionOutput -HelperEntries $entries -ChangedFiles $changedFiles -Redactions $redactions
    Write-Utf8NoBom -Path (Join-Path $stageDir 'PROVENANCE.txt') -Text $provenance

    # runtime-manifest.json: the shape the installer reads when it sits next to
    # codex.exe. It lists only the runtime executables, so verification cannot
    # fail because of LICENSE, NOTICE, PROVENANCE, SHA256SUMS or source/.
    $manifestFileName = [string] (Get-PinnedValue -Pins $Plan.Pins -Path 'runtimeManifest.fileName')
    $manifestScript = Join-Path $Plan.RepoRoot 'build\New-RuntimeManifest.ps1'
    $manifestRuntimeFiles = @(Get-PinnedValue -Pins $Plan.Pins -Path 'runtimeManifest.files')
    $manifestProvenancePath = 'source/codex-native-provider.patch'
    $manifestTargetPath = Join-Path $stageDir $manifestFileName
    try {
        & $manifestScript `
            -RuntimeDirectory $stageDir `
            -OutputPath $manifestTargetPath `
            -Version $Plan.Version `
            -FileNames $manifestRuntimeFiles `
            -Kind $(if ($Plan.FixtureMode) { 'fixture' } else { 'source-build' }) `
            -Publishable (-not $Plan.FixtureMode) `
            -BundleName $Plan.BundleName `
            -BuildProfile $Plan.Profile `
            -Toolchain $Plan.Toolchain `
            -SourceRepositoryUrl $Plan.SourceUrl `
            -SourceTag $Plan.SourceTag `
            -SourceCommit $Plan.SourceCommit `
            -PatchPath $manifestProvenancePath `
            -PatchSha256 $Plan.PatchDigest `
            -CliSha256 (Get-Sha256 -Path $cliTarget) | Out-Null
    } catch {
        throw "Failed to write $manifestFileName`: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $manifestTargetPath)) {
        throw "Failed to write $manifestFileName."
    }

    # Read it back and re-check every hash against the staged files. This catches
    # a manifest that is valid JSON but does not describe what we just built.
    $writtenManifest = Get-Content -Raw -LiteralPath $manifestTargetPath | ConvertFrom-Json
    if ([string] $writtenManifest.version -ne $Plan.Version) {
        throw "$manifestFileName reports version '$($writtenManifest.version)' instead of '$($Plan.Version)'."
    }
    $manifestEntries = @($writtenManifest.files.PSObject.Properties)
    if ($manifestEntries.Count -ne $manifestRuntimeFiles.Count) {
        throw "$manifestFileName lists $($manifestEntries.Count) files; pins.json expects $($manifestRuntimeFiles.Count)."
    }
    foreach ($property in $manifestEntries) {
        $stagedPath = Join-Path $stageDir $property.Name
        if (-not (Test-Path -LiteralPath $stagedPath)) {
            throw "$manifestFileName lists '$($property.Name)', which is not in the bundle."
        }
        $stagedHash = Get-Sha256 -Path $stagedPath
        if ($stagedHash -ne ([string] $property.Value).ToLowerInvariant()) {
            throw "$manifestFileName hash for '$($property.Name)' does not match the staged file."
        }
    }
    Write-Note ("runtime manifest: " + $manifestFileName + " (" + $manifestEntries.Count + ' files verified)')

    # PROVENANCE.txt is written into the bundle, so it must not carry the
    # builder's real paths. Fail loudly rather than shipping a personal path.
    $textLeakSources = @(
        (Join-Path $stageDir 'PROVENANCE.txt'),
        (Join-Path $stageDir $manifestFileName)
    )
    foreach ($textPath in $textLeakSources) {
        if (-not (Test-Path -LiteralPath $textPath)) { continue }
        $textHits = @(Test-TextFileForLeaks -Path $textPath -Redactions $redactions)
        if ($textHits.Count -gt 0) {
            throw "$([System.IO.Path]::GetFileName($textPath)) still contains a build-machine path: $($textHits -join ', ')."
        }
    }
    Write-Note 'Bundle text files contain no build-machine paths.'

    $sumLines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $stageDir -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object FullName)) {
        $relative = Get-RelativePath -BasePath $stageDir -Path $file.FullName
        $sumLines += ((Get-Sha256 -Path $file.FullName) + '  ' + $relative)
    }
    Write-Utf8NoBom -Path (Join-Path $stageDir 'SHA256SUMS.txt') -Text (($sumLines -join "`n") + "`n")
    Write-Note ("SHA256SUMS.txt lists " + $sumLines.Count + ' files')

    if (-not (Test-Path -LiteralPath $Plan.OutputRoot)) {
        New-Item -ItemType Directory -Force -Path $Plan.OutputRoot | Out-Null
    }
    if (Test-Path -LiteralPath $Plan.BundleZip) {
        Remove-Item -LiteralPath $Plan.BundleZip -Force
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    } catch {
        Write-Note 'System.IO.Compression.FileSystem is already available.'
    }
    $zip = [System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $Plan.BundleZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $zipFile = Get-Item -LiteralPath $Plan.BundleZip
    $zipDigest = Get-Sha256 -Path $Plan.BundleZip
    Write-Utf8NoBom -Path ($Plan.BundleZip + '.sha256') -Text ($zipDigest + '  ' + $zipFile.Name + "`n")

    Write-Note ("Bundle: " + $zipFile.FullName)
    Write-Note ("Size  : " + [math]::Round($zipFile.Length / 1MB, 1) + ' MiB')
    Write-Note ("SHA256: $zipDigest")

    return [pscustomobject]@{
        StageDir   = $stageDir
        ZipPath    = $zipFile.FullName
        ZipName    = $zipFile.Name
        ZipSha256  = $zipDigest
        ZipSize    = $zipFile.Length
        Version    = $versionOutput
        FileCount  = $sumLines.Count + 1
    }
}

function New-ProvenanceText {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $BuiltBinary,
        [Parameter(Mandatory)] [string] $VersionOutput,
        [Parameter(Mandatory)] [array] $HelperEntries,
        [Parameter(Mandatory)] [array] $ChangedFiles,
        [Parameter(Mandatory)] [array] $Redactions
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Codex native DeepSeek runtime bundle')
    $lines.Add('==================================')
    $lines.Add('')
    $lines.Add('Produced by the source-build workflow in the codex-deepseek-native repository.')
    $lines.Add('The patched codex.exe is built from source. The companion executables are the')
    $lines.Add('unmodified official builds from the matching upstream release.')
    $lines.Add('')
    $lines.Add('Source')
    $lines.Add('------')
    $lines.Add('repository        : ' + $Plan.SourceUrl)
    $lines.Add('tag               : ' + $Plan.SourceTag + ' (tag object ' + $Plan.SourceTagSha + ')')
    $lines.Add('commit            : ' + $Plan.SourceCommit)
    $lines.Add('workspace version : ' + $Plan.Version)
    $lines.Add('')
    $lines.Add('Patch')
    $lines.Add('-----')
    $lines.Add('file              : source/codex-native-provider.patch')
    $lines.Add('sha256 (normalized): ' + $Plan.PatchDigest)
    foreach ($file in $ChangedFiles) {
        $lines.Add('changes           : ' + $file)
    }
    $lines.Add('')
    $lines.Add('Build')
    $lines.Add('-----')
    $lines.Add('toolchain         : ' + $Plan.Toolchain + ' (rustup profile minimal)')
    $lines.Add('target triple     : ' + $Plan.TargetTriple)
    $lines.Add('cargo profile     : ' + $Plan.Profile)
    $lines.Add('cargo version     : ' + $Plan.CargoVersion)
    $lines.Add('rustc version     : ' + $Plan.RustVersion)
    $lines.Add('codex --version   : ' + $VersionOutput)
    $lines.Add('cli sha256        : ' + (Get-Sha256 -Path $BuiltBinary))
    $lines.Add('cli size (bytes)  : ' + (Get-Item -LiteralPath $BuiltBinary).Length)
    foreach ($pair in $Plan.RemapPairs) {
        $lines.Add('path remap        : ' + $pair.Real + ' -> ' + $pair.Virtual)
    }
    $lines.Add('RUSTFLAGS         : ' + ($Plan.RustFlags -join ' '))
    $lines.Add('built at (UTC)    : ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $lines.Add('runner image      : ' + (Get-ValueOrUnknown -Value $env:ImageOS))
    $lines.Add('workflow run      : ' + (Get-ValueOrUnknown -Value $env:GITHUB_RUN_ID) + ' attempt ' + (Get-ValueOrUnknown -Value $env:GITHUB_RUN_ATTEMPT))
    $lines.Add('builder repo ref  : ' + (Get-ValueOrUnknown -Value $env:GITHUB_SHA))
    $lines.Add('machine-readable  : runtime-manifest.json (version + file hashes the installer verifies,')
    $lines.Add('                    plus this commit and patch digest); SHA256SUMS.txt covers every file')
    $lines.Add('')
    $lines.Add('Official companion executables (verified against verification/official-downloads.json)')
    $lines.Add('-------------------------------------------------------------------------------------')
    foreach ($entry in $HelperEntries) {
        $lines.Add($entry.BundleName + ' <- ' + $entry.Name)
        $lines.Add('  url    : ' + $entry.Url)
        $lines.Add('  sha256 : ' + $entry.Sha256)
        $lines.Add('  bytes  : ' + $entry.Size)
    }
    $lines.Add('')
    $lines.Add('Not included')
    $lines.Add('------------')
    $lines.Add('- No binaries copied from a local Codex installation.')
    $lines.Add('- No user configuration, model settings or credentials.')
    $lines.Add('- No API keys, tokens or provider secrets. The build ran without registry')
    $lines.Add('  credentials and used a throwaway cargo home inside the build root.')
    $lines.Add('')
    # The provenance file is shipped inside the bundle, so it must not carry the
    # builder's real folder names. The remap list and RUSTFLAGS are the places
    # those paths naturally appear, so the whole document is sanitized last.
    return (ConvertTo-SanitizedText -Text ($lines -join "`n") -Redactions $Redactions)
}

function Get-ValueOrUnknown {
    param([string] $Value)
    if (-not $Value) { return 'unknown (local run)' }
    return $Value
}

function Get-RedactionMap {
    param([Parameter(Mandatory)] [object] $Plan)

    # Longest first so that nested paths are replaced before their parents.
    $pairs = @(
        [pscustomobject]@{ Real = $Plan.RepoRoot; Placeholder = '<builder-repo>' },
        [pscustomobject]@{ Real = $Plan.WorkRoot; Placeholder = '<build-root>' },
        [pscustomobject]@{ Real = $Plan.SourceDir; Placeholder = '<build-root>/src/codex' },
        [pscustomobject]@{ Real = $Plan.CargoHome; Placeholder = '<build-root>/cargo' },
        [pscustomobject]@{ Real = $Plan.RustupHome; Placeholder = '<build-root>/rustup' },
        [pscustomobject]@{ Real = $Plan.TargetDir; Placeholder = '<build-root>/target' }
    )
    if ($env:USERPROFILE) {
        $pairs += [pscustomobject]@{ Real = $env:USERPROFILE; Placeholder = '<user-profile>' }
    }
    if ($env:USERNAME) {
        $pairs += [pscustomobject]@{ Real = ('C:\Users\' + $env:USERNAME); Placeholder = '<user-profile>' }
        $pairs += [pscustomobject]@{ Real = $env:USERNAME; Placeholder = '<user>' }
    }
    return $pairs | Where-Object { $_.Real } | Sort-Object -Property @{ Expression = { $_.Real.Length } } -Descending
}

function ConvertTo-SanitizedText {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [array] $Redactions
    )

    $result = $Text
    foreach ($pair in $Redactions) {
        $result = $result.Replace($pair.Real, $pair.Placeholder)
    }
    return $result
}

function Test-TextFileForLeaks {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [array] $Redactions
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $hits = @()
    foreach ($pair in $Redactions) {
        if ($text.Contains($pair.Real)) {
            $hits += $pair.Real
        }
    }
    return $hits
}


function Write-BuildReceipt {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $BinaryPath,
        [ValidateSet('source-build', 'fixture')]
        [string] $Kind = 'source-build'
    )

    if (-not (Test-Path -LiteralPath $Plan.StateDir)) {
        New-Item -ItemType Directory -Force -Path $Plan.StateDir | Out-Null
    }

    $publishable = ($Kind -eq 'source-build')
    $receipt = [ordered]@{
        schemaVersion      = 1
        kind               = $Kind
        publishable        = $publishable
        sourceCommit       = $Plan.SourceCommit
        sourceTag          = $Plan.SourceTag
        patchSha256        = $Plan.PatchDigest
        profile            = $Plan.Profile
        toolchain          = $Plan.Toolchain
        targetTriple       = $Plan.TargetTriple
        binaryPath         = $BinaryPath
        binarySha256       = (Get-Sha256 -Path $BinaryPath)
        binaryBytes        = (Get-Item -LiteralPath $BinaryPath).Length
        cargoVersion       = $Plan.CargoVersion
        rustcVersion       = $Plan.RustVersion
        builtAtUtc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        workflowRunId      = (Get-ValueOrUnknown -Value $env:GITHUB_RUN_ID)
        workflowRunAttempt = (Get-ValueOrUnknown -Value $env:GITHUB_RUN_ATTEMPT)
    }

    $json = $receipt | ConvertTo-Json -Depth 6
    Write-Utf8NoBom -Path $Plan.ReceiptPath -Text ($json + "`n")
    Write-Note ("Build receipt written: " + $Plan.ReceiptPath + " (kind " + $Kind + ")")
    return $Plan.ReceiptPath
}

function Assert-BuildReceipt {
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $BinaryPath,
        [switch] $AllowFixture
    )

    # Packaging must be driven by evidence that a real compile happened against
    # the pinned inputs. Without this, a planted codex.exe could be packaged and
    # handed out as if it were the patched build.
    if (-not (Test-Path -LiteralPath $Plan.ReceiptPath)) {
        $lines = @(
            "Refusing to package: no build receipt at $($Plan.ReceiptPath).",
            'This run was not driven by a successful cargo build of the pinned inputs, so the',
            "executable at $BinaryPath is unverified. Run the build step (do not pass",
            '-SkipBuild), or use -FixtureBinary for a clearly marked, non-publishable fixture',
            'bundle.'
        )
        throw ($lines -join "`n")
    }

    try {
        $receipt = Get-Content -Raw -LiteralPath $Plan.ReceiptPath | ConvertFrom-Json
    } catch {
        throw "The build receipt at $($Plan.ReceiptPath) is not valid JSON: $($_.Exception.Message)"
    }

    if ($AllowFixture) {
        if ([string] $receipt.kind -ne 'fixture') {
            throw "Refusing to package as a fixture: the receipt at $($Plan.ReceiptPath) is marked kind '$($receipt.kind)'."
        }
    } elseif ([string] $receipt.kind -ne 'source-build' -or -not [bool] $receipt.publishable) {
        throw "Refusing to package: the receipt at $($Plan.ReceiptPath) is marked kind '$($receipt.kind)' (publishable $($receipt.publishable)). Only a receipt from a real build step can produce a publishable bundle."
    }

    $expected = [ordered]@{
        sourceCommit = $Plan.SourceCommit
        patchSha256  = $Plan.PatchDigest
        profile      = $Plan.Profile
        toolchain    = $Plan.Toolchain
        targetTriple = $Plan.TargetTriple
    }
    $mismatches = @()
    foreach ($field in $expected.Keys) {
        $actual = [string] $receipt.$field
        if ($actual -ne [string] $expected[$field]) {
            $mismatches += ("$field" + ": receipt '" + $actual + "' vs plan '" + $expected[$field] + "'")
        }
    }
    if ($mismatches.Count -gt 0) {
        throw "Refusing to package: the build receipt does not match this run.`n  $($mismatches -join "`n  ")"
    }

    $binaryHash = Get-Sha256 -Path $BinaryPath
    if ($binaryHash -ne ([string] $receipt.binarySha256).ToLowerInvariant()) {
        throw "Refusing to package: the build receipt records binarySha256 '$($receipt.binarySha256)' but '$BinaryPath' hashes to '$binaryHash'. The executable changed after the build."
    }

    Write-Note ("Build receipt verified: kind " + $receipt.kind + ", binary " + $binaryHash)
    return $receipt
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$repositoryRoot = if ($RepoRoot) { Get-FullPath -Path $RepoRoot } else { Get-FullPath -Path (Split-Path -Parent $PSScriptRoot) }
$pinnedFile = if ($PinsPath) { Get-FullPath -Path $PinsPath } else { Join-Path $repositoryRoot 'build\pins.json' }
if (-not (Test-Path -LiteralPath $pinnedFile)) {
    throw "Pins file not found: $pinnedFile"
}
$pinsDocument = Get-Content -Raw -LiteralPath $pinnedFile | ConvertFrom-Json

$resolvedProfile = if ($PSBoundParameters.ContainsKey('Profile')) { $Profile } else { [string] (Get-PinnedValue -Pins $pinsDocument -Path 'buildProfile.default') }
$resolvedTarget = if ($TargetTriple) { $TargetTriple } else { [string] (Get-PinnedValue -Pins $pinsDocument -Path 'toolchain.targetTriple') }
$resolvedToolchain = if ($Toolchain) { $Toolchain } else { [string] (Get-PinnedValue -Pins $pinsDocument -Path 'toolchain.rustupToolchain') }
$resolvedVirtualRoot = if ($VirtualRoot) { $VirtualRoot } else { [string] (Get-PinnedValue -Pins $pinsDocument -Path 'paths.virtualRootDefault') }

$allowedProfiles = @(Get-PinnedValue -Pins $pinsDocument -Path 'buildProfile.allowed')
if ($allowedProfiles -notcontains $resolvedProfile) {
    throw "Profile '$resolvedProfile' is not in build/pins.json (allowed: $($allowedProfiles -join ', '))."
}

$resolvedWorkRoot = Get-FullPath -Path $WorkRoot
Assert-SafeWorkRoot -Path $resolvedWorkRoot -RepositoryRoot $repositoryRoot

$plan = New-BuildPlan -RepositoryRoot $repositoryRoot -PinnedFile $pinnedFile -ResolvedWorkRoot $resolvedWorkRoot `
    -ResolvedVirtualRoot $resolvedVirtualRoot -ResolvedProfile $resolvedProfile -ResolvedTargetTriple $resolvedTarget `
    -ResolvedToolchain $resolvedToolchain -ResolvedOutputRoot $OutputRoot -ResolvedBundleName $BundleName

Write-Host ''
Write-Host 'Codex native DeepSeek runtime: Windows x64 MSVC source build'
Write-BuildPlan -Plan $plan

foreach ($pair in $plan.RemapPairs) {
    if ($pair.Real -match '\s') {
        throw "RUSTFLAGS cannot express a path containing whitespace: '$($pair.Real)'. Choose a -WorkRoot and checkout path without spaces."
    }
}

Assert-FreeDiskSpace -Path $plan.WorkRoot -MinimumGiB $MinimumFreeGiB -InformationalOnly:$DryRun

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN: nothing is installed, fetched, patched, built, downloaded or written.'
    Write-Note ('rustup on PATH : ' + (Get-ValueOrUnknown -Value (Get-CommandPathOrNull -Name 'rustup')))
    Write-Note ('git on PATH    : ' + (Get-ValueOrUnknown -Value (Get-CommandPathOrNull -Name 'git')))
    $plannedSteps = @(
        if (-not $SkipToolchainInstall) { 'toolchain' }
        if (-not $SkipSourceFetch) { 'source' }
        'patch'
        if (-not $SkipBuild) { 'build' }
        if (-not $SkipTests) { 'tests' }
        if (-not $SkipPackage) { 'package' }
    )
    Write-Note ('steps planned  : ' + ($plannedSteps -join ', '))

    Step-Toolchain -Plan $plan -DryRun:$true
    Step-Source -Plan $plan -DryRun:$true
    Step-Patch -Plan $plan -DryRun:$true
    Step-Build -Plan $plan -DryRun:$true
    if (-not $SkipTests) {
        Step-Tests -Plan $plan -DryRun:$true
    } else {
        Write-Step 'Tests skipped (-SkipTests)'
    }
    if (-not $SkipPackage) {
        $null = Step-Package -Plan $plan -BuiltBinary $plan.CliBinaryPath -DryRun:$true
    } else {
        Write-Step 'Packaging skipped (-SkipPackage)'
    }

    Write-Host ''
    Write-Host 'DRY RUN finished: nothing was changed.'
    exit 0
}

if (-not $script:IsWindowsHost) {
    throw 'This build script targets Windows. Run it on Windows x64 with the MSVC toolchain.'
}

foreach ($directory in @($plan.WorkRoot, $plan.CargoHome, $plan.RustupHome, $plan.TargetDir, $plan.ToolRoot, $plan.DownloadRoot, $plan.PatchRoot, $plan.StageRoot, $plan.TempDir, $plan.StateDir)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
}

$env:CARGO_HOME = $plan.CargoHome
$env:RUSTUP_HOME = $plan.RustupHome
$env:RUSTUP_TOOLCHAIN = $plan.Toolchain
$env:CARGO_TARGET_DIR = $plan.TargetDir
$env:CARGO_BUILD_JOBS = [string] $plan.Jobs
$env:CARGO_INCREMENTAL = '0'
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
$env:CARGO_NET_RETRY = '10'
$env:CARGO_TERM_COLOR = 'never'
$env:RUST_MIN_STACK = '8388608'
$env:RUST_BACKTRACE = '0'
$env:RUSTFLAGS = ($plan.RustFlags -join ' ')
$env:NEXTEST_PROFILE = 'local'
$env:TEMP = $plan.TempDir
$env:TMP = $plan.TempDir
if ($plan.TargetTriple -eq 'x86_64-pc-windows-msvc') {
    # Mirrors the upstream Windows release build for the same target.
    $env:LIBSQLITE3_FLAGS = 'SQLITE_DISABLE_INTRINSIC'
}

Assert-CleanCargoHome -CargoHome $plan.CargoHome

if (-not $SkipMsvcEnvironment) {
    Import-MsvcEnvironment -TempDir $plan.TempDir | Out-Null
}

$plan | Add-Member -NotePropertyName PatchDigest -NotePropertyValue ([string] (Get-PinnedValue -Pins $plan.Pins -Path 'patch.sha256')) -Force
$plan | Add-Member -NotePropertyName CargoVersion -NotePropertyValue 'not captured yet' -Force
$plan | Add-Member -NotePropertyName RustVersion -NotePropertyValue 'not captured yet' -Force

Step-Toolchain -Plan $plan -DryRun:$false

if (Get-CommandPathOrNull -Name 'cargo') {
    $plan.CargoVersion = Get-ValueOrUnknown -Value ((& cargo --version) -join ' ')
} else {
    $plan.CargoVersion = 'cargo not on PATH (toolchain install skipped)'
}
if (Get-CommandPathOrNull -Name 'rustc') {
    $plan.RustVersion = Get-ValueOrUnknown -Value ((& rustc --version) -join ' ')
} else {
    $plan.RustVersion = 'rustc not on PATH (toolchain install skipped)'
}
Write-Note ("cargo: " + $plan.CargoVersion)
Write-Note ("rustc: " + $plan.RustVersion)

Step-Source -Plan $plan -DryRun:$false
Step-Patch -Plan $plan -DryRun:$false

$builtBinary = $null
if ($FixtureBinary) {
    Write-Step 'Fixture binary route (test only)'
    if (-not (Test-Path -LiteralPath $FixtureBinary -PathType Leaf)) {
        throw "The -FixtureBinary path does not exist: $FixtureBinary"
    }
    Write-WarnMsg 'FIXTURE MODE: no compile happens. The receipt is marked kind "fixture", the bundle name gains a -fixture suffix, and runtime-manifest.json records publishable=false.'
    $builtBinary = (Get-Item -LiteralPath $FixtureBinary).FullName
    Write-Note ("fixture binary: " + $builtBinary)
    Write-BuildReceipt -Plan $plan -BinaryPath $builtBinary -Kind 'fixture' | Out-Null
} elseif (-not $SkipBuild) {
    Step-Build -Plan $plan -DryRun:$false
    $builtBinary = Get-BuiltCliBinary -Plan $plan
} elseif (-not $SkipPackage) {
    Write-Step 'Build skipped (-SkipBuild); reusing an existing binary'
    $builtBinary = Get-BuiltCliBinary -Plan $plan
} else {
    Write-Step 'Build skipped (-SkipBuild)'
}

if (-not $SkipTests) {
    Step-Tests -Plan $plan -DryRun:$false
} else {
    Write-Step 'Tests skipped (-SkipTests)'
}

$package = $null
if (-not $SkipPackage) {
    $package = Step-Package -Plan $plan -BuiltBinary $builtBinary -DryRun:$false
} else {
    Write-Step 'Packaging skipped (-SkipPackage)'
}

if ($PruneBuildOutputs) {
    Write-Step 'Prune the cargo target directory'
    Remove-TreeUnderRoot -Path $plan.TargetDir -Root $plan.WorkRoot
}

Write-Host ''
Write-Host 'RESULT'
if ($builtBinary) {
    Write-Note ("built binary      : " + $builtBinary)
}
Write-Note ("cargo / rustc     : " + $plan.CargoVersion + ' | ' + $plan.RustVersion)
if ($package) {
    Write-Note ("bundle            : " + $package.ZipPath)
    Write-Note ("bundle sha256     : " + $package.ZipSha256)
    Write-Note ("bundle size       : " + [math]::Round($package.ZipSize / 1MB, 1) + ' MiB')
    Add-GitHubOutput -Name 'bundle_name' -Value $package.ZipName
    Add-GitHubOutput -Name 'bundle_zip' -Value $package.ZipPath
    Add-GitHubOutput -Name 'bundle_sha256' -Value $package.ZipSha256
    Add-GitHubOutput -Name 'cli_version' -Value $package.Version
    $summaryLines = @(
        '## Windows x64 MSVC source build',
        '',
        '| Item | Value |',
        '| --- | --- |',
        ('| Upstream commit | {0} ({1}) |' -f $plan.SourceCommit, $plan.SourceTag),
        ('| Cargo profile | {0} |' -f $plan.Profile),
        ('| Toolchain | {0} |' -f $plan.Toolchain),
        ('| codex --version | {0} |' -f $package.Version),
        ('| Bundle | {0} |' -f $package.ZipName),
        ('| Bundle SHA256 | {0} |' -f $package.ZipSha256),
        ('| Bundle size | {0} MiB |' -f [math]::Round($package.ZipSize / 1MB, 1)),
        '',
        'Pinned inputs live in build/pins.json; the official companion binaries were',
        'verified against verification/official-downloads.json.'
    )
    Add-StepSummary -Markdown ($summaryLines -join "`n")
}

Write-Host ''
Write-Host 'Build script finished.'
