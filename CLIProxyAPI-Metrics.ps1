param(
    [switch]$Collect,
    [switch]$Quota,
    [string]$AuthFile,
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$script:configPath = Join-Path $env:USERPROFILE 'Downloads\CLIProxyAPI_7.3.17_windows_amd64\config.yaml'
$script:keyPath = Join-Path $PSScriptRoot '管理密钥.dat'
$script:usagePath = Join-Path $PSScriptRoot '面板用量.json'
$script:quotaPath = Join-Path $PSScriptRoot '面板额度.json'
$script:entropy = [Text.Encoding]::UTF8.GetBytes('CLIProxyAPI-Helper-Management-v1')

function Get-ManagementKey {
    if (-not [IO.File]::Exists($script:keyPath)) { throw '管理密钥尚未配置。' }
    $blob = [Convert]::FromBase64String([IO.File]::ReadAllText($script:keyPath).Trim())
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($blob, $script:entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-ManagementPort {
    $config = [IO.File]::ReadAllText($script:configPath)
    $match = [regex]::Match($config, '(?m)^port:\s*(\d+)\s*$')
    if (-not $match.Success) { throw '无法读取代理端口。' }
    return [int]$match.Groups[1].Value
}

function Invoke-Management {
    param([string]$Path, [string]$Key, [int]$Port, [string]$Body = '', [int]$TimeoutMs = 6000)
    $url = 'http://127.0.0.1:{0}/v0/management/{1}' -f $Port, $Path
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($url)
    $request.Proxy = $null
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    $request.Headers['Authorization'] = 'Bearer ' + $Key
    if ($Body) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    }
    finally { $response.Dispose() }
}

function Save-JsonAtomically {
    param([string]$Path, $Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress))
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $Path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, $backup) }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Read-UsageState {
    if (-not [IO.File]::Exists($script:usagePath)) { return [pscustomobject]@{ Version = 1; Buckets = @() } }
    $state = [IO.File]::ReadAllText($script:usagePath) | ConvertFrom-Json
    if ($state.Version -ne 1 -or $null -eq $state.Buckets) { throw '用量记录格式无法识别。' }
    return $state
}

function Get-AuthIndexMap {
    param([string]$Key, [int]$Port)
    $map = @{}
    $response = Invoke-Management -Path 'auth-files' -Key $Key -Port $Port
    foreach ($file in @($response.files)) {
        if ($file.auth_index -and $file.name) {
            $map[[string]$file.auth_index] = ([string]$file.name -replace '(?i)^antigravity-', '' -replace '(?i)\.json$', '').ToLowerInvariant()
        }
    }
    return $map
}

function Resolve-UsageAccount {
    param($Record, [hashtable]$Map)
    $index = [string]$Record.auth_index
    if ($index -and $Map.ContainsKey($index)) { return $Map[$index] }
    $source = [string]$Record.source
    $email = [regex]::Match($source, '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}')
    if ($email.Success) { return $email.Value.ToLowerInvariant() }
    return ''
}

