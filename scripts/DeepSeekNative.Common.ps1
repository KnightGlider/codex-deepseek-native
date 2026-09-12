#Requires -Version 5.1
<#
    Shared helpers for the codex-deepseek-native scripts.
    Dot-source this file; do not run it directly.

    Safety rules this file exists to enforce:
      * Never write to a config file without first making a backup copy.
      * Only ever add or remove the marker-delimited managed block.
      * Preserve the original file encoding, byte order mark and line endings.
      * Never put a secret-looking value into a log file.
#>

function Resolve-DseFullPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        throw 'A path value was empty.'
    }

    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }

    try {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        throw "Not a usable path: '$Path' ($($_.Exception.Message))"
    }
}

function Get-DseDefaults {
    [CmdletBinding()]
    param(
        [string]$DefaultsPath
    )

    if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
        $DefaultsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\defaults.json'
    }
    $DefaultsPath = Resolve-DseFullPath $DefaultsPath

    if (-not (Test-Path -LiteralPath $DefaultsPath -PathType Leaf)) {
        throw "The defaults file is missing: $DefaultsPath"
    }

    try {
        $defaults = Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "The defaults file is not valid JSON ($DefaultsPath): $($_.Exception.Message)"
    }

    $requiredProperties = @(
        'marker', 'roleName', 'roleTable', 'roleConfigRelativePath', 'providerId', 'providerTable',
        'model', 'reasoningEffort', 'minimumRuntimeVersion', 'installRootName', 'subdirectories',
        'requiredRuntimeFiles', 'recommendedRuntimeFiles', 'desktopPackageName',
        'desktopRelativeExePath', 'desktopProcessName', 'defaultRouterBaseUrl', 'routerHealthPath',
        'stateFileName'
    )
    foreach ($name in $requiredProperties) {
        if ($null -eq $defaults.PSObject.Properties[$name]) {
            throw "The defaults file is missing the required property '$name': $DefaultsPath"
        }
    }

    return $defaults
}

function Get-DseUserProfile {
    [CmdletBinding()]
    param()

    # The packaged desktop app can redirect the process USERPROFILE variable.
    # Ask Windows for the user's own persisted value first so install, state and
    # runtime paths stay real folders instead of package private aliases.
    try {
        $persisted = [System.Environment]::GetEnvironmentVariable('USERPROFILE', 'User')
    }
    catch {
        $persisted = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($persisted) -and
        [System.IO.Path]::IsPathRooted($persisted) -and
        (Test-Path -LiteralPath $persisted -PathType Container)) {
        return $persisted
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $env:USERPROFILE
    }

    $folder = [System.Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($folder)) {
        return $folder
    }

    throw 'Windows did not report a user profile folder. Pass the paths explicitly instead.'
}

