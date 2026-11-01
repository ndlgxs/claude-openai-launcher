#Requires -Version 7.0
[CmdletBinding()]
param(
    [Alias('MetadataPath')]
    [string] $CatalogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')
$paths = Get-LauncherPaths

function Get-PositiveCatalogInteger {
    param([object] $Value, [string] $FieldName, [string] $ModelId)
    $number = 0L
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
        -not [long]::TryParse([string] $Value, [ref] $number) -or $number -le 0) {
        throw ("The catalog model '{0}' needs a positive integer '{1}'. No model files were changed." -f $ModelId, $FieldName)
    }
    return $number
}

function Get-IndependentSiwcBearer {
    param([string] $AuthRoot)
    if (-not (Test-Path -LiteralPath $AuthRoot -PathType Container)) {
        throw 'No independent proxy login is present. Run Login.ps1 before updating models.'
    }
    $credentialFiles = @(Get-ChildItem -LiteralPath $AuthRoot -File -Filter '*.json' |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($credentialFile in $credentialFiles) {
        try {
            $record = Get-Content -LiteralPath $credentialFile.FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        catch { continue }
        if ($record -isnot [System.Collections.IDictionary] -or $record['type'] -ne 'codex' -or
            $record['use_siwc'] -isnot [bool] -or -not $record['use_siwc']) { continue }
        if ($record.Contains('disabled') -and ($record['disabled'] -isnot [bool] -or $record['disabled'])) { continue }
        $siwc = $record['siwc']
        if ($siwc -isnot [System.Collections.IDictionary] -or
            $siwc['access_token'] -isnot [string] -or [string]::IsNullOrWhiteSpace($siwc['access_token'])) { continue }
        # The top-level access_token belongs to the older Codex OAuth partition.
        # Only this independent proxy record's SIWC bearer is used.
        return [string] $siwc['access_token']
    }
    throw 'No enabled independent proxy credential has ChatGPT plan authorization. Complete Login.ps1 and retry.'
}

function Get-AccountModelCatalog {
    param([string] $Bearer)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.openai.com/v1/models')
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Bearer)
    $request.Headers.Accept.ParseAdd('application/json')
    $request.Headers.UserAgent.ParseAdd('ClaudeOpenAI-Launcher/1.0')
    $response = $null
    try {
        try { $response = $client.SendAsync($request).GetAwaiter().GetResult() }
        catch { throw 'Could not fetch the OpenAI account model catalog over HTTPS. No model files were changed.' }
        if (-not $response.IsSuccessStatusCode) {
            $status = [int] $response.StatusCode
            if ($status -eq 401 -or $status -eq 403) {
                throw ("OpenAI rejected the ChatGPT plan authorization (HTTP {0}). Refresh the independent proxy login or run Login.ps1 again." -f $status)
            }
            throw ("OpenAI model catalog request returned HTTP {0}; redirects are not followed. No model files were changed." -f $status)
        }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        try { return $json | ConvertFrom-Json -AsHashtable }
        catch { throw 'OpenAI returned an invalid model catalog. No model files were changed.' }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
        $Bearer = $null
    }
}

$offlineMode = $PSBoundParameters.ContainsKey('CatalogPath')
if (-not $offlineMode) {
    $bearer = Get-IndependentSiwcBearer -AuthRoot $paths.AuthRoot
    try { $catalog = Get-AccountModelCatalog -Bearer $bearer }
    finally { $bearer = $null }
    $source = 'https://api.openai.com/v1/models'
    $sourceType = 'Current signed-in ChatGPT account catalog using its independent proxy SIWC authorization'
}
else {
    # Offline fixtures deliberately do not inspect AuthRoot or use a network client.
    if ([string]::IsNullOrWhiteSpace($CatalogPath)) { throw 'An offline catalog fixture path is required when -CatalogPath is supplied.' }
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'The offline catalog fixture does not exist.' }
    try { $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw 'The offline catalog fixture is not valid JSON.' }
    $source = 'offline-fixture:' + [IO.Path]::GetFileName($CatalogPath)
    $sourceType = 'Offline test fixture; account authorization and model availability were not verified'
}
if ($catalog -isnot [System.Collections.IDictionary] -or -not $catalog.Contains('models') -or
    $catalog['models'] -is [string] -or $catalog['models'] -is [System.Collections.IDictionary] -or
    $catalog['models'] -isnot [System.Collections.IEnumerable]) {
    throw "The account catalog must contain a 'models' array. No model files were changed."
}