function Add-UsageRecords {
    param($State, [object[]]$Records, [hashtable]$Map)
    $buckets = @{}
    foreach ($bucket in @($State.Buckets)) { $buckets[([string]$bucket.Account + '|' + [string]$bucket.Day)] = $bucket }
    $changed = $false
    foreach ($record in $Records) {
        $account = Resolve-UsageAccount -Record $record -Map $Map
        if (-not $account) { continue }
        $at = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$record.timestamp, [ref]$at)) { continue }
        $day = $at.ToLocalTime().ToString('yyyy-MM-dd')
        $id = $account + '|' + $day
        if (-not $buckets.ContainsKey($id)) {
            $buckets[$id] = [pscustomobject]@{
                Account = $account; Day = $day; Requests = 0; Failed = 0
                LatencySumMs = 0; LatencyReports = 0; InputTokens = 0; OutputTokens = 0
                CachedTokens = 0; ReasoningTokens = 0; TotalTokens = 0; TokenReports = 0
            }
        }
        $bucket = $buckets[$id]
        $bucket.Requests = [long]$bucket.Requests + 1
        if ($record.failed -eq $true) { $bucket.Failed = [long]$bucket.Failed + 1 }
        if ($null -ne $record.latency_ms -and [double]$record.latency_ms -ge 0) {
            $bucket.LatencySumMs = [long]$bucket.LatencySumMs + [long]$record.latency_ms
            $bucket.LatencyReports = [long]$bucket.LatencyReports + 1
        }
        if ($null -ne $record.tokens) {
            $tokens = $record.tokens
            $bucket.InputTokens = [long]$bucket.InputTokens + [long]$tokens.input_tokens
            $bucket.OutputTokens = [long]$bucket.OutputTokens + [long]$tokens.output_tokens
            $bucket.CachedTokens = [long]$bucket.CachedTokens + [long]$tokens.cached_tokens
            $bucket.ReasoningTokens = [long]$bucket.ReasoningTokens + [long]$tokens.reasoning_tokens
            $total = if ($null -ne $tokens.total_tokens) { [long]$tokens.total_tokens } else { [long]$tokens.input_tokens + [long]$tokens.output_tokens }
            $bucket.TotalTokens = [long]$bucket.TotalTokens + $total
            $bucket.TokenReports = [long]$bucket.TokenReports + 1
        }
        $changed = $true
    }
    if ($changed) {
        $oldest = (Get-Date).Date.AddDays(-30).ToString('yyyy-MM-dd')
        $State.Buckets = @($buckets.Values | Where-Object { $_.Day -ge $oldest } | Sort-Object Account, Day)
    }
    return $changed
}