function Test-DseVirtualizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $candidate = $Path.Replace('/', '\')
    foreach ($alias in @('\AppData\Local\Packages\', '\AppData\Local\Temp\')) {
        if ($candidate.IndexOf($alias, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-DseKitRoot {
    [CmdletBinding()]
    param()

    # This file lives in <kit>\scripts, so the kit root is one folder up.
    return (Split-Path -Parent $PSScriptRoot)
}

function Test-DsePathInside {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $resolvedPath = (Resolve-DseFullPath $Path).TrimEnd('\')
    $resolvedParent = (Resolve-DseFullPath $Parent).TrimEnd('\')

    if ($resolvedPath.Equals($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $resolvedPath.StartsWith($resolvedParent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DseCodexHome {
    [CmdletBinding()]
    param(
        [string]$CodexHome
    )

    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        return Resolve-DseFullPath $CodexHome
    }

    # Resolve exactly the way Codex itself does. These environment variables are
    # only read here and are never modified.
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return Resolve-DseFullPath $env:CODEX_HOME
    }

    # Use the same hardened profile resolution as the install root. Reading
    # $env:USERPROFILE directly would follow the packaged-app redirection and put
    # config.toml under an AppData\Local\Packages alias, where the Codex desktop
    # app would not look for it.
    $profile = Get-DseUserProfile
    return Resolve-DseFullPath (Join-Path $profile '.codex')
}

function Get-DseInstallRoot {
    [CmdletBinding()]
    param(
        [string]$InstallRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        return Resolve-DseFullPath $InstallRoot
    }

    $defaults = Get-DseDefaults
    return (Resolve-DseFullPath (Join-Path (Get-DseUserProfile) $defaults.installRootName))
}

function Get-DseSubdirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $defaults = Get-DseDefaults
    $relative = $defaults.subdirectories.PSObject.Properties[$Name]
    if ($null -eq $relative) {
        throw "Unknown subdirectory name '$Name'."
    }
    return (Join-Path $InstallRoot $relative.Value)
}

function Get-DseRuntimeDirectory {
    [CmdletBinding()]
    param(
        [string]$RuntimeDirectory,
        [string]$InstallRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        return Resolve-DseFullPath $RuntimeDirectory
    }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-DseInstallRoot
    }
    return Get-DseSubdirectory -InstallRoot $InstallRoot -Name 'runtime'
}

function Get-DseStateDirectory {
    [CmdletBinding()]
    param([string]$InstallRoot)
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-DseInstallRoot }
    return Get-DseSubdirectory -InstallRoot $InstallRoot -Name 'state'
}

function Get-DseLogDirectory {
    [CmdletBinding()]
    param([string]$InstallRoot)
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-DseInstallRoot }
    return Get-DseSubdirectory -InstallRoot $InstallRoot -Name 'logs'
}

function Get-DseBackupDirectory {
    [CmdletBinding()]
    param([string]$InstallRoot)
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-DseInstallRoot }
    return Get-DseSubdirectory -InstallRoot $InstallRoot -Name 'backups'
}

function Get-DseStatePath {
    [CmdletBinding()]
    param([string]$InstallRoot)

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-DseInstallRoot }
    $defaults = Get-DseDefaults
    return (Join-Path (Get-DseStateDirectory -InstallRoot $InstallRoot) $defaults.stateFileName)
}

function New-DseDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return $Path
}

function Protect-DseLogText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $redacted = $Text
    $redacted = [regex]::Replace($redacted, '\bsk-[A-Za-z0-9_\-]{8,}', '[redacted-key]')
    $redacted = [regex]::Replace($redacted, '\bgh[pousr]_[A-Za-z0-9]{16,}', '[redacted-token]')
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|authorization|bearer)["'']?\s*[:=]\s*["'']?)([^\s"'',;}\]]{4,})',
        '$1[redacted]'
    )
    return $redacted
}

function Write-DseLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,
        [string]$LogPath,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'PASS', 'FAIL')]
        [string]$Level = 'INFO'
    )

    $safe = Protect-DseLogText $Message
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $Level, $safe

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $directory = Split-Path -Parent $LogPath
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            New-DseDirectory $directory | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }

    return $line
}

function Read-DseTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $false
    # Strict UTF-8: if the bytes are not valid UTF-8 we must not guess, because
    # decoding with replacement characters and writing the file back would
    # silently change bytes outside the managed block.
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $offset = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        $hasBom = $true
        $offset = 3
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = New-Object System.Text.UTF32Encoding($false, $true)
        $hasBom = $true
        $offset = 4
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
        $hasBom = $true
        $offset = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.BigEndianUnicodeEncoding($false, $true)
        $hasBom = $true
        $offset = 2
    }

    try {
        $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        # Do not corrupt the file by guessing. Tell the user what to do instead.
        throw ("The file is not valid UTF-8 text: $Path`n" +
               '         This usually means it was saved as ANSI or another legacy encoding.' + [Environment]::NewLine +
               '         Re-save it as UTF-8 in a text editor, then run the command again.' + [Environment]::NewLine +
               '         Nothing was changed.')
    }

    [pscustomobject]@{
        Path     = $Path
        Text     = $text
        Encoding = $encoding
        HasBom   = $hasBom
        Length   = $bytes.Length
    }
}

