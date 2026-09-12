[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Contract')][switch]$DescribeContract,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$ArchivePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$ArtifactSha256,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][long]$ArtifactBytes,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$EvidenceDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')][string]$ManualRecordsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$expectedVersion = '3.203'
$expectedSourceSha256 = '1681a475c8be73348b852fd6248315c6cfb9795b57ef76f1846a8c4cd69c542f'
$expectedMainSpecSha256 = '0064174F1D3944B825F3D63316548B2AE8435C0D1BB060CA66F2F8497126BC0B'
$expectedSpeechSpecSha256 = '40B0F97EEC4B0417304FAD334822758DD28BA13C3D0CD5BD50B13499429D8403'
$expectedArtifactName = 'RabbitSubtitle-3.203-Windows-x64.zip'
$expectedPackageRoot = 'RabbitSubtitle-3.203'
$producerName = 'produce-physical-clean-windows-evidence.ps1'
$reportKeys = @(
    'schemaVersion', 'gate', 'version', 'sourceSha256', 'artifactSha256',
    'artifactBytes', 'artifactName', 'producer', 'producerSha256',
    'overallStatus', 'passed', 'startedAt', 'finishedAt', 'machine', 'checks',
    'secretsFound', 'fatalError', 'records'
)
$machineKeys = @(
    'windowsVersion', 'architecture', 'pythonOnPath', 'pyLauncherOnPath',
    'existingModelCache'
)
$physicalCheckNames = @(
    'zipSafety', 'packageIdentity', 'noDevelopmentDependencies',
    'externalCwdLaunch', 'desktopShortcutLaunch', 'speakerSetupCopyPresent',
    'bilingualOutput', 'firstModelInstall', 'modelInstallCancel',
    'modelInstallResume', 'missingModel', 'offlineReopen', 'batch', 'defender',
    'noConsoleWindows', 'packageImmutability'
)
$manualCheckNames = @(
    'bilingualOutput', 'firstModelInstall', 'modelInstallCancel',
    'modelInstallResume', 'missingModel', 'offlineReopen', 'batch'
)

if ($DescribeContract) {
    [ordered]@{
        schemaVersion = 1
        producer = $producerName
        version = $expectedVersion
        sourceSha256 = $expectedSourceSha256
        mainSpecSha256 = $expectedMainSpecSha256.ToLowerInvariant()
        speechSpecSha256 = $expectedSpeechSpecSha256.ToLowerInvariant()
        reportKeys = @($reportKeys | Sort-Object)
        machineKeys = @($machineKeys | Sort-Object)
        checks = @($physicalCheckNames | Sort-Object)
        manualChecks = @($manualCheckNames | Sort-Object)
    } | ConvertTo-Json -Depth 6
    return
}

$startedAt = [DateTimeOffset]::UtcNow
$currentPhase = 'initialization'
$monitorStarted = $false
$shortcutPath = $null
$extractRoot = $null
$package = $null
$recordsDirectory = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8NoBom {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-JsonRecord {
    param([string]$Name, [object]$Value)
    $path = Join-Path $recordsDirectory $Name
    Write-Utf8NoBom -Path $path -Text (($Value | ConvertTo-Json -Depth 30) + [char]10)
    return $path
}

function Get-Sha256Lower {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-IsUnderPath {
    param([string]$Candidate, [string]$Root)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $candidateFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PackageSnapshot {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rows = New-Object Collections.Generic.List[object]
    foreach ($item in @(Get-ChildItem -LiteralPath $rootFull -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
        $reparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($item.PSIsContainer) {
            $rows.Add([ordered]@{ path = $relative + '/'; type = 'directory'; reparsePoint = $reparse })
        } else {
            $rows.Add([ordered]@{
                path = $relative
                type = 'file'
                bytes = [long]$item.Length
                sha256 = Get-Sha256Lower -Path $item.FullName
                reparsePoint = $reparse
            })
        }
    }
    return @($rows)
}

function Stop-PackageProcesses {
    param([string]$PackageRoot)
    $prefix = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    for ($pass = 0; $pass -lt 4; $pass++) {
        $found = $false
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $executable = [string]$process.ExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($executable) -and $executable.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $found = $true
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $found) { break }
        Start-Sleep -Milliseconds 500
    }
}

function Wait-PackageWebUi {
    param([string]$PackageRoot, [int]$TimeoutSeconds = 180)
    $prefix = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ge 7860 -and $_.LocalPort -le 8860 })) {
                $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$listener.OwningProcess)" -ErrorAction SilentlyContinue
                if ($null -eq $owner) { continue }
                $executable = [string]$owner.ExecutablePath
                if ([string]::IsNullOrWhiteSpace($executable) -or -not $executable.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                try {
                    $response = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $listener.LocalPort) -Method Get -TimeoutSec 10 -UseBasicParsing
                    $identified = [string]$response.Content -match '(?i)RabbitSubtitle|gradio'
                    if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and $identified) {
                        return [ordered]@{
                            passed = $true
                            processId = [int]$owner.ProcessId
                            port = [int]$listener.LocalPort
                            httpStatus = [int]$response.StatusCode
                            pageIdentified = $true
                            elapsedMilliseconds = [long]$stopwatch.ElapsedMilliseconds
                        }
                    }
                } catch {}
            }
            Start-Sleep -Milliseconds 750
        }
    } finally {
        $stopwatch.Stop()
    }
    throw "RabbitSubtitle did not expose an identified loopback UI within $TimeoutSeconds seconds."
}