function Start-UsageCollector {
    $mutex = New-Object Threading.Mutex($false, 'Local\CLIProxyAPI_Helper_UsageCollector')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }
        $key = Get-ManagementKey
        $port = Get-ManagementPort
        $state = Read-UsageState
        if (-not $state.PSObject.Properties['LastPollAt']) { $state | Add-Member -NotePropertyName LastPollAt -NotePropertyValue '' }
        if (-not $state.PSObject.Properties['LastError']) { $state | Add-Member -NotePropertyName LastError -NotePropertyValue '' }
        $map = @{}
        $lastMapRefresh = [DateTime]::MinValue
        $failures = 0
        $dirty = $false
        while ($true) {
            try {
                if (((Get-Date) - $lastMapRefresh).TotalSeconds -ge 30) {
                    $map = Get-AuthIndexMap -Key $key -Port $port
                    $lastMapRefresh = Get-Date
                }
                $records = @(Invoke-Management -Path 'usage-queue?count=100' -Key $key -Port $port)
                if (Add-UsageRecords -State $state -Records $records -Map $map) { $dirty = $true }
                $state.LastPollAt = (Get-Date).ToString('o')
                $state.LastError = ''
                $dirty = $true
                if ($dirty) {
                    Save-JsonAtomically -Path $script:usagePath -Value $state
                    $dirty = $false
                }
                $failures = 0
                Start-Sleep -Seconds $(if ($records.Count -eq 100) { 1 } else { 4 })
            }
            catch {
                $failures++
                $state.LastError = '本机管理接口暂时无法读取。'
                try { Save-JsonAtomically -Path $script:usagePath -Value $state } catch { }
                if ($failures -ge 5) { break }
                Start-Sleep -Seconds 3
            }
        }
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Convert-QuotaPayload {
    param($Payload)
    if ($payload.response) { $payload = $payload.response }
    if ($payload.summary) { $payload = $payload.summary }
    $rows = @()
    foreach ($group in @($payload.groups)) {
        $groupName = [string]$(if ($group.displayName) { $group.displayName } else { $group.display_name })
        foreach ($bucket in @($group.buckets)) {
            $fraction = if ($null -ne $bucket.remainingFraction) { $bucket.remainingFraction } else { $bucket.remaining_fraction }
            if ($null -eq $fraction -and $bucket.remaining) { $fraction = $bucket.remaining.value }
            if ($null -eq $fraction) { continue }
            $number = 0.0
            if (-not [double]::TryParse([string]$fraction, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { continue }
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 1) { continue }
            $name = [string]$(if ($bucket.displayName) { $bucket.displayName } elseif ($bucket.display_name) { $bucket.display_name } else { $bucket.bucketId })
            $resetValue = if ($bucket.resetTime) { $bucket.resetTime } else { $bucket.reset_time }
            $reset = if ($resetValue -is [DateTime] -or $resetValue -is [DateTimeOffset]) { $resetValue.ToString('o') } else { [string]$resetValue }
            $resetAt = [DateTimeOffset]::MinValue
            $resetIso = ''
            if ([DateTimeOffset]::TryParse($reset, [ref]$resetAt)) {
                $resetIso = $resetAt.ToString('o')
                $reset = $resetAt.ToLocalTime().ToString('MM-dd HH:mm')
            }
            $rows += [pscustomobject]@{
                Group = $groupName
                Name = $(if ($groupName -and $name -and $groupName -ne $name) { $groupName + ' / ' + $name } elseif ($groupName) { $groupName } else { $name })
                Window = [string]$bucket.window
                RemainingFraction = $number
                RemainingPercent = [Math]::Round([Math]::Max(0, [Math]::Min(100, $number * 100)), 0)
                Reset = $(if ($reset) { $reset } else { '未提供' })
                ResetAt = $resetIso
            }
        }
    }
    if ($rows.Count -eq 0) { throw '上游没有返回可解析的额度数据。' }
    return $rows
}

function Convert-ArgonQuotaPayload {
    param($Payload)
    if ($Payload.response) { $Payload = $Payload.response }
    $models = @($Payload.models.PSObject.Properties | Where-Object { $_.Name -match '^gemini-4-argon(?:-|$)' } | Sort-Object Name)
    if ($models.Count -eq 0) { $models = @([pscustomobject]@{ Name = ''; Value = $null }) }
    foreach ($model in $models) {
        $info = $model.Value
        $state = if (-not $model.Name) { '未返回' } elseif ($info.disabled -eq $true) { '未开放' } else { '未知' }
        if ($info.disabled -ne $true -and $info.quotaInfo) {
            $bucket = [pscustomobject]@{
                displayName = $model.Name; window = 'model'
                remainingFraction = $info.quotaInfo.remainingFraction; resetTime = $info.quotaInfo.resetTime
            }
            try {
                Convert-QuotaPayload -Payload ([pscustomobject]@{ groups = @([pscustomobject]@{ displayName = 'Gemini 4 Argon'; buckets = @($bucket) }) })
                continue
            }
            catch { $state = '未知' }
        }
        [pscustomobject]@{
            Group = 'Gemini 4 Argon'; Name = 'Gemini 4 Argon / 额度状态'; Window = 'model'
            RemainingFraction = $null; RemainingPercent = $null; ResetAt = ''; StatusText = $state
            Reset = $(if ($state -eq '未开放') { '当前账号未开放；上游未提供额度' } else { '上游未提供额度' })
        }
    }
}

function Get-AntigravityQuotaUserAgent {
    param([string]$AuthIndex, [string]$Key, [int]$Port)
    # The unversioned UA omits Gemini quotas. Use the official Hub manifest through the configured proxy.
    $version = '2.25.0'
    try {
        $body = @{
            auth_index = $AuthIndex; method = 'GET'
            url = 'https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml'
            header = @{ 'User-Agent' = 'electron-builder' }
        } | ConvertTo-Json -Depth 5 -Compress
        $reply = Invoke-Management -Path 'api-call' -Key $Key -Port $Port -Body $body -TimeoutMs 15000
        $match = [regex]::Match([string]$reply.body, '(?m)^version:\s*["'']?(\d+\.\d+\.\d+)["'']?\s*$')
        if ([int]$reply.status_code -eq 200 -and $match.Success) { $version = $match.Groups[1].Value }
    }
    catch { } # Keep a verified version if the updater is temporarily unavailable.
    return 'antigravity/hub/' + $version + ' darwin/arm64'
}

function Get-QuotaResult {
    param([string]$FileName)
    if ($FileName -ne [IO.Path]::GetFileName($FileName) -or -not $FileName.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
        throw '账号文件名无效。'
    }
    $key = Get-ManagementKey
    $port = Get-ManagementPort
    $auths = Invoke-Management -Path 'auth-files' -Key $key -Port $port
    $selected = @($auths.files | Where-Object { $_.name -eq $FileName -and $_.provider -eq 'antigravity' -and $_.disabled -ne $true })
    if ($selected.Count -ne 1 -or -not $selected[0].auth_index) { throw '代理尚未加载这个可用账号。' }
    $authDir = Join-Path $env:USERPROFILE '.cli-proxy-api'
    $data = [IO.File]::ReadAllText((Join-Path $authDir $FileName)) | ConvertFrom-Json
    $projectId = [string]$data.project_id
    if (-not $projectId) { throw '账号缺少 project_id，请重新授权。' }
    $userAgent = Get-AntigravityQuotaUserAgent -AuthIndex $selected[0].auth_index -Key $key -Port $port
    $body = @{
        auth_index = [string]$selected[0].auth_index
        method = 'POST'
        url = 'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary'
        header = @{ Authorization = 'Bearer $TOKEN$'; 'Content-Type' = 'application/json'; 'User-Agent' = $userAgent }
        data = (@{ project = $projectId } | ConvertTo-Json -Compress)
    } | ConvertTo-Json -Depth 8 -Compress
    $reply = Invoke-Management -Path 'api-call' -Key $key -Port $port -Body $body -TimeoutMs 20000
    if ([int]$reply.status_code -lt 200 -or [int]$reply.status_code -ge 300) {
        $message = if ([string]$reply.body -match 'VALIDATION_REQUIRED|Verify your account') { 'Google 要求先验证此账号。' }
        elseif ([int]$reply.status_code -eq 401) { '上游授权已失效，请重新登录。' }
        else { '上游额度接口返回 HTTP ' + [int]$reply.status_code }
        throw $message
    }
    $payload = [string]$reply.body | ConvertFrom-Json
    $rows = @(Convert-QuotaPayload -Payload $payload)
    if (@($rows | Where-Object { $_.Group -match 'argon' }).Count -eq 0) {
        try {
            $catalogBody = $body | ConvertFrom-Json
            $catalogBody.url = 'https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels'
            $catalogReply = Invoke-Management -Path 'api-call' -Key $key -Port $port -Body ($catalogBody | ConvertTo-Json -Depth 8 -Compress) -TimeoutMs 20000
            if ([int]$catalogReply.status_code -lt 200 -or [int]$catalogReply.status_code -ge 300) { throw '模型额度查询失败。' }
            $rows += @(Convert-ArgonQuotaPayload -Payload ([string]$catalogReply.body | ConvertFrom-Json))
        }
        catch {
            $rows += [pscustomobject]@{
                Group = 'Gemini 4 Argon'; Name = 'Gemini 4 Argon / 额度状态'; Window = 'model'
                RemainingFraction = $null; RemainingPercent = $null; ResetAt = ''; StatusText = '查询失败'; Reset = '稍后重试查询额度'
            }
        }
    }
    return [pscustomobject]@{ Version = 1; Account = $FileName; Status = 'ok'; FetchedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Rows = $rows; Error = '' }
}

if ($Collect) { Start-UsageCollector }
elseif ($Quota) {
    try { $result = Get-QuotaResult -FileName $AuthFile }
    catch { $result = [pscustomobject]@{ Version = 1; Account = $AuthFile; Status = 'error'; FetchedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Rows = @(); Error = $_.Exception.Message } }
    $result | Add-Member -NotePropertyName RunId -NotePropertyValue $RunId
    Save-JsonAtomically -Path $script:quotaPath -Value $result
}