$specPath = Join-Path $paths.RepoRoot 'data\model-specs.json'
$specification = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json -AsHashtable
$modelOrder = @('gpt-6.1-sol', 'gpt-6-astra', 'gpt-6.1-terra', 'gpt-6-luna')
$allowedEfforts = @('none', 'low', 'medium', 'high', 'xhigh', 'max')
$selectedModels = [ordered]@{}
foreach ($modelId in $modelOrder) {
    $catalogEntries = @($catalog['models'] | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_['slug'] -eq $modelId -and $_['visibility'] -eq 'list'
    })
    if ($catalogEntries.Count -eq 0) { continue }
    if ($catalogEntries.Count -ne 1) { throw ("The account catalog contains duplicate visible entries for '{0}'." -f $modelId) }
    $entry = $catalogEntries[0]
    $serviceDefault = Get-PositiveCatalogInteger -Value $entry['context_window'] -FieldName 'context_window' -ModelId $modelId
    $accountMaximum = Get-PositiveCatalogInteger -Value $entry['max_context_window'] -FieldName 'max_context_window' -ModelId $modelId
    if ($accountMaximum -lt $serviceDefault) { throw ("The account maximum is smaller than the default window for '{0}'." -f $modelId) }
    if (-not $specification['models'].Contains($modelId)) { throw ("Published output specifications are missing for '{0}'." -f $modelId) }
    $modelSpec = $specification['models'][$modelId]
    $publishedOutput = Get-PositiveCatalogInteger -Value $modelSpec['maxOutputTokens'] -FieldName 'published maxOutputTokens' -ModelId $modelId
    $advertisedEfforts = @(foreach ($effortEntry in @($entry['supported_reasoning_levels'])) {
        if ($effortEntry -is [System.Collections.IDictionary]) { [string] $effortEntry['effort'] }
        elseif ($effortEntry -is [string]) { $effortEntry }
    })
    $efforts = @($allowedEfforts | Where-Object { $advertisedEfforts -contains $_ })
    $defaultEffort = [string] $entry['default_reasoning_level']
    if ($efforts -notcontains $defaultEffort) {
        $defaultEffort = if ($efforts -contains 'medium') { 'medium' } elseif ($efforts.Count) { $efforts[0] } else { $null }
    }
    $selectedModels[$modelId] = [ordered]@{
        displayName = [string] $modelSpec['displayName']
        serviceDefaultContextWindow = $serviceDefault
        accountMaxContextWindow = $accountMaximum
        publishedMaxOutputTokens = $publishedOutput
        reasoningLevels = $efforts
        defaultReasoningEffort = $defaultEffort
        outputSpecification = [string] $modelSpec['source']
    }
}
if ($selectedModels.Count -eq 0) { throw 'The account catalog has none of the four supported visible GPT models. No model files were changed.' }