function Write-DseTextFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        $Encoding,
        [switch]$HasBom
    )

    if ($null -eq $Encoding) {
        $Encoding = New-Object System.Text.UTF8Encoding([bool]$HasBom)
    }

    $directory = Split-Path -Parent $Path
    if ($PSCmdlet.ShouldProcess($Path, 'Write file')) {
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            New-DseDirectory $directory | Out-Null
        }
        # Write to a sibling temp file first, then swap it into place. A crash or
        # power loss mid-write can then only lose the temp file, never truncate
        # the user's existing file.
        $tempPath = '{0}.dse-tmp-{1}' -f $Path, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            [System.IO.File]::WriteAllText($tempPath, $Text, $Encoding)

            if ([System.IO.File]::Exists($Path)) {
                try {
                    # Replace keeps the original file's identity and is atomic.
                    [System.IO.File]::Replace($tempPath, $Path, $null)
                }
                catch {
                    # Some filesystems do not support Replace; a forced move is
                    # the next best thing and still never leaves a partial file.
                    [System.IO.File]::Delete($Path)
                    [System.IO.File]::Move($tempPath, $Path)
                }
            }
            else {
                [System.IO.File]::Move($tempPath, $Path)
            }
        }
        finally {
            if ([System.IO.File]::Exists($tempPath)) {
                try { [System.IO.File]::Delete($tempPath) } catch { }
            }
        }
    }
    return $Path
}

function Get-DseFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $hash = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-DseLineEnding {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return "`r`n" }
    if ($Text.IndexOf("`r`n", [System.StringComparison]::Ordinal) -ge 0) { return "`r`n" }
    return "`n"
}

function Find-DseManagedBlock {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    $beginToken = "# BEGIN $Marker"
    $endToken = "# END $Marker"
    $beginCount = 0
    $endCount = 0
    $beginIndex = -1
    $endIndex = -1

    if ($null -eq $Text) { $Text = '' }

    $searchFrom = 0
    while ($searchFrom -lt $Text.Length) {
        $found = $Text.IndexOf($beginToken, $searchFrom, [System.StringComparison]::Ordinal)
        if ($found -lt 0) { break }
        if (($found -eq 0) -or ($Text[$found - 1] -eq "`n")) {
            $beginCount++
            if ($beginIndex -lt 0) { $beginIndex = $found }
        }
        $searchFrom = $found + 1
    }

    $searchFrom = 0
    while ($searchFrom -lt $Text.Length) {
        $found = $Text.IndexOf($endToken, $searchFrom, [System.StringComparison]::Ordinal)
        if ($found -lt 0) { break }
        if (($found -eq 0) -or ($Text[$found - 1] -eq "`n")) {
            $endCount++
            if ($endIndex -lt 0) { $endIndex = $found }
        }
        $searchFrom = $found + 1
    }

    [pscustomobject]@{
        Marker       = $Marker
        Found        = ($beginIndex -ge 0)
        BeginIndex   = $beginIndex
        EndIndex     = $endIndex
        BeginCount   = $beginCount
        EndCount     = $endCount
        IsWellFormed = (($beginCount -eq 1) -and ($endCount -eq 1) -and ($endIndex -gt $beginIndex))
    }
}

function Remove-DseManagedBlock {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $block = Find-DseManagedBlock -Text $Text -Marker $Marker
    if (-not $block.Found) { return $Text }

    if (-not $block.IsWellFormed) {
        throw ("The config file contains a damaged '$Marker' block " +
               "(begin markers: $($block.BeginCount), end markers: $($block.EndCount)). " +
               'Nothing was changed. Fix or remove those lines by hand, then run this command again.')
    }

    $endToken = "# END $Marker"
    $removeStart = $block.BeginIndex
    $removeEnd = $block.EndIndex + $endToken.Length

    # Swallow the line ending that joined the block to the previous line.
    if ($removeStart -gt 0 -and $Text[$removeStart - 1] -eq "`n") {
        $removeStart--
        if ($removeStart -gt 0 -and $Text[$removeStart - 1] -eq "`r") { $removeStart-- }
    }

    # Swallow any trailing spaces on the end line and its line ending.
    while ($removeEnd -lt $Text.Length -and $Text[$removeEnd] -ne "`n") { $removeEnd++ }
    if ($removeEnd -lt $Text.Length) { $removeEnd++ }

    return ($Text.Substring(0, $removeStart) + $Text.Substring($removeEnd))
}

