$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CliProxyDpi {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
'@
if (-not [CliProxyDpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) {
    [void][CliProxyDpi]::SetProcessDPIAware()
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:cliFolder = Join-Path $env:USERPROFILE 'Downloads\CLIProxyAPI_7.3.17_windows_amd64'
$script:exePath = Join-Path $script:cliFolder 'cli-proxy-api.exe'
$script:configPath = Join-Path $script:cliFolder 'config.yaml'
$script:launcherPath = Join-Path $PSScriptRoot '启动CLIProxyAPI助手.cmd'
$script:statePath = Join-Path $PSScriptRoot '面板状态.json'
$script:metricsPath = Join-Path $PSScriptRoot 'CLIProxyAPI-Metrics.ps1'
$script:usagePath = Join-Path $PSScriptRoot '面板用量.json'
$script:quotaPath = Join-Path $PSScriptRoot '面板额度.json'
$script:managementKeyPath = Join-Path $PSScriptRoot '管理密钥.dat'
$script:configuredPort = 0
$script:authDirectory = $null
$script:servicePortProcess = $null
$script:portReachable = $false
$script:authSnapshot = $null
$script:lastListSignature = $null
$script:authBaselineSignature = $null
$script:authBaselineMap = @{}
$script:authChangedNames = @{}
$script:authWatchEnabled = $false
$script:authChangedSinceStart = $false
$script:workflowPhase = 'idle'
$script:phaseStartedAt = [DateTime]::MinValue
$script:workflowStartedAt = [DateTime]::MinValue
$script:loginProcess = $null
$script:openAuthorizationAfterService = $true
$script:waitNoticeLogged = $false
$script:lastAuthorizedRecord = $null
$script:lastObservedServicePid = $null
$script:accountBeforeAuthorization = $null
$script:lastCollectorCheck = [DateTime]::MinValue
$script:quotaProcess = $null
$script:quotaRunId = ''
$script:lastQuotaSignature = ''
$script:nextQuotaRefreshAt = [DateTime]::MinValue
$script:quotaObservedAccount = ''
$script:quotaAutoSwitchEnabled = $false
$script:geminiAutoSwitchEnabled = $false
$script:quotaExhaustedUntil = @{}
$script:quotaAutomationNotice = ''
$script:showMore = $false
$script:showLogs = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'CLIProxyAPI 运行面板'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.ClientSize = New-Object System.Drawing.Size(860, 850)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.AutoScroll = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'CLIProxyAPI'
$title.Location = New-Object System.Drawing.Point(28, 20)
$title.Size = New-Object System.Drawing.Size(800, 38)
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(34, 46, 62)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '本机代理  ·  单账号模式  ·  授权与用量'
$subtitle.Location = New-Object System.Drawing.Point(30, 61)
$subtitle.Size = New-Object System.Drawing.Size(800, 24)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(91, 103, 119)
$form.Controls.Add($subtitle)

function New-StatusCard {
    param([string]$Heading, [int]$X)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, 98)
    $panel.Size = New-Object System.Drawing.Size(192, 104)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.Add_Paint({
        param($sender, $eventArgs)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(225, 231, 239))
        try { $eventArgs.Graphics.DrawRectangle($pen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1) }
        finally { $pen.Dispose() }
    })

    $headingLabel = New-Object System.Windows.Forms.Label
    $headingLabel.Text = $Heading
    $headingLabel.Location = New-Object System.Drawing.Point(12, 10)
    $headingLabel.Size = New-Object System.Drawing.Size(166, 22)
    $headingLabel.ForeColor = [System.Drawing.Color]::FromArgb(103, 115, 130)
    $panel.Controls.Add($headingLabel)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = '检查中…'
    $valueLabel.Location = New-Object System.Drawing.Point(12, 34)
    $valueLabel.Size = New-Object System.Drawing.Size(166, 30)
    $valueLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(42, 61, 83)
    $panel.Controls.Add($valueLabel)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Text = ''
    $detailLabel.Location = New-Object System.Drawing.Point(12, 70)
    $detailLabel.Size = New-Object System.Drawing.Size(166, 24)
    $detailLabel.ForeColor = [System.Drawing.Color]::FromArgb(113, 125, 140)
    $detailLabel.AutoEllipsis = $true
    $panel.Controls.Add($detailLabel)

    $form.Controls.Add($panel)
    return @{ Panel = $panel; Value = $valueLabel; Detail = $detailLabel }
}

$script:serviceCard = New-StatusCard '代理服务' 28
$script:apiCard = New-StatusCard '本机接口' 232
$script:authCard = New-StatusCard '授权记录' 436
$script:updateCard = New-StatusCard '最近文件更新' 640

$progressTitle = New-Object System.Windows.Forms.Label
$progressTitle.Text = '运行状态'
$progressTitle.Location = New-Object System.Drawing.Point(28, 215)
$progressTitle.Size = New-Object System.Drawing.Size(380, 26)
$progressTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$progressTitle.ForeColor = [System.Drawing.Color]::FromArgb(42, 57, 76)
$form.Controls.Add($progressTitle)

$script:selfCheckButton = New-Object System.Windows.Forms.Button
$script:selfCheckButton.Text = '一键自检'
$script:selfCheckButton.Location = New-Object System.Drawing.Point(435, 212)
$script:selfCheckButton.Size = New-Object System.Drawing.Size(140, 29)
$script:selfCheckButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:selfCheckButton)

$script:progressValueLabel = New-Object System.Windows.Forms.Label
$script:progressValueLabel.Text = '0%'
$script:progressValueLabel.Location = New-Object System.Drawing.Point(780, 219)
$script:progressValueLabel.Size = New-Object System.Drawing.Size(50, 22)
$script:progressValueLabel.TextAlign = 'MiddleRight'
$script:progressValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(91, 103, 119)
$form.Controls.Add($script:progressValueLabel)

$script:phaseLabel = New-Object System.Windows.Forms.Label
$script:phaseLabel.Text = '尚未开始'
$script:phaseLabel.Location = New-Object System.Drawing.Point(600, 219)
$script:phaseLabel.Size = New-Object System.Drawing.Size(170, 22)
$script:phaseLabel.TextAlign = 'MiddleRight'
$script:phaseLabel.ForeColor = [System.Drawing.Color]::FromArgb(91, 103, 119)
$form.Controls.Add($script:phaseLabel)

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point(28, 246)
$script:progressBar.Size = New-Object System.Drawing.Size(804, 8)
$script:progressBar.Minimum = 0
$script:progressBar.Maximum = 100
$script:progressBar.Style = 'Blocks'
$script:progressBar.MarqueeAnimationSpeed = 28
$form.Controls.Add($script:progressBar)

$script:progressStatus = New-Object System.Windows.Forms.Label
$script:progressStatus.Text = '就绪。点击“启动服务”开始，授权可按需打开。'
$script:progressStatus.Location = New-Object System.Drawing.Point(30, 272)
$script:progressStatus.Size = New-Object System.Drawing.Size(800, 24)
$script:progressStatus.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
$script:progressStatus.AutoEllipsis = $true
$form.Controls.Add($script:progressStatus)

$script:startButton = New-Object System.Windows.Forms.Button
$script:startButton.Text = '启动并打开授权'
$script:startButton.Location = New-Object System.Drawing.Point(28, 306)
$script:startButton.Size = New-Object System.Drawing.Size(198, 40)
$script:startButton.FlatStyle = 'Flat'
$script:startButton.FlatAppearance.BorderSize = 0
$script:startButton.BackColor = [System.Drawing.Color]::FromArgb(40, 105, 210)
$script:startButton.ForeColor = [System.Drawing.Color]::White
$script:startButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:startButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:startButton)

$script:serviceOnlyButton = New-Object System.Windows.Forms.Button
$script:serviceOnlyButton.Text = '启动服务'
$script:serviceOnlyButton.Location = New-Object System.Drawing.Point(238, 306)
$script:serviceOnlyButton.Size = New-Object System.Drawing.Size(140, 40)
$script:serviceOnlyButton.FlatStyle = 'Flat'
$script:serviceOnlyButton.FlatAppearance.BorderSize = 0
$script:serviceOnlyButton.BackColor = [System.Drawing.Color]::FromArgb(40, 105, 210)
$script:serviceOnlyButton.ForeColor = [System.Drawing.Color]::White
$script:serviceOnlyButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:serviceOnlyButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:serviceOnlyButton)

$script:loginButton = New-Object System.Windows.Forms.Button
$script:loginButton.Text = '打开授权'
$script:loginButton.Location = New-Object System.Drawing.Point(390, 306)
$script:loginButton.Size = New-Object System.Drawing.Size(140, 40)
$script:loginButton.Enabled = $false
$script:loginButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:loginButton)

$script:refreshButton = New-Object System.Windows.Forms.Button
$script:refreshButton.Text = '刷新状态'
$script:refreshButton.Location = New-Object System.Drawing.Point(694, 306)
$script:refreshButton.Size = New-Object System.Drawing.Size(138, 40)
$script:refreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:refreshButton)

$script:openFolderButton = New-Object System.Windows.Forms.Button
$script:openFolderButton.Text = '打开授权目录'
$script:openFolderButton.Location = New-Object System.Drawing.Point(164, 354)
$script:openFolderButton.Size = New-Object System.Drawing.Size(124, 40)
$script:openFolderButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:openFolderButton)

$script:copyButton = New-Object System.Windows.Forms.Button
$script:copyButton.Text = '复制状态摘要'
$script:copyButton.Location = New-Object System.Drawing.Point(708, 354)
$script:copyButton.Size = New-Object System.Drawing.Size(124, 40)
$script:copyButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:copyButton)

$script:stopButton = New-Object System.Windows.Forms.Button
$script:stopButton.Text = '停止服务'
$script:stopButton.Location = New-Object System.Drawing.Point(542, 306)
$script:stopButton.Size = New-Object System.Drawing.Size(140, 40)
$script:stopButton.Enabled = $false
$script:stopButton.ForeColor = [System.Drawing.Color]::FromArgb(170, 50, 50)
$script:stopButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:stopButton)

$script:moreButton = New-Object System.Windows.Forms.Button
$script:moreButton.Text = '更多功能  ▾'
$script:moreButton.Location = New-Object System.Drawing.Point(694, 306)
$script:moreButton.Size = New-Object System.Drawing.Size(138, 40)
$script:moreButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:moreButton)

$script:copyAddressButton = New-Object System.Windows.Forms.Button
$script:copyAddressButton.Text = '复制接口地址'
$script:copyAddressButton.Location = New-Object System.Drawing.Point(28, 354)
$script:copyAddressButton.Size = New-Object System.Drawing.Size(124, 40)
$script:copyAddressButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:copyAddressButton)

$script:openConfigButton = New-Object System.Windows.Forms.Button
$script:openConfigButton.Text = '查看配置文件'
$script:openConfigButton.Location = New-Object System.Drawing.Point(300, 354)
$script:openConfigButton.Size = New-Object System.Drawing.Size(124, 40)
$script:openConfigButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:openConfigButton)

$script:openProgramButton = New-Object System.Windows.Forms.Button
$script:openProgramButton.Text = '打开程序目录'
$script:openProgramButton.Location = New-Object System.Drawing.Point(436, 354)
$script:openProgramButton.Size = New-Object System.Drawing.Size(124, 40)
$script:openProgramButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:openProgramButton)

$script:copyAccountButton = New-Object System.Windows.Forms.Button
$script:copyAccountButton.Text = '复制选中账号'
$script:copyAccountButton.Location = New-Object System.Drawing.Point(572, 354)
$script:copyAccountButton.Size = New-Object System.Drawing.Size(124, 40)
$script:copyAccountButton.Enabled = $false
$script:copyAccountButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:copyAccountButton)

$script:uptimeLabel = New-Object System.Windows.Forms.Label
$script:uptimeLabel.Text = '服务运行时长：未运行'
$script:uptimeLabel.Location = New-Object System.Drawing.Point(28, 399)
$script:uptimeLabel.Size = New-Object System.Drawing.Size(804, 20)
$script:uptimeLabel.TextAlign = 'MiddleRight'
$script:uptimeLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
$form.Controls.Add($script:uptimeLabel)

$accountsTitle = New-Object System.Windows.Forms.Label
$accountsTitle.Text = '当前账号'
$accountsTitle.Location = New-Object System.Drawing.Point(28, 423)
$accountsTitle.Size = New-Object System.Drawing.Size(145, 25)
$accountsTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$accountsTitle.ForeColor = [System.Drawing.Color]::FromArgb(42, 57, 76)
$form.Controls.Add($accountsTitle)

$script:accountToggleButton = New-Object System.Windows.Forms.Button
$script:accountToggleButton.Text = '切换账号  ▾'
$script:accountToggleButton.Location = New-Object System.Drawing.Point(185, 420)
$script:accountToggleButton.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($script:accountToggleButton)

$script:switchAccountButton = New-Object System.Windows.Forms.Button
$script:switchAccountButton.Text = '只用选中账号'
$script:switchAccountButton.Location = New-Object System.Drawing.Point(317, 420)
$script:switchAccountButton.Size = New-Object System.Drawing.Size(150, 30)
$script:switchAccountButton.Enabled = $false
$script:switchAccountButton.Visible = $false
$form.Controls.Add($script:switchAccountButton)

$script:restoreAccountsButton = New-Object System.Windows.Forms.Button
$script:restoreAccountsButton.Text = '暂停全部账号'
$script:restoreAccountsButton.Location = New-Object System.Drawing.Point(345, 420)
$script:restoreAccountsButton.Size = New-Object System.Drawing.Size(125, 30)
$script:restoreAccountsButton.Enabled = $false
$form.Controls.Add($script:restoreAccountsButton)

$script:locateAccountButton = New-Object System.Windows.Forms.Button
$script:locateAccountButton.Text = '定位选中账号文件'
$script:locateAccountButton.Location = New-Object System.Drawing.Point(480, 420)
$script:locateAccountButton.Size = New-Object System.Drawing.Size(160, 30)
$script:locateAccountButton.Enabled = $false
$script:locateAccountButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:locateAccountButton)

$script:currentAccountLabel = New-Object System.Windows.Forms.Label
$script:currentAccountLabel.Text = ''
$script:currentAccountLabel.Location = New-Object System.Drawing.Point(650, 424)
$script:currentAccountLabel.Size = New-Object System.Drawing.Size(182, 24)
$script:currentAccountLabel.TextAlign = 'MiddleRight'
$script:currentAccountLabel.AutoEllipsis = $true
$script:currentAccountLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
$form.Controls.Add($script:currentAccountLabel)

$script:lastAuthorizedLabel = New-Object System.Windows.Forms.Label
$script:lastAuthorizedLabel.Text = '最近完成授权：暂无面板确认的记录'
$script:lastAuthorizedLabel.Location = New-Object System.Drawing.Point(13, 31)
$script:lastAuthorizedLabel.Size = New-Object System.Drawing.Size(775, 21)
$script:lastAuthorizedLabel.AutoEllipsis = $true
$script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 105, 75)