function Invoke-DirectLaunchCheck {
    param([string]$Executable, [string]$WorkingDirectory, [string]$PackageRoot)
    Stop-PackageProcesses -PackageRoot $PackageRoot
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['RABBITSUBTITLE_NO_BROWSER'] = '1'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    Assert-True -Condition $process.Start() -Message 'The package could not start from the external working directory.'
    try {
        $result = Wait-PackageWebUi -PackageRoot $PackageRoot
        $result.workingDirectory = $WorkingDirectory
        return $result
    } finally {
        Stop-PackageProcesses -PackageRoot $PackageRoot
        $process.Dispose()
    }
}

function Invoke-ShortcutLaunchCheck {
    param([string]$Shortcut, [string]$PackageRoot)
    Stop-PackageProcesses -PackageRoot $PackageRoot
    $process = $null
    $savedNoBrowser = [Environment]::GetEnvironmentVariable('RABBITSUBTITLE_NO_BROWSER', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('RABBITSUBTITLE_NO_BROWSER', '1', 'Process')
        $process = Start-Process -FilePath $Shortcut -PassThru
        $result = Wait-PackageWebUi -PackageRoot $PackageRoot
        $result.shortcut = [IO.Path]::GetFileName($Shortcut)
        return $result
    } finally {
        Stop-PackageProcesses -PackageRoot $PackageRoot
        [Environment]::SetEnvironmentVariable('RABBITSUBTITLE_NO_BROWSER', $savedNoBrowser, 'Process')
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Start-ConsoleWindowMonitor {
    if ($null -eq ('RabbitSubtitlePhysicalConsoleMonitor' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;

public static class RabbitSubtitlePhysicalConsoleMonitor {
    private const uint EVENT_OBJECT_SHOW = 0x8002;
    private const int OBJID_WINDOW = 0;
    private const uint WINEVENT_OUTOFCONTEXT = 0;
    private delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint threadId, uint eventTime);
    private static WinEventDelegate callback;
    private static IntPtr hook = IntPtr.Zero;
    private static ConcurrentQueue<string> observations = new ConcurrentQueue<string>();

    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventDelegate callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder value, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder value, int length);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    private static void Observe(IntPtr ignoredHook, uint ignoredEvent, IntPtr hwnd, int idObject, int ignoredChild, uint ignoredThread, uint ignoredTime) {
        if (hwnd == IntPtr.Zero || idObject != OBJID_WINDOW) return;
        var className = new StringBuilder(256);
        GetClassName(hwnd, className, className.Capacity);
        var name = className.ToString();
        if (!String.Equals(name, "ConsoleWindowClass", StringComparison.Ordinal) && !String.Equals(name, "CASCADIA_HOSTING_WINDOW_CLASS", StringComparison.Ordinal)) return;
        uint processId;
        GetWindowThreadProcessId(hwnd, out processId);
        var title = new StringBuilder(1024);
        GetWindowText(hwnd, title, title.Capacity);
        observations.Enqueue(DateTimeOffset.UtcNow.ToString("o") + "|" + processId + "|" + name + "|" + title.ToString());
    }

    public static void Start() {
        if (hook != IntPtr.Zero) throw new InvalidOperationException("Console monitor already started.");
        observations = new ConcurrentQueue<string>();
        callback = Observe;
        hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, callback, 0, 0, WINEVENT_OUTOFCONTEXT);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("SetWinEventHook failed.");
    }

    public static string[] Stop() {
        if (hook != IntPtr.Zero) {
            UnhookWinEvent(hook);
            hook = IntPtr.Zero;
        }
        return observations.ToArray();
    }
}
'@
    }
    [RabbitSubtitlePhysicalConsoleMonitor]::Start()
}

