# ============================================================================
#  修复后端 exe 未被替换的问题
# ----------------------------------------------------------------------------
#  症状：
#    · 壳 exe / resources\backend\VERSION 已是最新（例如 1.0.7）
#    · 但 resources\backend\MGStudioServer.exe 时间戳仍是很久以前
#    · 界面里版本号显示旧值，「一键更新」里的下载源仍是 GitHub 旧地址
#
#  已查明的事实（本脚本的依据）：
#    1. 该 exe **并未被文件锁占用** —— 实测可在进程运行时重命名成功
#    2. 缓存里的安装包与官方发布**哈希完全一致**，下载无误
#    3. NSIS 安装时 shell 与静态资源都换掉了，唯独后端 exe 没有
#    4. 因此最可能的情况是：安装时该 exe 正被旧进程占用/正被上层的
#       "应用正在运行"检测打断，使安装提前退出（壳在先、后端 exe 在后）
#
#  本脚本做三件事：
#    ① 结束全部 MGStudio / MGStudioServer 进程
#    ② 把后端 exe 改名为 .old（而不是删除）—— 避免"删了又没装上"的坏结局，
#       同时腾出位置让安装程序必须重新写入该文件
#    ③ 提示重新运行安装包，并给出验证命令
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File .\fix-backend-exe.ps1
#    然后重新运行 MGStudio 安装包
# ============================================================================
[CmdletBinding()]
param(
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Continue'

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  OK  $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  !!  $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "      $m" }

# ---------- 定位安装目录 ----------
# 坑（真实踩到）：注册表的 UninstallString 形如
#     "D:\猫歌映画\MGStudio\Uninstall MGStudio.exe" /S
# 带引号、还带参数。若直接 Trim('"') 再 Split-Path -Parent，
# 会把 " /S" 或未闭合的引号一起当成路径，Test-Path 抛 InvalidArgument：
#     InvalidArgument: D:\猫歌映画\MGStudi... MGStudio.exe":String
# 因此改为用正则只取"第一个引号内"或"到第一个空白为止"的那段路径。
function Get-DirFromUninstallString([string]$s) {
    if (-not $s) { return '' }
    $t = $s.Trim()
    $m = [regex]::Match($t, '^"([^"]+)"')
    if ($m.Success) {
        $exePath = $m.Groups[1].Value
    } else {
        $exePath = ($t -split '\s+')[0]
    }
    if (-not $exePath) { return '' }
    $exePath = $exePath.Trim('"')
    try { return (Split-Path -Path $exePath -Parent) } catch { return '' }
}

if (-not $InstallDir -or -not (Test-Path $InstallDir -ErrorAction SilentlyContinue)) {
    $found = ''
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        $hits = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^MGStudio' }
        foreach ($hit in $hits) {
            $cand = ''
            if ($hit.InstallLocation) { $cand = $hit.InstallLocation.Trim('"') }
            if ((-not $cand -or -not (Test-Path $cand -ErrorAction SilentlyContinue)) -and $hit.UninstallString) {
                $cand = Get-DirFromUninstallString $hit.UninstallString
            }
            if ($cand -and (Test-Path $cand -ErrorAction SilentlyContinue)) { $found = $cand; break }
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

if (-not $InstallDir -or -not (Test-Path $InstallDir -ErrorAction SilentlyContinue)) {
    Write-Warn2 '无法自动定位安装目录。请显式指定：'
    Write-Info '.\fix-backend-exe.ps1 -InstallDir "D:\你的安装目录\MGStudio"'
    exit 1
}
Write-Host ''
Write-Info "安装目录: $InstallDir"

# ---------- ① 结束进程 ----------
Write-Step '① 结束全部 MGStudio 进程'
$procs = @(Get-Process -Name 'MGStudio', 'MGStudioServer' -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Ok '没有正在运行的进程'
} else {
    foreach ($p in $procs) { Write-Info "结束 $($p.ProcessName) PID=$($p.Id)" }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = @(Get-Process -Name 'MGStudio', 'MGStudioServer' -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        Write-Warn2 "仍有 $($left.Count) 个进程未退出；请在任务管理器手动结束后重新运行本脚本"
        exit 1
    }
    Write-Ok '全部已结束'
}

# ---------- ② 移走后端 exe ----------
Write-Step '② 移走过期的后端 exe'
$exe = Join-Path $InstallDir 'resources\backend\MGStudioServer.exe'
if (-not (Test-Path $exe)) {
    Write-Warn2 "未找到：$exe"
    exit 1
}
$exeTime = (Get-Item $exe).LastWriteTime
$verFile = Join-Path $InstallDir 'resources\backend\VERSION'
$verTime = if (Test-Path $verFile) { (Get-Item $verFile).LastWriteTime } else { $null }
Write-Info "后端 exe 时间 : $exeTime"
if ($verTime) { Write-Info "VERSION  时间 : $verTime" }

$old = "$exe.old"
try {
    if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $exe -Destination $old -ErrorAction Stop
    Write-Ok "已改名为 MGStudioServer.exe.old（保留备份，未删除）"
} catch {
    Write-Warn2 "移动失败：$($_.Exception.Message)"
    exit 1
}

# ---------- ③ 下一步 ----------
Write-Step '③ 下一步：重新运行安装包'
Write-Host ''
Write-Host '  现在后端 exe 已腾出位置。请运行最新安装包（覆盖安装）：' -ForegroundColor Yellow
Write-Host ''
Write-Host '    https://github.com/maoge19523-cpu/MGCanvas2.0/releases/latest' -ForegroundColor Gray
Write-Host '    （国内镜像：在地址最前面加 https://gh-proxy.com/ ）' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  装完后执行以下命令验证（这一步是判断修复成功的关键）：' -ForegroundColor Cyan
Write-Host ''
Write-Host "    Get-Item '$exe' | Select-Object LastWriteTime" -ForegroundColor Gray
Write-Host ''
Write-Host '  · 时间变成"今天"  -> 修复成功，后端 exe 已被正确替换' -ForegroundColor Green
Write-Host '  · 文件不存在      -> 安装程序确实没有包含该文件，请把这个结果告诉我' -ForegroundColor Red
Write-Host ''
Write-Host '  确认成功后可以删掉备份：' -ForegroundColor DarkGray
Write-Host "    Remove-Item '$old' -Force" -ForegroundColor DarkGray
Write-Host ''