function Add-DseManagedBlock {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Block
    )

    if ($null -eq $Text) { $Text = '' }
    $stripped = Remove-DseManagedBlock -Text $Text -Marker $Marker
    if ([string]::IsNullOrEmpty($stripped)) { return $Block }
    $eol = Get-DseLineEnding $stripped
    return ($stripped + $eol + $Block)
}

function Set-DseManagedBlock {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$BlockPath,
        [switch]$CreateIfMissing
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = Read-DseTextFile -Path $Path
    }
    elseif ($CreateIfMissing) {
        $current = [pscustomobject]@{
            Path     = $Path
            Text     = ''
            Encoding = (New-Object System.Text.UTF8Encoding($false))
            HasBom   = $false
            Length   = 0
        }
    }
    else {
        throw "The file does not exist: $Path"
    }

    $fragment = Read-DseTextFile -Path $BlockPath
    $eol = Get-DseLineEnding $current.Text
    $block = ($fragment.Text -replace "`r`n", "`n") -replace "`n", $eol
    if (-not $block.EndsWith($eol)) { $block += $eol }

    $updated = Add-DseManagedBlock -Text $current.Text -Marker $Marker -Block $block
    $changed = ($updated -ne $current.Text)

    if ($changed) {
        Write-DseTextFile -Path $Path -Text $updated -Encoding $current.Encoding | Out-Null
    }

    [pscustomobject]@{
        Path    = $Path
        Changed = $changed
        Text    = $updated
    }
}

function Get-DseVersionFromText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $match = [regex]::Match($Text, '(?<!\d)(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $null }

    return (New-Object System.Version(
        [int]$match.Groups[1].Value,
        [int]$match.Groups[2].Value,
        [int]$match.Groups[3].Value))
}

function Test-DseMinimumVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$MinimumVersion
    )

    $actual = Get-DseVersionFromText $Text
    if ($null -eq $actual) { return $false }
    return ($actual -ge ([version]$MinimumVersion))
}

function Invoke-DseVersionProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [int]$TimeoutSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "The version probe target does not exist: $ExePath"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExePath
    $startInfo.Arguments = '--version'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Split-Path -Parent $ExePath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    # Read both pipes concurrently. Draining them one after the other can deadlock
    # when the child fills the other pipe while we are still waiting on the first.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit([int]($TimeoutSeconds * 1000))) {
        try { $process.Kill() } catch { }
        throw "The version probe timed out after $TimeoutSeconds seconds: $ExePath"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()

    [pscustomobject]@{
        ExePath  = $ExePath
        ExitCode = $exitCode
        StdOut   = $stdout.Trim()
        StdErr   = $stderr.Trim()
        Raw      = ("$stdout`n$stderr").Trim()
        Version  = (Get-DseVersionFromText "$stdout`n$stderr")
    }
}

function Test-DseRuntimeDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        $Defaults,
        [switch]$AllowMissingRecommendedHelpers
    )

    if ($null -eq $Defaults) { $Defaults = Get-DseDefaults }

    $present = New-Object System.Collections.Generic.List[string]
    $missingRequired = New-Object System.Collections.Generic.List[string]
    $missingRecommended = New-Object System.Collections.Generic.List[string]

    $exists = Test-Path -LiteralPath $RuntimeDirectory -PathType Container
    if ($exists) {
        foreach ($name in $Defaults.requiredRuntimeFiles) {
            if (Test-Path -LiteralPath (Join-Path $RuntimeDirectory $name) -PathType Leaf) {
                $present.Add($name)
            }
            else {
                $missingRequired.Add($name)
            }
        }
        foreach ($name in $Defaults.recommendedRuntimeFiles) {
            if (Test-Path -LiteralPath (Join-Path $RuntimeDirectory $name) -PathType Leaf) {
                $present.Add($name)
            }
            else {
                $missingRecommended.Add($name)
            }
        }
    }

    $isValid = $exists -and ($missingRequired.Count -eq 0)
    if (-not $AllowMissingRecommendedHelpers) {
        $isValid = $isValid -and ($missingRecommended.Count -eq 0)
    }

    [pscustomobject]@{
        RuntimeDirectory               = $RuntimeDirectory
        Exists                         = $exists
        Present                        = $present.ToArray()
        MissingRequired                = $missingRequired.ToArray()
        MissingRecommended             = $missingRecommended.ToArray()
        AllowMissingRecommendedHelpers = [bool]$AllowMissingRecommendedHelpers
        IsValid                        = [bool]$isValid
    }
}