function Stop-ConsoleWindowMonitor {
    return @([RabbitSubtitlePhysicalConsoleMonitor]::Stop())
}

function Confirm-ManualCheck {
    param([string]$Name, [string]$Instruction)
    Write-Host ''
    Write-Host ("MANUAL CHECK: {0}" -f $Name) -ForegroundColor Cyan
    Write-Host $Instruction
    Write-Host ("Save at least one redacted screenshot or text log as '{0}--<description>.<ext>' in:" -f $Name)
    Write-Host $ManualRecordsDirectory
    $expected = "PASS $Name"
    $answer = Read-Host ("After completing the operation, type exactly: {0}" -f $expected)
    Assert-True -Condition ($answer -ceq $expected) -Message "Manual check '$Name' was not explicitly passed."
    $note = Read-Host 'Enter a short observation (no email, path, license, password, or token)'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($note) -and $note.Length -le 500) -Message "Manual check '$Name' needs a concise observation."
    $files = @(Get-ChildItem -LiteralPath $ManualRecordsDirectory -File -Force | Where-Object { $_.Name.StartsWith($Name + '--', [StringComparison]::Ordinal) } | Sort-Object Name)
    Assert-True -Condition ($files.Count -gt 0) -Message "Manual check '$Name' has no prefixed record file."
    $allowedExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.txt', '.json', '.log', '.csv')
    $recordNames = New-Object Collections.Generic.List[string]
    foreach ($file in $files) {
        Assert-True -Condition ($allowedExtensions -contains $file.Extension.ToLowerInvariant()) -Message "Manual record '$($file.Name)' has an unsupported extension."
        Assert-True -Condition ($file.Length -gt 0 -and $file.Length -le 25MB) -Message "Manual record '$($file.Name)' is empty or larger than 25 MiB."
        Assert-True -Condition (-not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) -Message "Manual record '$($file.Name)' is a reparse point."
        $destination = Join-Path $recordsDirectory $file.Name
        Assert-True -Condition (-not (Test-Path -LiteralPath $destination)) -Message "Manual record name '$($file.Name)' collides with another record."
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $recordNames.Add($file.Name)
    }
    return [ordered]@{
        passed = $true
        observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        confirmation = $expected
        observation = $note
        records = @($recordNames)
    }
}

function Assert-NoTextSecrets {
    param([string]$Directory)
    $patterns = @(
        '(?i)\bhf_[a-z0-9]{20,}\b',
        '(?i)\bgh[pousr]_[a-z0-9]{20,}\b',
        '(?i)\bsk-[a-z0-9_-]{20,}\b',
        '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '(?i)"(?:token|password|secret|api[_-]?key)"\s*:\s*"[^"\s]+"'
    )
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force)) {
        if (@('.txt', '.json', '.log', '.csv') -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($pattern in $patterns) {
            Assert-True -Condition (-not [regex]::IsMatch($text, $pattern)) -Message "Possible secret found in record '$($file.Name)'. Remove it and rerun."
        }
    }
}

