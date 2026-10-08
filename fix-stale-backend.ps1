# ============================================================================
#  修复「壳是新的、后端是旧的」状态
# ----------------------------------------------------------------------------
#  症状：
#    · 版本号显示正常（例如 1.0.3），但「一键更新」里的下载源仍是 GitHub 旧地址
#    · 重启应用无效 —— 因为旧后端进程从未退出
#    · 安装目录 resources\backend\MGStudioServer.exe 的时间戳比 VERSION 早很多
#
#  成因：
#    安装新版时旧后端仍在运行 → exe 被占用 → 安装程序跳过替换；
#    但 VERSION 是文本文件、被换成了新版本号，于是旧 exe 也回报新版本；
#    新壳探测到"版本号一致"便复用该进程，形成常驻的旧后端。
#
#  本脚本只处理 MGStudio 自己的进程与文件，做三件事：
#    1. 结束所有 MGStudio / MGStudioServer 进程（释放被占用的 exe）
#    2. 对比后端 exe 与 VERSION 的时间戳，判定是否过期
#    3. 给出下一步（重新运行安装包覆盖安装）
#
#  用法：执行本脚本 → 重新运行安装包覆盖安装（这次 exe 会被正确替换）
# ============================================================================
[CmdletBinding()]
param(
    # 留空则自动查找安装位置
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Continue'

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "      $m" }

# ---------- 自动定位安装目录 ----------
if (-not $InstallDir -or -not (Test-Path $InstallDir)) {
    $found = ''
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        $hits = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^MGStudio' }
        foreach ($hit in $hits) {
            if ($hit.InstallLocation) {
                $cand = $hit.InstallLocation.Trim('"')
                if (Test-Path $cand) { $found = $cand; break }
            }
            if (-not $found -and $hit.UninstallString) {
                $u = $hit.UninstallString.Trim('"')
                $dir = Split-Path $u -Parent
                if ($dir -and (Test-Path $dir)) { $found = $dir; break }
            }
        }
        if ($found) { break }
    }
    if (-not $found) {
        $p = Get-Process -Name 'MGStudio' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) {
            $full = ''
            try { $full = $p.Path } catch { $full = '' }
            if ($full) { $found = Split-Path $full -Parent }
        }
    }
    if ($found) { $InstallDir = $found }
}

if (-not $InstallDir -or -not (Test-Path $InstallDir)) {
    Write-Warn2 '无法自动定位 MGStudio 安装目录。请显式指定，例如：'
    Write-Info '.\fix-stale-backend.ps1 -InstallDir "D:\你的安装目录\MGStudio"'
    exit 1
}
Write-Host ''
Write-Info "安装目录: $InstallDir"

# ---------- ① 结束进程 ----------
Write-Step '① 结束 MGStudio 相关进程'
$procs = @(Get-Process -Name 'MGStudio', 'MGStudioServer' -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Ok '没有残留进程'
} else {
    foreach ($p in $procs) {
        $pth = ''
        try { $pth = $p.Path } catch { $pth = '(无法读取路径)' }
        Write-Info "结束 $($p.ProcessName) PID=$($p.Id)  $pth"
    }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = @(Get-Process -Name 'MGStudio', 'MGStudioServer' -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        Write-Warn2 "仍有 $($left.Count) 个进程未退出，请在任务管理器手动结束后重试"
    } else {
        Write-Ok '全部已结束，exe 占用已释放'
    }
}

# ---------- ② 检查文件时间戳 ----------
Write-Step '② 检查安装目录里的文件'
$shell = Join-Path $InstallDir 'MGStudio.exe'
$exe = Join-Path $InstallDir 'resources\backend\MGStudioServer.exe'
$ver = Join-Path $InstallDir 'resources\backend\VERSION'

if (Test-Path $shell) {
    $sv = (Get-Item $shell).VersionInfo
    Write-Info "壳 exe      : FileVersion=$($sv.FileVersion)   时间=$((Get-Item $shell).LastWriteTime)"
} else {
    Write-Warn2 "未找到壳 exe：$shell"
}
if (Test-Path $ver) {
    Write-Info "后端 VERSION: $((Get-Content $ver -Raw).Trim())   时间=$((Get-Item $ver).LastWriteTime)"
}
if (Test-Path $exe) {
    Write-Info "后端 exe    : $([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB   时间=$((Get-Item $exe).LastWriteTime)"
}

# ---------- ③ 判定是否过期 ----------
Write-Step '③ 判定后端 exe 是否过期'
if ((Test-Path $exe) -and (Test-Path $ver)) {
    $exeTime = (Get-Item $exe).LastWriteTime
    $verTime = (Get-Item $ver).LastWriteTime
    $gapHours = [math]::Round(($verTime - $exeTime).TotalHours, 1)
    if ($gapHours -gt 1) {
        Write-Warn2 "后端 exe 比 VERSION 早 $gapHours 小时 —— 安装时被占用，未被替换"
        Write-Host ''
        Write-Host '  → 进程已结束，请重新运行安装包覆盖安装（这次会正确替换 exe）：' -ForegroundColor Yellow
        Write-Host '     https://github.com/maoge19523-cpu/MGCanvas2.0/releases/latest' -ForegroundColor Gray
        Write-Host '     （国内可用镜像：在地址最前面加 https://gh-proxy.com/ ）' -ForegroundColor Gray
    } else {
        Write-Ok "后端 exe 与 VERSION 时间接近（差 $gapHours 小时），未发现过期"
    }
} elseif (-not (Test-Path $exe)) {
    Write-Warn2 "未找到后端 exe：$exe"
} else {
    Write-Warn2 '未找到后端 VERSION，无法比较时间'
}

Write-Host ''
Write-Host '  说明：从 1.0.4 起，应用启动时会自动结束这类陈旧后端进程，' -ForegroundColor DarkGray
Write-Host '        发版脚本也会在打包前校验后端 exe 新鲜度，不会再出现该状态。' -ForegroundColor DarkGray
Write-Host ''