function Assert-DseManifestNotFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$Path
    )

    # A fixture or non-publishable bundle must never pass itself off as a working
    # runtime just because its hashes agree with the stub files inside it.
    $reason = $null
    foreach ($flagName in @('fixtureOnly', 'isFixture', 'testFixture')) {
        $property = $Manifest.PSObject.Properties[$flagName]
        if ($null -ne $property -and ($property.Value -eq $true -or "$($property.Value)" -ieq 'true')) {
            $reason = "it is marked '$flagName = true'"
            break
        }
    }
    if (-not $reason) {
        $property = $Manifest.PSObject.Properties['publishable']
        if ($null -ne $property -and ($property.Value -eq $false -or "$($property.Value)" -ieq 'false')) {
            $reason = "it is marked 'publishable = false'"
        }
    }
    if (-not $reason) {
        $property = $Manifest.PSObject.Properties['kind']
        if ($null -ne $property -and "$($property.Value)" -imatch '^(fixture|stub|test|mock)$') {
            $reason = "its kind is '$($property.Value)'"
        }
    }
    if (-not $reason) { return }

    $where = 'This runtime manifest'
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $where = "This runtime manifest is not a usable release: $Path" }

    throw ("$where`n" +
           "         It was rejected because $reason.`n" +
           '         A test fixture or non-publishable bundle cannot be installed as a working runtime.' + [Environment]::NewLine +
           '         Use the release archive produced by the project build, or point -RuntimeDirectory at your own build.' + [Environment]::NewLine +
           '         Nothing was changed.')
}