try {
    $currentPhase = 'input-validation'
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    $EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
    $ManualRecordsDirectory = [IO.Path]::GetFullPath($ManualRecordsDirectory)
    Assert-True -Condition (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -Message 'The approved Draft ZIP is missing.'
    Assert-True -Condition ([IO.Path]::GetFileName($ArchivePath) -ceq $expectedArtifactName) -Message 'The ZIP filename is not canonical.'
    $ArtifactSha256 = $ArtifactSha256.ToLowerInvariant()
    Assert-True -Condition ($ArtifactSha256 -cmatch '^[0-9a-f]{64}$') -Message 'ArtifactSha256 must be 64 lowercase hexadecimal characters.'
    Assert-True -Condition ($ArtifactBytes -gt 0) -Message 'ArtifactBytes must be positive.'
    $archiveItem = Get-Item -LiteralPath $ArchivePath
    Assert-True -Condition ([long]$archiveItem.Length -eq $ArtifactBytes) -Message 'The Draft ZIP byte length differs from the approved value.'
    Assert-True -Condition ((Get-Sha256Lower -Path $ArchivePath) -ceq $ArtifactSha256) -Message 'The Draft ZIP SHA-256 differs from the approved value.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $EvidenceDirectory)) -Message 'EvidenceDirectory must be a new path; refusing to overwrite evidence.'
    $manualRecordsSameAsEvidence = [IO.Path]::GetFullPath($ManualRecordsDirectory).TrimEnd('\') -ceq [IO.Path]::GetFullPath($EvidenceDirectory).TrimEnd('\')
    Assert-True -Condition (-not $manualRecordsSameAsEvidence -and -not (Test-IsUnderPath -Candidate $ManualRecordsDirectory -Root $EvidenceDirectory)) -Message 'ManualRecordsDirectory must be outside EvidenceDirectory.'
    New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
    $recordsDirectory = Join-Path $EvidenceDirectory 'physicalCleanWindows.records'
    New-Item -ItemType Directory -Path $recordsDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $ManualRecordsDirectory)) { New-Item -ItemType Directory -Path $ManualRecordsDirectory | Out-Null }
    Assert-True -Condition (Test-Path -LiteralPath $ManualRecordsDirectory -PathType Container) -Message 'ManualRecordsDirectory is unavailable.'

    $runningScript = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    $producerCopy = Join-Path $EvidenceDirectory $producerName
    Copy-Item -LiteralPath $runningScript -Destination $producerCopy

    $currentPhase = 'machine-preflight'
    $pythonCommand = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue
    $pyCommand = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue
    $pythonOnPath = $null -ne $pythonCommand
    $pyLauncherOnPath = $null -ne $pyCommand
    Assert-True -Condition (-not $pythonOnPath) -Message 'python.exe is on PATH; this is not the required clean machine.'
    Assert-True -Condition (-not $pyLauncherOnPath) -Message 'py.exe is on PATH; this is not the required clean machine.'
    Assert-True -Condition ([Environment]::Is64BitOperatingSystem) -Message 'A 64-bit Windows installation is required.'
    $cacheRoots = @(
        (Join-Path $env:LOCALAPPDATA 'RabbitSubtitle\alignment-models'),
        (Join-Path $env:LOCALAPPDATA 'RabbitSubtitle\speaker-models'),
        (Join-Path $env:USERPROFILE '.cache\huggingface'),
        (Join-Path $env:LOCALAPPDATA 'huggingface')
    )
    $cacheFiles = New-Object Collections.Generic.List[string]
    foreach ($cacheRoot in $cacheRoots) {
        if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $cacheRoot -File -Force -Recurse -ErrorAction SilentlyContinue)) { $cacheFiles.Add($file.FullName) }
        }
    }
    $existingModelCache = $cacheFiles.Count -gt 0
    Assert-True -Condition (-not $existingModelCache) -Message 'An existing RabbitSubtitle or Hugging Face model cache was found; use a clean Windows account.'
    $os = Get-CimInstance Win32_OperatingSystem
    $windowsVersion = ('{0} {1} build {2}' -f ([string]$os.Caption).Trim(), [string]$os.Version, [string]$os.BuildNumber).Trim()
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($windowsVersion)) -Message 'Windows version could not be recorded.'
    $machine = [ordered]@{
        windowsVersion = $windowsVersion
        architecture = 'AMD64'
        pythonOnPath = $false
        pyLauncherOnPath = $false
        existingModelCache = $false
    }
    Write-JsonRecord -Name 'machine-preflight.json' -Value ([ordered]@{
        machine = $machine
        checkedModelCacheLocations = @('LOCALAPPDATA/RabbitSubtitle/alignment-models', 'LOCALAPPDATA/RabbitSubtitle/speaker-models', 'USERPROFILE/.cache/huggingface', 'LOCALAPPDATA/huggingface')
        checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }) | Out-Null

    $currentPhase = 'zip-safety'
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('RabbitSubtitle-physical-3.203-' + [Guid]::NewGuid().ToString('N'))
    Assert-True -Condition ([IO.Path]::GetFullPath($extractRoot).StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) -Message 'Temporary extraction path escaped the Windows temporary directory.'
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        Assert-True -Condition ($zip.Entries.Count -gt 0 -and $zip.Entries.Count -le 50000) -Message 'The ZIP is empty or has too many entries.'
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        $files = 0
        $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($name) -and -not $name.Contains('\') -and -not $name.StartsWith('/') -and $name -cnotmatch '[\x00-\x1f:]') -Message "Unsafe ZIP entry: $name"
            $normalized = $name.TrimEnd('/')
            $segments = @($normalized.Split('/'))
            Assert-True -Condition ($segments.Count -gt 0 -and $segments[0] -ceq $expectedPackageRoot) -Message "ZIP entry is outside the package root: $name"
            foreach ($segment in $segments) {
                Assert-True -Condition (-not [string]::IsNullOrEmpty($segment) -and $segment -cne '.' -and $segment -cne '..' -and -not $segment.EndsWith('.') -and -not $segment.EndsWith(' ')) -Message "ZIP entry has an unsafe path segment: $name"
                Assert-True -Condition ($reserved -cnotcontains $segment.Split('.')[0].ToUpperInvariant()) -Message "ZIP entry uses a reserved device name: $name"
            }
            Assert-True -Condition $seen.Add($normalized) -Message "ZIP has a case-insensitive duplicate entry: $name"
            $external = ([long]$entry.ExternalAttributes) -band 0xFFFFFFFFL
            Assert-True -Condition ((($external -shr 16) -band 0xF000) -ne 0xA000) -Message "ZIP contains a symbolic link: $name"
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                $files++
                Assert-True -Condition ([long]$entry.Length -le 8GB) -Message "ZIP entry is unreasonably large: $name"
                $total += [long]$entry.Length
                Assert-True -Condition ($total -le 20GB) -Message 'ZIP expands beyond the 20 GiB acceptance limit.'
                if ($entry.Length -gt 1MB) {
                    Assert-True -Condition ($entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -le 2000) -Message "Unsafe compression ratio: $name"
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractRoot)
    $package = Join-Path $extractRoot $expectedPackageRoot
    $topLevel = @(Get-ChildItem -LiteralPath $extractRoot -Force)
    Assert-True -Condition ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer -and $topLevel[0].Name -ceq $expectedPackageRoot) -Message 'ZIP must extract to one exact package root.'
    $reparsePoints = @(Get-ChildItem -LiteralPath $package -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    Assert-True -Condition ($reparsePoints.Count -eq 0) -Message 'Extracted package contains a reparse point.'
    $checks = [ordered]@{}
    $checks.zipSafety = [ordered]@{ passed = $true; entries = $seen.Count; files = $files; uncompressedBytes = $total; reparsePoints = 0 }
    Write-JsonRecord -Name 'zip-safety.json' -Value $checks.zipSafety | Out-Null

    $currentPhase = 'package-identity'
    $requiredFiles = @(
        'RabbitSubtitle-3.203.exe', 'speech-runtime/RabbitSubtitleSpeech.exe',
        'RELEASE-BUILD.json', 'VERSION.txt', 'CLEAN-WINDOWS-TEST-CHECKLIST-3.203.txt',
        'START-HERE-3.203.txt', 'THIRD-PARTY-SPEECH-NOTICES.md',
        'THIRD-PARTY-LICENSES/README.txt', 'app_modules/speech-copy.json',
        'app_modules/speaker-setup-copy.json', 'index.html'
    )
    foreach ($relative in $requiredFiles) {
        $requiredPath = Join-Path $package $relative
        Assert-True -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message "Required package file is missing: $relative"
        Assert-True -Condition ((Get-Item -LiteralPath $requiredPath).Length -gt 0) -Message "Required package file is empty: $relative"
    }
    foreach ($forbidden in @('.env', 'hf_credentials.json', 'license.json', 'queue.sqlite3')) {
        Assert-True -Condition (@(Get-ChildItem -LiteralPath $package -Force -Recurse -File | Where-Object { $_.Name -ieq $forbidden }).Count -eq 0) -Message "Forbidden credential or runtime state is packaged: $forbidden"
    }
    $manifestPath = Join-Path $package 'RELEASE-BUILD.json'
    $manifest = [IO.File]::ReadAllText($manifestPath, (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    Assert-True -Condition ([int]$manifest.schemaVersion -eq 1 -and [string]$manifest.version -ceq $expectedVersion -and [string]$manifest.sourceSha256 -ceq $expectedSourceSha256) -Message 'RELEASE-BUILD.json release identity is invalid.'
    Assert-True -Condition ([string]$manifest.specSha256.main -ceq $expectedMainSpecSha256 -and [string]$manifest.specSha256.speech -ceq $expectedSpeechSpecSha256) -Message 'RELEASE-BUILD.json spec identities are invalid.'
    $mainExe = Join-Path $package 'RabbitSubtitle-3.203.exe'
    $speechExe = Join-Path $package 'speech-runtime\RabbitSubtitleSpeech.exe'
    $mainSha = (Get-Sha256Lower -Path $mainExe).ToUpperInvariant()
    $speechSha = (Get-Sha256Lower -Path $speechExe).ToUpperInvariant()
    Assert-True -Condition ([string]$manifest.executableSha256.main -ceq $mainSha -and [string]$manifest.executableSha256.speech -ceq $speechSha) -Message 'Packaged executable hashes do not match RELEASE-BUILD.json.'
    foreach ($case in @(@($mainExe, 'RabbitSubtitle-3.203.exe'), @($speechExe, 'RabbitSubtitleSpeech.exe'))) {
        $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($case[0])
        Assert-True -Condition ([string]$versionInfo.FileVersion -ceq '3.203.0.0' -and [string]$versionInfo.ProductVersion -ceq '3.203.0.0' -and [string]$versionInfo.OriginalFilename -ceq $case[1]) -Message "Invalid PE metadata: $($case[1])"
    }
    $checks.packageIdentity = [ordered]@{ passed = $true; sourceSha256 = $expectedSourceSha256; mainSpecSha256 = $expectedMainSpecSha256.ToLowerInvariant(); speechSpecSha256 = $expectedSpeechSpecSha256.ToLowerInvariant(); mainExeSha256 = $mainSha.ToLowerInvariant(); speechExeSha256 = $speechSha.ToLowerInvariant(); requiredFiles = $requiredFiles }
    $speakerCopy = [IO.File]::ReadAllText((Join-Path $package 'app_modules\speaker-setup-copy.json'), (New-Object Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    $locales = @($speakerCopy.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    Assert-True -Condition (($locales -join ',') -ceq 'en,ja,ko,zh-CN,zh-TW') -Message 'speaker-setup-copy.json does not contain the exact five locales.'
    $checks.speakerSetupCopyPresent = [ordered]@{ passed = $true; path = 'app_modules/speaker-setup-copy.json'; locales = $locales; sha256 = Get-Sha256Lower -Path (Join-Path $package 'app_modules\speaker-setup-copy.json') }
    Write-JsonRecord -Name 'package-identity.json' -Value ([ordered]@{ packageIdentity = $checks.packageIdentity; speakerSetupCopyPresent = $checks.speakerSetupCopyPresent }) | Out-Null

    $beforeSnapshot = @(Get-PackageSnapshot -Root $package)
    Write-JsonRecord -Name 'package-tree-before.json' -Value $beforeSnapshot | Out-Null

    $currentPhase = 'startup-and-console-observation'
    Start-ConsoleWindowMonitor
    $monitorStarted = $true
    $externalCwd = Join-Path $extractRoot 'external-working-directory'
    New-Item -ItemType Directory -Path $externalCwd | Out-Null
    $checks.noDevelopmentDependencies = [ordered]@{ passed = $true; pythonOnPath = $false; pyLauncherOnPath = $false; packageRootIsTemporaryExtraction = $true; sourceDirectoryPresent = $false }
    $checks.externalCwdLaunch = Invoke-DirectLaunchCheck -Executable $mainExe -WorkingDirectory $externalCwd -PackageRoot $package
    $desktop = [Environment]::GetFolderPath('Desktop')
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($desktop) -and (Test-Path -LiteralPath $desktop -PathType Container)) -Message 'The current account has no usable Desktop directory.'
    $shortcutPath = Join-Path $desktop 'RabbitSubtitle 3.203 Physical Acceptance.lnk'
    Assert-True -Condition (-not (Test-Path -LiteralPath $shortcutPath)) -Message 'Acceptance shortcut already exists; remove it before rerunning.'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $mainExe
    $shortcut.WorkingDirectory = $desktop
    $shortcut.Description = 'RabbitSubtitle 3.203 physical clean-Windows acceptance'
    $shortcut.Save()
    $checks.desktopShortcutLaunch = Invoke-ShortcutLaunchCheck -Shortcut $shortcutPath -PackageRoot $package
    Write-JsonRecord -Name 'startup-checks.json' -Value ([ordered]@{ noDevelopmentDependencies = $checks.noDevelopmentDependencies; externalCwdLaunch = $checks.externalCwdLaunch; desktopShortcutLaunch = $checks.desktopShortcutLaunch }) | Out-Null

    $currentPhase = 'manual-acceptance'
    Write-Host ''
    Write-Host 'The automatic package and startup checks passed.' -ForegroundColor Green
    Write-Host 'Use the extracted package shown below for every manual check:'
    Write-Host $package
    Write-Host 'Keep this PowerShell window open. Do not open another terminal while the console-window monitor is active.'
    Write-Host 'Never paste a Hugging Face token, license key, email, or private path into the records. Enter any token only in the masked RabbitSubtitle field.'
    Write-Host ''
    Write-Host 'Launch the retained Desktop acceptance shortcut now and complete the seven checks. The prompts will wait.'

    $checks.bilingualOutput = Confirm-ManualCheck -Name 'bilingualOutput' -Instruction 'Create a short output with two visible subtitle languages; play the beginning, middle, and end; confirm neither line is lost or outside the safe area.'
    $checks.missingModel = Confirm-ManualCheck -Name 'missingModel' -Instruction 'Before the first install, run a speech task from the recorded empty-cache state and confirm the app reports a localized missing-model condition instead of crashing.'
    $checks.modelInstallCancel = Confirm-ManualCheck -Name 'modelInstallCancel' -Instruction 'Start the first model installation, cancel it from the app, and confirm the UI returns a controlled cancelled state without a stuck worker.'
    $checks.modelInstallResume = Confirm-ManualCheck -Name 'modelInstallResume' -Instruction 'Resume or retry after cancellation and confirm the installation completes and the app remains usable.'
    $checks.firstModelInstall = Confirm-ManualCheck -Name 'firstModelInstall' -Instruction 'Confirm the cache-empty first-install lifecycle (including the cancellation and resume just tested) has reached a completed/ready state. Enter any private token only in the masked app field.'
    $checks.offlineReopen = Confirm-ManualCheck -Name 'offlineReopen' -Instruction 'Disconnect networking after installation, close and reopen RabbitSubtitle, then complete one local speech operation successfully while offline.'
    $checks.batch = Confirm-ManualCheck -Name 'batch' -Instruction 'Run a small non-sensitive multi-file batch, confirm successes remain intact when one input fails, and verify the output ZIP opens and lists the expected successful outputs.'
    $finalAttestation = Read-Host 'Type exactly: I personally performed all seven manual checks on this clean Windows machine.'
    Assert-True -Condition ($finalAttestation -ceq 'I personally performed all seven manual checks on this clean Windows machine.') -Message 'The physical tester attestation was not exact.'
    Write-JsonRecord -Name 'manual-observations.json' -Value ([ordered]@{ attestation = $finalAttestation; checks = [ordered]@{ bilingualOutput = $checks.bilingualOutput; firstModelInstall = $checks.firstModelInstall; modelInstallCancel = $checks.modelInstallCancel; modelInstallResume = $checks.modelInstallResume; missingModel = $checks.missingModel; offlineReopen = $checks.offlineReopen; batch = $checks.batch } }) | Out-Null

    Stop-PackageProcesses -PackageRoot $package
    $observedConsoleWindows = Stop-ConsoleWindowMonitor
    $monitorStarted = $false
    Assert-True -Condition ($observedConsoleWindows.Count -eq 0) -Message ("Console-window monitor observed {0} new console window(s): {1}" -f $observedConsoleWindows.Count, ($observedConsoleWindows -join '; '))
    $checks.noConsoleWindows = [ordered]@{ passed = $true; monitor = 'SetWinEventHook EVENT_OBJECT_SHOW for ConsoleWindowClass and CASCADIA_HOSTING_WINDOW_CLASS across automatic and manual startup checks'; observedCount = 0; observed = @() }
    Write-JsonRecord -Name 'console-window-monitor.json' -Value $checks.noConsoleWindows | Out-Null

    $currentPhase = 'defender'
    Assert-True -Condition ($null -ne (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) -and $null -ne (Get-Command Start-MpScan -ErrorAction SilentlyContinue)) -Message 'Microsoft Defender cmdlets are unavailable.'
    $defenderBefore = Get-MpComputerStatus
    Assert-True -Condition ([bool]$defenderBefore.AntivirusEnabled -and [bool]$defenderBefore.AMServiceEnabled -and [bool]$defenderBefore.RealTimeProtectionEnabled) -Message 'Microsoft Defender protection is not fully enabled.'
    $scanStartedAt = [DateTimeOffset]::UtcNow
    Start-MpScan -ScanType CustomScan -ScanPath $ArchivePath
    Start-MpScan -ScanType CustomScan -ScanPath $package
    $detections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object {
        $resources = @($_.Resources) -join [char]10
        $_.InitialDetectionTime -ge $scanStartedAt.LocalDateTime -and ($resources.IndexOf($ArchivePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $resources.IndexOf($package, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    Assert-True -Condition ($detections.Count -eq 0) -Message 'Microsoft Defender detected a threat in the ZIP or extracted package.'
    $defenderAfter = Get-MpComputerStatus
    $checks.defender = [ordered]@{ passed = $true; antivirusEnabled = [bool]$defenderAfter.AntivirusEnabled; realTimeProtectionEnabled = [bool]$defenderAfter.RealTimeProtectionEnabled; signaturesUpdatedAt = [string]$defenderAfter.AntivirusSignatureLastUpdated; threatsFound = @(); scannedArchive = $expectedArtifactName; scannedPackage = $expectedPackageRoot }
    Write-JsonRecord -Name 'defender.json' -Value $checks.defender | Out-Null

    $currentPhase = 'package-immutability'
    $afterSnapshot = @(Get-PackageSnapshot -Root $package)
    Write-JsonRecord -Name 'package-tree-after.json' -Value $afterSnapshot | Out-Null
    $beforeText = [IO.File]::ReadAllText((Join-Path $recordsDirectory 'package-tree-before.json'))
    $afterText = [IO.File]::ReadAllText((Join-Path $recordsDirectory 'package-tree-after.json'))
    Assert-True -Condition ($beforeText -ceq $afterText) -Message 'The extracted package tree changed during physical acceptance.'
    $checks.packageImmutability = [ordered]@{ passed = $true; entries = $afterSnapshot.Count; beforeSha256 = Get-Sha256Lower -Path (Join-Path $recordsDirectory 'package-tree-before.json'); afterSha256 = Get-Sha256Lower -Path (Join-Path $recordsDirectory 'package-tree-after.json') }

    $currentPhase = 'evidence-finalization'
    Assert-NoTextSecrets -Directory $recordsDirectory
    $actualCheckSet = @($checks.Keys | Sort-Object) -join [char]10
    $expectedCheckSet = @($physicalCheckNames | Sort-Object) -join [char]10
    Assert-True -Condition ($actualCheckSet -ceq $expectedCheckSet) -Message 'The physical check set is incomplete or contains extras.'
    foreach ($name in $physicalCheckNames) { Assert-True -Condition ([bool]$checks[$name].passed) -Message "Physical check '$name' did not pass." }
    $recordEvidence = New-Object Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $recordsDirectory -File -Force | Sort-Object Name)) {
        $recordEvidence.Add([ordered]@{ name = $file.Name; bytes = [long]$file.Length; sha256 = Get-Sha256Lower -Path $file.FullName })
    }
    Assert-True -Condition ($recordEvidence.Count -gt 0) -Message 'No immutable records were produced.'
    $report = [ordered]@{
        schemaVersion = 1
        gate = 'cleanWindowsPackage'
        version = $expectedVersion
        sourceSha256 = $expectedSourceSha256
        artifactSha256 = $ArtifactSha256
        artifactBytes = $ArtifactBytes
        artifactName = $expectedArtifactName
        producer = $producerName
        producerSha256 = Get-Sha256Lower -Path $producerCopy
        overallStatus = 'PASS'
        passed = $true
        startedAt = $startedAt.ToString('o')
        finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
        machine = $machine
        checks = $checks
        secretsFound = @()
        fatalError = $null
        records = @($recordEvidence)
    }
    Write-Utf8NoBom -Path (Join-Path $EvidenceDirectory 'physicalCleanWindows.json') -Text (($report | ConvertTo-Json -Depth 40) + [char]10)
    Write-Host ''
    Write-Host 'Physical clean-Windows evidence passed and was written fail-closed:' -ForegroundColor Green
    Write-Host (Join-Path $EvidenceDirectory 'physicalCleanWindows.json')
    Write-Host "Assembler input role: physicalCleanWindows"
} catch {
    $failure = [ordered]@{
        schemaVersion = 1
        gate = 'cleanWindowsPackage'
        version = $expectedVersion
        sourceSha256 = $expectedSourceSha256
        artifactSha256 = if ($null -eq $ArtifactSha256) { '' } else { [string]$ArtifactSha256 }
        artifactBytes = $ArtifactBytes
        overallStatus = 'FAIL'
        passed = $false
        phase = $currentPhase
        failedAt = [DateTimeOffset]::UtcNow.ToString('o')
        errorType = $_.Exception.GetType().FullName
        error = $_.Exception.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        try {
            if (-not (Test-Path -LiteralPath $EvidenceDirectory)) { New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null }
            Write-Utf8NoBom -Path (Join-Path $EvidenceDirectory 'physicalCleanWindows.failure.json') -Text (($failure | ConvertTo-Json -Depth 10) + [char]10)
        } catch {}
    }
    [Console]::Error.WriteLine("Physical clean-Windows acceptance failed in '$currentPhase': $($_.Exception.Message)")
    exit 1
} finally {
    if ($monitorStarted) {
        try { [void](Stop-ConsoleWindowMonitor) } catch {}
    }
    if ($null -ne $package -and (Test-Path -LiteralPath $package -PathType Container)) {
        try { Stop-PackageProcesses -PackageRoot $package } catch {}
    }
    if ($null -ne $shortcutPath -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        try { Remove-Item -LiteralPath $shortcutPath -Force } catch {}
    }
    if ($null -ne $extractRoot -and (Test-Path -LiteralPath $extractRoot -PathType Container)) {
        try {
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\RabbitSubtitle-physical-3.203-'
            $resolvedExtract = [IO.Path]::GetFullPath($extractRoot)
            if ($resolvedExtract.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedExtract -Recurse -Force
            }
        } catch {}
    }
}