$accountSummary = New-Object System.Windows.Forms.Panel
$accountSummary.Location = New-Object System.Drawing.Point(28, 449)
$accountSummary.Size = New-Object System.Drawing.Size(804, 82)
$accountSummary.BackColor = [System.Drawing.Color]::FromArgb(239, 243, 248)
$script:runningAccountLabel = New-Object System.Windows.Forms.Label
$script:runningAccountLabel.Text = '当前运行账号：检查中…'
$script:runningAccountLabel.Location = New-Object System.Drawing.Point(13, 7)
$script:runningAccountLabel.Size = New-Object System.Drawing.Size(775, 24)
$script:runningAccountLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:runningAccountLabel.ForeColor = [System.Drawing.Color]::FromArgb(42, 61, 83)
$script:runningAccountLabel.AutoEllipsis = $true
$accountSummary.Controls.Add($script:runningAccountLabel)
$accountSummary.Controls.Add($script:lastAuthorizedLabel)

$accountEvidence = New-Object System.Windows.Forms.Label
$accountEvidence.Text = '账号状态来自本地文件；切换后代理会热加载，面板不验证上游有效性。'
$accountEvidence.Location = New-Object System.Drawing.Point(13, 55)
$accountEvidence.Size = New-Object System.Drawing.Size(775, 20)
$accountEvidence.ForeColor = [System.Drawing.Color]::FromArgb(86, 105, 97)
$accountEvidence.AutoEllipsis = $true
$accountSummary.Controls.Add($accountEvidence)
$form.Controls.Add($accountSummary)

$script:accountList = New-Object System.Windows.Forms.ListView
$script:accountList.Location = New-Object System.Drawing.Point(28, 539)
$script:accountList.Size = New-Object System.Drawing.Size(804, 108)
$script:accountList.View = 'Details'
$script:accountList.FullRowSelect = $true
$script:accountList.GridLines = $false
$script:accountList.HideSelection = $false
$script:accountList.ShowItemToolTips = $true
$script:accountList.Visible = $false
[void]$script:accountList.Columns.Add('账号（来自本地文件名）', 400)
[void]$script:accountList.Columns.Add('本地状态', 150)
[void]$script:accountList.Columns.Add('文件更新时间', 230)
$form.Controls.Add($script:accountList)

$metricsPanel = New-Object System.Windows.Forms.Panel
$metricsPanel.Location = New-Object System.Drawing.Point(28, 658)
$metricsPanel.Size = New-Object System.Drawing.Size(804, 340)
$metricsPanel.BackColor = [System.Drawing.Color]::White
$metricsPanel.Add_Paint({
    param($sender, $eventArgs)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(225, 231, 239))
    try { $eventArgs.Graphics.DrawRectangle($pen, 0, 0, $sender.ClientSize.Width - 1, $sender.ClientSize.Height - 1) }
    finally { $pen.Dispose() }
})
$form.Controls.Add($metricsPanel)

$metricsTitle = New-Object System.Windows.Forms.Label
$metricsTitle.Text = '当前账号 · 额度与用量'
$metricsTitle.Location = New-Object System.Drawing.Point(12, 10)
$metricsTitle.Size = New-Object System.Drawing.Size(400, 26)
$metricsTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$metricsTitle.ForeColor = [System.Drawing.Color]::FromArgb(42, 57, 76)
$metricsPanel.Controls.Add($metricsTitle)

$script:quotaRefreshButton = New-Object System.Windows.Forms.Button
$script:quotaRefreshButton.Text = '查询额度'
$script:quotaRefreshButton.Location = New-Object System.Drawing.Point(650, 7)
$script:quotaRefreshButton.Size = New-Object System.Drawing.Size(140, 30)
$script:quotaRefreshButton.Enabled = $false
$script:quotaRefreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$metricsPanel.Controls.Add($script:quotaRefreshButton)

$script:quotaAutoSwitchButton = New-Object System.Windows.Forms.Button
$script:quotaAutoSwitchButton.Text = 'Claude 耗尽自动切号：关'
$script:quotaAutoSwitchButton.Size = New-Object System.Drawing.Size(220, 30)
$metricsPanel.Controls.Add($script:quotaAutoSwitchButton)

$script:geminiAutoSwitchButton = New-Object System.Windows.Forms.Button
$script:geminiAutoSwitchButton.Text = 'Gemini 耗尽自动切号：关'
$script:geminiAutoSwitchButton.Size = New-Object System.Drawing.Size(220, 30)
$metricsPanel.Controls.Add($script:geminiAutoSwitchButton)

$script:quotaScheduleLabel = New-Object System.Windows.Forms.Label
$script:quotaScheduleLabel.Text = '额度每 10 分钟自动刷新'
$script:quotaScheduleLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
$script:quotaScheduleLabel.AutoEllipsis = $true
$metricsPanel.Controls.Add($script:quotaScheduleLabel)

$script:metricsAccountLabel = New-Object System.Windows.Forms.Label
$script:metricsAccountLabel.Text = '账号：等待检查'
$script:metricsAccountLabel.Location = New-Object System.Drawing.Point(12, 42)
$script:metricsAccountLabel.Size = New-Object System.Drawing.Size(775, 20)
$script:metricsAccountLabel.AutoEllipsis = $true
$metricsPanel.Controls.Add($script:metricsAccountLabel)

$script:usageSummaryLabel = New-Object System.Windows.Forms.Label
$script:usageSummaryLabel.Text = '今日请求：—   成功率：—   平均延迟：—'
$script:usageSummaryLabel.Location = New-Object System.Drawing.Point(12, 65)
$script:usageSummaryLabel.Size = New-Object System.Drawing.Size(775, 23)
$script:usageSummaryLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:usageSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 105, 75)
$metricsPanel.Controls.Add($script:usageSummaryLabel)

$script:tokenSummaryLabel = New-Object System.Windows.Forms.Label
$script:tokenSummaryLabel.Text = '今日 Token：—   输入：—   输出：—   缓存：—   推理：—'
$script:tokenSummaryLabel.Location = New-Object System.Drawing.Point(12, 92)
$script:tokenSummaryLabel.Size = New-Object System.Drawing.Size(775, 23)
$script:tokenSummaryLabel.AutoEllipsis = $true
$metricsPanel.Controls.Add($script:tokenSummaryLabel)

$script:quotaStatusLabel = New-Object System.Windows.Forms.Label
$script:quotaStatusLabel.Text = '额度：服务就绪后，每 10 分钟自动查询。'
$script:quotaStatusLabel.Location = New-Object System.Drawing.Point(12, 119)
$script:quotaStatusLabel.Size = New-Object System.Drawing.Size(775, 20)
$script:quotaStatusLabel.AutoEllipsis = $true
$metricsPanel.Controls.Add($script:quotaStatusLabel)

$script:quotaCards = New-Object System.Windows.Forms.Panel
$script:quotaCards.Location = New-Object System.Drawing.Point(12, 145)
$script:quotaCards.Size = New-Object System.Drawing.Size(778, 180)
$script:quotaCards.AutoScroll = $true
$script:quotaCards.BackColor = [System.Drawing.Color]::White
$metricsPanel.Controls.Add($script:quotaCards)

$activityTitle = New-Object System.Windows.Forms.Label
$activityTitle.Text = '运行记录'
$activityTitle.Location = New-Object System.Drawing.Point(28, 658)
$activityTitle.Size = New-Object System.Drawing.Size(350, 24)
$activityTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$activityTitle.ForeColor = [System.Drawing.Color]::FromArgb(42, 57, 76)
$form.Controls.Add($activityTitle)

$script:copyActivityButton = New-Object System.Windows.Forms.Button
$script:copyActivityButton.Text = '复制运行记录'
$script:copyActivityButton.Location = New-Object System.Drawing.Point(552, 654)
$script:copyActivityButton.Size = New-Object System.Drawing.Size(136, 29)
$script:copyActivityButton.Enabled = $false
$script:copyActivityButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:copyActivityButton)

$script:clearActivityButton = New-Object System.Windows.Forms.Button
$script:clearActivityButton.Text = '清空面板记录'
$script:clearActivityButton.Location = New-Object System.Drawing.Point(696, 654)
$script:clearActivityButton.Size = New-Object System.Drawing.Size(136, 29)
$script:clearActivityButton.Enabled = $false
$script:clearActivityButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:clearActivityButton)

$script:logsToggleButton = New-Object System.Windows.Forms.Button
$script:logsToggleButton.Text = '查看运行日志  ▾'
$script:logsToggleButton.Location = New-Object System.Drawing.Point(696, 654)
$script:logsToggleButton.Size = New-Object System.Drawing.Size(136, 29)
$script:logsToggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($script:logsToggleButton)

$script:activityList = New-Object System.Windows.Forms.ListBox
$script:activityList.Location = New-Object System.Drawing.Point(28, 688)
$script:activityList.Size = New-Object System.Drawing.Size(804, 86)
$script:activityList.HorizontalScrollbar = $true
$script:activityList.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($script:activityList)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = '选中账号可复制名称；账号列表仅依据本地文件，不代表该账号被某次请求使用。'
$footer.Location = New-Object System.Drawing.Point(30, 784)
$footer.Size = New-Object System.Drawing.Size(800, 20)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(115, 124, 137)
$footer.AutoEllipsis = $true
$footer.Visible = $false
$form.Controls.Add($footer)

function Set-PanelButtonStyle {
    param([System.Windows.Forms.Button]$Button, [string]$Kind = 'Secondary')
    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = $form.Font
    $Button.FlatAppearance.BorderSize = 1
    $Button.BackColor = [System.Drawing.Color]::White
    $Button.ForeColor = [System.Drawing.Color]::FromArgb(39, 52, 70)
    $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(215, 223, 233)
    $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(241, 246, 253)
    $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(226, 237, 250)
    if ($Kind -eq 'Primary') {
        $Button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
        $Button.BackColor = [System.Drawing.Color]::FromArgb(36, 99, 205)
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(36, 99, 205)
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(28, 84, 181)
        $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(22, 70, 156)
    }
    elseif ($Kind -eq 'Danger') {
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(180, 51, 42)
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(239, 210, 207)
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(254, 244, 243)
        $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(251, 228, 225)
    }
    elseif ($Kind -eq 'Quiet') {
        $Button.FlatAppearance.BorderSize = 0
        $Button.BackColor = $form.BackColor
    }
}

foreach ($button in @($script:loginButton, $script:startButton, $script:refreshButton,
    $script:selfCheckButton, $script:copyAddressButton, $script:openFolderButton,
    $script:openConfigButton, $script:openProgramButton, $script:copyAccountButton,
    $script:copyButton, $script:switchAccountButton, $script:restoreAccountsButton,
    $script:locateAccountButton, $script:quotaRefreshButton, $script:quotaAutoSwitchButton, $script:geminiAutoSwitchButton, $script:copyActivityButton,
    $script:clearActivityButton)) { Set-PanelButtonStyle $button }
Set-PanelButtonStyle $script:serviceOnlyButton 'Primary'
Set-PanelButtonStyle $script:stopButton 'Danger'
Set-PanelButtonStyle $script:moreButton 'Quiet'
Set-PanelButtonStyle $script:accountToggleButton 'Quiet'
Set-PanelButtonStyle $script:logsToggleButton 'Quiet'

$buttonTips = New-Object System.Windows.Forms.ToolTip
$buttonTips.InitialDelay = 450
$buttonTips.ReshowDelay = 100
$buttonTips.AutoPopDelay = 7000
$buttonTips.SetToolTip($script:startButton, '启动代理服务并打开 Antigravity 授权；服务已运行时直接打开授权。')
$buttonTips.SetToolTip($script:serviceOnlyButton, '仅启动代理服务，不打开浏览器授权窗口。')
$buttonTips.SetToolTip($script:loginButton, '复用当前代理服务，重新打开授权窗口。')
$buttonTips.SetToolTip($script:stopButton, '确认后停止本面板识别到的代理服务。')
$buttonTips.SetToolTip($script:openConfigButton, '用记事本查看配置；保存修改后需重启服务。')
$buttonTips.SetToolTip($script:copyAccountButton, '先在下方账号列表中选中一行，只复制显示的账号名称。')
$buttonTips.SetToolTip($script:clearActivityButton, '只清空本面板的运行记录，不影响代理服务或文件。')
$buttonTips.SetToolTip($script:selfCheckButton, '检查程序、配置、本机端口、代理进程和本地账号记录；不会发送模型请求。')
$buttonTips.SetToolTip($script:locateAccountButton, '在资源管理器中定位选中的本地授权文件，不打开文件内容。')
$buttonTips.SetToolTip($script:switchAccountButton, '停用其他本地授权账号，只保留选中的账号供代理使用。')
$buttonTips.SetToolTip($script:restoreAccountsButton, '停用全部本地账号；需要恢复时选中一个账号并点击“只用选中账号”。')
$buttonTips.SetToolTip($script:quotaRefreshButton, '立即刷新当前账号额度；服务运行时也会每 10 分钟自动查询，不发送模型请求。')
$buttonTips.SetToolTip($script:quotaAutoSwitchButton, '默认关闭。仅控制 Claude / GPT 的 5 小时或每周额度耗尽时切号，Gemini 由独立开关控制。按账号列表顺序，跳过已确认耗尽或格式异常的账号；先停用旧账号，再启用新账号。查询失败不会切号。关闭面板后停止自动切号。')
$buttonTips.SetToolTip($script:geminiAutoSwitchButton, '默认关闭。控制 Gemini（含 Argon）真实额度耗尽时切号，Claude / GPT 由独立开关控制。按账号列表顺序，跳过已确认耗尽或格式异常的账号；先停用旧账号，再启用新账号。查询失败、额度未知或模型未开放不会切号。关闭面板后停止自动切号。')
$accountEvidence.Visible = $false
$script:advancedButtons = @($script:startButton, $script:refreshButton, $script:selfCheckButton,
    $script:copyAddressButton, $script:openFolderButton, $script:openConfigButton,
    $script:openProgramButton, $script:copyAccountButton, $script:copyButton,
    $script:restoreAccountsButton, $script:locateAccountButton)
foreach ($button in $script:advancedButtons) { $button.Visible = $false }
$script:activityList.Visible = $false
$script:copyActivityButton.Visible = $false
$script:clearActivityButton.Visible = $false

function Write-Activity {
    param([string]$Message)
    $entry = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:activityList.Items.Insert(0, $entry)
    while ($script:activityList.Items.Count -gt 60) {
        $script:activityList.Items.RemoveAt($script:activityList.Items.Count - 1)
    }
    $script:copyActivityButton.Enabled = $true
    $script:clearActivityButton.Enabled = $true
}

