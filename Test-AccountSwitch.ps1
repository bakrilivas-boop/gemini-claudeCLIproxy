$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'CLIProxyAPI-Helper.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | ForEach-Object Message | Out-String) }
$names = @('Get-AuthSnapshot', 'Set-AuthFileDisabled', 'Update-AccountSwitchControls', 'Switch-ToAccount', 'Switch-ToSelectedAccount', 'Pause-AllAccounts', 'Ensure-SingleAccount', 'Restore-AccountAfterFailedAuthorization', 'Start-LoginProcess', 'Complete-Workflow', 'Fail-Workflow', 'Get-ActiveQuotaAccount', 'Set-QuotaAutoSwitch', 'Start-QuotaRefresh', 'Update-QuotaAutomation', 'Invoke-QuotaAutoSwitch', 'Update-QuotaProcess')
foreach ($name in $names) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    Invoke-Expression $definition.Extent.Text
}

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Activity([string]$Message) { $script:testActivity += $Message }
function Set-ProgressState { }
function Set-WorkflowControls { }
function Save-LastAuthorizedAccount { }
function Set-PanelButtonStyle { }
function Update-MetricsDisplay { }
function Start-Process {
    $script:testStarts++
    $process = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
    $process | Add-Member ScriptMethod Dispose { }
    return $process
}
function Refresh-Dashboard {
    $script:authSnapshot = Ensure-SingleAccount -Snapshot (Get-AuthSnapshot)
    Update-AccountSwitchControls
}

