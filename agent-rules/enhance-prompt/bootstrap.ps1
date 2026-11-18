<#
.SYNOPSIS
  交互规则跨机部署脚本（幂等）
.DESCRIPTION
  从私有仓库 clone/pull 唯一规范源，生成各 IDE 引用文件（引用而非复制正文），
  并在 WorkBuddy 用户级记忆与项目级记忆中维护受管段落。
  所有受管段落以 BEGIN/END 标记包裹；重复执行先移除旧段落再写入，保证幂等。
.PARAMETER WorkBuddyUserDir
  仅更新指定的 WorkBuddy 用户目录；未指定时扫描所有 user-*/MEMORY.md。
.PARAMETER ProjectRoot
  项目根目录（刷新项目级指针）；默认当前目录。
.PARAMETER RepoUrl
  规范源仓库 URL；默认 HTTPS。
#>
param(
    [string]$WorkBuddyUserDir,
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$RepoUrl = 'https://github.com/hmbphxkw76-byte/agent-rules.git'
)

$ErrorActionPreference = 'Stop'

# 跨机路径：全部由 USERPROFILE 动态构造，不硬编码用户名
$HomeDir  = $env:USERPROFILE
$RulesDir = Join-Path $HomeDir '.agent-rules'
$SpecFile = Join-Path $RulesDir 'global-interaction-rule.md'
$SpecRef  = '@' + ($SpecFile -replace '\\', '/')

$BeginMark = '<!-- BEGIN agent-rules managed -->'
$EndMark   = '<!-- END agent-rules managed -->'

function Set-ManagedBlock {
    param([string]$Path, [string]$Block)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $old = ''
    if (Test-Path -LiteralPath $Path) {
        $old = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    $pattern = '(?ms)' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '\r?\n?'
    $clean = [regex]::Replace($old, $pattern, '').TrimEnd()
    $newContent = if ($clean) { $clean + "`r`n`r`n" + $Block + "`r`n" } else { $Block + "`r`n" }
    [System.IO.File]::WriteAllText($Path, $newContent, $utf8NoBom)
}

# 1. clone 或 pull 规范源
Write-Host '[1/4] 规范源同步'
if (Test-Path -LiteralPath (Join-Path $RulesDir '.git')) {
    git -C $RulesDir pull --ff-only
    Write-Host "  pulled: $SpecFile"
} elseif (Test-Path -LiteralPath $SpecFile) {
    Write-Host '  目录已存在且含规范源、未初始化 git：跳过 clone（本机初始化场景）'
} else {
    git clone $RepoUrl $RulesDir
    Write-Host "  cloned: $RulesDir"
}
if (-not (Test-Path -LiteralPath $SpecFile)) { throw "规范源缺失: $SpecFile" }

# 2. 生成各 IDE 引用文件（引用而非复制正文）
Write-Host '[2/4] 生成 IDE 引用文件'
Set-ManagedBlock -Path (Join-Path $HomeDir '.claude\CLAUDE.md') -Block "$BeginMark`n$SpecRef`n$EndMark"
Set-ManagedBlock -Path (Join-Path $HomeDir '.gemini\GEMINI.md') -Block "$BeginMark`n$SpecRef`n$EndMark"
Set-ManagedBlock -Path (Join-Path $HomeDir '.cursor\rules\agent-rules.mdc') -Block "$BeginMark`n$SpecRef`n$EndMark"
Set-ManagedBlock -Path (Join-Path $HomeDir '.windsurf\rules\agent-rules.md') -Block "$BeginMark`n$SpecRef`n$EndMark"

# 3. WorkBuddy 用户级记忆与项目级指针
Write-Host '[3/4] 刷新 WorkBuddy 记忆指针'
$wbBlock = "$BeginMark`n- **交互流程**：遵循唯一规范源 $SpecRef；仅任务型输入走润色—展示—确认—执行，纯提问 / 确认 / 补充直接处理。`n$EndMark"
$userDirs = @()
if ($WorkBuddyUserDir) {
    $userDirs += $WorkBuddyUserDir
} else {
    $wbRoot = Join-Path $HomeDir '.workbuddy'
    if (Test-Path -LiteralPath $wbRoot) {
        $userDirs += @(Get-ChildItem -LiteralPath $wbRoot -Directory -Filter 'user-*' | ForEach-Object { $_.FullName })
    }
}
foreach ($d in $userDirs) {
    $mem = Join-Path $d 'MEMORY.md'
    if (Test-Path -LiteralPath $mem) {
        Set-ManagedBlock -Path $mem -Block $wbBlock
        Write-Host "  updated: $mem"
    }
}
if (Test-Path -LiteralPath (Join-Path $ProjectRoot '.workbuddy')) {
    $projMem = Join-Path $ProjectRoot '.workbuddy\memory\MEMORY.md'
    Set-ManagedBlock -Path $projMem -Block $wbBlock
    Write-Host "  updated: $projMem"
}

# 4. 完成
Write-Host '[4/4] 完成'
Write-Host "  规范源: $SpecFile"
Write-Host '  新电脑部署: git clone <repo> ~/.agent-rules ; powershell -File ~/.agent-rules/bootstrap.ps1'