function Set-ProgressState {
    param([int]$Value, [string]$Message, [bool]$Indeterminate = $false)
    $bounded = [Math]::Max(0, [Math]::Min(100, $Value))
    if ($Indeterminate) {
        $script:progressBar.Style = 'Marquee'
        $script:progressValueLabel.Text = '等待中'
    }
    else {
        $script:progressBar.Style = 'Blocks'
        $script:progressBar.Value = $bounded
        $script:progressValueLabel.Text = '{0}%' -f $bounded
    }
    $script:progressStatus.Text = $Message
    $phaseText = switch ($script:workflowPhase) {
        'waiting-service' { '启动服务' }
        'delay-before-login' { '准备授权' }
        'service-ready' { '服务已就绪' }
        'waiting-auth' { '等待授权' }
        'complete' { '本地授权已保存' }
        'unconfirmed' { '授权未确认' }
        'failed' { '操作失败' }
        'stopped' { '服务已停止' }
        default { '尚未开始' }
    }
    $script:phaseLabel.Text = $phaseText
    $script:progressStatus.ForeColor = if ($script:workflowPhase -in @('failed', 'unconfirmed')) {
        [System.Drawing.Color]::FromArgb(170, 75, 38)
    } elseif ($script:workflowPhase -eq 'complete') {
        [System.Drawing.Color]::FromArgb(30, 105, 75)
    } else {
        [System.Drawing.Color]::FromArgb(78, 92, 110)
    }
}

function Read-LaunchConfig {
    $script:configuredPort = 0
    $script:authDirectory = $null
    if (-not (Test-Path -LiteralPath $script:configPath -PathType Leaf)) {
        return $false
    }

    $portValue = 0
    $authValue = $null
    foreach ($match in (Select-String -LiteralPath $script:configPath -Pattern '^\s*(port|auth-dir)\s*:' -ErrorAction SilentlyContinue)) {
        if ($match.Line -match '^\s*port\s*:\s*(?<value>\d+)\s*$') {
            $portValue = [int]$Matches['value']
        }
        elseif ($match.Line -match '^\s*auth-dir\s*:\s*(?<value>.*?)\s*$') {
            $authValue = [regex]::Replace($Matches['value'], '\s+#.*$', '').Trim()
            if ($authValue.Length -ge 2) {
                if (($authValue[0] -eq '"' -and $authValue[$authValue.Length - 1] -eq '"') -or ($authValue[0] -eq "'" -and $authValue[$authValue.Length - 1] -eq "'")) {
                    $authValue = $authValue.Substring(1, $authValue.Length - 2)
                }
            }
        }
    }

    if ($portValue -gt 0 -and $portValue -le 65535) {
        $script:configuredPort = $portValue
    }
    if ([string]::IsNullOrWhiteSpace($authValue)) {
        $authValue = '~/.cli-proxy-api'
    }

    if ($authValue -eq '~') {
        $authValue = $env:USERPROFILE
    }
    elseif ($authValue.StartsWith('~/') -or $authValue.StartsWith('~\')) {
        $authValue = Join-Path $env:USERPROFILE $authValue.Substring(2)
    }
    else {
        $authValue = [Environment]::ExpandEnvironmentVariables($authValue)
        if (-not [System.IO.Path]::IsPathRooted($authValue)) {
            $authValue = Join-Path $script:cliFolder $authValue
        }
    }
    $script:authDirectory = [System.IO.Path]::GetFullPath($authValue)
    return $true
}

function Get-AuthSnapshot {
    $rows = @()
    if ($script:authDirectory -and (Test-Path -LiteralPath $script:authDirectory -PathType Container)) {
        $recordNumber = 0
        foreach ($file in (Get-ChildItem -LiteralPath $script:authDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $recordNumber++
            $accountName = $file.BaseName -replace '(?i)^(?:antigravity|gemini|codex|claude)-', ''
            $emailMatch = [regex]::Match($accountName, '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}')
            if ($emailMatch.Success) {
                $displayName = $emailMatch.Value
            }
            else {
                $displayName = '本地账号记录 {0}' -f $recordNumber
            }

            $provider = 'OAuth'
            foreach ($candidate in @('Antigravity', 'Gemini', 'Codex', 'Claude')) {
                if ($file.BaseName -match [regex]::Escape($candidate)) {
                    $provider = $candidate
                    break
                }
            }

            $disabled = $null
            $problem = ''
            try {
                $authData = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                if ($authData -isnot [pscustomobject]) { throw '授权文件不是 JSON 对象。' }
                $disabledProperty = $authData.PSObject.Properties['disabled']
                if ($disabledProperty) {
                    if ($disabledProperty.Value -is [bool]) { $disabled = $disabledProperty.Value }
                }
                else { $disabled = $false }
                if ($provider -eq 'Antigravity') {
                    $missing = @()
                    if ([string]$authData.type -ne 'antigravity') {
                        $missing += 'type'
                        $provider = '未识别'
                    }
                    $missing += @('access_token', 'refresh_token', 'project_id') | Where-Object {
                        -not ($authData.PSObject.Properties[$_] -and -not [string]::IsNullOrWhiteSpace([string]$authData.$_))
                    }
                    if ($missing.Count -gt 0) { $problem = '缺少 ' + ($missing -join ', ') }
                }
            }
            catch { $problem = 'JSON 无法读取' }

            $fileSignature = '{0}|{1}|{2}' -f $file.Name, $file.Length, $file.LastWriteTimeUtc.Ticks
            $rows += [pscustomobject]@{
                Name = $file.Name
                DisplayName = $displayName
                Provider = $provider
                Updated = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                Signature = $fileSignature
                Disabled = $disabled
                Problem = $problem
            }
        }
    }

    $signature = (@($rows | Sort-Object Name | ForEach-Object { $_.Signature }) -join [char]10)
    return [pscustomobject]@{ Rows = $rows; Signature = $signature }
}

function Set-AuthFileDisabled {
    param([string]$FileName, [bool]$Disabled)
    if ($FileName -ne [System.IO.Path]::GetFileName($FileName) -or -not $FileName.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '授权文件名无效。'
    }
    $filePath = Join-Path $script:authDirectory $FileName
    $originalBytes = [System.IO.File]::ReadAllBytes($filePath)
    $hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $json = $utf8.GetString($originalBytes, $offset, $originalBytes.Length - $offset)
    $authData = $json | ConvertFrom-Json
    if ($authData -isnot [pscustomobject]) { throw '授权文件不是 JSON 对象。' }
    $disabledProperty = $authData.PSObject.Properties['disabled']
    if ($disabledProperty) {
        if ($disabledProperty.Value -isnot [bool]) { throw '授权文件的 disabled 字段不是布尔值。' }
        if ($disabledProperty.Value -eq $Disabled) { return }
        $disabledProperty.Value = $Disabled
    }
    else {
        $authData | Add-Member -NotePropertyName disabled -NotePropertyValue $Disabled
    }
    $updatedJson = $authData | ConvertTo-Json -Depth 100 -Compress
    $verified = $updatedJson | ConvertFrom-Json
    if ($verified.PSObject.Properties['disabled'].Value -ne $Disabled) { throw '授权文件状态校验失败。' }
    $body = $utf8.GetBytes($updatedJson)
    if ($hasBom) {
        $updatedBytes = New-Object byte[] ($body.Length + 3)
        $updatedBytes[0] = 0xEF; $updatedBytes[1] = 0xBB; $updatedBytes[2] = 0xBF
        [System.Array]::Copy($body, 0, $updatedBytes, 3, $body.Length)
    }
    else { $updatedBytes = $body }
    $temporaryPath = Join-Path $script:authDirectory ('.switch-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $script:authDirectory ('.switch-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $updatedBytes)
        if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) -ne [Convert]::ToBase64String($originalBytes)) {
            throw '授权文件刚被其他程序更新，请重试。'
        }
        [System.IO.File]::Replace($temporaryPath, $filePath, $backupPath)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
        if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
    }
}

function Update-AccountSwitchControls {
    $rows = if ($script:authSnapshot) { @($script:authSnapshot.Rows) } else { @() }
    $busy = $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')
    $valid = @($rows | Where-Object { $null -eq $_.Disabled }).Count -eq 0
    $selectedName = if ($script:accountList.SelectedItems.Count -gt 0) { [string]$script:accountList.SelectedItems[0].Tag } else { '' }
    $selected = @($rows | Where-Object { $_.Name -eq $selectedName })
    $enabled = @($rows | Where-Object { $_.Disabled -eq $false })
    $script:switchAccountButton.Enabled = (-not $busy -and $valid -and $selected.Count -eq 1 -and -not $selected[0].Problem -and -not ($enabled.Count -eq 1 -and $enabled[0].Name -eq $selectedName))
    $script:restoreAccountsButton.Enabled = (-not $busy -and $valid -and $enabled.Count -gt 0)
}

function Switch-ToAccount {
    param([string]$FileName)
    $snapshot = Get-AuthSnapshot
    $rows = @($snapshot.Rows)
    $target = @($rows | Where-Object { $_.Name -eq $FileName })
    if ($target.Count -ne 1 -or $target[0].Problem -or @($rows | Where-Object { $null -eq $_.Disabled }).Count -gt 0) {
        throw '账号格式或停用状态异常，无法安全切换。'
    }
    foreach ($row in $rows) {
        if ($row.Name -ne $FileName -and $row.Disabled -eq $false) {
            Set-AuthFileDisabled -FileName $row.Name -Disabled $true
        }
    }
    Set-AuthFileDisabled -FileName $FileName -Disabled $false
    $script:authSnapshot = Get-AuthSnapshot
    $nowEnabled = @($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false })
    if ($nowEnabled.Count -ne 1 -or $nowEnabled[0].Name -ne $FileName -or @($script:authSnapshot.Rows | Where-Object { $null -eq $_.Disabled }).Count -gt 0) {
        throw '切换后本地状态未达到仅启用选中账号。'
    }
    $script:quotaObservedAccount = $FileName
    $script:nextQuotaRefreshAt = (Get-Date).AddSeconds(2)
}