$activeContext = [long] (($selectedModels.Values | ForEach-Object { $_.accountMaxContextWindow } | Measure-Object -Minimum).Minimum)
$publishedOutputBudget = [long] (($selectedModels.Values | ForEach-Object { $_.publishedMaxOutputTokens } | Measure-Object -Minimum).Minimum)
$minimumCompaction = 100000L
$reservedHeadroom = 44000L
$budgetWithRoom = [long] ([Math]::Floor(($activeContext - $minimumCompaction - $reservedHeadroom) / 1000.0) * 1000)
$commonOutputBudget = [long] [Math]::Min($publishedOutputBudget, $budgetWithRoom)
if ($commonOutputBudget -lt 1024) { throw 'The account context windows are too small to reserve a useful output budget and 100K history. No model files were changed.' }
$autoCompact = [long] [Math]::Min(700000, [Math]::Floor(($activeContext - $commonOutputBudget - $reservedHeadroom) / 1000.0) * 1000)
if ($autoCompact -lt $minimumCompaction) { throw 'The account context windows cannot safely fit automatic compaction and output headroom. No model files were changed.' }

$profiles = [ordered]@{}
$availableModels = [Collections.Generic.List[string]]::new()
$pickerOptions = [Collections.Generic.List[object]]::new()
$modelSettings = [ordered]@{}
foreach ($modelId in $selectedModels.Keys) {
    $selected = $selectedModels[$modelId]
    $profiles[$modelId] = [ordered]@{
        displayName = $selected.displayName
        serviceDefaultContextWindow = $selected.serviceDefaultContextWindow
        accountMaxContextWindow = $selected.accountMaxContextWindow
        contextWindow = $activeContext
        maxOutputTokens = $commonOutputBudget
        autoCompactWindow = $autoCompact
        reasoningLevels = $selected.reasoningLevels
        defaultReasoningEffort = $selected.defaultReasoningEffort
        outputSpecification = $selected.outputSpecification
    }
    $variants = @($modelId) + @($selected.reasoningLevels | ForEach-Object { '{0}({1})' -f $modelId, $_ })
    foreach ($variant in $variants) {
        $availableModels.Add($variant)
        $label = if ($variant -eq $modelId) { $selected.displayName } else {
            '{0} ({1})' -f $selected.displayName, ($variant -replace '^.*\(([^)]+)\)$', '$1')
        }
        # CLI effort is a native session setting, so the picker keeps four raw
        # models. Fixed suffix IDs remain allowlisted for manual compatibility.
        if ($variant -eq $modelId) {
            $pickerOptions.Add([ordered]@{
                model = $variant
                label = $label
                description = ('{0}K context; compact at {1}K; change thinking with /effort' -f ($activeContext / 1000), ($autoCompact / 1000))
            })
        }
        $modelSettings[$variant] = [ordered]@{ autoCompactWindow = $autoCompact }
    }
}
$profileDocument = [ordered]@{
    schemaVersion = 1
    verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
    source = $source
    sourceType = $sourceType
    activeContextWindow = $activeContext
    commonOutputBudget = $commonOutputBudget
    autoCompactWindow = $autoCompact
    outputNote = 'Local Claude output budget is limited by published model capability and reserved headroom. SIWC does not accept max_output_tokens; upstream controls actual output.'
    contextNote = 'Context override uses the minimum account-advertised maximum across selectable models. It is not a long-context inference test.'
    profiles = $profiles
}
$sessionSettings = [ordered]@{
    autoCompactEnabled = $true
    autoCompactWindow = $autoCompact
    availableModels = $availableModels.ToArray()
    modelPicker = [ordered]@{ replaceBuiltInOptions = $true; options = $pickerOptions.ToArray() }
    modelSettings = $modelSettings
}

# Both documents are built and validated before either destination is replaced.
# Common.ps1 writes each JSON file by atomic replacement.
Write-LauncherJson -Path $paths.SessionSettingsPath -Value $sessionSettings
Write-LauncherJson -Path $paths.ProfilesPath -Value $profileDocument
[pscustomobject]@{
    ModelCount = $profiles.Count
    ActiveContextWindow = $activeContext
    CommonOutputBudget = $commonOutputBudget
    AutoCompactWindow = $autoCompact
    ProfilesPath = $paths.ProfilesPath
    SessionSettingsPath = $paths.SessionSettingsPath
} | ConvertTo-Json -Compress