$fixture = Join-Path $PSScriptRoot ('account-switch-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixture)
$first = Join-Path $fixture 'antigravity-first@example.com.json'
$second = Join-Path $fixture 'antigravity-second@example.com.json'
$incomplete = Join-Path $fixture 'antigravity-incomplete@example.com.json'
$quotaFixture = Join-Path $fixture 'quota-result.json'
try {
    $script:testActivity = @()
    $script:testStarts = 0
    $script:authDirectory = $fixture
    $script:workflowPhase = 'idle'
    $script:switchAccountButton = [pscustomobject]@{ Enabled = $false }
    $script:restoreAccountsButton = [pscustomobject]@{ Enabled = $false }
    $script:accountList = [pscustomobject]@{ SelectedItems = @([pscustomobject]@{ Tag = [System.IO.Path]::GetFileName($first) }) }
    $script:accountBeforeAuthorization = $null
    $script:currentAccountLabel = [pscustomobject]@{ Text = '' }
    $script:exePath = $sourcePath
    $script:configPath = $sourcePath
    $script:launcherPath = $sourcePath
    [System.IO.File]::WriteAllText($first, '{"type":"antigravity","access_token":"TEST_A","refresh_token":"REFRESH_A","project_id":"PROJECT_A","nested":{"count":3},"disabled":false}', [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($second, '{"type":"antigravity","access_token":"TEST_B","refresh_token":"REFRESH_B","project_id":"PROJECT_B","disabled":false}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($incomplete, '{"email":"incomplete@example.com","refresh_token":"REFRESH_C"}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::SetLastWriteTimeUtc($first, [DateTime]::UtcNow.AddMinutes(-3))
    [System.IO.File]::SetLastWriteTimeUtc($second, [DateTime]::UtcNow.AddMinutes(-2))
    [System.IO.File]::SetLastWriteTimeUtc($incomplete, [DateTime]::UtcNow.AddMinutes(-1))

    Refresh-Dashboard
    Assert (@($script:authSnapshot.Rows | Where-Object { $_.Name -eq [System.IO.Path]::GetFileName($first) })[0].DisplayName -eq 'first@example.com') 'Account email includes filename prefix'
    Assert (@($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false }).Count -eq 1) 'Auto-selection failed'
    Assert ((Get-Content -LiteralPath $second -Raw | ConvertFrom-Json).disabled -eq $false) 'Latest account not retained'
    Assert ((Get-Content -LiteralPath $incomplete -Raw | ConvertFrom-Json).disabled -eq $true) 'Incomplete account incorrectly retained'
    Assert (@($script:authSnapshot.Rows | Where-Object { $_.Name -eq [System.IO.Path]::GetFileName($incomplete) -and $_.Problem }).Count -eq 1) 'Incomplete account not flagged'

    $script:accountList.SelectedItems = @([pscustomobject]@{ Tag = [System.IO.Path]::GetFileName($incomplete) })
    Update-AccountSwitchControls
    Assert (-not $script:switchAccountButton.Enabled) 'Incomplete account can be selected for routing'
    $script:accountList.SelectedItems = @([pscustomobject]@{ Tag = [System.IO.Path]::GetFileName($first) })
    Update-AccountSwitchControls

    Switch-ToSelectedAccount
    Assert ((Get-Content -LiteralPath $first -Raw | ConvertFrom-Json).disabled -eq $false) 'Selected account not enabled'
    Assert ((Get-Content -LiteralPath $second -Raw | ConvertFrom-Json).disabled -eq $true) 'Other account not disabled'
    Assert ((Get-Content -LiteralPath $first -Raw | ConvertFrom-Json).access_token -eq 'TEST_A') 'Token changed'
    Assert ([System.IO.File]::ReadAllBytes($first)[0] -eq 0xEF) 'BOM lost'

    Pause-AllAccounts
    Assert (@((Get-AuthSnapshot).Rows | Where-Object { $_.Disabled -eq $false }).Count -eq 0) 'Pause failed'
    Switch-ToSelectedAccount
    Assert (@((Get-AuthSnapshot).Rows | Where-Object { $_.Disabled -eq $false }).Count -eq 1) 'Resume selected failed'

    $script:accountBeforeAuthorization = [System.IO.Path]::GetFileName($first)
    Set-AuthFileDisabled -FileName $script:accountBeforeAuthorization -Disabled $true
    Restore-AccountAfterFailedAuthorization
    Assert ((Get-Content -LiteralPath $first -Raw | ConvertFrom-Json).disabled -eq $false) 'Rollback failed'

    Start-LoginProcess
    Assert ((Get-Content -LiteralPath $first -Raw | ConvertFrom-Json).disabled -eq $true) 'Old account remained enabled during login'
    Set-AuthFileDisabled -FileName ([System.IO.Path]::GetFileName($second)) -Disabled $false
    $script:authChangedNames[[System.IO.Path]::GetFileName($second)] = $true
    Refresh-Dashboard
    Complete-Workflow -Message 'done' -WasSuccessful $true
    Assert ((Get-Content -LiteralPath $first -Raw | ConvertFrom-Json).disabled -eq $true) 'Old account enabled after login'
    Assert ((Get-Content -LiteralPath $second -Raw | ConvertFrom-Json).disabled -eq $false) 'New account not enabled after login'

    Start-LoginProcess
    Assert ((Get-Content -LiteralPath $second -Raw | ConvertFrom-Json).disabled -eq $true) 'Active account remained enabled during second login'
    Fail-Workflow 'cancelled'
    Assert ((Get-Content -LiteralPath $second -Raw | ConvertFrom-Json).disabled -eq $false) 'Original account not restored after failed login'

    # Use only fixture credentials. Check every write to ensure the old account is disabled first.
    $script:testSetDisabled = (Get-Item Function:Set-AuthFileDisabled).ScriptBlock
    function Set-AuthFileDisabled {
        param([string]$FileName, [bool]$Disabled)
        & $script:testSetDisabled -FileName $FileName -Disabled $Disabled
        Assert (@((Get-AuthSnapshot).Rows | Where-Object { $_.Disabled -eq $false }).Count -le 1) 'Multiple accounts enabled during a switch'
    }
    function New-TestQuota {
        param([string]$Account, [double]$Fraction = 0, [string]$Group = 'Claude and GPT models')
        return [pscustomobject]@{
            Account = $Account; Status = 'ok'; RunId = $script:quotaRunId
            Rows = @([pscustomobject]@{ Group = $Group; RemainingFraction = $Fraction; RemainingPercent = [Math]::Round($Fraction * 100); ResetAt = (Get-Date).AddHours(2).ToString('o') })
        }
    }
    Add-Type -AssemblyName System.Drawing
    $firstName = [IO.Path]::GetFileName($first)
    $secondName = [IO.Path]::GetFileName($second)
    $script:quotaAutoSwitchButton = [pscustomobject]@{ Text = ''; BackColor = $null; ForeColor = $null }
    $script:geminiAutoSwitchButton = [pscustomobject]@{ Text = ''; BackColor = $null; ForeColor = $null }
    $script:geminiAutoSwitchEnabled = $false
    $script:quotaRefreshButton = [pscustomobject]@{ Text = ''; Enabled = $true }
    $script:quotaStatusLabel = [pscustomobject]@{ Text = '' }
    $script:quotaScheduleLabel = [pscustomobject]@{ Text = '' }
    $buttonTips = [pscustomobject]@{}
    $buttonTips | Add-Member ScriptMethod SetToolTip { param($Control, $Text) }
    $script:quotaPath = $quotaFixture
    $script:metricsPath = $sourcePath
    $script:quotaProcess = $null
    $script:portReachable = $true
    $script:servicePortProcess = [pscustomobject]@{ Id = 1 }
    $script:workflowPhase = 'idle'
    $script:quotaRunId = 'fixture-run'
    Switch-ToAccount -FileName $firstName
    Set-QuotaAutoSwitch -Enabled $false
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName)
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'Disabled toggle switched accounts'
    Set-QuotaAutoSwitch -Enabled $true
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0 'Gemini Models')
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0.00001)
    $result = New-TestQuota $firstName
    $result.Status = 'error'
    Invoke-QuotaAutoSwitch -Result $result
    $result.Status = 'ok'; $result.RunId = 'old-run'
    Invoke-QuotaAutoSwitch -Result $result
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $secondName)
    $script:workflowPhase = 'waiting-auth'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName)
    $script:workflowPhase = 'idle'
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'False exhaustion or stale result switched accounts'

    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName)
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Exhaustion did not switch to the next valid account'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $secondName)
    $activityCount = $script:testActivity.Count
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $secondName)
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName -and $script:testActivity.Count -eq $activityCount) 'Exhausted accounts looped or logged repeatedly'
    Assert ($script:quotaAutomationNotice -match '无可切换账号') 'All-exhausted state is not visible'
    $script:quotaExhaustedUntil[$firstName] = (Get-Date).AddSeconds(-1)
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $secondName)
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'Reset account was not eligible again'
    [void]$script:quotaExhaustedUntil.Remove($secondName)
    [IO.File]::WriteAllText($incomplete, 'invalid json')
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName)
    Assert (-not $script:quotaAutoSwitchEnabled -and -not $script:geminiAutoSwitchEnabled -and (Get-ActiveQuotaAccount).Name -eq $firstName) 'Unsafe switch did not fail closed'
    [IO.File]::WriteAllText($incomplete, '{"disabled":true}')
    Refresh-Dashboard

    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0 'Gemini Models')
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'Disabled Gemini toggle switched accounts'
    Set-QuotaAutoSwitch -Family Gemini -Enabled $true
    Assert ($script:geminiAutoSwitchEnabled -and -not $script:quotaAutoSwitchEnabled) 'Gemini toggle changed Claude setting'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName)
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0.00001 'Gemini Models')
    $result = New-TestQuota $firstName 0 'Gemini Models'
    $result.Status = 'error'
    Invoke-QuotaAutoSwitch -Result $result
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'Gemini switched on Claude exhaustion, rounded zero or a query error'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0 'Gemini Models')
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Gemini exhaustion did not switch accounts'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $secondName 0 'Gemini Models')
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName -and $script:quotaAutomationNotice -match '^Gemini.*无可切换账号') 'Gemini all-exhausted state looped or used the wrong label'

    # With both toggles enabled, exhaustion in either family excludes the account.
    Switch-ToAccount -FileName $firstName
    Set-QuotaAutoSwitch -Enabled $true
    Assert ($script:geminiAutoSwitchEnabled) 'Claude toggle changed Gemini setting'
    $result = New-TestQuota $firstName
    $result.Rows += (New-TestQuota $firstName 0.8 'Gemini Models').Rows
    Invoke-QuotaAutoSwitch -Result $result
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Claude exhaustion was ignored with both toggles enabled'
    $result = New-TestQuota $secondName 0.8
    $result.Rows += (New-TestQuota $secondName 0 'Gemini Models').Rows
    Invoke-QuotaAutoSwitch -Result $result
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Mixed-family exhaustion caused accounts to loop'
    Set-QuotaAutoSwitch -Enabled $false
    Assert ($script:geminiAutoSwitchEnabled) 'Disabling Claude also disabled Gemini'
    Set-QuotaAutoSwitch -Family Gemini -Enabled $false
    Switch-ToAccount -FileName $firstName

    Set-QuotaAutoSwitch -Family Gemini -Enabled $true
    $result = New-TestQuota $firstName 0 'Gemini 4 Argon'
    $result.Rows[0].RemainingFraction = $null
    Invoke-QuotaAutoSwitch -Result $result
    Assert ((Get-ActiveQuotaAccount).Name -eq $firstName) 'Unavailable Argon triggered an account switch'
    Invoke-QuotaAutoSwitch -Result (New-TestQuota $firstName 0 'Gemini 4 Argon')
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Argon exhaustion was ignored by the Gemini toggle'
    Set-QuotaAutoSwitch -Family Gemini -Enabled $false
    Switch-ToAccount -FileName $firstName

    # Exercise the real timer/worker lifecycle with a mocked subprocess and local result file.
    Set-QuotaAutoSwitch -Enabled $false
    $script:testStarts = 0
    $script:nextQuotaRefreshAt = (Get-Date).AddSeconds(-1)
    Update-QuotaAutomation
    $refreshDelay = ($script:nextQuotaRefreshAt - (Get-Date)).TotalSeconds
    Assert ($script:testStarts -eq 1 -and $refreshDelay -gt 598 -and $refreshDelay -le 600) 'Automatic refresh is not scheduled at 10 minutes'
    Start-QuotaRefresh -Manual
    Assert ($script:testStarts -eq 1) 'Overlapping quota queries were launched'
    $script:quotaProcess.HasExited = $true
    Update-QuotaAutomation
    Assert ($script:testStarts -eq 1) 'Exited worker was replaced before its result was processed'
    $result = New-TestQuota $firstName 0.7
    [IO.File]::WriteAllText($quotaFixture, ($result | ConvertTo-Json -Depth 8))
    Update-QuotaProcess
    Update-QuotaAutomation
    Assert ($null -eq $script:quotaProcess -and $script:testStarts -eq 1) 'Completed query did not wait for the next interval'
    $script:nextQuotaRefreshAt = (Get-Date).AddSeconds(-1)
    Update-QuotaAutomation
    Assert ($script:testStarts -eq 2) 'Next refresh interval did not launch another query'

    $oldResult = New-TestQuota $firstName
    Switch-ToAccount -FileName $secondName
    Set-QuotaAutoSwitch -Enabled $true
    $script:quotaProcess.HasExited = $true
    [IO.File]::WriteAllText($quotaFixture, ($oldResult | ConvertTo-Json -Depth 8))
    Update-QuotaProcess
    Assert ((Get-ActiveQuotaAccount).Name -eq $secondName) 'Previous account result switched the newly selected account'
    $script:workflowPhase = 'waiting-auth'
    Start-QuotaRefresh
    Assert ($script:testStarts -eq 2) 'Quota refreshed during authorization'
    $script:workflowPhase = 'idle'; $script:portReachable = $false
    Start-QuotaRefresh
    Assert ($script:testStarts -eq 2) 'Quota refreshed while service was stopped'
    $script:portReachable = $true
    Pause-AllAccounts
    Update-QuotaAutomation
    Assert ($script:testStarts -eq 2 -and -not (Get-ActiveQuotaAccount)) 'Paused accounts were activated by automation'
    Assert (@(Get-ChildItem -LiteralPath $fixture -File -Filter '*.tmp').Count -eq 0) 'Temporary file left behind'
    'ACCOUNT_SWITCH_TEST_OK'
}
finally {
    if ([System.IO.File]::Exists($quotaFixture)) { Remove-Item -LiteralPath $quotaFixture }
    if ([System.IO.File]::Exists($first)) { Remove-Item -LiteralPath $first }
    if ([System.IO.File]::Exists($second)) { Remove-Item -LiteralPath $second }
    if ([System.IO.File]::Exists($incomplete)) { Remove-Item -LiteralPath $incomplete }
    if ([System.IO.Directory]::Exists($fixture)) { Remove-Item -LiteralPath $fixture }
}