function Test-DseRuntimeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [string]$ManifestPath,
        $Defaults
    )

    if ($null -eq $Defaults) { $Defaults = Get-DseDefaults }

    $discoveredPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            throw "The runtime manifest passed with -RuntimeManifest does not exist: $ManifestPath"
        }
        $discoveredPath = $ManifestPath
    }
    else {
        $candidate = Join-Path $RuntimeDirectory $Defaults.runtimeManifestFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $discoveredPath = $candidate }
    }

    if ([string]::IsNullOrWhiteSpace($discoveredPath)) {
        return [pscustomobject]@{
            ManifestPath = $null
            Present      = $false
            Verified     = $false
            Problems     = @()
            Results      = @()
            MissingFiles = @()
            Mismatches   = @()
            Version      = $null
        }
    }

    try {
        $manifest = Get-Content -LiteralPath $discoveredPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "The runtime manifest is not valid JSON ($discoveredPath): $($_.Exception.Message)"
    }

    Assert-DseManifestNotFixture -Manifest $manifest -Path $discoveredPath

    # Accepted shapes:
    #   { "version": "0.153.4", "files": { "codex.exe": "<sha256>", ... } }
    #   { "version": "0.153.4", "files": [ { "name": "codex.exe", "sha256": "..." } ] }
    #
    # A manifest must describe every required runtime file. A manifest that only
    # hashes, say, a README must not be able to mark a runtime as verified.
    $requiredNames = @($Defaults.requiredRuntimeFiles | ForEach-Object { "$_" })
    $entries = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $manifest.PSObject.Properties['files']) {
        $problems.Add("the manifest has no 'files' section")
    }
    else {
        $files = $manifest.files

        if ($files -is [System.Management.Automation.PSCustomObject]) {
            # Object form: the property names are the file names.
            foreach ($property in $files.PSObject.Properties) {
                $entries.Add([pscustomobject]@{ Name = "$($property.Name)"; Sha256 = "$($property.Value)" })
            }
        }
        elseif ($files -is [System.Collections.IEnumerable] -and -not ($files -is [string])) {
            # Array form: one object per file, with name and sha256 fields.
            foreach ($item in $files) {
                if ($null -eq $item) {
                    $problems.Add('an entry in the files list is empty')
                    continue
                }
                if (-not $item.PSObject.Properties['name']) {
                    $problems.Add('an entry in the files list has no name')
                    continue
                }
                $sha = ''
                if ($item.PSObject.Properties['sha256']) { $sha = "$($item.sha256)" }
                $entries.Add([pscustomobject]@{ Name = "$($item.name)"; Sha256 = $sha })
            }
        }
        else {
            $problems.Add("the 'files' section must be an object or a list")
        }
    }

    foreach ($entry in $entries) {
        # The name must be exactly one of the runtime files this product needs.
        # That also rejects path traversal, subfolders and unexpected files.
        if ($requiredNames -notcontains $entry.Name) {
            $problems.Add("unexpected file in the manifest: '$($entry.Name)'")
        }
        if ($entry.Name -match '[\\/]' -or $entry.Name -match '\.\.') {
            $problems.Add("the manifest file name is not a plain file name: '$($entry.Name)'")
        }
        if ($entry.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $problems.Add("the manifest hash for '$($entry.Name)' is not a valid SHA256")
        }
    }

    $duplicates = @($entries | Group-Object -Property Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($duplicate in $duplicates) {
        $problems.Add("the manifest lists '$duplicate' more than once")
    }

    foreach ($name in $requiredNames) {
        if (@($entries | Where-Object { $_.Name -eq $name }).Count -eq 0) {
            $problems.Add("the manifest is missing required file '$name'")
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    $mismatches = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $filePath = Join-Path $RuntimeDirectory $entry.Name
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $missing.Add($entry.Name)
            $results.Add([pscustomobject]@{ Name = $entry.Name; Status = 'missing'; Expected = $entry.Sha256; Actual = $null })
            continue
        }
        $actual = Get-DseFileSha256 -Path $filePath
        if ($actual -eq $entry.Sha256.ToLowerInvariant()) {
            $results.Add([pscustomobject]@{ Name = $entry.Name; Status = 'ok'; Expected = $entry.Sha256; Actual = $actual })
        }
        else {
            $mismatches.Add($entry.Name)
            $results.Add([pscustomobject]@{ Name = $entry.Name; Status = 'mismatch'; Expected = $entry.Sha256; Actual = $actual })
        }
    }

    $version = $null
    if ($null -ne $manifest.PSObject.Properties['version']) { $version = "$($manifest.version)" }

    $verified = (($missing.Count -eq 0) -and ($mismatches.Count -eq 0) -and ($problems.Count -eq 0) -and ($entries.Count -gt 0))

    [pscustomobject]@{
        ManifestPath = $discoveredPath
        Present      = $true
        Verified     = $verified
        Problems     = $problems.ToArray()
        Results      = $results.ToArray()
        MissingFiles = $missing.ToArray()
        Mismatches   = $mismatches.ToArray()
        Version      = $version
    }
}

function Get-DseDesktopExecutable {
    [CmdletBinding()]
    param($Defaults)

    if ($null -eq $Defaults) { $Defaults = Get-DseDefaults }

    if (-not (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) {
        throw 'Get-AppxPackage is not available in this PowerShell session, so the Codex desktop app cannot be located. Run this from a normal Windows PowerShell or PowerShell 7 window.'
    }

    $packages = @(Get-AppxPackage -Name $Defaults.desktopPackageName -ErrorAction SilentlyContinue)
    if ($packages.Count -eq 0) {
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $Defaults.desktopPackageName })
    }
    if ($packages.Count -eq 0) {
        throw "The packaged Codex desktop app ('$($Defaults.desktopPackageName)') is not installed for this user. Install or update the Codex desktop app, then run this again."
    }

    $chosen = $packages |
        Sort-Object -Property @{ Expression = { try { [version]$_.Version } catch { [version]'0.0.0' } } } -Descending |
        Select-Object -First 1

    $executable = Join-Path $chosen.InstallLocation $Defaults.desktopRelativeExePath

    [pscustomobject]@{
        PackageName     = $chosen.Name
        PackageVersion  = "$($chosen.Version)"
        InstallLocation = $chosen.InstallLocation
        ExecutablePath  = $executable
        Exists          = (Test-Path -LiteralPath $executable -PathType Leaf)
    }
}

