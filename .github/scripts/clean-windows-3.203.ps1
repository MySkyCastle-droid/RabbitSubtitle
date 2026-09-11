[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SourceSha256,
    [Parameter(Mandatory = $true)][string]$ArtifactSha256,
    [Parameter(Mandatory = $true)][string]$ArtifactBytes,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lf = [string][char]10
$cr = [string][char]13

$expectedVersion = '3.203'
$expectedSourceSha256 = '8ffc581ad8a6dc1e345263f896187d6757ef8fcc2bcf3d51cd3dc31466086dc5'
$expectedMainSpecSha256 = '0064174F1D3944B825F3D63316548B2AE8435C0D1BB060CA66F2F8497126BC0B'
$expectedSpeechSpecSha256 = '744D80FA70E81F9CE6B05BA5A343BFBF00C9EF89B4EAC5DDA8A86867B479F3F6'
$expectedAssetName = "RabbitSubtitle-$expectedVersion-Windows-x64.zip"
$expectedPackageRoot = "RabbitSubtitle-$expectedVersion"
$startedAt = [DateTimeOffset]::UtcNow

$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$recordsDirectory = Join-Path $EvidenceDirectory 'records'
$outputsDirectory = Join-Path $EvidenceDirectory 'outputs'
New-Item -ItemType Directory -Path $EvidenceDirectory, $recordsDirectory, $outputsDirectory -Force | Out-Null

$runIdentity = if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    [Guid]::NewGuid().ToString('N')
} else {
    "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
}
$temporaryParent = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [IO.Path]::GetTempPath()
} else {
    [IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
$stateRoot = Join-Path $temporaryParent "rabbit-subtitle-clean-state-$runIdentity"
$extractRoot = Join-Path $temporaryParent "rabbit-subtitle-clean-extract-$runIdentity"
if ((Test-Path -LiteralPath $stateRoot) -or (Test-Path -LiteralPath $extractRoot)) {
    throw 'Fresh-state or extraction directory already exists; refusing to reuse state.'
}
New-Item -ItemType Directory -Path $stateRoot, $extractRoot | Out-Null

$checks = [ordered]@{}
$currentPhase = 'initialization'
$fatalError = $null
$package = $null
$artifactByteCount = 0L
$beforeSnapshotPath = Join-Path $recordsDirectory 'package-tree-before.json'
$afterSnapshotPath = Join-Path $recordsDirectory 'package-tree-after.json'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    Write-Utf8NoBom -Path $Path -Text (($Value | ConvertTo-Json -Depth 30) + $lf)
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-Sha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-StrictUtf8 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3) {
        $hasBom = $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        Assert-True -Condition (-not $hasBom) -Message "$([IO.Path]::GetFileName($Path)) must not contain a UTF-8 BOM."
    }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw "$([IO.Path]::GetFileName($Path)) is not strict UTF-8."
    }
}

function Assert-JsonObjectKeys {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-True -Condition ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) -Message "$Label must be a JSON object."
    $names = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        Assert-True -Condition ($seen.Add($property.Name)) -Message "$Label contains duplicate property '$($property.Name)'."
        $names.Add($property.Name)
    }
    $actualSorted = @($names | Sort-Object -CaseSensitive)
    $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
    Assert-True -Condition (($actualSorted -join $lf) -ceq ($expectedSorted -join $lf)) -Message "$Label keys are incomplete or contain unexpected fields. Actual: $($actualSorted -join ', ')."
}

function Get-PackageSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $rootPath -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
        $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($item.PSIsContainer) {
            $items.Add([ordered]@{ path = "$relative/"; type = 'directory'; reparsePoint = $isReparse })
        } else {
            $items.Add([ordered]@{
                path = $relative
                type = 'file'
                bytes = [int64]$item.Length
                sha256 = Get-Sha256Lower -Path $item.FullName
                reparsePoint = $isReparse
            })
        }
    }
    return @($items)
}

function New-CleanEnvironment {
    param([Parameter(Mandatory = $true)][string]$Name)
    $root = Join-Path $stateRoot $Name
    Assert-True -Condition (-not (Test-Path -LiteralPath $root)) -Message "Clean runtime state '$Name' was unexpectedly reused."
    $localAppData = Join-Path $root 'LocalAppData'
    $appData = Join-Path $root 'AppData'
    $userProfile = Join-Path $root 'UserProfile'
    $temp = Join-Path $root 'Temp'
    $hfHome = Join-Path $root 'HuggingFace'
    $torchHome = Join-Path $root 'Torch'
    New-Item -ItemType Directory -Path $localAppData, $appData, $userProfile, $temp, $hfHome, $torchHome | Out-Null
    $systemRoot = [IO.Path]::GetFullPath($env:SystemRoot)
    $sanitizedPath = @((Join-Path $systemRoot 'System32'), (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0')) -join ';'
    $environment = [ordered]@{
        ALL_PROXY = ''
        APPDATA = $appData
        COMSPEC = (Join-Path $systemRoot 'System32\cmd.exe')
        HF_HOME = $hfHome
        HF_HUB_CACHE = (Join-Path $hfHome 'hub')
        HF_HUB_DISABLE_IMPLICIT_TOKEN = '1'
        HF_HUB_DISABLE_TELEMETRY = '1'
        LOCALAPPDATA = $localAppData
        NO_PROXY = '127.0.0.1,localhost'
        NUMBER_OF_PROCESSORS = [string]$env:NUMBER_OF_PROCESSORS
        PATH = $sanitizedPath
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        PROCESSOR_ARCHITECTURE = [string]$env:PROCESSOR_ARCHITECTURE
        PYANNOTE_METRICS_ENABLED = '0'
        RABBITSUBTITLE_NO_BROWSER = '1'
        SYSTEMDRIVE = [string]$env:SystemDrive
        SYSTEMROOT = $systemRoot
        TEMP = $temp
        TMP = $temp
        TORCH_HOME = $torchHome
        USERPROFILE = $userProfile
        WINDIR = $systemRoot
    }
    return [pscustomobject]@{ Name = $Name; Root = $root; LocalAppData = $localAppData; Environment = $environment }
}

function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter()][int[]]$AllowedExitCodes = @(0),
        [Parameter()][string]$RecordName
    )
    $processInfo = [Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $FilePath
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { [void]$processInfo.ArgumentList.Add($argument) }
    $processInfo.Environment.Clear()
    foreach ($key in $Environment.Keys) { $processInfo.Environment[[string]$key] = [string]$Environment[$key] }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    Assert-True -Condition ($process.Start()) -Message "Failed to start $FilePath."
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch {}
        throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
    }
    $process.WaitForExit()
    $stopwatch.Stop()
    $result = [ordered]@{
        file = [IO.Path]::GetFileName($FilePath)
        arguments = @($ArgumentList)
        exitCode = [int]$process.ExitCode
        elapsedMilliseconds = [int64]$stopwatch.ElapsedMilliseconds
        stdout = $stdoutTask.GetAwaiter().GetResult()
        stderr = $stderrTask.GetAwaiter().GetResult()
    }
    if (-not [string]::IsNullOrWhiteSpace($RecordName)) { Write-Json -Path (Join-Path $recordsDirectory "$RecordName.json") -Value $result }
    Assert-True -Condition ($AllowedExitCodes -contains $process.ExitCode) -Message "$([IO.Path]::GetFileName($FilePath)) returned exit code $($process.ExitCode)."
    return [pscustomobject]$result
}

