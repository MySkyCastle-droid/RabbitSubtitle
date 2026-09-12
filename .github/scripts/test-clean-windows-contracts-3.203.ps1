[CmdletBinding()]
param(
    [string]$AssemblerPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$hostedScript = Join-Path $PSScriptRoot 'clean-windows-3.203.ps1'
$physicalScript = Join-Path $PSScriptRoot 'produce-physical-clean-windows-evidence.ps1'
$workflow = Join-Path $root '.github\workflows\clean-windows-3.203.yml'
$expectedAssemblerSha256 = 'd7ad033b87a5c12909a29401a3d80839e88b2bdb282473990cef34d46c9b15c7'
$expectedSourceSha256 = '1681a475c8be73348b852fd6248315c6cfb9795b57ef76f1846a8c4cd69c542f'
$expectedMainSpecSha256 = '0064174f1d3944b825f3d63316548b2ae8435c0d1bb060ca66f2f8497126bc0b'
$expectedSpeechSpecSha256 = '40b0f97eec4b0417304fad334822758dd28ba13c3d0cd5bd50b13499429d8403'
$expectedReportKeys = @(
    'artifactBytes', 'artifactName', 'artifactSha256', 'checks', 'fatalError',
    'finishedAt', 'gate', 'machine', 'overallStatus', 'passed', 'producer',
    'producerSha256', 'records', 'schemaVersion', 'secretsFound',
    'sourceSha256', 'startedAt', 'version'
)
$expectedHostedReportKeys = @(
    'schemaVersion', 'gate', 'version', 'sourceSha256', 'artifactSha256',
    'artifactBytes', 'artifactName', 'overallStatus', 'passed',
    'releaseGateEligible', 'coreAcceptancePassed', 'acceptanceScope',
    'startedAt', 'finishedAt', 'github', 'checks', 'fatalError', 'records',
    'limitations'
)
$expectedMachineKeys = @('architecture', 'existingModelCache', 'pyLauncherOnPath', 'pythonOnPath', 'windowsVersion')
$expectedPhysicalChecks = @(
    'batch', 'bilingualOutput', 'defender', 'desktopShortcutLaunch',
    'externalCwdLaunch', 'firstModelInstall', 'missingModel',
    'modelInstallCancel', 'modelInstallResume', 'noConsoleWindows',
    'noDevelopmentDependencies', 'offlineReopen', 'packageIdentity',
    'packageImmutability', 'speakerSetupCopyPresent', 'zipSafety'
)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ExactSet {
    param([object[]]$Actual, [object[]]$Expected, [string]$Label)
    $actualText = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive) -join [char]10
    $expectedText = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive) -join [char]10
    Assert-True -Condition ($actualText -ceq $expectedText) -Message "$Label differs from the exact release contract."
}

function Assert-Parses {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $source = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
    [void][Management.Automation.Language.Parser]::ParseInput($source, $Path, [ref]$tokens, [ref]$errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message ("PowerShell parser rejected {0}: {1}" -f $Path, (($errors | ForEach-Object { $_.Message }) -join '; '))
}

function Test-TextContains {
    param([string]$Text, [string]$Value, [switch]$IgnoreCase)
    $comparison = if ($IgnoreCase) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $Text.IndexOf($Value, $comparison) -ge 0
}

function Test-ScriptContainsExactHashtable {
    param([string]$Path, [object[]]$ExpectedKeys)
    $source = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, $Path, [ref]$tokens, [ref]$errors)
    $expected = @($ExpectedKeys | Sort-Object -CaseSensitive) -join [char]10
    foreach ($hashtable in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true)) {
        $keys = New-Object Collections.Generic.List[string]
        $static = $true
        foreach ($pair in $hashtable.KeyValuePairs) {
            try { $keys.Add([string]$pair.Item1.SafeGetValue()) } catch { $static = $false; break }
        }
        if ($static -and ((@($keys) | Sort-Object -CaseSensitive) -join [char]10) -ceq $expected) { return $true }
    }
    return $false
}

foreach ($file in @($hostedScript, $physicalScript)) {
    Assert-True -Condition (Test-Path -LiteralPath $file -PathType Leaf) -Message "Missing script: $file"
    Assert-Parses -Path $file
}
Assert-True -Condition (Test-Path -LiteralPath $workflow -PathType Leaf) -Message 'Clean Windows workflow is missing.'