function Switch-ToSelectedAccount {
    Refresh-Dashboard
    if (-not $script:switchAccountButton.Enabled -or $script:accountList.SelectedItems.Count -ne 1) { return }
    $selectedName = [string]$script:accountList.SelectedItems[0].Tag
    try {
        Switch-ToAccount -FileName $selectedName
        $script:quotaAutomationNotice = ''
        Refresh-Dashboard
        $target = @($script:authSnapshot.Rows | Where-Object { $_.Name -eq $selectedName })[0]
        Write-Activity ('本地已设为只使用 {0}；代理热加载及实际请求账号未验证。' -f $target.DisplayName)
    }
    catch {
        Refresh-Dashboard
        [System.Windows.Forms.MessageBox]::Show(('切换未完成：{0}`n请检查账号列表；部分账号可能已停用。' -f $_.Exception.Message), '切换账号失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Pause-AllAccounts {
    Refresh-Dashboard
    if (-not $script:restoreAccountsButton.Enabled) { return }
    try {
        foreach ($row in @($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false })) {
            Set-AuthFileDisabled -FileName $row.Name -Disabled $true
        }
        Refresh-Dashboard
        if (@($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false }).Count -gt 0) {
            throw '仍有账号处于启用状态。'
        }
        Write-Activity '已暂停全部本地账号；代理热加载未验证。'
    }
    catch {
        Refresh-Dashboard
        [System.Windows.Forms.MessageBox]::Show(('暂停未完成：{0}`n请查看账号列表后重试。' -f $_.Exception.Message), '暂停账号失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Ensure-SingleAccount {
    param($Snapshot)
    $enabledRows = @($Snapshot.Rows | Where-Object { $_.Disabled -eq $false })
    if ($enabledRows.Count -le 1) { return $Snapshot }
    $validRows = @($enabledRows | Where-Object { -not $_.Problem })
    $candidates = if ($validRows.Count -gt 0) { $validRows } else { $enabledRows }
    $keep = $candidates | Sort-Object Updated -Descending | Select-Object -First 1
    foreach ($row in $enabledRows) {
        if ($row.Name -ne $keep.Name) {
            Set-AuthFileDisabled -FileName $row.Name -Disabled $true
        }
    }
    Write-Activity ('发现多个启用账号，已自动只保留最近保存的 {0}。' -f $keep.DisplayName)
    return Get-AuthSnapshot
}

function Restore-AccountAfterFailedAuthorization {
    $previous = $script:accountBeforeAuthorization
    $script:accountBeforeAuthorization = $null
    if (-not $previous) { return }
    try {
        $rows = @((Get-AuthSnapshot).Rows)
        foreach ($row in $rows) {
            if ($row.Name -ne $previous -and $row.Disabled -eq $false) {
                Set-AuthFileDisabled -FileName $row.Name -Disabled $true
            }
        }
        if (@($rows | Where-Object { $_.Name -eq $previous }).Count -eq 1) {
            Set-AuthFileDisabled -FileName $previous -Disabled $false
            Write-Activity '授权未完成，已恢复原来使用的账号。'
        }
    }
    catch { Write-Activity ('未能恢复原账号，请在列表中手动选择：' + $_.Exception.Message) }
}

function Read-LastAuthorizedAccount {
    if (-not (Test-Path -LiteralPath $script:statePath -PathType Leaf)) {
        return
    }
    try {
        $saved = [System.IO.File]::ReadAllText($script:statePath) | ConvertFrom-Json
        if ($saved.CompletedAt -and ($saved.FileName -or $saved.Ambiguous)) {
            $script:lastAuthorizedRecord = $saved
        }
    }
    catch {
        Write-Activity '最近授权状态文件无法读取；账号列表仍可正常查看。'
    }
}

function Save-LastAuthorizedAccount {
    $updatedRows = @($script:authSnapshot.Rows | Where-Object { $script:authChangedNames.ContainsKey($_.Name) })
    if ($updatedRows.Count -ne 1) {
        $script:lastAuthorizedRecord = [pscustomobject]@{
            FileName = ''
            CompletedAt = (Get-Date).ToString('o')
            Ambiguous = $true
        }
        $script:lastAuthorizedLabel.Text = '最近完成授权：多条记录同时更新，无法确定单个账号'
    }
    else {
        $script:lastAuthorizedRecord = [pscustomobject]@{
            FileName = $updatedRows[0].Name
            CompletedAt = (Get-Date).ToString('o')
            Ambiguous = $false
        }
    }
    try {
        $json = $script:lastAuthorizedRecord | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($script:statePath, $json, [System.Text.UTF8Encoding]::new($false))
        if ($updatedRows.Count -eq 1) {
            Write-Activity ('最近完成授权的账号记录：{0}' -f $updatedRows[0].DisplayName)
        }
    }
    catch {
        Write-Activity '账号已确认，但无法保存面板的最近授权状态。'
    }
}

function Test-ConfiguredPort {
    if ($script:configuredPort -le 0) {
        return $false
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect('127.0.0.1', $script:configuredPort, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne(250)) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-PortOwnerProcess {
    if ($script:configuredPort -le 0) {
        return $null
    }
    $ownerIds = @()
    $portSuffix = ':{0}' -f $script:configuredPort
    foreach ($line in (& netstat.exe -ano -p TCP)) {
        $fields = $line.Trim() -split '\s+'
        if ($fields.Count -lt 5 -or $fields[0] -ne 'TCP' -or -not $fields[1].EndsWith($portSuffix) -or $fields[3] -ne 'LISTENING') {
            continue
        }
        $ownerId = 0
        if ([int]::TryParse($fields[4], [ref]$ownerId) -and $ownerIds -notcontains $ownerId) {
            $ownerIds += $ownerId
        }
    }
    foreach ($ownerId in $ownerIds) {
        try {
            $ownerProcess = Get-Process -Id $ownerId -ErrorAction Stop
            if ($ownerProcess.Path -and [string]::Equals([System.IO.Path]::GetFullPath($ownerProcess.Path), [System.IO.Path]::GetFullPath($script:exePath), [System.StringComparison]::OrdinalIgnoreCase)) {
                return $ownerProcess
            }
        }
        catch {
        }
    }
    return $null
}

function Update-ServiceCard {
    $script:portReachable = Test-ConfiguredPort
    $script:servicePortProcess = Get-PortOwnerProcess

    if ($script:portReachable -and $script:servicePortProcess) {
        $script:serviceCard.Value.Text = '运行中'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(30, 135, 85)
        $script:serviceCard.Detail.Text = 'PID {0} · 接口可连接' -f $script:servicePortProcess.Id
    }
    elseif ($script:portReachable) {
        $script:serviceCard.Value.Text = '端口有响应'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(198, 130, 20)
        $script:serviceCard.Detail.Text = '端口响应进程与本助手不匹配'
    }
    elseif ($script:workflowPhase -eq 'waiting-service') {
        $script:serviceCard.Value.Text = '启动中'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(198, 130, 20)
        $script:serviceCard.Detail.Text = '等待配置端口开始监听'
    }
    else {
        $script:serviceCard.Value.Text = '未运行'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(177, 62, 62)
        $script:serviceCard.Detail.Text = '点击“启动并打开授权”'
    }

    if ($script:servicePortProcess) {
        $uptime = (Get-Date) - $script:servicePortProcess.StartTime
        $script:uptimeLabel.Text = '服务运行时长：{0:%d} 天 {0:hh} 小时 {0:mm} 分钟' -f $uptime
    }
    else {
        $script:uptimeLabel.Text = '服务运行时长：未确认'
    }

    if ($script:configuredPort -gt 0) {
        $script:apiCard.Value.Text = '127.0.0.1:{0}' -f $script:configuredPort
        if ($script:portReachable) {
            $script:apiCard.Detail.Text = '端口可连接，未验证请求'
            $script:apiCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(30, 135, 85)
        }
        else {
            $script:apiCard.Detail.Text = '等待本机接口监听'
            $script:apiCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(42, 61, 83)
        }
    }
    else {
        $script:apiCard.Value.Text = '未读取'
        $script:apiCard.Detail.Text = '请检查 config.yaml'
        $script:apiCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(177, 62, 62)
    }
}

function Refresh-Dashboard {
    $exeExists = Test-Path -LiteralPath $script:exePath -PathType Leaf
    $configExists = Read-LaunchConfig
    if (-not $configExists) {
        $script:portReachable = $false
        $script:servicePortProcess = $null
        $script:authSnapshot = [pscustomobject]@{ Rows = @(); Signature = '' }
        $script:serviceCard.Value.Text = '配置缺失'
        $script:serviceCard.Detail.Text = '找不到 config.yaml'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(177, 62, 62)
        $script:apiCard.Value.Text = '未知'
        $script:apiCard.Detail.Text = '无法读取端口'
        $script:authCard.Value.Text = '未知'
        $script:authCard.Detail.Text = '无法读取授权目录'
        $script:updateCard.Value.Text = '—'
        $script:updateCard.Detail.Text = ''
        $script:uptimeLabel.Text = '服务运行时长：未确认'
        $script:currentAccountLabel.Text = '本次记录更新：无法读取配置'
        $script:runningAccountLabel.Text = '当前运行账号：配置缺失，无法确定'
        $script:lastAuthorizedLabel.Text = '最近完成授权：无法读取授权目录'
        $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(239, 243, 248)
        $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
        $script:accountList.Items.Clear()
        $script:lastListSignature = $null
        $script:loginButton.Enabled = $false
        $script:stopButton.Enabled = $false
        $script:serviceOnlyButton.Enabled = $false
        $script:serviceOnlyButton.BackColor = [System.Drawing.Color]::FromArgb(236, 241, 247)
        $script:serviceOnlyButton.ForeColor = [System.Drawing.Color]::FromArgb(93, 106, 124)
        $script:serviceOnlyButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(222, 230, 239)
        $script:copyAddressButton.Enabled = $false
        $script:copyAccountButton.Enabled = $false
        $script:locateAccountButton.Enabled = $false
        $script:switchAccountButton.Enabled = $false
        $script:restoreAccountsButton.Enabled = $false
        if ($script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) {
            Fail-Workflow '配置文件无法读取，已中止当前启动或授权流程。'
        }
        return
    }

    Update-ServiceCard
    $currentServicePid = if ($script:servicePortProcess) { $script:servicePortProcess.Id } else { $null }
    if ($currentServicePid -ne $script:lastObservedServicePid) {
        if ($currentServicePid) {
            Write-Activity ('检测到代理服务 PID {0}。' -f $currentServicePid)
        }
        elseif ($script:lastObservedServicePid) {
            Write-Activity '代理服务已停止。'
            if ($script:workflowPhase -ne 'waiting-service') {
                $script:workflowPhase = 'stopped'
                $script:authWatchEnabled = $false
                Set-ProgressState 0 '代理服务已停止；账号记录仍保留在本地。'
            }
        }
        $script:lastObservedServicePid = $currentServicePid
    }
    $workflowActive = $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')
    $script:loginButton.Enabled = ($script:servicePortProcess -and -not $workflowActive)
    $script:stopButton.Enabled = ($script:servicePortProcess -and -not $workflowActive)
    $script:serviceOnlyButton.Enabled = (-not $workflowActive -and -not ($script:portReachable -and $script:servicePortProcess))
    $script:serviceOnlyButton.Text = if ($script:servicePortProcess -and $script:portReachable) { '服务运行中' } elseif ($script:workflowPhase -eq 'waiting-service') { '启动中…' } else { '启动服务' }
    $script:serviceOnlyButton.BackColor = if ($script:serviceOnlyButton.Enabled) { [System.Drawing.Color]::FromArgb(36, 99, 205) } elseif ($script:servicePortProcess -and $script:portReachable) { [System.Drawing.Color]::FromArgb(229, 246, 237) } else { [System.Drawing.Color]::FromArgb(236, 241, 247) }
    $script:serviceOnlyButton.ForeColor = if ($script:serviceOnlyButton.Enabled) { [System.Drawing.Color]::White } elseif ($script:servicePortProcess -and $script:portReachable) { [System.Drawing.Color]::FromArgb(21, 126, 71) } else { [System.Drawing.Color]::FromArgb(93, 106, 124) }
    $script:serviceOnlyButton.FlatAppearance.BorderColor = if ($script:serviceOnlyButton.Enabled) { [System.Drawing.Color]::FromArgb(36, 99, 205) } elseif ($script:servicePortProcess -and $script:portReachable) { [System.Drawing.Color]::FromArgb(208, 235, 218) } else { [System.Drawing.Color]::FromArgb(222, 230, 239) }
    $script:copyAddressButton.Enabled = $script:configuredPort -gt 0
    if (-not $workflowActive) {
        $script:startButton.Text = if ($script:portReachable -and $script:servicePortProcess) { '打开授权（服务已运行）' } else { '启动并打开授权' }
    }
    if (-not $exeExists) {
        $script:serviceCard.Value.Text = '程序缺失'
        $script:serviceCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(177, 62, 62)
        $script:serviceCard.Detail.Text = '找不到 cli-proxy-api.exe'
    }

    $snapshot = Get-AuthSnapshot
    try { $snapshot = Ensure-SingleAccount -Snapshot $snapshot }
    catch { Write-Activity ('无法自动保持单账号：' + $_.Exception.Message) }
    $script:authSnapshot = $snapshot
    if ($script:workflowPhase -in @('idle', 'service-ready') -and $script:portReachable -and $script:servicePortProcess) {
        $script:workflowPhase = 'service-ready'
        $readyAccounts = @($snapshot.Rows | Where-Object { $_.Disabled -eq $false -and -not $_.Problem -and $_.Provider -eq 'Antigravity' })
        if ($readyAccounts.Count -eq 1) { Set-ProgressState 100 '服务已运行，单个本地账号已加载；实际模型请求尚未验证。' }
        else { Set-ProgressState 65 '服务已运行；请检查下方账号记录。' }
    }
    if (-not ($script:portReachable -and $script:servicePortProcess)) {
        $script:runningAccountLabel.Text = '当前运行账号：服务未就绪，无法确定'
    }
    else {
        $enabledRows = @($snapshot.Rows | Where-Object { $_.Disabled -eq $false -and -not $_.Problem })
        $problemRows = @($snapshot.Rows | Where-Object { $_.Problem })
        $unknownRows = @($snapshot.Rows | Where-Object { $null -eq $_.Disabled })
        if ($unknownRows.Count -gt 0) {
            $script:runningAccountLabel.Text = '当前运行账号：有记录状态读取失败，无法确定'
        }
        elseif ($enabledRows.Count -eq 1) {
            $script:runningAccountLabel.Text = '当前可用账号：{0}（本地设置，实际请求未验证）' -f $enabledRows[0].DisplayName
        }
        elseif ($enabledRows.Count -gt 1) {
            $script:runningAccountLabel.Text = '当前可用账号：{0} 个；单次请求由代理选择' -f $enabledRows.Count
        }
        elseif ($problemRows.Count -gt 0) {
            $script:runningAccountLabel.Text = '当前可用账号：无；{0} 个授权文件格式不完整' -f $problemRows.Count
        }
        elseif ($snapshot.Rows.Count -gt 0) {
            $script:runningAccountLabel.Text = '当前可用账号：无，全部本地账号已停用'
        }
        else {
            $script:runningAccountLabel.Text = '当前可用账号：未找到本地授权文件'
        }
    }
    if ($script:lastAuthorizedRecord -and $script:lastAuthorizedRecord.Ambiguous) {
        $script:lastAuthorizedLabel.Text = '最近完成授权：多条记录同时更新，无法确定单个账号'
        $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(255, 246, 225)
        $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(138, 90, 24)
    }
    elseif ($script:lastAuthorizedRecord) {
        $savedRow = @($snapshot.Rows | Where-Object { $_.Name -eq $script:lastAuthorizedRecord.FileName })
        $completedTime = [DateTimeOffset]::MinValue
        if ($savedRow.Count -eq 1 -and [DateTimeOffset]::TryParse($script:lastAuthorizedRecord.CompletedAt, [ref]$completedTime)) {
            $completedAt = $completedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            $script:lastAuthorizedLabel.Text = '最近完成授权（依据本地记录）：{0}  ·  {1}' -f $savedRow[0].DisplayName, $completedAt
            $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(235, 246, 241)
            $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 105, 75)
        }
        else {
            $script:lastAuthorizedLabel.Text = '最近完成授权：记录已不在本地授权目录'
            $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(255, 246, 225)
            $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(138, 90, 24)
        }
    }
    elseif ($snapshot.Rows.Count -gt 0) {
        $latestLocal = $snapshot.Rows | Sort-Object Updated -Descending | Select-Object -First 1
        $script:lastAuthorizedLabel.Text = '最近修改的本地记录：{0}  ·  {1}（不代表完成授权）' -f $latestLocal.DisplayName, $latestLocal.Updated
        $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(239, 243, 248)
        $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
    }
    else {
        $script:lastAuthorizedLabel.Text = '最近完成授权：暂无本地账号记录'
        $accountSummary.BackColor = [System.Drawing.Color]::FromArgb(239, 243, 248)
        $script:lastAuthorizedLabel.ForeColor = [System.Drawing.Color]::FromArgb(78, 92, 110)
    }
    if ($script:authWatchEnabled -and $null -ne $script:authBaselineSignature -and $snapshot.Signature -ne $script:authBaselineSignature) {
        $changedRows = @($snapshot.Rows | Where-Object {
            -not $script:authBaselineMap.ContainsKey($_.Name) -or $script:authBaselineMap[$_.Name] -ne $_.Signature
        })
        if ($changedRows.Count -gt 0) {
            $script:authChangedSinceStart = $true
            $newAccountDetected = $false
            foreach ($row in $changedRows) {
                if (-not $script:authChangedNames.ContainsKey($row.Name)) {
                    $newAccountDetected = $true
                }
                $script:authChangedNames[$row.Name] = $true
            }
            if ($newAccountDetected) {
                Write-Activity '检测到本地授权记录新增或更新。'
            }
        }
    }

    if ($snapshot.Signature -ne $script:lastListSignature) {
        $selectedName = if ($script:accountList.SelectedItems.Count -gt 0) { $script:accountList.SelectedItems[0].Tag } else { $null }
        $script:accountList.BeginUpdate()
        try {
            $script:accountList.Items.Clear()
            if ($snapshot.Rows.Count -eq 0) {
                $emptyItem = New-Object System.Windows.Forms.ListViewItem -ArgumentList @('尚无本地 JSON 授权记录')
                [void]$emptyItem.SubItems.Add('—')
                [void]$emptyItem.SubItems.Add('完成登录后自动检查')
                [void]$script:accountList.Items.Add($emptyItem)
            }
            else {
                foreach ($row in @($snapshot.Rows | Sort-Object DisplayName)) {
                    $rowStatus = if ($row.Problem) { '不可用：' + $row.Problem } elseif ($null -eq $row.Disabled) { '状态读取失败' } elseif ($row.Disabled) { '已停用' } else { '可参与路由（本地）' }
                    $item = New-Object System.Windows.Forms.ListViewItem -ArgumentList @($row.DisplayName)
                    $item.Tag = $row.Name
                    [void]$item.SubItems.Add($rowStatus)
                    [void]$item.SubItems.Add($row.Updated)
                    $item.ToolTipText = '{0}{1}{2} · {3} · {4}' -f $row.DisplayName, [Environment]::NewLine, $row.Provider, $rowStatus, $row.Updated
                    if ($row.Problem -or $null -eq $row.Disabled) {
                        $item.BackColor = [System.Drawing.Color]::FromArgb(255, 246, 225)
                    }
                    elseif ($row.Disabled) {
                        $item.BackColor = [System.Drawing.Color]::FromArgb(239, 241, 244)
                    }
                    elseif ($script:authChangedNames.ContainsKey($row.Name)) {
                        $item.BackColor = [System.Drawing.Color]::FromArgb(225, 244, 232)
                    }
                    elseif ($row.Disabled -eq $false) {
                        $item.BackColor = [System.Drawing.Color]::FromArgb(235, 246, 241)
                    }
                    [void]$script:accountList.Items.Add($item)
                    if ($selectedName -and $selectedName -eq $row.Name) { $item.Selected = $true }
                }
            }
            $script:lastListSignature = $snapshot.Signature
            $script:copyAccountButton.Enabled = $script:accountList.SelectedItems.Count -gt 0
            $script:locateAccountButton.Enabled = $script:copyAccountButton.Enabled
        }
        finally {
            $script:accountList.EndUpdate()
        }
    }
    Update-AccountSwitchControls

    if ($script:authChangedNames.Count -gt 0) {
        $changedAccounts = @($snapshot.Rows | Where-Object { $script:authChangedNames.ContainsKey($_.Name) } | ForEach-Object { $_.DisplayName } | Select-Object -Unique)
        if ($changedAccounts.Count -eq 1) {
            $script:currentAccountLabel.Text = '本次记录更新：{0}' -f $changedAccounts[0]
        }
        elseif ($changedAccounts.Count -gt 1) {
            $script:currentAccountLabel.Text = '本次有 {0} 个账号记录更新，请查看下方绿色行' -f $changedAccounts.Count
        }
    }
    elseif ($script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) {
        $script:currentAccountLabel.Text = '本次记录更新：等待浏览器授权…'
    }
    elseif ($script:workflowPhase -in @('failed', 'unconfirmed')) {
        $script:currentAccountLabel.Text = '本次记录更新：未确认'
    }
    else {
        $script:currentAccountLabel.Text = ''
    }

    $count = @($snapshot.Rows).Count
    if ($count -gt 0) {
        $script:authCard.Value.Text = '{0} 条记录' -f $count
        $activeCount = @($snapshot.Rows | Where-Object { $_.Disabled -eq $false -and -not $_.Problem }).Count
        $inactiveCount = @($snapshot.Rows | Where-Object { $_.Disabled -eq $true -and -not $_.Problem }).Count
        $problemCount = @($snapshot.Rows | Where-Object { $_.Problem }).Count
        $script:authCard.Value.ForeColor = if ($activeCount -gt 0) { [System.Drawing.Color]::FromArgb(30, 135, 85) } else { [System.Drawing.Color]::FromArgb(198, 130, 20) }
        $script:authCard.Detail.Text = '{0} 可用 / {1} 停用 / {2} 异常' -f $activeCount, $inactiveCount, $problemCount
        $latest = $snapshot.Rows | Sort-Object Updated -Descending | Select-Object -First 1
        $script:updateCard.Value.Text = $latest.Updated.Substring(11)
        $script:updateCard.Detail.Text = $latest.DisplayName
    }
    else {
        $script:authCard.Value.Text = '无记录'
        $script:authCard.Value.ForeColor = [System.Drawing.Color]::FromArgb(198, 130, 20)
        $script:authCard.Detail.Text = '等待授权文件写入'
        $script:updateCard.Value.Text = '—'
        $script:updateCard.Detail.Text = '暂无本地记录'
    }
    Update-MetricsDisplay
    Ensure-MetricsCollector
}

function Ensure-MetricsCollector {
    if (-not ($script:portReachable -and $script:servicePortProcess)) { return }
    if (-not (Test-Path -LiteralPath $script:managementKeyPath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:metricsPath -PathType Leaf)) { return }
    if (((Get-Date) - $script:lastCollectorCheck).TotalSeconds -lt 15) { return }
    $script:lastCollectorCheck = Get-Date
    $mutex = New-Object Threading.Mutex($false, 'Local\CLIProxyAPI_Helper_UsageCollector')
    $available = $false
    try {
        try { $available = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $available = $true }
        if ($available) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-File', ('"' + $script:metricsPath + '"'), '-Collect') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        }
    }
    catch { Write-Activity ('用量采集器启动失败：' + $_.Exception.Message) }
    finally {
        if ($available) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Scale-MetricPixel([int]$Value) {
    return [int][Math]::Round($Value * $dpiScale)
}

function Clear-QuotaCards {
    foreach ($card in @($script:quotaCards.Controls)) {
        $script:quotaCards.Controls.Remove($card)
        $card.Dispose()
    }
    $script:quotaCards.AutoScrollMinSize = [System.Drawing.Size]::Empty
}

function Layout-QuotaCards {
    $cards = @($script:quotaCards.Controls | Where-Object { $_.Tag -and $_.Tag.Rows })
    if ($cards.Count -eq 0) {
        foreach ($control in $script:quotaCards.Controls) { $control.Width = [Math]::Max(1, $script:quotaCards.ClientSize.Width - (Scale-MetricPixel 12)) }
        return
    }
    $gap = Scale-MetricPixel 10
    $width = [Math]::Max(1, $script:quotaCards.ClientSize.Width - (Scale-MetricPixel 2))
    $columns = if ($width -ge (Scale-MetricPixel 580)) { 2 } else { 1 }
    $cardWidth = [int][Math]::Floor(($width - ($columns - 1) * $gap) / $columns)
    $rowTop = 0
    for ($start = 0; $start -lt $cards.Count; $start += $columns) {
        $rowHeight = 0
        for ($column = 0; $column -lt $columns -and ($start + $column) -lt $cards.Count; $column++) {
            $card = $cards[$start + $column]
            $cardHeight = Scale-MetricPixel (42 + 62 * $card.Tag.Rows.Count)
            $card.SetBounds($column * ($cardWidth + $gap), $rowTop, $cardWidth, $cardHeight)
            $card.Tag.Title.Width = $cardWidth - (Scale-MetricPixel 24)
            foreach ($entry in $card.Tag.Rows) {
                $entry.Name.Width = $cardWidth - (Scale-MetricPixel 88)
                $entry.Percent.Left = $cardWidth - (Scale-MetricPixel 70)
                $entry.Track.Width = $cardWidth - (Scale-MetricPixel 24)
                $entry.Fill.Width = [int][Math]::Round($entry.Track.Width * $entry.Value / 100)
                $entry.Reset.Width = $cardWidth - (Scale-MetricPixel 24)
            }
            $rowHeight = [Math]::Max($rowHeight, $cardHeight)
        }
        $rowTop += $rowHeight + $gap
    }
    $script:quotaCards.AutoScrollMinSize = New-Object System.Drawing.Size(0, $rowTop)
}

function Render-QuotaCards {
    param([object[]]$Rows)
    Clear-QuotaCards
    if (-not $Rows -or $Rows.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = '点击“刷新当前账号额度”后，在这里查看各周期剩余量。'
        $empty.ForeColor = [System.Drawing.Color]::FromArgb(105, 118, 135)
        $empty.AutoEllipsis = $true
        $empty.Location = New-Object System.Drawing.Point((Scale-MetricPixel 6), (Scale-MetricPixel 10))
        $empty.Size = New-Object System.Drawing.Size(([Math]::Max(1, $script:quotaCards.ClientSize.Width - (Scale-MetricPixel 12))), (Scale-MetricPixel 38))
        $script:quotaCards.Controls.Add($empty)
        return
    }
    $groups = @($Rows | Group-Object { ([string]$_.Name -split ' / ', 2)[0] } | Sort-Object @{ Expression = { if ($_.Name -match '^Claude') { 0 } elseif ($_.Name -match '^Gemini( Models)?$') { 1 } else { 2 } } }, Name)
    foreach ($group in $groups) {
        $items = @($group.Group | Sort-Object @{ Expression = { if ($_.Window -eq '5h') { 0 } elseif ($_.Window -eq 'weekly') { 1 } else { 2 } } })
        $card = New-Object System.Windows.Forms.Panel
        $card.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.Text = ([string]$group.Name -replace '(?i) models$', '')
        $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
        $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 43, 60)
        $titleLabel.SetBounds((Scale-MetricPixel 12), (Scale-MetricPixel 9), (Scale-MetricPixel 250), (Scale-MetricPixel 26))
        $card.Controls.Add($titleLabel)
        $entries = @()
        for ($i = 0; $i -lt $items.Count; $i++) {
            $row = $items[$i]
            $top = Scale-MetricPixel (40 + 62 * $i)
            $label = New-Object System.Windows.Forms.Label
            $label.Text = switch ([string]$row.Window) { '5h' { '5 小时' } 'weekly' { '每周' } default { ([string]$row.Name -split ' / ', 2)[-1] } }
            $label.ForeColor = [System.Drawing.Color]::FromArgb(68, 83, 104)
            $label.SetBounds((Scale-MetricPixel 12), $top, (Scale-MetricPixel 190), (Scale-MetricPixel 20))
            $card.Controls.Add($label)
            $percent = New-Object System.Windows.Forms.Label
            $hasQuota = $null -ne $row.RemainingPercent
            $percent.Text = if ($hasQuota) { '{0}%' -f $row.RemainingPercent } else { [string]$row.StatusText }
            $percent.TextAlign = 'MiddleRight'
            $percent.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            $remaining = [Math]::Max(0, [Math]::Min(100, [int]$row.RemainingPercent))
            $remainingColor = if (-not $hasQuota) { [System.Drawing.Color]::FromArgb(105, 118, 135) } elseif ($remaining -le 20) { [System.Drawing.Color]::FromArgb(191, 62, 50) } elseif ($remaining -le 50) { [System.Drawing.Color]::FromArgb(172, 111, 22) } else { [System.Drawing.Color]::FromArgb(21, 151, 81) }
            $percent.ForeColor = $remainingColor
            $percent.SetBounds((Scale-MetricPixel 200), $top, (Scale-MetricPixel 58), (Scale-MetricPixel 20))
            $card.Controls.Add($percent)
            $track = New-Object System.Windows.Forms.Panel
            $track.BackColor = [System.Drawing.Color]::FromArgb(224, 231, 239)
            $track.Visible = $hasQuota
            $track.SetBounds((Scale-MetricPixel 12), ($top + (Scale-MetricPixel 23)), (Scale-MetricPixel 250), (Scale-MetricPixel 6))
            $fill = New-Object System.Windows.Forms.Panel
            $fill.BackColor = $remainingColor
            $fill.Height = $track.Height
            $track.Controls.Add($fill)
            $card.Controls.Add($track)
            $reset = New-Object System.Windows.Forms.Label
            $reset.Text = $(if ($hasQuota) { '重置：' } else { '' }) + [string]$row.Reset
            $reset.ForeColor = [System.Drawing.Color]::FromArgb(105, 118, 135)
            $reset.SetBounds((Scale-MetricPixel 12), ($top + (Scale-MetricPixel 34)), (Scale-MetricPixel 250), (Scale-MetricPixel 20))
            $card.Controls.Add($reset)
            $entries += [pscustomobject]@{ Name = $label; Percent = $percent; Track = $track; Fill = $fill; Reset = $reset; Value = $remaining }
        }
        $card.Tag = [pscustomobject]@{ Title = $titleLabel; Rows = $entries }
        $script:quotaCards.Controls.Add($card)
    }
    Layout-QuotaCards
}

function Update-MetricsDisplay {
    $active = @($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false -and -not $_.Problem -and $_.Provider -eq 'Antigravity' })
    if ($active.Count -ne 1) {
        $script:quotaRefreshButton.Text = '查询额度'
        $script:metricsAccountLabel.Text = '账号：没有格式完整且单独启用的 Antigravity 授权账号'
        $script:usageSummaryLabel.Text = '今日请求：—   成功率：—   平均延迟：—'
        $script:tokenSummaryLabel.Text = '今日 Token：—   输入：—   输出：—   缓存：—   推理：—'
        $script:quotaStatusLabel.Text = '额度：请先完成授权并只启用一个账号。'
        $script:quotaRefreshButton.Enabled = $false
        if ($script:lastQuotaSignature -ne 'no-account') { Render-QuotaCards -Rows @() }
        $script:lastQuotaSignature = 'no-account'
        return
    }
    $account = $active[0].DisplayName.ToLowerInvariant()
    $quotaBusy = $null -ne $script:quotaProcess
    $workflowBusy = $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')
    $script:quotaRefreshButton.Enabled = ($script:portReachable -and $script:servicePortProcess -and -not $quotaBusy -and -not $workflowBusy)
    $script:quotaRefreshButton.Text = if ($quotaBusy) { '查询中…' } else { '查询额度' }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $buckets = @()
    $readError = $false
    $collectorStatus = '等待首次采集'
    try {
        if ([IO.File]::Exists($script:usagePath)) {
            $state = [IO.File]::ReadAllText($script:usagePath) | ConvertFrom-Json
            $buckets = @($state.Buckets | Where-Object { $_.Account -eq $account -and $_.Day -eq $today })
            if ($state.LastError) { $collectorStatus = '采集异常' }
            else {
                $lastPoll = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$state.LastPollAt, [ref]$lastPoll)) {
                    $collectorStatus = if (((Get-Date) - $lastPoll.LocalDateTime).TotalSeconds -le 20) { '采集中' } else { '采集已中断' }
                }
            }
        }
    }
    catch { $readError = $true; $collectorStatus = '用量文件读取失败'; $buckets = @() }
    if (-not $script:portReachable) { $collectorStatus = '服务未连接' }
    $script:metricsAccountLabel.Text = '账号：{0} · 用量采集：{1}' -f $account, $collectorStatus
    $buttonTips.SetToolTip($script:metricsAccountLabel, '仅统计代理已归属到该账号的请求。' + $script:metricsAccountLabel.Text)
    $requests = 0L; $failed = 0L; $latencySum = 0L; $latencyReports = 0L
    $totalTokens = 0L; $inputTokens = 0L; $outputTokens = 0L; $cachedTokens = 0L; $reasoningTokens = 0L; $tokenReports = 0L
    foreach ($bucket in $buckets) {
        $requests += [long]$bucket.Requests; $failed += [long]$bucket.Failed
        $latencySum += [long]$bucket.LatencySumMs; $latencyReports += [long]$bucket.LatencyReports
        $totalTokens += [long]$bucket.TotalTokens; $inputTokens += [long]$bucket.InputTokens
        $outputTokens += [long]$bucket.OutputTokens; $cachedTokens += [long]$bucket.CachedTokens
        $reasoningTokens += [long]$bucket.ReasoningTokens; $tokenReports += [long]$bucket.TokenReports
    }
    $successRate = if ($requests -gt 0) { '{0:N1}%' -f (100.0 * ($requests - $failed) / $requests) } else { '—' }
    $averageLatency = if ($latencyReports -gt 0) { '{0:N0} ms' -f ($latencySum / $latencyReports) } else { '—' }
    $script:usageSummaryLabel.Text = if ($readError) { '今日用量记录暂时无法读取。' }
    elseif ($collectorStatus -eq '等待首次采集') { '今日请求：—   成功率：—   平均延迟：—' }
    else { '今日请求：{0:N0}（失败 {1:N0}）   成功率：{2}   平均延迟：{3}' -f $requests, $failed, $successRate, $averageLatency }
    $script:tokenSummaryLabel.Text = if ($readError) { '今日 Token：本地记录暂时无法读取' }
    elseif ($collectorStatus -eq '等待首次采集') { '今日 Token：等待首次采集' }
    elseif ($tokenReports -gt 0) {
        '今日 Token：{0:N0}   输入：{1:N0}   输出：{2:N0}   缓存：{3:N0}   推理：{4:N0}（{5} 次有用量）' -f $totalTokens, $inputTokens, $outputTokens, $cachedTokens, $reasoningTokens, $tokenReports
    } else { '今日 Token：暂无上游返回的用量数据' }

    if ($script:quotaProcess -and -not $script:quotaProcess.HasExited) {
        $script:quotaStatusLabel.Text = '额度：正在查询当前账号，请稍候…'
        return
    }
    $quota = $null
    $signature = $account
    try {
        if ([IO.File]::Exists($script:quotaPath)) {
            $info = Get-Item -LiteralPath $script:quotaPath
            $signature += '|{0}|{1}' -f $info.Length, $info.LastWriteTimeUtc.Ticks
            $quota = [IO.File]::ReadAllText($script:quotaPath) | ConvertFrom-Json
        }
    }
    catch { $script:quotaStatusLabel.Text = '额度：本地结果暂时无法读取。'; return }
    if ($signature -eq $script:lastQuotaSignature) { return }
    $script:lastQuotaSignature = $signature
    Render-QuotaCards -Rows @()
    if (-not $quota -or $quota.Account -ne $active[0].Name) {
        $script:quotaStatusLabel.Text = '额度：等待自动刷新，也可点击“查询额度”。'
        return
    }
    if ($quota.Status -ne 'ok') {
        $script:quotaStatusLabel.Text = '额度：获取失败，{0}' -f $quota.Error
        return
    }
    $script:quotaStatusLabel.Text = '额度：上游返回于 {0}；剩余比例不等于 Token 余额。' -f $quota.FetchedAt
    Render-QuotaCards -Rows @($quota.Rows)
}

function Get-ActiveQuotaAccount {
    $active = @($script:authSnapshot.Rows | Where-Object { $_.Disabled -eq $false })
    if ($active.Count -eq 1 -and -not $active[0].Problem -and $active[0].Provider -eq 'Antigravity') { return $active[0] }
}

function Set-QuotaAutoSwitch {
    param([bool]$Enabled, [ValidateSet('Claude', 'Gemini')][string]$Family = 'Claude')
    if ($Family -eq 'Gemini') {
        $script:geminiAutoSwitchEnabled = $Enabled
        $button = $script:geminiAutoSwitchButton
        $familyLabel = 'Gemini'
    }
    else {
        $script:quotaAutoSwitchEnabled = $Enabled
        $button = $script:quotaAutoSwitchButton
        $familyLabel = 'Claude / GPT'
    }
    $script:quotaExhaustedUntil = @{}
    $script:quotaAutomationNotice = ''
    $button.Text = '{0} 耗尽自动切号：{1}' -f $Family, $(if ($Enabled) { '开' } else { '关' })
    Set-PanelButtonStyle $button
    if ($Enabled) {
        $button.BackColor = [System.Drawing.Color]::FromArgb(229, 246, 237)
        $button.ForeColor = [System.Drawing.Color]::FromArgb(22, 112, 77)
        $script:nextQuotaRefreshAt = Get-Date
        Write-Activity ('已开启 {0} 额度耗尽自动切号；按账号列表顺序，一次只启用一个账号。' -f $familyLabel)
    }
    else { Write-Activity ('已关闭 {0} 额度耗尽自动切号；当前账号保持不变。' -f $familyLabel) }
}

function Start-QuotaRefresh {
    param([switch]$Manual)
    $active = Get-ActiveQuotaAccount
    if (-not $active -or $script:quotaProcess -or -not $script:portReachable -or -not $script:servicePortProcess -or
        $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) { return }
    $script:quotaObservedAccount = $active.Name
    $script:nextQuotaRefreshAt = (Get-Date).AddMinutes(10)
    $script:quotaRunId = [guid]::NewGuid().ToString('N')
    try {
        $arguments = @('-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-File', ('"' + $script:metricsPath + '"'), '-Quota', '-AuthFile', ('"' + $active.Name + '"'), '-RunId', $script:quotaRunId)
        $script:quotaProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru
        $script:quotaRefreshButton.Enabled = $false
        $script:quotaRefreshButton.Text = '查询中…'
        $script:quotaStatusLabel.Text = '额度：正在查询当前账号，请稍候…'
        if ($Manual) { Write-Activity ('已开始查询 {0} 的额度。' -f $active.DisplayName) }
    }
    catch { $script:quotaStatusLabel.Text = '额度：无法启动查询，' + $_.Exception.Message }
}

function Update-QuotaAutomation {
    $active = Get-ActiveQuotaAccount
    $now = Get-Date
    if (-not $active -or -not $script:portReachable -or -not $script:servicePortProcess) {
        $text = '每 10 分钟刷新 · 等待服务及单个可用账号'
    }
    elseif ($script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) {
        $text = '每 10 分钟刷新 · 授权期间暂停查询与切号'
    }
    else {
        if ($script:quotaObservedAccount -ne $active.Name) {
            $script:quotaObservedAccount = $active.Name
            $script:nextQuotaRefreshAt = $now.AddSeconds(2)
        }
        if (-not $script:quotaProcess -and $now -ge $script:nextQuotaRefreshAt) { Start-QuotaRefresh }
        $seconds = [Math]::Max(0, [int][Math]::Ceiling(($script:nextQuotaRefreshAt - (Get-Date)).TotalSeconds))
        $text = if ($script:quotaProcess) { '每 10 分钟刷新 · 正在查询' } else { '每 10 分钟刷新 · 下次 {0:00}:{1:00}' -f [int][Math]::Floor($seconds / 60), ($seconds % 60) }
    }
    if ($script:quotaAutomationNotice) { $text = $script:quotaAutomationNotice }
    $script:quotaScheduleLabel.Text = $text
    $buttonTips.SetToolTip($script:quotaScheduleLabel, $text + '。关闭面板后停止自动刷新和自动切号。')
}

function Invoke-QuotaAutoSwitch {
    param($Result)
    $active = Get-ActiveQuotaAccount
    if ((-not $script:quotaAutoSwitchEnabled -and -not $script:geminiAutoSwitchEnabled) -or -not $active -or $Result.Status -ne 'ok' -or
        $Result.RunId -ne $script:quotaRunId -or $Result.Account -ne $active.Name -or
        -not $script:portReachable -or -not $script:servicePortProcess -or
        $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) { return }
    $quotaRows = @($Result.Rows | Where-Object {
        ($script:quotaAutoSwitchEnabled -and $_.Group -match '^Claude( and GPT)?( models)?$') -or
        ($script:geminiAutoSwitchEnabled -and $_.Group -match '^Gemini\b')
    })
    if ($quotaRows.Count -eq 0) { return }
    $exhausted = @($quotaRows | Where-Object {
        $fraction = 0.0
        $null -ne $_.RemainingFraction -and
        [double]::TryParse([string]$_.RemainingFraction, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$fraction) -and $fraction -eq 0
    })
    if ($exhausted.Count -eq 0) {
        [void]$script:quotaExhaustedUntil.Remove($active.Name)
        $script:quotaAutomationNotice = ''
        return
    }
    $now = Get-Date
    $until = $now.AddMinutes(10)
    $familyLabel = (@($exhausted | ForEach-Object { if ($_.Group -match '^Gemini') { 'Gemini' } else { 'Claude / GPT' } } | Select-Object -Unique) -join '、')
    foreach ($row in $exhausted) {
        $resetAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$row.ResetAt, [ref]$resetAt)) { $until = [DateTime]::MaxValue; break }
        if ($resetAt.LocalDateTime -gt $until) { $until = $resetAt.LocalDateTime }
    }
    $script:quotaExhaustedUntil[$active.Name] = $until
    $accounts = @($script:authSnapshot.Rows | Where-Object { $_.Provider -eq 'Antigravity' -and -not $_.Problem -and $null -ne $_.Disabled } | Sort-Object DisplayName)
    $currentIndex = 0
    for ($i = 0; $i -lt $accounts.Count; $i++) { if ($accounts[$i].Name -eq $active.Name) { $currentIndex = $i; break } }
    $next = $null
    for ($offset = 1; $offset -lt $accounts.Count; $offset++) {
        $candidate = $accounts[($currentIndex + $offset) % $accounts.Count]
        if (-not $script:quotaExhaustedUntil.ContainsKey($candidate.Name) -or $script:quotaExhaustedUntil[$candidate.Name] -le $now) {
            $next = $candidate; break
        }
    }
    if (-not $next) {
        $notice = '{0} 额度耗尽 · 无可切换账号，等待额度恢复' -f $familyLabel
        if ($script:quotaAutomationNotice -ne $notice) { Write-Activity $notice }
        $script:quotaAutomationNotice = $notice
        return
    }
    try {
        Switch-ToAccount -FileName $next.Name
        Refresh-Dashboard
        $script:quotaAutomationNotice = '已自动切换：' + $next.DisplayName
        Write-Activity ('{0} 的 {1} 额度耗尽，已切换为只使用 {2}；稍后查询新账号额度。' -f $active.DisplayName, $familyLabel, $next.DisplayName)
    }
    catch {
        $message = $_.Exception.Message
        Set-QuotaAutoSwitch -Enabled $false
        Set-QuotaAutoSwitch -Family Gemini -Enabled $false
        $script:quotaAutomationNotice = '自动切号失败，已关闭开关；请检查账号列表'
        Write-Activity ('自动切号失败：' + $message)
        Refresh-Dashboard
    }
}

