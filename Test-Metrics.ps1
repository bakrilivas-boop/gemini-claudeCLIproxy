$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CLIProxyAPI-Metrics.ps1')

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$state = [pscustomobject]@{ Version = 1; Buckets = @() }
$day = (Get-Date).ToString('yyyy-MM-dd')
$records = @(
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o'); auth_index = 'auth-a'; source = ''; failed = $false; latency_ms = 1200
        tokens = [pscustomobject]@{ input_tokens = 100; output_tokens = 30; cached_tokens = 20; reasoning_tokens = 10; total_tokens = 130 }
    },
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o'); auth_index = 'auth-a'; source = ''; failed = $true; latency_ms = 800
        tokens = $null
    },
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o'); auth_index = 'unknown'; source = ''; failed = $true; latency_ms = 900
        tokens = $null
    }
)
$map = @{ 'auth-a' = 'test@example.com' }
Assert (Add-UsageRecords -State $state -Records $records -Map $map) 'No usage change reported'
$bucket = @($state.Buckets | Where-Object { $_.Account -eq 'test@example.com' -and $_.Day -eq $day })
Assert ($bucket.Count -eq 1) 'Wrong account attribution'
Assert ($bucket[0].Requests -eq 2 -and $bucket[0].Failed -eq 1) 'Request count failed'
Assert ($bucket[0].LatencySumMs -eq 2000 -and $bucket[0].LatencyReports -eq 2) 'Latency count failed'
Assert ($bucket[0].TotalTokens -eq 130 -and $bucket[0].TokenReports -eq 1) 'Token count failed'
Assert ($bucket[0].CachedTokens -eq 20 -and $bucket[0].ReasoningTokens -eq 10) 'Token detail failed'
$quotaPayload = '{"groups":[{"displayName":"Gemini","buckets":[{"displayName":"Flash","window":"daily","remainingFraction":0.75,"resetTime":"2026-09-28T00:00:00Z"},{"display_name":"Pro","remaining_fraction":0,"reset_time":"2026-09-29T00:00:00Z"}]}]}' | ConvertFrom-Json
$quotaRows = @(Convert-QuotaPayload -Payload $quotaPayload)
Assert ($quotaRows.Count -eq 2) 'Quota row count failed'
Assert ($quotaRows[0].Name -eq 'Gemini / Flash' -and $quotaRows[0].RemainingPercent -eq 75) 'Quota percentage failed'
Assert ($quotaRows[1].Name -eq 'Gemini / Pro' -and $quotaRows[1].RemainingPercent -eq 0) 'Zero quota failed'
Assert ($quotaRows[1].RemainingFraction -eq 0 -and $quotaRows[1].Group -eq 'Gemini' -and $quotaRows[1].ResetAt -match '^2026-09-29T') 'Quota decision metadata lost'
Assert (([DateTimeOffset]::Parse($quotaRows[0].ResetAt)).UtcDateTime -eq [DateTime]::Parse('2026-09-28T00:00:00Z').ToUniversalTime()) 'Quota reset time lost its UTC offset'
$edgePayload = '{"groups":[{"displayName":"Claude and GPT models","buckets":[{"remainingFraction":0.00001},{"remainingFraction":-0.1},{"remainingFraction":1.5},{"remainingFraction":"NaN"},{"remainingFraction":"Infinity"}]}]}' | ConvertFrom-Json
$edgeRows = @(Convert-QuotaPayload -Payload $edgePayload)
Assert ($edgeRows.Count -eq 1 -and $edgeRows[0].RemainingPercent -eq 0 -and $edgeRows[0].RemainingFraction -gt 0) 'Rounded zero or invalid quota treated as exhaustion'
$argonPayload = '{"models":{"gemini-4-argon-high":{"displayName":"Gemini 4 Argon","quotaInfo":{"remainingFraction":0.42,"resetTime":"2026-10-24T00:00:00Z"}}}}' | ConvertFrom-Json
$argonRows = @(Convert-ArgonQuotaPayload -Payload $argonPayload)
Assert ($argonRows.Count -eq 1 -and $argonRows[0].Group -eq 'Gemini 4 Argon' -and $argonRows[0].RemainingPercent -eq 42) 'Argon quota was not discovered'
$disabledPayload = '{"models":{"gemini-4-argon-disabled":{"displayName":"Gemini 4 Argon","disabled":true,"tagTitle":"Unavailable","quotaInfo":{"remainingFraction":0}}}}' | ConvertFrom-Json
$disabledRows = @(Convert-ArgonQuotaPayload -Payload $disabledPayload)
Assert ($disabledRows.Count -eq 1 -and $null -eq $disabledRows[0].RemainingFraction -and $disabledRows[0].StatusText -eq '未开放') 'Disabled Argon was treated as exhausted'
$missingRows = @(Convert-ArgonQuotaPayload -Payload ('{"models":{}}' | ConvertFrom-Json))
Assert ($missingRows.Count -eq 1 -and $null -eq $missingRows[0].RemainingPercent -and $missingRows[0].StatusText -eq '未返回') 'Missing Argon quota was fabricated'
$invalidRows = @(Convert-ArgonQuotaPayload -Payload ('{"models":{"gemini-4-argon-high":{"quotaInfo":{"remainingFraction":-1}}}}' | ConvertFrom-Json))
Assert ($null -eq $invalidRows[0].RemainingFraction -and $invalidRows[0].StatusText -eq '未知') 'Invalid Argon quota was accepted'
# Replay the complete request path with fixture credentials and no network.
$fixtureRoot = Join-Path $PSScriptRoot ('quota-test-' + [guid]::NewGuid().ToString('N'))
$fixtureAuthDir = Join-Path $fixtureRoot '.cli-proxy-api'
$fixtureAuth = Join-Path $fixtureAuthDir 'antigravity-test.json'
$previousProfile = $env:USERPROFILE
try {
    [void][IO.Directory]::CreateDirectory($fixtureAuthDir)
    [IO.File]::WriteAllText($fixtureAuth, '{"project_id":"fixture-project"}')
    $env:USERPROFILE = $fixtureRoot
    function Get-ManagementKey { 'fixture-key' }
    function Get-ManagementPort { 8317 }
    function Invoke-Management {
        param($Path, $Key, $Port, $Body, $TimeoutMs)
        if ($Path -eq 'auth-files') { return [pscustomobject]@{ files = @([pscustomobject]@{name='antigravity-test.json';provider='antigravity';disabled=$false;auth_index='fixture-index'}) } }
        $request = $Body | ConvertFrom-Json
        if ($request.url -match 'manifest/') { return [pscustomobject]@{status_code=200;body="version: 2.25.1`n"} }
        Assert ($request.header.'User-Agent' -eq 'antigravity/hub/2.25.1 darwin/arm64') 'Quota request omitted the current versioned User-Agent'
        if ($request.url -match 'retrieveUserQuotaSummary$') { return [pscustomobject]@{status_code=200;body='{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":1}]}]}'} }
        if ($script:failCatalog) { return [pscustomobject]@{status_code=503;body='{}'} }
        return [pscustomobject]@{status_code=200;body='{"models":{"gemini-4-argon-high":{"quotaInfo":{"remainingFraction":0.42}}}}'}
    }
    $result = Get-QuotaResult -FileName 'antigravity-test.json'
    Assert ($result.Status -eq 'ok' -and $result.Rows.Count -eq 2 -and $result.Rows[1].RemainingPercent -eq 42) 'Combined summary and Argon query failed'
    $script:failCatalog = $true
    $result = Get-QuotaResult -FileName 'antigravity-test.json'
    Assert ($result.Status -eq 'ok' -and $result.Rows[0].RemainingPercent -eq 100 -and $result.Rows[1].StatusText -eq '查询失败') 'Catalog failure discarded valid summary quota'
}
finally {
    $env:USERPROFILE = $previousProfile
    if ([IO.File]::Exists($fixtureAuth)) { Remove-Item -LiteralPath $fixtureAuth }
    if ([IO.Directory]::Exists($fixtureAuthDir)) { Remove-Item -LiteralPath $fixtureAuthDir }
    if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot }
}
'METRICS_TEST_OK'