$contract = (& $physicalScript -DescribeContract | Out-String) | ConvertFrom-Json
Assert-True -Condition ([int]$contract.schemaVersion -eq 1) -Message 'Physical producer contract schema is not 1.'
Assert-True -Condition ([string]$contract.producer -ceq 'produce-physical-clean-windows-evidence.ps1') -Message 'Physical producer filename differs from the assembler contract.'
Assert-True -Condition ([string]$contract.version -ceq '3.203') -Message 'Physical producer version differs from 3.203.'
Assert-True -Condition ([string]$contract.sourceSha256 -ceq $expectedSourceSha256) -Message 'Physical producer source hash is stale.'
Assert-True -Condition ([string]$contract.mainSpecSha256 -ceq $expectedMainSpecSha256) -Message 'Physical producer main spec hash is stale.'
Assert-True -Condition ([string]$contract.speechSpecSha256 -ceq $expectedSpeechSpecSha256) -Message 'Physical producer speech spec hash is stale.'
Assert-ExactSet -Actual @($contract.reportKeys) -Expected $expectedReportKeys -Label 'Physical root keys'
Assert-ExactSet -Actual @($contract.machineKeys) -Expected $expectedMachineKeys -Label 'Physical machine keys'
Assert-ExactSet -Actual @($contract.checks) -Expected $expectedPhysicalChecks -Label 'Physical checks'
Assert-True -Condition (Test-ScriptContainsExactHashtable -Path $physicalScript -ExpectedKeys $expectedReportKeys) -Message 'Physical PASS report builder does not use the exact root key set.'
Assert-True -Condition (Test-ScriptContainsExactHashtable -Path $physicalScript -ExpectedKeys $expectedMachineKeys) -Message 'Physical machine builder does not use the exact machine key set.'
Assert-True -Condition (Test-ScriptContainsExactHashtable -Path $hostedScript -ExpectedKeys $expectedHostedReportKeys) -Message 'Hosted PASS report builder does not use the exact root key set.'

$hostedText = [IO.File]::ReadAllText($hostedScript)
$workflowText = [IO.File]::ReadAllText($workflow)
Assert-True -Condition (Test-TextContains -Text $hostedText -Value $expectedSourceSha256 -IgnoreCase) -Message 'Hosted helper source hash is stale.'
Assert-True -Condition (Test-TextContains -Text $hostedText -Value $expectedMainSpecSha256 -IgnoreCase) -Message 'Hosted helper main spec hash is stale.'
Assert-True -Condition (Test-TextContains -Text $hostedText -Value $expectedSpeechSpecSha256 -IgnoreCase) -Message 'Hosted helper speech spec hash is stale.'
Assert-True -Condition (Test-TextContains -Text $hostedText -Value "Join-Path `$EvidenceDirectory 'githubWindowsRunner.records'") -Message 'Hosted helper does not emit the assembler-required records directory.'
Assert-True -Condition (-not [regex]::IsMatch($hostedText, "(?m)^\s*role\s*=\s*'githubWindowsRunner'\s*$")) -Message 'Hosted raw payload contains a forbidden role key.'
Assert-True -Condition (Test-TextContains -Text $workflowText -Value 'githubWindowsRunner.records') -Message 'Workflow does not preserve the role-bound records directory.'
Assert-True -Condition (Test-TextContains -Text $workflowText -Value "Join-Path `$evidence 'workflow-diagnostics'") -Message 'Workflow does not isolate post-report diagnostics from immutable raw records.'
Assert-True -Condition (-not (Test-TextContains -Text $workflowText -Value "Join-Path `$records 'workflow-outcomes.json'")) -Message 'Workflow mutates immutable raw records after the report is written.'
Assert-True -Condition (-not [regex]::IsMatch($workflowText, "(?m)^\s*role\s*:\s*githubWindowsRunner\s*$|(?m)^\s*role\s*=\s*'githubWindowsRunner'\s*$")) -Message 'Workflow fallback contains a forbidden role key.'
Assert-True -Condition (Test-TextContains -Text $workflowText -Value 'GH_TOKEN: ${{ github.token }}') -Message 'Draft download is not authenticated with the same-repository GITHUB_TOKEN.'
Assert-True -Condition (Test-TextContains -Text $workflowText -Value 'The draft must contain only the canonical ZIP and checksum sidecar.') -Message 'Draft asset set is not exact.'

if (-not [string]::IsNullOrWhiteSpace($AssemblerPath)) {
    $AssemblerPath = [IO.Path]::GetFullPath($AssemblerPath)
    Assert-True -Condition (Test-Path -LiteralPath $AssemblerPath -PathType Leaf) -Message 'AssemblerPath is missing.'
    $assemblerSha = (Get-FileHash -LiteralPath $AssemblerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True -Condition ($assemblerSha -ceq $expectedAssemblerSha256) -Message 'Assembler file hash differs from the final locked SHA-256.'
    $assemblerText = [IO.File]::ReadAllText($AssemblerPath)
    foreach ($value in @($expectedSourceSha256, $expectedMainSpecSha256, $expectedSpeechSpecSha256, 'produce-physical-clean-windows-evidence.ps1')) {
        Assert-True -Condition (Test-TextContains -Text $assemblerText -Value $value -IgnoreCase) -Message "Assembler does not contain locked contract value: $value"
    }
    foreach ($name in $expectedPhysicalChecks) {
        Assert-True -Condition (Test-TextContains -Text $assemblerText -Value ('"' + $name + '"')) -Message "Assembler does not contain physical check '$name'."
    }
}

Write-Host 'PASS: hosted and physical clean-Windows scripts match the locked 3.203 contract.'
