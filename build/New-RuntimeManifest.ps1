#requires -Version 5.1
<#
.SYNOPSIS
    Writes the runtime-manifest.json that ships inside the bundle.

.DESCRIPTION
    The manifest format is the one the installer already documents and verifies
    (see scripts/DeepSeekNative.Common.ps1, Test-DseRuntimeManifest, and
    config/defaults.json -> runtimeManifestFileName). The accepted shape is:

        {
          "version": "0.153.4",
          "files": { "codex.exe": "<sha256>", "codex-command-runner.exe": "<sha256>", ... }
        }

    The installer uses `files` to check the four runtime executables that sit
    next to codex.exe, and `version` for its minimum-version check. An array
    form (`files` as a list of {name, sha256}) is also accepted by the installer,
    but the object form is what its fixtures use, so that is what is written here.

    Extra top-level keys are ignored by the installer and are used to carry
    build provenance: which upstream commit was patched, and with which patch
    digest.

    Only the files named in -FileNames are listed. Nothing else in the bundle
    (LICENSE, NOTICE.txt, PROVENANCE.txt, SHA256SUMS.txt, source/) is added to
    the manifest, and the manifest never lists itself: a manifest that listed
    files a user might not keep beside the runtime would make the installer's
    verification fail for the wrong reason.

.PARAMETER RuntimeDirectory
    Folder that contains the runtime executables. Hashes are computed from here.

.PARAMETER FileNames
    File names to include in the manifest. Defaults to the four required runtime
    executables from config/defaults.json.

.PARAMETER OutputPath
    Where to write the manifest. Defaults to runtime-manifest.json inside
    -RuntimeDirectory.

.PARAMETER Version
    Version string the installer compares against its minimum. Use the plain
    workspace version, for example 0.153.4.

.PARAMETER SourceCommit, SourceTag, PatchSha256, PatchPath
    Provenance for the patched build. Recorded, not interpreted.

.EXAMPLE
    pwsh -File build/New-RuntimeManifest.ps1 -RuntimeDirectory C:\stage -Version 0.153.4 `
        -SourceCommit 3d2ee51ca2d5db578f328aa75e20aa22c0197c9a `
        -PatchSha256 5114784472499c99a42cd02dc05032eeabc9ef21ac528660f26bfeafcdb0217a
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RuntimeDirectory,
    [string] $OutputPath,
    [Parameter(Mandatory)] [string] $Version,
    [string[]] $FileNames,
    [string] $Product = 'codex-deepseek-native',
    [string] $Kind = 'source-build',
    [bool] $Publishable = $true,
    [string] $BundleName,
    [string] $BuildProfile,
    [string] $Toolchain,
    [string] $SourceRepositoryUrl,
    [string] $SourceCommit,
    [string] $SourceTag,
    [string] $PatchPath,
    [string] $PatchSha256,
    [string] $CliSha256,
    [string] $BuiltAtUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RuntimeDirectory -PathType Container)) {
    throw "Runtime directory not found: $RuntimeDirectory"
}

if (-not $FileNames -or $FileNames.Count -eq 0) {
    $FileNames = @(
        'codex.exe',
        'codex-command-runner.exe',
        'codex-windows-sandbox-setup.exe',
        'codex-code-mode-host.exe'
    )
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $RuntimeDirectory 'runtime-manifest.json'
}

$files = [ordered]@{}
foreach ($name in $FileNames) {
    $path = Join-Path $RuntimeDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Cannot write the runtime manifest: '$name' is missing from $RuntimeDirectory."
    }
    $files[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (-not $BuiltAtUtc) {
    $BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$manifest = [ordered]@{
    schemaVersion = 1
    product       = $Product
    kind          = $Kind
    publishable   = $Publishable
    version       = $Version
    builtAtUtc    = $BuiltAtUtc
}

if ($BundleName) { $manifest['bundleName'] = $BundleName }
if ($BuildProfile) { $manifest['buildProfile'] = $BuildProfile }
if ($Toolchain) { $manifest['toolchain'] = $Toolchain }

$source = [ordered]@{}
if ($SourceRepositoryUrl) { $source['repositoryUrl'] = $SourceRepositoryUrl }
if ($SourceTag) { $source['tag'] = $SourceTag }
if ($SourceCommit) { $source['commit'] = $SourceCommit }
if ($PatchPath) { $source['patchPath'] = $PatchPath }
if ($PatchSha256) { $source['patchSha256'] = $PatchSha256 }
if ($CliSha256) { $source['codexExeSha256'] = $CliSha256 }
if ($source.Count -gt 0) {
    $manifest['source'] = $source
}

$manifest['files'] = $files

$json = $manifest | ConvertTo-Json -Depth 8
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, ($json + "`n"), $encoding)

Write-Host ("Wrote " + $OutputPath)
foreach ($name in $files.Keys) {
    Write-Host ("  " + $name + "  " + $files[$name])
}

return $OutputPath