function Update-QuotaProcess {
    if (-not $script:quotaProcess -or -not $script:quotaProcess.HasExited) { return }
    $exitCode = $script:quotaProcess.ExitCode
    $script:quotaProcess.Dispose()
    $script:quotaProcess = $null
    try {
        $result = [IO.File]::ReadAllText($script:quotaPath) | ConvertFrom-Json
        if ($result.RunId -ne $script:quotaRunId) { throw '查询没有生成对应结果。' }
        $script:lastQuotaSignature = ''
        Update-MetricsDisplay
        Invoke-QuotaAutoSwitch -Result $result
    }
    catch { $script:quotaStatusLabel.Text = '额度查询未完成（退出代码 {0}）：{1}' -f $exitCode, $_.Exception.Message }
}

function Set-WorkflowControls {
    $isActive = $script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')
    $script:startButton.Enabled = -not $isActive
    $script:loginButton.Enabled = (-not $isActive -and $script:servicePortProcess)
    $script:stopButton.Enabled = (-not $isActive -and $script:servicePortProcess)
    $script:serviceOnlyButton.Enabled = (-not $isActive -and -not ($script:portReachable -and $script:servicePortProcess))
    Update-AccountSwitchControls
    if ($isActive) {
        $script:startButton.Text = '处理中…'
    }
    else {
        $script:startButton.Text = if ($script:portReachable -and $script:servicePortProcess) { '打开授权（服务已运行）' } else { '启动并打开授权' }
    }
}