function Assert-NoPythonOnPath {
    param([Parameter(Mandatory = $true)][pscustomobject]$CleanRuntime)
    $whereExe = Join-Path $CleanRuntime.Environment.SYSTEMROOT 'System32\where.exe'
    $results = [Collections.Generic.List[object]]::new()
    foreach ($command in @('python.exe', 'python3.exe', 'py.exe')) {
        $safeName = $command.Replace('.', '-')
        $result = Invoke-Process -FilePath $whereExe -ArgumentList @($command) -WorkingDirectory $CleanRuntime.Root -Environment $CleanRuntime.Environment -TimeoutSeconds 15 -AllowedExitCodes @(0, 1) -RecordName "path-$($CleanRuntime.Name)-$safeName"
        Assert-True -Condition ($result.exitCode -ne 0) -Message "$command is visible in the sanitized runtime PATH."
        $results.Add([ordered]@{ command = $command; available = $false })
    }
    return @($results)
}

function Write-Request {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    Write-Utf8NoBom -Path $Path -Text (($Value | ConvertTo-Json -Depth 20 -Compress) + $lf)
}

function Invoke-SpeechRequest {
    param(
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][pscustomobject]$CleanRuntime,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $caseDirectory = Join-Path $CleanRuntime.Root $CaseName
    New-Item -ItemType Directory -Path $caseDirectory | Out-Null
    $requestPath = Join-Path $caseDirectory 'request.json'
    $resultPath = Join-Path $caseDirectory 'result.json'
    $Payload['output'] = $resultPath
    Write-Request -Path $requestPath -Value $Payload
    $processResult = Invoke-Process -FilePath (Join-Path $package 'speech-runtime\RabbitSubtitleSpeech.exe') -ArgumentList @($requestPath) -WorkingDirectory $caseDirectory -Environment $Environment -TimeoutSeconds $TimeoutSeconds -RecordName "speech-$CaseName-process"
    Assert-True -Condition (Test-Path -LiteralPath $resultPath -PathType Leaf) -Message "Speech request '$CaseName' did not write result.json."
    $result = (Read-StrictUtf8 -Path $resultPath) | ConvertFrom-Json -Depth 20
    Assert-True -Condition ([int]$result.cloudSpeechCalls -eq 0) -Message "Speech request '$CaseName' reported a cloud speech call."
    Write-Json -Path (Join-Path $recordsDirectory "speech-$CaseName-result.json") -Value $result
    return $result
}

function Test-ProcessBelongsToPackage {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][int]$RootProcessId, [Parameter(Mandatory = $true)][string]$PackageRoot)
    $visited = [Collections.Generic.HashSet[int]]::new()
    $candidate = $ProcessId
    while ($candidate -gt 0 -and $visited.Add($candidate)) {
        if ($candidate -eq $RootProcessId) { return $true }
        $record = Get-CimInstance Win32_Process -Filter "ProcessId = $candidate" -ErrorAction SilentlyContinue
        if ($null -eq $record) { return $false }
        if (-not [string]::IsNullOrWhiteSpace([string]$record.ExecutablePath)) {
            $executable = [IO.Path]::GetFullPath([string]$record.ExecutablePath)
            $packagePrefix = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
            if ($executable.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        $candidate = [int]$record.ParentProcessId
    }
    return $false
}

function Assert-FileIdentity {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int64]$Bytes, [Parameter(Mandatory = $true)][string]$Sha256)
    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "Installed model file is missing: $Path"
    $item = Get-Item -LiteralPath $Path
    Assert-True -Condition ([int64]$item.Length -eq $Bytes) -Message "Installed model file has the wrong size: $Path"
    Assert-True -Condition ((Get-Sha256Lower -Path $Path) -ceq $Sha256.ToLowerInvariant()) -Message "Installed model file has the wrong SHA-256: $Path"
}