function Get-DseRunningDesktopProcesses {
    [CmdletBinding()]
    param(
        $Defaults,
        [string]$InstallLocation
    )

    if ($null -eq $Defaults) { $Defaults = Get-DseDefaults }

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name $Defaults.desktopProcessName -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { $path = $null }

        $isMatch = $false
        if ($path) {
            if (-not [string]::IsNullOrWhiteSpace($InstallLocation)) {
                $normalizedRoot = $InstallLocation.TrimEnd('\')
                $isMatch = $path.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
            }
            else {
                $isMatch = ($path -like "*\$($Defaults.desktopRelativeExePath)")
            }
        }

        $matches.Add([pscustomobject]@{
            Id             = $process.Id
            ProcessName    = $process.ProcessName
            Path           = $path
            PathKnown      = [bool]$path
            IsInstalledApp = [bool]$isMatch
        })
    }

    return $matches.ToArray()
}

function Get-DseTomlBasicString {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

function New-DseDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [string]$IconPath,
        [string]$PowerShellPath
    )

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $candidates = @(
            (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        )
        $onPath = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
        if ($onPath) { $candidates += $onPath.Source }
        if ($PSVersionTable.PSEdition -eq 'Core') { $candidates += (Get-Process -Id $PID).Path }

        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $PowerShellPath = $candidate
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        throw 'Could not find a PowerShell executable to point the shortcut at.'
    }

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create desktop shortcut')) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $PowerShellPath
        $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
        $shortcut.WorkingDirectory = Split-Path -Parent $LauncherPath
        $shortcut.Description = 'Launch the Codex desktop app with the native DeepSeek backend'
        if ($IconPath -and (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            $shortcut.IconLocation = "$IconPath,0"
        }
        $shortcut.WindowStyle = 1
        $shortcut.Save()
    }

    return $ShortcutPath
}

function Test-DseDesktopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return $false }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $folder = Split-Path -Parent $LauncherPath
        return ($shortcut.Arguments -like "*$LauncherPath*") -and
               ([string]::IsNullOrWhiteSpace($shortcut.WorkingDirectory) -or $shortcut.WorkingDirectory -eq $folder)
    }
    catch {
        return $false
    }
}

function Remove-DseDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'not found' }
    }
    if (-not (Test-DseDesktopShortcut -ShortcutPath $ShortcutPath -LauncherPath $LauncherPath)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'the shortcut does not belong to this product' }
    }

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Remove desktop shortcut')) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
    return [pscustomobject]@{ Removed = $true; Reason = 'removed' }
}

function Read-DseInstallState {
    [CmdletBinding()]
    param(
        [string]$InstallRoot,
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-DseStatePath -InstallRoot $InstallRoot
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }

    try {
        return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "The install state file is not valid JSON: $StatePath ($($_.Exception.Message))"
    }
}

function Write-DseInstallState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$InstallRoot,
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-DseStatePath -InstallRoot $InstallRoot
    }

    if ($PSCmdlet.ShouldProcess($StatePath, 'Write install state')) {
        $directory = Split-Path -Parent $StatePath
        New-DseDirectory $directory | Out-Null
        $json = $State | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    return $StatePath
}

function Copy-DseBackup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = Split-Path -Leaf $Path
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $BackupDirectory ('{0}.{1}.bak' -f $Label, $stamp)
    $counter = 0
    while (Test-Path -LiteralPath $target) {
        $counter++
        $target = Join-Path $BackupDirectory ('{0}.{1}-{2}.bak' -f $Label, $stamp, $counter)
    }

    if ($PSCmdlet.ShouldProcess($Path, "Back up to $target")) {
        New-DseDirectory $BackupDirectory | Out-Null
        Copy-Item -LiteralPath $Path -Destination $target -Force
    }

    return $target
}