function Fail-Workflow {
    param([string]$Message)
    Restore-AccountAfterFailedAuthorization
    $script:workflowPhase = 'failed'
    $script:authWatchEnabled = $false
    $script:loginProcess = $null
    if ($script:portReachable -and $script:servicePortProcess) {
        Set-ProgressState 55 $Message
    }
    else {
        Set-ProgressState 0 $Message
    }
    if (-not $script:authChangedSinceStart) {
        $script:currentAccountLabel.Text = '本次记录更新：未确认'
    }
    Write-Activity $Message
    Set-WorkflowControls
}

function Complete-Workflow {
    param([string]$Message, [bool]$WasSuccessful)
    $script:authWatchEnabled = $false
    if ($WasSuccessful) {
        $script:workflowPhase = 'complete'
        Save-LastAuthorizedAccount
        $changedRows = @($script:authSnapshot.Rows | Where-Object { $script:authChangedNames.ContainsKey($_.Name) } | Sort-Object Updated -Descending)
        if ($changedRows.Count -gt 0) {
            $selectedName = $changedRows[0].Name
            try {
                foreach ($row in @($script:authSnapshot.Rows | Where-Object { $_.Name -ne $selectedName -and $_.Disabled -eq $false })) {
                    Set-AuthFileDisabled -FileName $row.Name -Disabled $true
                }
                Set-AuthFileDisabled -FileName $selectedName -Disabled $false
                Write-Activity ('本次授权后已只启用 {0}。' -f $changedRows[0].DisplayName)
            }
            catch { Write-Activity ('新账号启用失败，请在列表中手动选择：' + $_.Exception.Message) }
        }
        $script:accountBeforeAuthorization = $null
        Refresh-Dashboard
        Set-ProgressState 100 $Message
    }
    else {
        Restore-AccountAfterFailedAuthorization
        $script:workflowPhase = 'unconfirmed'
        $script:currentAccountLabel.Text = '本次记录更新：未确认'
        if ($script:portReachable -and $script:servicePortProcess) {
            Set-ProgressState 55 $Message
        }
        else {
            Set-ProgressState 0 $Message
        }
    }
    Write-Activity $Message
    Set-WorkflowControls
}

function Start-LoginProcess {
    if (-not (Test-Path -LiteralPath $script:exePath -PathType Leaf) -or -not (Test-Path -LiteralPath $script:configPath -PathType Leaf)) {
        Fail-Workflow '程序或配置文件缺失，未能打开授权流程。'
        return
    }

    $snapshot = Get-AuthSnapshot
    $previous = @($snapshot.Rows | Where-Object { $_.Disabled -eq $false })
    $script:accountBeforeAuthorization = if ($previous.Count -eq 1) { $previous[0].Name } else { $null }
    try {
        foreach ($row in $previous) {
            Set-AuthFileDisabled -FileName $row.Name -Disabled $true
        }
    }
    catch {
        Fail-Workflow ('无法暂停旧账号，授权未启动：' + $_.Exception.Message)
        return
    }
    $snapshot = Get-AuthSnapshot
    $script:authBaselineSignature = $snapshot.Signature
    $script:authBaselineMap = @{}
    foreach ($row in @($snapshot.Rows)) {
        $script:authBaselineMap[$row.Name] = $row.Signature
    }
    $script:authChangedNames = @{}
    $script:authChangedSinceStart = $false
    $script:authWatchEnabled = $true
    $script:lastListSignature = $null
    $script:currentAccountLabel.Text = '本次记录更新：等待浏览器授权…'
    try {
        $loginCommand = '""{0}" --login"' -f $script:launcherPath
        $script:loginProcess = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', $loginCommand) -WorkingDirectory $PSScriptRoot -WindowStyle Normal -PassThru
        $script:workflowPhase = 'waiting-auth'
        $script:workflowStartedAt = Get-Date
        $script:waitNoticeLogged = $false
        Set-ProgressState 78 '授权窗口已打开；等待浏览器完成登录并检查本地记录。' $true
        Write-Activity '授权窗口已打开。请在浏览器中选择并确认账号。'
        Set-WorkflowControls
    }
    catch {
        Fail-Workflow ('授权窗口启动失败：' + $_.Exception.Message + '。请查看 Windows 安全提示。')
    }
}

