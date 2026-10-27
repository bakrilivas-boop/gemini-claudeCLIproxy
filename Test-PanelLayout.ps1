$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CLIProxyAPI-Helper.ps1'))
$source = [regex]::Replace($source, '\[void\]\$form\.ShowDialog\(\)\s*$', '')
$source = $source.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'"))
Invoke-Expression $source
function Update-QuotaAutomation { }
try {
    $form.Opacity = 0
    $form.Show()
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.Application]::DoEvents()
    $rightmost = @($script:updateCard.Panel.Right, $script:stopButton.Right, $metricsPanel.Right) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($form.Height -gt [System.Windows.Forms.Screen]::FromControl($form).WorkingArea.Height) { throw 'Initial panel height exceeds the screen.' }
    if ($rightmost -gt $form.ClientSize.Width) { throw "Panel is wider than the window: right=$rightmost client=$($form.ClientSize.Width) dpi=$dpiScale" }
    if ($metricsPanel.Top -le $accountSummary.Bottom) { throw 'Metrics panel overlaps account summary.' }
    if ($activityTitle.Top -le $metricsPanel.Bottom) { throw 'Activity section overlaps metrics panel.' }
    if ($script:quotaCards.Bottom -gt $metricsPanel.ClientSize.Height) { throw 'Quota cards are outside metrics panel.' }
    if ($script:quotaAutoSwitchButton.Bottom -ge $script:metricsAccountLabel.Top -or $script:quotaScheduleLabel.Right -gt $metricsPanel.ClientSize.Width) { throw 'Quota automation controls overlap content.' }
    if ($script:geminiAutoSwitchButton.Left -lt $script:quotaAutoSwitchButton.Right -or $script:geminiAutoSwitchButton.Bottom -ge $script:quotaScheduleLabel.Top) { throw 'Gemini toggle overlaps quota controls.' }
    if ($script:quotaAutoSwitchEnabled -or $script:geminiAutoSwitchEnabled) { throw 'Automatic account switching must default to off.' }
    $script:quotaAutoSwitchButton.PerformClick()
    if (-not $script:quotaAutoSwitchEnabled -or $script:quotaAutoSwitchButton.Text -notmatch '：开$') { throw 'Auto-switch button did not enable.' }
    $script:geminiAutoSwitchButton.PerformClick()
    if (-not $script:geminiAutoSwitchEnabled -or -not $script:quotaAutoSwitchEnabled -or $script:geminiAutoSwitchButton.Text -notmatch '：开$') { throw 'Gemini auto-switch button did not enable independently.' }
    $script:quotaAutoSwitchButton.PerformClick()
    if ($script:quotaAutoSwitchEnabled -or -not $script:geminiAutoSwitchEnabled -or $script:quotaAutoSwitchButton.Text -notmatch '：关$') { throw 'Claude auto-switch button did not disable independently.' }
    $script:geminiAutoSwitchButton.PerformClick()
    if ($script:geminiAutoSwitchEnabled -or $script:geminiAutoSwitchButton.Text -notmatch '：关$') { throw 'Gemini auto-switch button did not disable.' }
    $sampleRows = @(
        [pscustomobject]@{ Name = 'Claude / Five Hour'; Window = '5h'; RemainingPercent = 75; Reset = '23:00' },
        [pscustomobject]@{ Name = 'Claude / Weekly'; Window = 'weekly'; RemainingPercent = 90; Reset = '10-04 17:00' },
        [pscustomobject]@{ Name = 'Gemini / Five Hour'; Window = '5h'; RemainingPercent = 100; Reset = '23:00' },
        [pscustomobject]@{ Name = 'Gemini / Weekly'; Window = 'weekly'; RemainingPercent = 98; Reset = '10-04 12:00' },
        [pscustomobject]@{ Name = 'Gemini 4 Argon / 额度状态'; Window = 'model'; RemainingPercent = $null; StatusText = '未开放'; Reset = '当前账号未开放；上游未提供额度' }
    )
    Render-QuotaCards -Rows $sampleRows
    $cards = @($script:quotaCards.Controls | Where-Object { $_.Tag -and $_.Tag.Rows })
    if ($cards.Count -ne 3 -or $cards[0].Tag.Rows[0].Fill.Width -le 0) { throw 'Quota cards did not render.' }
    if ($cards[2].Tag.Rows[0].Percent.Text -ne '未开放' -or $cards[2].Tag.Rows[0].Track.Visible) { throw 'Unavailable Argon quota was displayed as a percentage.' }
    if ($cards[2].Bottom -gt $script:quotaCards.ClientSize.Height) { throw 'Argon quota card is clipped.' }
    $script:accountToggleButton.PerformClick()
    if (-not $script:accountList.Visible -or -not $script:switchAccountButton.Visible -or $metricsPanel.Top -le $script:accountList.Bottom) { throw 'Account list did not expand cleanly.' }
    $script:accountToggleButton.PerformClick()
    if ($script:accountList.Visible -or $script:switchAccountButton.Visible -or $metricsPanel.Top -le $accountSummary.Bottom) { throw 'Account list did not collapse cleanly.' }
    $script:moreButton.PerformClick()
    if (-not $script:showMore -or -not $script:startButton.Visible) { throw 'More functions did not expand.' }
    $script:moreButton.PerformClick()
    if ($script:showMore -or $script:startButton.Visible) { throw 'More functions did not collapse.' }
    $script:logsToggleButton.PerformClick()
    if (-not $script:showLogs -or -not $script:activityList.Visible) { throw 'Logs did not expand.' }
    $script:logsToggleButton.PerformClick()
    if ($script:showLogs -or $script:activityList.Visible) { throw 'Logs did not collapse.' }
    $form.ClientSize = New-Object System.Drawing.Size(540, 700)
    $script:layout.Reflow()
    $script:accountToggleButton.PerformClick()
    if ($metricsPanel.Top -le $script:accountList.Bottom) { throw 'Compact account list overlaps metrics panel.' }
    if ($script:quotaCards.Bottom -gt $metricsPanel.ClientSize.Height) { throw 'Compact quota cards are outside metrics panel.' }
    if ($script:quotaAutoSwitchButton.Bottom -ge $script:geminiAutoSwitchButton.Top -or $script:geminiAutoSwitchButton.Bottom -ge $script:quotaScheduleLabel.Top -or $script:quotaScheduleLabel.Bottom -ge $script:metricsAccountLabel.Top) { throw 'Compact quota automation controls overlap.' }
    if ($cards[1].Top -le $cards[0].Top) { throw 'Compact quota cards did not stack.' }
    'PANEL_LAYOUT_TEST_OK'
}
finally { $form.Dispose() }