try {
    $currentPhase = 'input-validation'
    Assert-True -Condition ($Version -ceq $expectedVersion) -Message "Only RabbitSubtitle $expectedVersion is accepted."
    $SourceSha256 = $SourceSha256.ToLowerInvariant()
    $ArtifactSha256 = $ArtifactSha256.ToLowerInvariant()
    Assert-True -Condition ($SourceSha256 -cmatch '^[0-9a-f]{64}$') -Message 'sourceSha256 must be 64 lowercase hexadecimal characters.'
    Assert-True -Condition ($SourceSha256 -ceq $expectedSourceSha256) -Message 'sourceSha256 is not the frozen 3.203 source identity.'
    Assert-True -Condition ($ArtifactSha256 -cmatch '^[0-9a-f]{64}$') -Message 'artifactSha256 must be 64 hexadecimal characters.'
    Assert-True -Condition ($ArtifactBytes -cmatch '^[1-9][0-9]*$') -Message 'artifactBytes must be a positive base-10 integer.'
    $parsedBytes = [int64]::TryParse($ArtifactBytes, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$artifactByteCount)
    Assert-True -Condition $parsedBytes -Message 'artifactBytes does not fit in a signed 64-bit integer.'
    Assert-True -Condition (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -Message 'Downloaded candidate archive is missing.'
    $archiveItem = Get-Item -LiteralPath $ArchivePath
    Assert-True -Condition ([int64]$archiveItem.Length -eq $artifactByteCount) -Message 'Downloaded ZIP size does not match artifactBytes.'
    Assert-True -Condition ((Get-Sha256Lower -Path $ArchivePath) -ceq $ArtifactSha256) -Message 'Downloaded ZIP SHA-256 does not match artifactSha256.'
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) -Message 'GH_TOKEN must not be present during package execution.'
    Assert-True -Condition ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) -Message 'GITHUB_TOKEN must not be present during package execution.'

    $downloadMetadataPath = Join-Path $recordsDirectory 'download-metadata.json'
    Assert-True -Condition (Test-Path -LiteralPath $downloadMetadataPath -PathType Leaf) -Message 'Authenticated download metadata record is missing.'
    $downloadMetadata = (Read-StrictUtf8 -Path $downloadMetadataPath) | ConvertFrom-Json -Depth 20
    $downloadMatches = [string]$downloadMetadata.version -ceq $Version -and [string]$downloadMetadata.sourceSha256 -ceq $SourceSha256 -and [string]$downloadMetadata.artifactSha256 -ceq $ArtifactSha256 -and [int64]$downloadMetadata.artifactBytes -eq $artifactByteCount -and [string]$downloadMetadata.assetName -ceq $expectedAssetName -and [bool]$downloadMetadata.releaseDraft -and [string]$downloadMetadata.repository -ceq 'MySkyCastle-droid/RabbitSubtitle'
    Assert-True -Condition $downloadMatches -Message 'Download metadata is not bound to the requested draft artifact.'
    $checks.inputValidation = [ordered]@{
        passed = $true
        expectedVersion = $expectedVersion
        frozenSourceSha256 = $expectedSourceSha256
        artifactSha256 = $ArtifactSha256
        artifactBytes = $artifactByteCount
        tokenPresentDuringExecution = $false
    }

    $currentPhase = 'zip-safety-and-extraction'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        Assert-True -Condition ($zip.Entries.Count -gt 0) -Message 'Candidate ZIP is empty.'
        Assert-True -Condition ($zip.Entries.Count -le 50000) -Message 'Candidate ZIP has too many entries.'
        $seenEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $totalUncompressed = 0L
        $fileCount = 0
        $reservedDevices = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
        foreach ($entry in $zip.Entries) {
            $entryName = [string]$entry.FullName
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($entryName)) -Message 'ZIP contains an unnamed entry.'
            Assert-True -Condition (-not $entryName.Contains('\')) -Message "ZIP entry uses a backslash: $entryName"
            Assert-True -Condition (-not $entryName.StartsWith('/', [StringComparison]::Ordinal)) -Message "ZIP entry is absolute: $entryName"
            Assert-True -Condition ($entryName -cnotmatch '[\x00-\x1f:]') -Message "ZIP entry contains a forbidden character: $entryName"
            $normalizedEntry = $entryName.TrimEnd('/')
            $segments = @($normalizedEntry.Split('/'))
            Assert-True -Condition ($segments.Count -gt 0 -and $segments[0] -ceq $expectedPackageRoot) -Message "ZIP entry is outside the exact package root: $entryName"
            $unsafeSegments = @($segments | Where-Object { $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..' })
            Assert-True -Condition ($unsafeSegments.Count -eq 0) -Message "ZIP entry contains an unsafe path segment: $entryName"
            foreach ($segment in $segments) {
                Assert-True -Condition (-not $segment.EndsWith('.', [StringComparison]::Ordinal) -and -not $segment.EndsWith(' ', [StringComparison]::Ordinal)) -Message "ZIP entry has a Windows-ambiguous path segment: $entryName"
                $deviceBase = $segment.Split('.')[0].ToUpperInvariant()
                Assert-True -Condition ($reservedDevices -cnotcontains $deviceBase) -Message "ZIP entry uses a reserved Windows device name: $entryName"
            }
            Assert-True -Condition ($seenEntries.Add($normalizedEntry)) -Message "ZIP contains a case-insensitive duplicate entry: $entryName"
            $externalAttributes = ([int64]$entry.ExternalAttributes) -band 0xFFFFFFFFL
            $unixType = ($externalAttributes -shr 16) -band 0xF000
            Assert-True -Condition ($unixType -ne 0xA000) -Message "ZIP contains a symbolic-link entry: $entryName"
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                $fileCount++
                Assert-True -Condition ([int64]$entry.Length -le 8GB) -Message "ZIP entry is unreasonably large: $entryName"
                $totalUncompressed += [int64]$entry.Length
                Assert-True -Condition ($totalUncompressed -le 20GB) -Message 'ZIP expands beyond the 20 GiB acceptance limit.'
                if ($entry.Length -gt 1MB) {
                    Assert-True -Condition ($entry.CompressedLength -gt 0) -Message "ZIP entry has an invalid compressed size: $entryName"
                    Assert-True -Condition (($entry.Length / $entry.CompressedLength) -le 2000) -Message "ZIP entry has an unsafe compression ratio: $entryName"
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractRoot, $false)
    $package = Join-Path $extractRoot $expectedPackageRoot
    Assert-True -Condition (Test-Path -LiteralPath $package -PathType Container) -Message 'Exact extracted package root is missing.'
    $topLevelEntries = @(Get-ChildItem -LiteralPath $extractRoot -Force)
    $singleExactRoot = $topLevelEntries.Count -eq 1 -and $topLevelEntries[0].PSIsContainer -and $topLevelEntries[0].Name -ceq $expectedPackageRoot
    Assert-True -Condition $singleExactRoot -Message 'Candidate ZIP must contain exactly one package root.'
    $reparsePoints = @(Get-ChildItem -LiteralPath $package -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    Assert-True -Condition ($reparsePoints.Count -eq 0) -Message 'Extracted package contains a reparse point.'
    $checks.zipSafety = [ordered]@{
        passed = $true
        root = $expectedPackageRoot
        entries = $seenEntries.Count
        files = $fileCount
        uncompressedBytes = $totalUncompressed
        reparsePoints = 0
    }

    $currentPhase = 'package-identity'
    $requiredPaths = @(
        "RabbitSubtitle-$expectedVersion.exe"
        'ffmpeg.exe'
        'ffprobe.exe'
        'speech-runtime/RabbitSubtitleSpeech.exe'
        'RELEASE-BUILD.json'
        'VERSION.txt'
        "CLEAN-WINDOWS-TEST-CHECKLIST-$expectedVersion.txt"
        "START-HERE-$expectedVersion.txt"
        'THIRD-PARTY-SPEECH-NOTICES.md'
        'THIRD-PARTY-LICENSES/README.txt'
        'THIRD-PARTY-LICENSES/FFmpeg-8.1/SOURCE.md'
        'THIRD-PARTY-LICENSES/FFmpeg-8.1/SHA256SUMS.txt'
        'THIRD-PARTY-LICENSES/FFmpeg-8.1/LICENSE-NOTICE.txt'
        'app_modules/speech-copy.json'
        'app_modules/speaker-setup-copy.json'
        'app_modules/hojo_vendor/model-manifest.json'
        'index.html'
        'twobu_logo_From_EVE4.png'
    )
    foreach ($relativePath in $requiredPaths) {
        $candidatePath = Join-Path $package $relativePath
        Assert-True -Condition (Test-Path -LiteralPath $candidatePath -PathType Leaf) -Message "Required package file is missing: $relativePath"
        Assert-True -Condition ((Get-Item -LiteralPath $candidatePath).Length -gt 0) -Message "Required package file is empty: $relativePath"
    }
    foreach ($forbidden in @('.env', 'hf_credentials.json', 'license.json', 'queue.sqlite3')) {
        $matches = @(Get-ChildItem -LiteralPath $package -Force -Recurse -File | Where-Object { $_.Name -ieq $forbidden })
        Assert-True -Condition ($matches.Count -eq 0) -Message "Package contains forbidden runtime or credential state: $forbidden"
    }

    $requiredLocales = @('en', 'ja', 'ko', 'zh-CN', 'zh-TW')
    foreach ($copyFile in @('app_modules/speech-copy.json', 'app_modules/speaker-setup-copy.json')) {
        $copyPath = Join-Path $package $copyFile
        $copy = (Read-StrictUtf8 -Path $copyPath) | ConvertFrom-Json -Depth 30
        $locales = @($copy.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        Assert-True -Condition (($locales -join ',') -ceq ($requiredLocales -join ',')) -Message "$copyFile does not contain exactly the five supported locales."
    }

    $ffmpegSumsPath = Join-Path $package 'THIRD-PARTY-LICENSES/FFmpeg-8.1/SHA256SUMS.txt'
    $ffmpegSums = Read-StrictUtf8 -Path $ffmpegSumsPath
    foreach ($binary in @('ffmpeg.exe', 'ffprobe.exe')) {
        $sumPattern = '(?mi)^([0-9a-f]{64})  bin/' + [regex]::Escape($binary) + '$'
        $sumMatches = @([regex]::Matches($ffmpegSums, $sumPattern))
        Assert-True -Condition ($sumMatches.Count -eq 1) -Message "FFmpeg SHA256SUMS.txt has no unique $binary identity."
        $declaredSha = $sumMatches[0].Groups[1].Value.ToLowerInvariant()
        Assert-True -Condition ((Get-Sha256Lower -Path (Join-Path $package $binary)) -ceq $declaredSha) -Message "$binary does not match its third-party SHA256SUMS.txt declaration."
    }

    $versionText = Read-StrictUtf8 -Path (Join-Path $package 'VERSION.txt')
    $expectedVersionText = "RabbitSubtitle $expectedVersion"
    $versionExact = $versionText -ceq $expectedVersionText -or $versionText -ceq ($expectedVersionText + $lf)
    Assert-True -Condition $versionExact -Message 'VERSION.txt does not contain the exact release identity.'

    $checklistPath = Join-Path $package "CLEAN-WINDOWS-TEST-CHECKLIST-$expectedVersion.txt"
    $checklistText = Read-StrictUtf8 -Path $checklistPath
    $checklistLines = @($checklistText -split '\r?\n')
    $headingExact = $checklistLines.Count -gt 0 -and $checklistLines[0] -ceq "RabbitSubtitle $expectedVersion — Clean Windows acceptance checklist"
    Assert-True -Condition $headingExact -Message 'Clean Windows checklist heading is not exact.'
    $discoveredVersions = @([regex]::Matches($checklistText, 'RabbitSubtitle(?:-|\s+)(\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True -Condition ($discoveredVersions.Count -eq 1 -and $discoveredVersions[0] -ceq $expectedVersion) -Message 'Clean Windows checklist contains a missing or mismatched version.'
    $requiredChecklistPhrases = @(
        'Install the optional speech alignment models from an empty cache'
        'Run one speech alignment locally after installation'
        'install the speaker diarization models from an empty cache'
        'Run one speaker diarization locally after installation'
        'NOT TESTED / BLOCKED'
    )
    $normalizedChecklist = ($checklistText -split '\s+' | Where-Object { $_ }) -join ' '
    foreach ($phrase in $requiredChecklistPhrases) {
        Assert-True -Condition ($normalizedChecklist.Contains($phrase, [StringComparison]::Ordinal)) -Message "Clean Windows checklist omits required phrase: $phrase"
    }

    $manifestPath = Join-Path $package 'RELEASE-BUILD.json'
    $manifestText = Read-StrictUtf8 -Path $manifestPath
    Assert-True -Condition (-not $manifestText.Contains($cr)) -Message 'RELEASE-BUILD.json must use LF line endings.'
    $singleFinalLf = $manifestText.EndsWith($lf, [StringComparison]::Ordinal) -and -not $manifestText.EndsWith($lf + $lf, [StringComparison]::Ordinal)
    Assert-True -Condition $singleFinalLf -Message 'RELEASE-BUILD.json must have exactly one final LF.'
    $manifestDocument = [Text.Json.JsonDocument]::Parse($manifestText)
    try {
        $manifestRoot = $manifestDocument.RootElement
        Assert-JsonObjectKeys -Element $manifestRoot -Expected @('schemaVersion', 'version', 'sourceSha256', 'specSha256', 'executableSha256') -Label 'RELEASE-BUILD.json'
        Assert-JsonObjectKeys -Element ($manifestRoot.GetProperty('specSha256')) -Expected @('main', 'speech') -Label 'RELEASE-BUILD.json specSha256'
        Assert-JsonObjectKeys -Element ($manifestRoot.GetProperty('executableSha256')) -Expected @('main', 'speech') -Label 'RELEASE-BUILD.json executableSha256'
    } finally {
        $manifestDocument.Dispose()
    }
    $manifest = $manifestText | ConvertFrom-Json -Depth 10
    Assert-True -Condition ([int]$manifest.schemaVersion -eq 1) -Message 'RELEASE-BUILD.json schemaVersion is not 1.'
    Assert-True -Condition ([string]$manifest.version -ceq $expectedVersion) -Message 'RELEASE-BUILD.json version mismatch.'
    Assert-True -Condition ([string]$manifest.sourceSha256 -ceq $expectedSourceSha256) -Message 'RELEASE-BUILD.json source SHA mismatch.'
    $specsExact = [string]$manifest.specSha256.main -ceq $expectedMainSpecSha256 -and [string]$manifest.specSha256.speech -ceq $expectedSpeechSpecSha256
    Assert-True -Condition $specsExact -Message 'RELEASE-BUILD.json spec SHA mismatch.'

    $mainExe = Join-Path $package "RabbitSubtitle-$expectedVersion.exe"
    $speechExe = Join-Path $package 'speech-runtime\RabbitSubtitleSpeech.exe'
    $mainExeSha = (Get-Sha256Lower -Path $mainExe).ToUpperInvariant()
    $speechExeSha = (Get-Sha256Lower -Path $speechExe).ToUpperInvariant()
    $executablesExact = [string]$manifest.executableSha256.main -ceq $mainExeSha -and [string]$manifest.executableSha256.speech -ceq $speechExeSha
    Assert-True -Condition $executablesExact -Message 'RELEASE-BUILD.json executable SHA mismatch.'
    $expectedManifest = [ordered]@{
        executableSha256 = [ordered]@{ main = $mainExeSha; speech = $speechExeSha }
        schemaVersion = 1
        sourceSha256 = $expectedSourceSha256
        specSha256 = [ordered]@{ main = $expectedMainSpecSha256; speech = $expectedSpeechSpecSha256 }
        version = $expectedVersion
    }
    $canonicalManifest = (($expectedManifest | ConvertTo-Json -Depth 5) -replace ($cr + $lf), $lf) + $lf
    Assert-True -Condition ($manifestText -ceq $canonicalManifest) -Message 'RELEASE-BUILD.json is not canonical immutable JSON.'

    $peVersions = [ordered]@{}
    foreach ($executableCase in @(
        [ordered]@{ role = 'main'; path = $mainExe; original = "RabbitSubtitle-$expectedVersion.exe" },
        [ordered]@{ role = 'speech'; path = $speechExe; original = 'RabbitSubtitleSpeech.exe' }
    )) {
        $stream = [IO.File]::OpenRead($executableCase.path)
        try {
            $firstByte = $stream.ReadByte()
            $secondByte = $stream.ReadByte()
        } finally {
            $stream.Dispose()
        }
        Assert-True -Condition ($firstByte -eq 0x4D -and $secondByte -eq 0x5A) -Message "$($executableCase.role) executable has no MZ PE header."
        $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($executableCase.path)
        $fileParts = @($versionInfo.FileMajorPart, $versionInfo.FileMinorPart, $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart)
        $productParts = @($versionInfo.ProductMajorPart, $versionInfo.ProductMinorPart, $versionInfo.ProductBuildPart, $versionInfo.ProductPrivatePart)
        $versionsExact = ($fileParts -join '.') -ceq '3.203.0.0' -and ($productParts -join '.') -ceq '3.203.0.0' -and [string]$versionInfo.FileVersion -ceq '3.203.0.0' -and [string]$versionInfo.ProductVersion -ceq '3.203.0.0'
        Assert-True -Condition $versionsExact -Message "$($executableCase.role) executable PE version is not 3.203.0.0."
        Assert-True -Condition ([string]$versionInfo.OriginalFilename -ceq $executableCase.original) -Message "$($executableCase.role) executable OriginalFilename is incorrect."
        $peVersions[$executableCase.role] = [ordered]@{
            fileVersion = [string]$versionInfo.FileVersion
            productVersion = [string]$versionInfo.ProductVersion
            originalFilename = [string]$versionInfo.OriginalFilename
        }
    }
    $checks.packageIdentity = [ordered]@{
        passed = $true
        requiredFiles = $requiredPaths
        manifest = $manifest
        peVersions = $peVersions
    }

    $currentPhase = 'package-immutability-baseline'
    $beforeSnapshot = @(Get-PackageSnapshot -Root $package)
    Assert-True -Condition (@($beforeSnapshot | Where-Object { $_.reparsePoint }).Count -eq 0) -Message 'Package snapshot found a reparse point.'
    Write-Json -Path $beforeSnapshotPath -Value $beforeSnapshot
    $checks.packageBaseline = [ordered]@{
        passed = $true
        entries = $beforeSnapshot.Count
        snapshotSha256 = Get-Sha256Lower -Path $beforeSnapshotPath
    }

    $currentPhase = 'clean-path'
    $uiRuntime = New-CleanEnvironment -Name 'ui'
    $smokeRuntime = New-CleanEnvironment -Name 'release-smoke'
    $alignmentRuntime = New-CleanEnvironment -Name 'alignment'
    $speakerRuntime = New-CleanEnvironment -Name 'speaker'
    $pythonChecks = [ordered]@{}
    foreach ($runtime in @($uiRuntime, $smokeRuntime, $alignmentRuntime, $speakerRuntime)) {
        $pythonChecks[$runtime.Name] = @(Assert-NoPythonOnPath -CleanRuntime $runtime)
        Assert-True -Condition (@(Get-ChildItem -LiteralPath $runtime.LocalAppData -Force).Count -eq 0) -Message "$($runtime.Name) LOCALAPPDATA was not empty before first launch."
    }
    $checks.cleanEnvironment = [ordered]@{
        passed = $true
        path = $uiRuntime.Environment.PATH
        python = $pythonChecks
        runnerImage = [string]$env:ImageOS
        runnerImageVersion = [string]$env:ImageVersion
        note = 'The hosted image may contain Python outside PATH; every tested executable receives a cleared environment and a Python-free sanitized PATH.'
    }

    $currentPhase = 'web-ui-launch'
    $baselinePorts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
        [void]$baselinePorts.Add("$($listener.LocalAddress):$($listener.LocalPort)")
    }
    $uiInfo = [Diagnostics.ProcessStartInfo]::new()
    $uiInfo.FileName = $mainExe
    $uiInfo.WorkingDirectory = $uiRuntime.Root
    $uiInfo.UseShellExecute = $false
    $uiInfo.CreateNoWindow = $true
    $uiInfo.RedirectStandardOutput = $true
    $uiInfo.RedirectStandardError = $true
    $uiInfo.Environment.Clear()
    foreach ($key in $uiRuntime.Environment.Keys) { $uiInfo.Environment[[string]$key] = [string]$uiRuntime.Environment[$key] }
    $uiProcess = [Diagnostics.Process]::new()
    $uiProcess.StartInfo = $uiInfo
    Assert-True -Condition ($uiProcess.Start()) -Message 'Failed to start the packaged Web UI.'
    $uiStdoutTask = $uiProcess.StandardOutput.ReadToEndAsync()
    $uiStderrTask = $uiProcess.StandardError.ReadToEndAsync()
    $uiStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $uiPort = $null
    $uiOwnerPid = $null
    $httpStatus = $null
    $pageIdentified = $false
    try {
        while ($uiStopwatch.Elapsed.TotalSeconds -lt 180 -and -not $uiProcess.HasExited) {
            $newListeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
                $_.LocalPort -ge 7860 -and $_.LocalPort -le 8860 -and -not $baselinePorts.Contains("$($_.LocalAddress):$($_.LocalPort)")
            })
            foreach ($listener in $newListeners) {
                $belongs = Test-ProcessBelongsToPackage -ProcessId ([int]$listener.OwningProcess) -RootProcessId $uiProcess.Id -PackageRoot $package
                if ($belongs) {
                    try {
                        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($listener.LocalPort)/" -Method Get -TimeoutSec 10 -SkipHttpErrorCheck -NoProxy
                        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                            $uiPort = [int]$listener.LocalPort
                            $uiOwnerPid = [int]$listener.OwningProcess
                            $httpStatus = [int]$response.StatusCode
                            $pageIdentified = [bool]([string]$response.Content -match '(?i)RabbitSubtitle|gradio')
                            break
                        }
                    } catch {}
                }
            }
            if ($null -ne $uiPort) { break }
            Start-Sleep -Milliseconds 750
        }
        Assert-True -Condition ($null -ne $uiPort) -Message 'Packaged Web UI did not expose a loopback HTTP listener within 180 seconds.'
        Assert-True -Condition $pageIdentified -Message 'Loopback UI response did not identify RabbitSubtitle or Gradio.'
    } finally {
        $uiStopwatch.Stop()
        if (-not $uiProcess.HasExited) {
            try {
                $uiProcess.Kill($true)
                [void]$uiProcess.WaitForExit(30000)
            } catch {}
        }
        $uiStdout = if ($uiStdoutTask.Wait(10000)) { $uiStdoutTask.GetAwaiter().GetResult() } else { '[capture did not close within 10 seconds]' }
        $uiStderr = if ($uiStderrTask.Wait(10000)) { $uiStderrTask.GetAwaiter().GetResult() } else { '[capture did not close within 10 seconds]' }
        Write-Utf8NoBom -Path (Join-Path $recordsDirectory 'web-ui.stdout.log') -Text $uiStdout
        Write-Utf8NoBom -Path (Join-Path $recordsDirectory 'web-ui.stderr.log') -Text $uiStderr
    }
    $checks.webUi = [ordered]@{
        passed = $true
        processId = $uiProcess.Id
        listenerProcessId = $uiOwnerPid
        loopbackPort = $uiPort
        httpStatus = $httpStatus
        pageIdentified = $pageIdentified
        elapsedMilliseconds = [int64]$uiStopwatch.ElapsedMilliseconds
    }
    Write-Json -Path (Join-Path $recordsDirectory 'web-ui.json') -Value $checks.webUi

    $currentPhase = 'release-smoke'
    $smokeCase = Join-Path $smokeRuntime.Root 'case'
    $smokeOutput = Join-Path $outputsDirectory 'release-smoke'
    New-Item -ItemType Directory -Path $smokeCase, $smokeOutput | Out-Null
    $sourceVideo = Join-Path $smokeCase 'source.mp4'
    $sourceSrt = Join-Path $smokeCase 'source.srt'
    $smokeResultPath = Join-Path $smokeCase 'result.json'
    $ffmpeg = Join-Path $package 'ffmpeg.exe'
    $ffprobe = Join-Path $package 'ffprobe.exe'
    $fixtureArguments = @(
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'color=c=0x17324d:s=640x360:d=2:r=25',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2',
        '-shortest', '-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'aac',
        $sourceVideo
    )
    Invoke-Process -FilePath $ffmpeg -ArgumentList $fixtureArguments -WorkingDirectory $smokeCase -Environment $smokeRuntime.Environment -TimeoutSeconds 90 -RecordName 'release-smoke-fixture-ffmpeg' | Out-Null
    $traditionalText = '兔子字幕讓雙字幕清楚易讀。'
    $englishText = 'RabbitSubtitle keeps bilingual captions easy to read.'
    $srtText = @('1', '00:00:00,100 --> 00:00:01,850', $traditionalText, $englishText, '') -join $lf
    Write-Utf8NoBom -Path $sourceSrt -Text $srtText
    $smokeRequestPath = Join-Path $smokeCase 'request.json'
    $smokeRequest = [ordered]@{
        video = $sourceVideo
        srt = $sourceSrt
        outputDir = $smokeOutput
        result = $smokeResultPath
        bilingual = $true
        primaryLanguage = 'zh-TW'
        secondaryLanguage = 'en'
        preset = 'clear'
    }
    Write-Request -Path $smokeRequestPath -Value $smokeRequest
    $smokeProcess = Invoke-Process -FilePath $mainExe -ArgumentList @('--release-smoke', $smokeRequestPath) -WorkingDirectory $smokeCase -Environment $smokeRuntime.Environment -TimeoutSeconds 300 -RecordName 'release-smoke-process'
    Assert-True -Condition (Test-Path -LiteralPath $smokeResultPath -PathType Leaf) -Message 'Release smoke did not write its result JSON.'
    $smoke = (Read-StrictUtf8 -Path $smokeResultPath) | ConvertFrom-Json -Depth 20
    $smokeCore = [string]$smoke.version -ceq $expectedVersion -and [string]$smoke.mode -ceq 'offline-release-smoke' -and [bool]$smoke.passed -and [bool]$smoke.frozen -and [string]$smoke.renderCore -ceq 'app_modules.shared_caption_output.render_shared_captions' -and [bool]$smoke.bilingual -and [int]$smoke.rows -gt 0
    $smokeOffline = [int]$smoke.cloudCalls -eq 0 -and [int]$smoke.networkCalls -eq 0 -and [int]$smoke.credentialReads -eq 0 -and @($smoke.credentialModulesImported).Count -eq 0 -and @($smoke.modelModulesImported).Count -eq 0 -and -not [bool]$smoke.gradioImported -and -not [bool]$smoke.uiStarted
    $probeExact = [bool]$smoke.videoProbe.passed -and [int]$smoke.videoProbe.exitCode -eq 0 -and [double]$smoke.videoProbe.duration -gt 0 -and [int]$smoke.videoProbe.width -gt 0 -and [int]$smoke.videoProbe.height -gt 0
    Assert-True -Condition ($smokeCore -and $smokeOffline -and $probeExact) -Message 'Release smoke provenance or offline assertions failed.'
    $smokeFiles = @($smoke.files)
    $smokeRoles = @($smokeFiles | ForEach-Object { [string]$_.role } | Sort-Object -Unique)
    Assert-True -Condition ($smokeFiles.Count -eq 4 -and ($smokeRoles -join ',') -ceq 'ass,mp4,project,srt') -Message 'Release smoke did not emit exactly SRT, ASS, MP4 and project outputs.'
    foreach ($fileRecord in $smokeFiles) {
        $outputPath = [IO.Path]::GetFullPath([string]$fileRecord.path)
        $outputPrefix = [IO.Path]::GetFullPath($smokeOutput).TrimEnd('\') + '\'
        Assert-True -Condition ($outputPath.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) -Message 'Release smoke reported an output outside its evidence directory.'
        Assert-True -Condition (Test-Path -LiteralPath $outputPath -PathType Leaf) -Message "Release smoke output is missing: $outputPath"
        $outputItem = Get-Item -LiteralPath $outputPath
        $outputExact = $outputItem.Length -gt 0 -and [int64]$fileRecord.bytes -eq $outputItem.Length -and [string]$fileRecord.sha256 -ceq (Get-Sha256Lower -Path $outputPath).ToUpperInvariant()
        Assert-True -Condition $outputExact -Message "Release smoke output identity mismatch: $outputPath"
    }
    $inputHashesExact = [string]$smoke.inputSha256.video -ceq (Get-Sha256Lower -Path $sourceVideo).ToUpperInvariant() -and [string]$smoke.inputSha256.srt -ceq (Get-Sha256Lower -Path $sourceSrt).ToUpperInvariant()
    Assert-True -Condition $inputHashesExact -Message 'Release smoke input hashes do not match the generated fixtures.'
    $renderedSrt = [IO.File]::ReadAllText((Join-Path $smokeOutput 'release-smoke.srt'), [Text.UTF8Encoding]::new($true))
    $bothLanguages = $renderedSrt.Contains($traditionalText, [StringComparison]::Ordinal) -and $renderedSrt.Contains($englishText, [StringComparison]::Ordinal)
    Assert-True -Condition $bothLanguages -Message 'Release smoke SRT does not retain both subtitle languages.'
    Write-Json -Path (Join-Path $recordsDirectory 'release-smoke-result.json') -Value $smoke
    $checks.releaseSmoke = [ordered]@{
        passed = $true
        bilingual = $true
        roles = $smokeRoles
        networkCalls = [int]$smoke.networkCalls
        cloudCalls = [int]$smoke.cloudCalls
        credentialReads = [int]$smoke.credentialReads
        outputDirectory = $smokeOutput
    }

    $currentPhase = 'alignment-first-install'
    $alignmentCase = Join-Path $alignmentRuntime.Root 'fixture'
    New-Item -ItemType Directory -Path $alignmentCase | Out-Null
    $speechWaveRaw = Join-Path $alignmentCase 'speech-raw.wav'
    $speechWave = Join-Path $alignmentCase 'speech-16k-mono.wav'
    Add-Type -AssemblyName System.Speech
    $synthesizer = [System.Speech.Synthesis.SpeechSynthesizer]::new()
    try {
        $synthesizer.SetOutputToWaveFile($speechWaveRaw)
        $synthesizer.Speak('Rabbit subtitle works offline and keeps every word aligned.')
    } finally {
        $synthesizer.Dispose()
    }
    $speechFixtureArguments = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $speechWaveRaw, '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', $speechWave)
    Invoke-Process -FilePath $ffmpeg -ArgumentList $speechFixtureArguments -WorkingDirectory $alignmentCase -Environment $alignmentRuntime.Environment -TimeoutSeconds 90 -RecordName 'alignment-fixture-ffmpeg' | Out-Null

    $missingAlignment = Invoke-SpeechRequest -CaseName 'alignment-missing-model' -CleanRuntime $alignmentRuntime -Environment $alignmentRuntime.Environment -Payload @{ action = 'align'; language = 'en'; media = $speechWave } -TimeoutSeconds 120
    $missingControlled = [string]$missingAlignment.error -ceq 'alignment_models_missing' -and [string]$missingAlignment.errorType -ceq 'ValueError'
    Assert-True -Condition $missingControlled -Message 'Empty-cache alignment did not return the controlled alignment_models_missing error.'

    $alignmentInstall = Invoke-SpeechRequest -CaseName 'alignment-public-install' -CleanRuntime $alignmentRuntime -Environment $alignmentRuntime.Environment -Payload @{ action = 'install_alignment'; language = 'en' } -TimeoutSeconds 2700
    $installPassed = [bool]$alignmentInstall.ready -and [bool]$alignmentInstall.offline -and [string]$alignmentInstall.language -ceq 'en' -and [int]$alignmentInstall.cloudSpeechCalls -eq 0
    Assert-True -Condition $installPassed -Message 'Public alignment model installation failed.'

    $alignmentRoot = Join-Path $alignmentRuntime.LocalAppData 'RabbitSubtitle\alignment-models\v1'
    $asrRoot = Join-Path $alignmentRuntime.LocalAppData 'RabbitSubtitle\speaker-models\v1\Systran--faster-whisper-small\536b0662742c02347bc0e980a01041f333bce120'
    $installedAssets = @(
        [ordered]@{ path = Join-Path $alignmentRoot 'wav2vec2_fairseq_base_ls960_asr_ls960.pth'; bytes = 377664473L; sha256 = '488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d' },
        [ordered]@{ path = Join-Path $asrRoot 'config.json'; bytes = 2370L; sha256 = 'b55496ac7940a7ae47d2c01eab40edfd8701feec1229d9cce3b40014383fb828' },
        [ordered]@{ path = Join-Path $asrRoot 'model.bin'; bytes = 483546902L; sha256 = '3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671' },
        [ordered]@{ path = Join-Path $asrRoot 'tokenizer.json'; bytes = 2203239L; sha256 = 'fb7b63191e9bb045082c79fd742a3106a12c99513ab30df4a0d47fa6cb6fd0ab' },
        [ordered]@{ path = Join-Path $asrRoot 'vocabulary.txt'; bytes = 459861L; sha256 = '34ce3fe1c5041027b3f8d42912270993f986dbc4bb34cf27f951e34a1e453913' }
    )
    $installedAssetEvidence = [Collections.Generic.List[object]]::new()
    foreach ($asset in $installedAssets) {
        Assert-FileIdentity -Path $asset.path -Bytes $asset.bytes -Sha256 $asset.sha256
        $installedAssetEvidence.Add([ordered]@{
            relativePath = [IO.Path]::GetRelativePath($alignmentRuntime.LocalAppData, $asset.path).Replace('\', '/')
            bytes = $asset.bytes
            sha256 = $asset.sha256
        })
    }

    $offlineEnvironment = [ordered]@{}
    foreach ($key in $alignmentRuntime.Environment.Keys) { $offlineEnvironment[$key] = $alignmentRuntime.Environment[$key] }
    $offlineEnvironment['HF_HUB_OFFLINE'] = '1'
    $offlineEnvironment['TRANSFORMERS_OFFLINE'] = '1'
    $offlineEnvironment['HTTP_PROXY'] = 'http://127.0.0.1:9'
    $offlineEnvironment['HTTPS_PROXY'] = 'http://127.0.0.1:9'
    $offlineEnvironment['ALL_PROXY'] = 'http://127.0.0.1:9'
    $offlineAlignment = Invoke-SpeechRequest -CaseName 'alignment-offline-run' -CleanRuntime $alignmentRuntime -Environment $offlineEnvironment -Payload @{ action = 'align'; language = 'en'; media = $speechWave } -TimeoutSeconds 1200
    $offlineErrorProperty = $offlineAlignment.PSObject.Properties['error']
    $hasOfflineError = $null -ne $offlineErrorProperty -and -not [string]::IsNullOrEmpty([string]$offlineErrorProperty.Value)
    $alignmentCore = -not $hasOfflineError -and [string]$offlineAlignment.language -ceq 'en' -and [string]$offlineAlignment.source -ceq 'whisperx' -and -not [bool]$offlineAlignment.manualTimingVerified -and @($offlineAlignment.segments).Count -gt 0
    Assert-True -Condition $alignmentCore -Message 'Installed alignment models did not complete an offline WhisperX alignment.'
    $wordSegments = @($offlineAlignment.segments | Where-Object { @($_.words).Count -gt 0 })
    Assert-True -Condition ($wordSegments.Count -gt 0) -Message 'Offline alignment returned no word-level timing.'
    $wrongProvenance = @($offlineAlignment.segments | Where-Object { [string]$_.source -cne 'whisperx' })
    Assert-True -Condition ($wrongProvenance.Count -eq 0) -Message 'Offline alignment returned non-WhisperX provenance.'
    $checks.alignment = [ordered]@{
        passed = $true
        emptyCacheError = [string]$missingAlignment.error
        publicInstall = [ordered]@{
            ready = [bool]$alignmentInstall.ready
            offline = [bool]$alignmentInstall.offline
            language = [string]$alignmentInstall.language
            credentialVariablesPresent = $false
            cacheInitiallyEmpty = $true
            installedAssets = @($installedAssetEvidence)
        }
        offlineRun = [ordered]@{
            source = [string]$offlineAlignment.source
            language = [string]$offlineAlignment.language
            segments = @($offlineAlignment.segments).Count
            wordTimedSegments = $wordSegments.Count
            cloudSpeechCalls = [int]$offlineAlignment.cloudSpeechCalls
            manualTimingVerified = [bool]$offlineAlignment.manualTimingVerified
            networkBoundary = 'HF offline flags, dead loopback proxies, and the packaged speech worker socket block'
        }
    }

    $currentPhase = 'speaker-prerequisites'
    $speakerInstall = Invoke-SpeechRequest -CaseName 'speaker-no-tester-token' -CleanRuntime $speakerRuntime -Environment $speakerRuntime.Environment -Payload @{ action = 'install' } -TimeoutSeconds 120
    $speakerInstallControlled = [string]$speakerInstall.error -ceq 'credential_missing' -and [string]$speakerInstall.errorType -ceq 'ValueError'
    Assert-True -Condition $speakerInstallControlled -Message 'Speaker installation without tester credentials did not fail safely.'
    $speakerDiarize = Invoke-SpeechRequest -CaseName 'speaker-models-missing' -CleanRuntime $speakerRuntime -Environment $speakerRuntime.Environment -Payload @{ action = 'diarize'; media = $speechWave; speaker_count = 'auto' } -TimeoutSeconds 120
    $speakerDiarizeControlled = [string]$speakerDiarize.error -ceq 'models_missing' -and [string]$speakerDiarize.errorType -ceq 'ValueError'
    Assert-True -Condition $speakerDiarizeControlled -Message 'Speaker diarization without models did not fail safely.'
    $checks.speaker = [ordered]@{
        status = 'notRunTermsCredentialRequired'
        fullInstall = 'notRunTermsCredentialRequired'
        offlineDiarization = 'notRunTermsCredentialRequired'
        delegatedGate = 'automaticDiarization'
        controlledPreconditions = [ordered]@{
            status = 'passed'
            emptyCache = $true
            credentialMissingError = [string]$speakerInstall.error
            modelsMissingError = [string]$speakerDiarize.error
        }
        reason = 'This cleanWindowsPackage scope only verifies safe empty-cache failures. A tester-owned Hugging Face token and accepted upstream model terms are required for full installation; exact-package installation and offline diarization belong to the automaticDiarization gate.'
    }

    $currentPhase = 'package-immutability-final'
    $afterSnapshot = @(Get-PackageSnapshot -Root $package)
    Write-Json -Path $afterSnapshotPath -Value $afterSnapshot
    $beforeSnapshotText = Read-StrictUtf8 -Path $beforeSnapshotPath
    $afterSnapshotText = Read-StrictUtf8 -Path $afterSnapshotPath
    Assert-True -Condition ($beforeSnapshotText -ceq $afterSnapshotText) -Message 'Packaged files changed during clean Windows execution.'
    $checks.packageImmutability = [ordered]@{
        passed = $true
        entries = $afterSnapshot.Count
        beforeSha256 = Get-Sha256Lower -Path $beforeSnapshotPath
        afterSha256 = Get-Sha256Lower -Path $afterSnapshotPath
    }
} catch {
    $fatalError = [ordered]@{
        phase = $currentPhase
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        scriptStackTrace = $_.ScriptStackTrace
    }
    Write-Json -Path (Join-Path $recordsDirectory 'fatal-error.json') -Value $fatalError
}

$recordEvidence = [Collections.Generic.List[object]]::new()
foreach ($recordFile in @(Get-ChildItem -LiteralPath $recordsDirectory -File -Force | Sort-Object Name)) {
    $recordEvidence.Add([ordered]@{
        name = $recordFile.Name
        bytes = [int64]$recordFile.Length
        sha256 = Get-Sha256Lower -Path $recordFile.FullName
    })
}

$coreAcceptancePassed = $null -eq $fatalError
$overallStatus = if ($coreAcceptancePassed) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    schemaVersion = 1
    gate = 'cleanWindowsPackage'
    version = $Version
    sourceSha256 = $SourceSha256
    artifactSha256 = $ArtifactSha256
    artifactBytes = $artifactByteCount
    artifactName = $expectedAssetName
    overallStatus = $overallStatus
    passed = $overallStatus -ceq 'PASS'
    releaseGateEligible = $overallStatus -ceq 'PASS'
    coreAcceptancePassed = $coreAcceptancePassed
    acceptanceScope = [ordered]@{
        gate = 'cleanWindowsPackage'
        passed = $coreAcceptancePassed
        requiredChecks = @(
            'zipSafetyAndExtraction'
            'packageIdentityAndManifest'
            'pythonFreePathAndNoDevelopmentDirectoryDependency'
            'webUiStartup'
            'bilingualReleaseSmoke'
            'alignmentEmptyCacheThenPublicInstallThenOfflineRun'
            'speakerEmptyCacheControlledCredentialMissingAndModelsMissing'
        )
        exclusions = @(
            [ordered]@{
                capability = 'speakerFullInstallAndOfflineDiarization'
                status = 'notRunTermsCredentialRequired'
                delegatedGate = 'automaticDiarization'
                reason = 'Requires tester-owned Hugging Face credentials and acceptance of upstream gated-model terms; this cleanWindowsPackage report does not claim that capability passed.'
            }
        )
    }
    startedAt = $startedAt.ToString('o')
    finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
    github = [ordered]@{
        repository = [string]$env:GITHUB_REPOSITORY
        ref = [string]$env:GITHUB_REF
        sha = [string]$env:GITHUB_SHA
        runId = [string]$env:GITHUB_RUN_ID
        runAttempt = [string]$env:GITHUB_RUN_ATTEMPT
        workflow = [string]$env:GITHUB_WORKFLOW
    }
    checks = $checks
    fatalError = $fatalError
    records = @($recordEvidence)
    limitations = @(
        'GitHub windows-latest is sanitized to a Python-free PATH but is not a literal machine image from which Python has been uninstalled.'
        'Full speaker model installation and offline diarization are outside the cleanWindowsPackage acceptance scope and are recorded as notRunTermsCredentialRequired; they must pass separately in the exact-package automaticDiarization gate.'
        'The test is bound to a draft release asset; it does not publish, upload, modify, or promote a release.'
        'windows-latest and its preinstalled GitHub CLI are mutable runner dependencies. The report records the image identity and download metadata records the GitHub CLI version.'
    )
}
$reportPath = Join-Path $EvidenceDirectory 'clean-windows-report.json'
Write-Json -Path $reportPath -Value $report

if ($null -ne $fatalError) {
    [Console]::Error.WriteLine("Clean Windows verification failed in phase '$($fatalError.phase)': $($fatalError.message)")
    exit 1
}
Write-Host 'Clean Windows package acceptance passed. Full speaker installation and offline diarization were not run because tester-owned terms and credentials are required; that capability remains delegated to automaticDiarization.'