function Begin-LaunchWorkflow {
    param([bool]$OpenAuthorization = $true)
    if ($script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:exePath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('找不到 cli-proxy-api.exe。请检查 Downloads 中的 CLIProxyAPI 文件夹。', '程序缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (-not (Read-LaunchConfig)) {
        [System.Windows.Forms.MessageBox]::Show('找不到 config.yaml。请检查 CLIProxyAPI 文件夹。', '配置缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($script:configuredPort -le 0) {
        [System.Windows.Forms.MessageBox]::Show('config.yaml 中没有可读取的服务端口，暂时无法检测接口状态。', '配置不完整', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Refresh-Dashboard
    $script:authWatchEnabled = $false
    $script:authChangedSinceStart = $false
    $script:authChangedNames = @{}
    $script:authBaselineSignature = $null
    $script:authBaselineMap = @{}
    $script:lastListSignature = $null
    $script:currentAccountLabel.Text = if ($OpenAuthorization) { '本次记录更新：等待浏览器授权…' } else { '本次记录更新：尚未开始' }
    $script:openAuthorizationAfterService = $OpenAuthorization
    $script:workflowStartedAt = Get-Date
    $script:waitNoticeLogged = $false
    Set-ProgressState 8 '正在检查程序、配置和本机端口…'
    Write-Activity '开始启动流程。'

    if ($script:portReachable -and -not $script:servicePortProcess) {
        Fail-Workflow ('端口 {0} 已被其他程序占用；为避免启动重复服务，已停止本次流程。' -f $script:configuredPort)
        return
    }
    if ($script:servicePortProcess -and -not $script:portReachable) {
        Fail-Workflow ('代理程序已监听端口 {0}，但本机接口无法连接；未启动第二个实例。' -f $script:configuredPort)
        return
    }

    if ($script:portReachable) {
        if ($OpenAuthorization) {
            $script:workflowPhase = 'delay-before-login'
            $script:phaseStartedAt = Get-Date
            Set-ProgressState 55 '检测到代理服务已运行，将直接准备授权窗口。'
            Write-Activity '复用已运行的代理服务，没有再启动第二个实例。'
        }
        else {
            $script:workflowPhase = 'service-ready'
            Set-ProgressState 100 '代理服务已在运行；未打开授权窗口。'
            Write-Activity '代理服务已在运行，没有再启动第二个实例。'
        }
    }
    else {
        try {
            $serviceCommand = '""{0}" --service"' -f $script:launcherPath
            Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', $serviceCommand) -WorkingDirectory $PSScriptRoot -WindowStyle Normal | Out-Null
            $script:workflowPhase = 'waiting-service'
            Set-ProgressState 15 '服务进程已启动，正在等待本机接口监听…'
            Write-Activity '已启动代理服务，正在检测本机接口。'
        }
        catch {
            Fail-Workflow ('代理服务启动失败：' + $_.Exception.Message)
            return
        }
    }
    Set-WorkflowControls
}

function Begin-LoginOnly {
    if ($script:workflowPhase -in @('waiting-service', 'delay-before-login', 'waiting-auth')) {
        return
    }
    Refresh-Dashboard
    if (-not $script:servicePortProcess -or -not $script:portReachable) {
        [System.Windows.Forms.MessageBox]::Show('代理服务尚未就绪。请先点击“启动并打开授权”。', '服务未就绪', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Write-Activity '按下“重新打开授权”，将复用当前代理服务。'
    Start-LoginProcess
}

function Advance-Workflow {
    if ($script:workflowPhase -eq 'waiting-service') {
        if ($script:portReachable -and $script:servicePortProcess) {
            if ($script:openAuthorizationAfterService) {
                $script:workflowPhase = 'delay-before-login'
                $script:phaseStartedAt = Get-Date
                Set-ProgressState 55 '本机接口已就绪，3 秒后打开授权窗口。'
            }
            else {
                $script:workflowPhase = 'service-ready'
                Set-ProgressState 100 '代理服务已就绪；未打开授权窗口。'
                Set-WorkflowControls
            }
            Write-Activity ('本机接口 127.0.0.1:{0} 已可连接。' -f $script:configuredPort)
        }
        elseif (((Get-Date) - $script:workflowStartedAt).TotalSeconds -ge 30) {
            Fail-Workflow '等待本机接口超时。请查看代理服务窗口中的错误信息。'
        }
        else {
            $elapsed = [int]((Get-Date) - $script:workflowStartedAt).TotalSeconds
            $progress = [Math]::Min(48, 15 + ($elapsed * 1))
            Set-ProgressState $progress '服务正在启动，等待本机接口开始监听…'
        }
        return
    }

    if ($script:workflowPhase -eq 'delay-before-login') {
        if (((Get-Date) - $script:phaseStartedAt).TotalSeconds -ge 3) {
            Start-LoginProcess
        }
        return
    }

    if ($script:workflowPhase -eq 'waiting-auth') {
        if ($script:authChangedSinceStart -and $script:loginProcess -and -not $script:loginProcess.HasExited) {
            Set-ProgressState 90 '已检测到本地记录更新，正在等待登录程序结束…' $true
        }
        if ($script:loginProcess -and $script:loginProcess.HasExited) {
            $exitCode = $script:loginProcess.ExitCode
            $script:loginProcess = $null
            if ($exitCode -eq 0 -and $script:authChangedSinceStart) {
                Complete-Workflow '本地授权记录已保存；上游账号能否调用模型仍需验证。' $true
            }
            elseif ($exitCode -eq 0) {
                Complete-Workflow '授权未确认：浏览器回调已到达不代表凭证保存；本地记录未更新，请查看登录窗口信息。' $false
            }
            else {
                Fail-Workflow ('登录程序退出代码为 {0}。请查看登录窗口或运行记录。' -f $exitCode)
            }
        }
        elseif (-not $script:waitNoticeLogged -and ((Get-Date) - $script:workflowStartedAt).TotalSeconds -ge 60) {
            $script:waitNoticeLogged = $true
            Write-Activity '仍在等待浏览器授权；完成后会自动检查本地授权记录。'
        }
    }
}

$script:refreshButton.Add_Click({
    Refresh-Dashboard
    Write-Activity '已手动刷新服务、端口和本地授权记录状态。'
})

function Get-LocalCheckReport {
    Refresh-Dashboard
    $programStatus = if (Test-Path -LiteralPath $script:exePath -PathType Leaf) { '已找到' } else { '缺失' }
    $configStatus = if (Test-Path -LiteralPath $script:configPath -PathType Leaf) { '已找到' } else { '缺失' }
    $directoryStatus = if ($script:authDirectory -and (Test-Path -LiteralPath $script:authDirectory -PathType Container)) { '已找到' } else { '未找到' }
    $serviceStatus = if ($script:portReachable -and $script:servicePortProcess) {
        '运行中，PID {0}' -f $script:servicePortProcess.Id
    } elseif ($script:portReachable) {
        '端口有响应，但进程与本助手不匹配'
    } else {
        '未检测到可连接的本机接口'
    }
    $count = if ($script:authDirectory) { @($script:authSnapshot.Rows).Count } else { '未知' }
    return @(
        '程序文件：' + $programStatus,
        '配置文件：' + $configStatus,
        '配置端口：' + $script:configuredPort,
        '代理服务：' + $serviceStatus,
        '授权目录：' + $directoryStatus,
        '本地账号记录：' + $count,
        '',
        '本检查不发送模型请求，也不验证上游账号有效性。'
    ) -join [Environment]::NewLine
}

$script:selfCheckButton.Add_Click({
    try {
        $report = Get-LocalCheckReport
        [System.Windows.Forms.MessageBox]::Show($report, '本机自检结果', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        Write-Activity '已完成本机自检。'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '本机自检失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$script:startButton.Add_Click({ Begin-LaunchWorkflow })
$script:serviceOnlyButton.Add_Click({ Begin-LaunchWorkflow -OpenAuthorization:$false })
$script:loginButton.Add_Click({ Begin-LoginOnly })
$script:moreButton.Add_Click({
    $script:showMore = -not $script:showMore
    foreach ($button in $script:advancedButtons) { $button.Visible = $script:showMore }
    $script:moreButton.Text = if ($script:showMore) { '收起功能  ▴' } else { '更多功能  ▾' }
    $script:layout.Reflow()
})
$script:accountToggleButton.Add_Click({
    $expanded = -not $script:accountList.Visible
    $script:accountList.Visible = $expanded
    $script:switchAccountButton.Visible = $expanded
    $script:accountToggleButton.Text = if ($expanded) { '收起账号  ▴' } else { '切换账号  ▾' }
    $script:layout.Reflow()
})
$script:logsToggleButton.Add_Click({
    $script:showLogs = -not $script:showLogs
    $script:activityList.Visible = $script:showLogs
    $script:copyActivityButton.Visible = $script:showLogs
    $script:clearActivityButton.Visible = $script:showLogs
    $script:logsToggleButton.Text = if ($script:showLogs) { '收起运行日志  ▴' } else { '查看运行日志  ▾' }
    $script:layout.Reflow()
    if ($script:showLogs) { $form.ScrollControlIntoView($script:activityList) }
})

$script:accountList.Add_SelectedIndexChanged({
    $script:copyAccountButton.Enabled = ($script:accountList.SelectedItems.Count -gt 0 -and $null -ne $script:accountList.SelectedItems[0].Tag)
    $script:locateAccountButton.Enabled = $script:copyAccountButton.Enabled
    Update-AccountSwitchControls
})

$script:switchAccountButton.Add_Click({ Switch-ToSelectedAccount })
$script:restoreAccountsButton.Add_Click({ Pause-AllAccounts })

$script:quotaRefreshButton.Add_Click({
    Refresh-Dashboard
    Start-QuotaRefresh -Manual
})
$script:quotaAutoSwitchButton.Add_Click({ Set-QuotaAutoSwitch -Enabled (-not $script:quotaAutoSwitchEnabled) })
$script:geminiAutoSwitchButton.Add_Click({ Set-QuotaAutoSwitch -Family Gemini -Enabled (-not $script:geminiAutoSwitchEnabled) })

$script:copyAccountButton.Add_Click({
    if ($script:accountList.SelectedItems.Count -eq 0 -or $null -eq $script:accountList.SelectedItems[0].Tag) { return }
    $accountName = $script:accountList.SelectedItems[0].Text
    [System.Windows.Forms.Clipboard]::SetText($accountName)
    Write-Activity ('已复制选中账号：{0}' -f $accountName)
})

$script:locateAccountButton.Add_Click({
    if ($script:accountList.SelectedItems.Count -eq 0 -or -not $script:authDirectory) { return }
    $fileName = [string]$script:accountList.SelectedItems[0].Tag
    if ($fileName -ne [System.IO.Path]::GetFileName($fileName)) { return }
    $filePath = Join-Path $script:authDirectory $fileName
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('选中的授权文件已不存在，请先刷新状态。', '文件未找到', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $filePath + '"') | Out-Null
})

$script:stopButton.Add_Click({
    Refresh-Dashboard
    $target = $script:servicePortProcess
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show('没有找到可由面板确认的服务进程。', '无法停止', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $question = '确定停止 CLIProxyAPI 服务（PID {0}）吗？正在处理的请求会中断。' -f $target.Id
    $choice = [System.Windows.Forms.MessageBox]::Show($question, '停止代理服务', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $verified = Get-PortOwnerProcess
    if (-not $verified -or $verified.Id -ne $target.Id -or $verified.StartTime -ne $target.StartTime) {
        Refresh-Dashboard
        Write-Activity '服务进程在确认期间已变化，未执行停止操作。'
        return
    }
    try {
        Stop-Process -Id $verified.Id -Force -ErrorAction Stop
        $script:workflowPhase = 'stopped'
        $script:authWatchEnabled = $false
        Set-ProgressState 0 '代理服务已停止；账号记录仍保留在本地。'
        Write-Activity ('已停止代理服务 PID {0}。' -f $verified.Id)
        Refresh-Dashboard
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '停止失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$script:copyAddressButton.Add_Click({
    Refresh-Dashboard
    if ($script:configuredPort -gt 0) {
        $address = 'http://127.0.0.1:{0}/v1' -f $script:configuredPort
        [System.Windows.Forms.Clipboard]::SetText($address)
        Write-Activity ('已复制本机接口地址 {0}。' -f $address)
    }
})

$script:openFolderButton.Add_Click({
    Refresh-Dashboard
    if ($script:authDirectory -and (Test-Path -LiteralPath $script:authDirectory -PathType Container)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:authDirectory + '"') | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('授权目录尚不存在；完成一次登录后，CLIProxyAPI 会写入本地记录。', '授权目录不存在', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})

$script:openConfigButton.Add_Click({
    if (Test-Path -LiteralPath $script:configPath -PathType Leaf) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:configPath + '"') | Out-Null
        Write-Activity '已在记事本中打开配置文件；保存修改后需重启服务才能生效。'
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('找不到 config.yaml。', '配置缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$script:openProgramButton.Add_Click({
    if (Test-Path -LiteralPath $script:cliFolder -PathType Container) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:cliFolder + '"') | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('找不到 CLIProxyAPI 程序目录。', '目录缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$script:copyActivityButton.Add_Click({
    if ($script:activityList.Items.Count -eq 0) { return }
    $lines = @($script:activityList.Items | ForEach-Object { [string]$_ })
    [System.Windows.Forms.Clipboard]::SetText(($lines -join [Environment]::NewLine))
    Write-Activity '已复制面板运行记录。'
})

$script:clearActivityButton.Add_Click({
    $script:activityList.Items.Clear()
    $script:copyActivityButton.Enabled = $false
    $script:clearActivityButton.Enabled = $false
})

$script:copyButton.Add_Click({
    Refresh-Dashboard
    $count = if ($script:authDirectory) { @($script:authSnapshot.Rows).Count } else { 'unknown' }
    $serviceState = if ($script:portReachable -and $script:servicePortProcess) { 'running' } elseif ($script:workflowPhase -eq 'waiting-service') { 'starting' } elseif ($script:portReachable) { 'port occupied by another process' } elseif ($script:configuredPort -le 0) { 'unknown' } else { 'stopped' }
    $apiState = if ($script:portReachable) { 'reachable' } else { 'not reachable' }
    $summary = @(
        'CLIProxyAPI local status',
        ('service={0}' -f $serviceState),
        ('port={0}; api={1}' -f $script:configuredPort, $apiState),
        ('local_auth_records={0}' -f $count),
        ('workflow={0}' -f $script:workflowPhase),
        'Credential validity is not verified by this local summary.'
    ) -join [Environment]::NewLine
    [System.Windows.Forms.Clipboard]::SetText($summary)
    Write-Activity '已复制不含密钥和账号名的状态摘要。'
})

$script:refreshTimer = New-Object System.Windows.Forms.Timer
$script:refreshTimer.Interval = 1200
$script:refreshTimer.Add_Tick({
    try {
        Refresh-Dashboard
        Update-QuotaProcess
        Advance-Workflow
        Update-QuotaAutomation
    }
    catch {
        Set-ProgressState 0 ('状态刷新失败：' + $_.Exception.Message)
    }
})

$form.Add_Shown({
    Read-LastAuthorizedAccount
    Refresh-Dashboard
    Write-Activity '面板已就绪；状态每 1.2 秒刷新，额度每 10 分钟刷新，Claude 和 Gemini 自动切号默认关闭。'
    $script:refreshTimer.Start()
})
$form.Add_FormClosed({
    $script:refreshTimer.Stop()
    $script:refreshTimer.Dispose()
    if ($script:quotaProcess) {
        try { if (-not $script:quotaProcess.HasExited) { $script:quotaProcess.Kill() } }
        catch { }
        finally { $script:quotaProcess.Dispose(); $script:quotaProcess = $null }
    }
})

$dpiScale = [Math]::Max(1.0, [CliProxyDpi]::GetDpiForSystem() / 96.0)
if ($dpiScale -gt 1.0) {
    $form.Scale([System.Drawing.SizeF]::new([single]$dpiScale, [single]$dpiScale))
    foreach ($column in $script:accountList.Columns) {
        $column.Width = [int][Math]::Round($column.Width * $dpiScale)
    }
}
$form.MinimumSize = [System.Drawing.Size]::new([int][Math]::Round(500 * $dpiScale), [int][Math]::Round(480 * $dpiScale))
$screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
$form.Height = [Math]::Min($form.Height, [Math]::Max($form.MinimumSize.Height, [int]($screenHeight * 0.92)))

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

public sealed class CliProxyFluidLayout {
    private readonly Form viewport;
    private readonly double scale;
    private readonly Dictionary<string, Control> controls = new Dictionary<string, Control>();
    private readonly List<Panel> cardPanels = new List<Panel>();
    private readonly List<Label> cardValues = new List<Label>();
    private readonly List<Label> cardDetails = new List<Label>();
    private bool busy;
    private int lastWidth = -1;
    private int lastHeight = -1;

    private static readonly string[] Primary = { "serviceOnlyButton", "loginButton", "stopButton", "moreButton" };
    private static readonly int[] PrimaryWidths = { 230, 200, 160, 160 };
    private static readonly int[] PrimaryMinimums = { 150, 130, 120, 130 };
    private static readonly string[] Advanced = { "startButton", "refreshButton", "selfCheckButton", "copyAddressButton", "openFolderButton", "openConfigButton", "openProgramButton", "copyAccountButton", "copyButton", "restoreAccountsButton", "locateAccountButton" };
    private static readonly int[] AdvancedWidths = { 160, 120, 120, 125, 125, 125, 125, 125, 125, 125, 155 };
    private static readonly int[] AdvancedMinimums = { 140, 105, 105, 110, 110, 110, 110, 110, 110, 110, 135 };

    public CliProxyFluidLayout(Form viewport, double scale) {
        this.viewport = viewport;
        this.scale = scale;
    }

    public void Register(string name, Control control) {
        controls.Add(name, control);
    }

    public void AddCard(Panel panel, Label value, Label detail) {
        cardPanels.Add(panel);
        cardValues.Add(value);
        cardDetails.Add(detail);
    }

    public void Reflow() {
        lastWidth = -1;
        lastHeight = -1;
        Apply();
    }

    private int P(int value) {
        return (int)Math.Round(value * scale);
    }

    private Control C(string name) {
        return controls[name];
    }

    private void B(Control control, int x, int y, int width, int height) {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        if (control.Left != x || control.Top != y || control.Width != width || control.Height != height) {
            control.SetBounds(x, y, width, height);
        }
    }

    private void B(string name, int x, int y, int width, int height) {
        B(C(name), x, y, width, height);
    }

    private int PlaceButtons(string[] names, int[] preferred, int[] minimums, int left, int top, int contentWidth, int gap) {
        int index = 0;
        int row = 0;
        int height = P(40);
        int rowGap = P(8);
        while (index < names.Length) {
            int count = 0;
            int minimumUsed = 0;
            while (index + count < names.Length) {
                int next = minimumUsed + (count > 0 ? gap : 0) + P(minimums[index + count]);
                if (count > 0 && next > contentWidth) break;
                minimumUsed = next;
                count++;
            }
            int preferredTotal = 0;
            for (int i = 0; i < count; i++) preferredTotal += preferred[index + i];
            int available = contentWidth - (count - 1) * gap;
            int x = left;
            for (int i = 0; i < count; i++) {
                int width = count == 1 ? contentWidth :
                    i == count - 1 ? left + contentWidth - x :
                    (int)Math.Round((double)available * preferred[index + i] / preferredTotal);
                B(names[index + i], x, top + row * (height + rowGap), width, height);
                x += width + gap;
            }
            index += count;
            row++;
        }
        return top + row * height + (row - 1) * rowGap;
    }

    public void Apply() {
        int viewWidth = viewport.ClientSize.Width;
        int viewHeight = viewport.ClientSize.Height;
        if (busy || viewWidth <= 0 || viewHeight <= 0 || (viewWidth == lastWidth && viewHeight == lastHeight)) return;
        busy = true;
        int scrollY = Math.Max(0, -viewport.AutoScrollPosition.Y);
        viewport.AutoScrollPosition = Point.Empty;
        viewport.SuspendLayout();
        try {
            int left = P(28);
            int gap = P(12);
            int right = viewWidth - left - SystemInformation.VerticalScrollBarWidth;
            int contentWidth = Math.Max(1, right - left);

            B("title", left, P(20), contentWidth, P(38));
            B("subtitle", left + P(2), P(61), contentWidth - P(2), P(24));

            int cardColumns = Math.Min(4, Math.Max(1, (contentWidth + gap) / (P(180) + gap)));
            int cardWidth = (contentWidth - (cardColumns - 1) * gap) / cardColumns;
            for (int i = 0; i < cardPanels.Count; i++) {
                int column = i % cardColumns;
                int row = i / cardColumns;
                int width = cardColumns == 3 && i == 3 ? contentWidth : cardWidth;
                B(cardPanels[i], left + column * (cardWidth + gap), P(98) + row * P(116), width, P(104));
                int labelWidth = width - P(26);
                if (cardValues[i].Width != labelWidth) cardValues[i].Width = labelWidth;
                if (cardDetails[i].Width != labelWidth) cardDetails[i].Width = labelWidth;
            }

            int cardRows = (cardPanels.Count + cardColumns - 1) / cardColumns;
            int progressTop = P(98) + (cardRows - 1) * P(116) + P(104) + P(13);
            bool compactProgress = contentWidth < P(590);
            int phaseLeft = right - P(230);
            int checkWidth = P(140);
            int checkX = compactProgress ? right - checkWidth : phaseLeft - gap - checkWidth;
            B("progressTitle", left, progressTop, checkX - left - gap, P(26));
            B("selfCheckButton", checkX, progressTop - P(3), checkWidth, P(29));
            int phaseY = compactProgress ? progressTop + P(32) : progressTop + P(4);
            B("progressValueLabel", right - P(50), phaseY, P(50), P(22));
            B("phaseLabel", phaseLeft, phaseY, P(170), P(22));
            int barY = progressTop + (compactProgress ? P(58) : P(31));
            B("progressBar", left, barY, contentWidth, P(8));
            int statusY = barY + P(16);
            B("progressStatus", left + P(2), statusY, contentWidth - P(4), P(24));

            int primaryY = statusY + P(34);
            int primaryBottom = PlaceButtons(Primary, PrimaryWidths, PrimaryMinimums, left, primaryY, contentWidth, gap);
            int advancedBottom = C("startButton").Visible ?
                PlaceButtons(Advanced, AdvancedWidths, AdvancedMinimums, left, primaryBottom + P(10), contentWidth, gap) : primaryBottom;
            int uptimeY = advancedBottom + P(5);
            B("uptimeLabel", left, uptimeY, contentWidth, P(20));

            int accountHeadingY = uptimeY + P(24);
            B("accountsTitle", left, accountHeadingY, P(145), P(25));
            int currentWidth = Math.Min(P(170), Math.Max(P(95), contentWidth - P(160)));
            B("currentAccountLabel", right - currentWidth, accountHeadingY, currentWidth, P(24));
            bool compactAccount = contentWidth < P(660);
            int toggleX = compactAccount ? left : left + P(145) + gap;
            int toggleY = compactAccount ? accountHeadingY + P(30) : accountHeadingY - P(3);
            B("accountToggleButton", toggleX, toggleY, compactAccount ? contentWidth : P(120), P(30));
            B("switchAccountButton", compactAccount ? left : toggleX + P(120) + gap,
                compactAccount ? accountHeadingY + P(68) : accountHeadingY - P(3),
                compactAccount ? contentWidth : P(170), P(30));
            bool accountListOpen = C("accountList").Visible;
            int summaryY = accountHeadingY + P(compactAccount ? (accountListOpen ? 106 : 68) : 32);
            int summaryHeight = P(62);
            B("accountSummary", left, summaryY, contentWidth, summaryHeight);
            foreach (string name in new string[] { "runningAccountLabel", "lastAuthorizedLabel" }) {
                Control label = C(name);
                int width = contentWidth - P(26);
                if (label.Width != width) label.Width = width;
            }

            int listY = summaryY + summaryHeight + P(8);
            ListView accountList = (ListView)C("accountList");
            B(accountList, left, listY, contentWidth, P(108));
            int columnWidth = Math.Max(1, accountList.ClientSize.Width - P(8));
            int first = (int)Math.Floor(columnWidth * 0.52);
            int second = (int)Math.Floor(columnWidth * 0.23);
            int third = columnWidth - first - second;
            if (accountList.Columns[0].Width != first) accountList.Columns[0].Width = first;
            if (accountList.Columns[1].Width != second) accountList.Columns[1].Width = second;
            if (accountList.Columns[2].Width != third) accountList.Columns[2].Width = third;

            int metricsTop = accountListOpen ? listY + P(119) : summaryY + summaryHeight + P(16);
            bool compactMetrics = contentWidth < P(600);
            int metricsHeight = P(compactMetrics ? 760 : 516);
            B("metricsPanel", left, metricsTop, contentWidth, metricsHeight);
            int innerWidth = contentWidth - P(26);
            B("metricsTitle", P(12), P(10), compactMetrics ? innerWidth : innerWidth - P(150), P(26));
            B("quotaRefreshButton", compactMetrics ? P(12) : contentWidth - P(152), compactMetrics ? P(39) : P(7), compactMetrics ? innerWidth : P(140), P(30));
            B("quotaAutoSwitchButton", P(12), P(compactMetrics ? 75 : 42), compactMetrics ? innerWidth : P(220), P(30));
            B("geminiAutoSwitchButton", P(compactMetrics ? 12 : 242), P(compactMetrics ? 110 : 42), compactMetrics ? innerWidth : P(220), P(30));
            B("quotaScheduleLabel", P(12), P(compactMetrics ? 145 : 78), innerWidth, P(20));
            int metricOffset = P(compactMetrics ? 128 : 66);
            B("metricsAccountLabel", P(12), P(42) + metricOffset, innerWidth, P(20));
            B("usageSummaryLabel", P(12), P(65) + metricOffset, innerWidth, P(23));
            B("tokenSummaryLabel", P(12), P(92) + metricOffset, innerWidth, P(23));
            B("quotaStatusLabel", P(12), P(119) + metricOffset, innerWidth, P(20));
            B("quotaCards", P(12), P(145) + metricOffset, innerWidth, P(compactMetrics ? 470 : 290));

            int activityHeadingY = metricsTop + metricsHeight + P(12);
            B("activityTitle", left, activityHeadingY, P(145), P(24));
            B("logsToggleButton", right - P(170), activityHeadingY - P(4), P(170), P(29));
            int contentBottom = activityHeadingY + P(35);
            if (C("activityList").Visible) {
                int buttonY = activityHeadingY + P(34);
                int buttonWidth = Math.Min(P(145), (contentWidth - gap) / 2);
                B("copyActivityButton", left, buttonY, buttonWidth, P(29));
                B("clearActivityButton", left + buttonWidth + gap, buttonY, buttonWidth, P(29));
                int activityY = buttonY + P(37);
                B("activityList", left, activityY, contentWidth, P(116));
                contentBottom = activityY + P(126);
            }
            Size contentSize = new Size(0, contentBottom + P(8));
            if (viewport.AutoScrollMinSize != contentSize) viewport.AutoScrollMinSize = contentSize;
            lastWidth = viewWidth;
            lastHeight = viewHeight;
        }
        finally {
            viewport.ResumeLayout(true);
            busy = false;
        }
        int maximumScroll = Math.Max(0, viewport.AutoScrollMinSize.Height - viewport.ClientSize.Height);
        int desiredScroll = Math.Min(scrollY, maximumScroll);
        if (-viewport.AutoScrollPosition.Y != desiredScroll) {
            viewport.AutoScrollPosition = new Point(0, desiredScroll);
        }
    }
}
'@

$script:layout = New-Object CliProxyFluidLayout -ArgumentList @($form, [double]$dpiScale)
$layoutControls = @{
    title = $title; subtitle = $subtitle; progressTitle = $progressTitle
    selfCheckButton = $script:selfCheckButton; progressValueLabel = $script:progressValueLabel
    phaseLabel = $script:phaseLabel; progressBar = $script:progressBar; progressStatus = $script:progressStatus
    startButton = $script:startButton; serviceOnlyButton = $script:serviceOnlyButton; moreButton = $script:moreButton
    loginButton = $script:loginButton; stopButton = $script:stopButton; refreshButton = $script:refreshButton
    copyAddressButton = $script:copyAddressButton; openFolderButton = $script:openFolderButton
    openConfigButton = $script:openConfigButton; openProgramButton = $script:openProgramButton
    copyAccountButton = $script:copyAccountButton; copyButton = $script:copyButton; uptimeLabel = $script:uptimeLabel
    accountsTitle = $accountsTitle; accountToggleButton = $script:accountToggleButton
    switchAccountButton = $script:switchAccountButton
    restoreAccountsButton = $script:restoreAccountsButton; locateAccountButton = $script:locateAccountButton
    currentAccountLabel = $script:currentAccountLabel; accountSummary = $accountSummary
    runningAccountLabel = $script:runningAccountLabel; lastAuthorizedLabel = $script:lastAuthorizedLabel
    accountEvidence = $accountEvidence; accountList = $script:accountList
    metricsPanel = $metricsPanel; metricsTitle = $metricsTitle; quotaRefreshButton = $script:quotaRefreshButton
    quotaAutoSwitchButton = $script:quotaAutoSwitchButton; quotaScheduleLabel = $script:quotaScheduleLabel
    geminiAutoSwitchButton = $script:geminiAutoSwitchButton
    metricsAccountLabel = $script:metricsAccountLabel; usageSummaryLabel = $script:usageSummaryLabel
    tokenSummaryLabel = $script:tokenSummaryLabel; quotaStatusLabel = $script:quotaStatusLabel
    quotaCards = $script:quotaCards; activityTitle = $activityTitle; logsToggleButton = $script:logsToggleButton
    copyActivityButton = $script:copyActivityButton; clearActivityButton = $script:clearActivityButton
    activityList = $script:activityList; footer = $footer
}
foreach ($entry in $layoutControls.GetEnumerator()) {
    $script:layout.Register($entry.Key, $entry.Value)
}
foreach ($card in @($script:serviceCard, $script:apiCard, $script:authCard, $script:updateCard)) {
    $script:layout.AddCard($card.Panel, $card.Value, $card.Detail)
}
$script:layoutTimer = New-Object System.Windows.Forms.Timer
$script:layoutTimer.Interval = 16
$script:layoutTimer.Add_Tick({
    if (-not $script:layoutPending) {
        $script:layoutTimer.Stop()
        return
    }
    $script:layoutPending = $false
    $script:layout.Apply()
})
$form.Add_Resize({
    $script:layoutPending = $true
    if (-not $script:layoutTimer.Enabled) { $script:layoutTimer.Start() }
})
$form.Add_ResizeEnd({
    $script:layoutPending = $false
    $script:layoutTimer.Stop()
    $script:layout.Apply()
})
$script:quotaCards.Add_Resize({ Layout-QuotaCards })
$form.Add_FormClosed({
    $script:layoutTimer.Stop()
    $script:layoutTimer.Dispose()
})
$script:layout.Apply()

[void]$form.ShowDialog()
