# ============================================================================
#  MGStudio / 猫歌映画 —— 一键发版
# ----------------------------------------------------------------------------
#  做四件事（按顺序）：
#    1. 同步版本号：VERSION / desktop/package.json / main.py 的 APP_VERSION /
#       static/update-notes.json 四处必须一致，否则更新判断会错乱。
#    2. 重新编译后端二进制（main.py 或 server/ 有改动时必需，
#       否则安装包里还是旧后端）。
#    3. 打包 Windows 安装包（NSIS）。
#    4. 发布到 GitHub Releases（electron-updater 从这里取更新）。
#
#  用法：
#    .\release.ps1                      # 用当前版本号构建，不发布
#    .\release.ps1 -Bump               # 版本号 +1（1.0.0 -> 1.0.1）后构建
#    .\release.ps1 -Publish            # 构建并发布 Release（需要 GH_TOKEN）
#    .\release.ps1 -Bump -Publish      # 升版本 + 构建 + 发布
#
#  发布前请设置 token（fine-grained，权限只需该仓库 Contents: Read and write）：
#    $env:GH_TOKEN = "github_pat_xxx"
#
#  说明：electron-updater 的 GitHub provider 不支持私有仓库，
#        仓库必须是 Public，否则客户端拿不到 latest.yml。
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Bump,
    [switch]$Publish,
    [switch]$SkipBackend,
    # 只做版本号同步就退出 —— 用于验证，不触发编译与打包
    [switch]$VersionOnly
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$desktop = Join-Path $root 'desktop'

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host "  XX  $msg" -ForegroundColor Red; exit 1 }

# ---------- 读取四处版本 ----------
function Get-Versions {
    $v = @{}
    $v.File = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
    $pkg = Get-Content (Join-Path $desktop 'package.json') -Raw | ConvertFrom-Json
    $v.Package = $pkg.version
    $py = Get-Content (Join-Path $root 'main.py') -Raw
    $m = [regex]::Match($py, 'APP_VERSION\s*=\s*"([^"]+)"')
    # 注意：PowerShell 5.1 不支持 $x = if(...){}else{}，必须用显式分支
    if ($m.Success) { $v.MainPy = $m.Groups[1].Value } else { $v.MainPy = '' }
    $notesPath = Join-Path $root 'static\update-notes.json'
    $notesRaw = [IO.File]::ReadAllText($notesPath)
    $nm = [regex]::Match($notesRaw, '"version"\s*:\s*"([^"]+)"')
    if ($nm.Success) { $v.Notes = $nm.Groups[1].Value } else { $v.Notes = '' }
    return $v
}

# ---------- 编码安全的写回 ----------
# 关键：这些文件含大量中文，且有 BOM/无 BOM 都可能存在。
# [IO.File]::WriteAllText 默认写 UTF-8 无 BOM，会把原有 BOM 抹掉，
# 也可能让某些读取方（PowerShell 5.1 的 Get-Content）按 GBK 误解码成乱码。
# 因此统一：先探测原文件是否带 UTF-8 BOM，再按同样方式写回。
function Write-TextPreservingEncoding([string]$path, [string]$text) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    [IO.File]::WriteAllText($path, $text, $enc)
}

# ---------- 写入版本号（保留各文件原有编码）----------
# 踩过的坑：曾用 [regex]::Replace($s, $pat, ('$1' + $ver + '$2'), 1) 拼接替换串。
# PowerShell 会把拼接结果按普通字符串处理，但替换串里的 $1 需要由正则引擎解释，
# 拼接后行为不可控 —— 实测把 package.json 写成了 `$11.0.0"`，一次损坏三个文件
# （已从 git 回退）。现在模式与替换串都用单引号整体写出，替换串只在表达式里
# 构造一次，且用 ${1}/${2} 显式界定，避免 $1 与后续数字粘连。
function Set-Version([string]$ver) {
    # VERSION（纯 ASCII，无 BOM）
    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), $ver + "`n", (New-Object System.Text.UTF8Encoding($false)))

    # desktop/package.json：锚定行首缩进 + "version"，只替换顶层字段，
    # 不会误伤 build.win.artifactName 里的 ${version}
    $pkgPath = Join-Path $desktop 'package.json'
    $pkgRaw = [IO.File]::ReadAllText($pkgPath)
    $pkgNew = [regex]::Replace($pkgRaw, '(?m)^(\s*"version"\s*:\s*")[^"]+(")', ('${1}' + $ver + '${2}'), 1)
    # 守卫：校验替换结果里顶层 version 确实等于目标值。
    # 不能比较"替换前后是否变化" —— 目标与当前版本相同时字符串不变，会误判失败。
    $chk = [regex]::Match($pkgNew, '(?m)^\s*"version"\s*:\s*"([^"]+)"')
    if (-not $chk.Success -or $chk.Groups[1].Value -ne $ver) {
        Die "package.json 的 version 未能写成 $ver"
    }
    Write-TextPreservingEncoding $pkgPath $pkgNew

    # main.py 的 APP_VERSION（行首锚定）
    $pyPath = Join-Path $root 'main.py'
    $pyRaw = [IO.File]::ReadAllText($pyPath)
    $pyNew = [regex]::Replace($pyRaw, '(?m)^(APP_VERSION\s*=\s*")[^"]+(")', ('${1}' + $ver + '${2}'), 1)
    $chkPy = [regex]::Match($pyNew, '(?m)^APP_VERSION\s*=\s*"([^"]+)"')
    if (-not $chkPy.Success -or $chkPy.Groups[1].Value -ne $ver) {
        Die "main.py 的 APP_VERSION 未能写成 $ver"
    }
    Write-TextPreservingEncoding $pyPath $pyNew

    # static/update-notes.json：只改首个 version 与 updated_at
    $notesPath = Join-Path $root 'static\update-notes.json'
    $notesRaw = [IO.File]::ReadAllText($notesPath)
    $notesNew = [regex]::Replace($notesRaw, '("version"\s*:\s*")[^"]+(")', ('${1}' + $ver + '${2}'), 1)
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszz00')
    $notesNew = [regex]::Replace($notesNew, '("updated_at"\s*:\s*")[^"]+(")', ('${1}' + $stamp + '${2}'), 1)
    Write-TextPreservingEncoding $notesPath $notesNew
}

# ---------- 主流程 ----------
Step '版本号一致性检查'
$before = Get-Versions
Write-Host "  VERSION=$($before.File)  package.json=$($before.Package)  main.py=$($before.MainPy)  update-notes.json=$($before.Notes)"

if ($Bump) {
    if ($before.File -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        Die "VERSION 不是 x.y.z 形式，无法自动 +1：$($before.File)"
    }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]; $pat = [int]$Matches[3]
    $target = "$maj.$min.$($pat + 1)"
    Write-Host "  升版本：$($before.File) -> $target"
    Set-Version $target
    Ok "四处版本号已同步为 $target"
} else {
    # 不升版本也要把它们对齐到 VERSION 的值
    if ($before.Package -ne $before.File -or $before.MainPy -ne $before.File -or $before.Notes -ne $before.File) {
        Warn "四处版本不一致，已统一为 VERSION 的值 $($before.File)"
        Set-Version $before.File
    } else {
        Ok "四处一致"
    }
}
$ver = (Get-Versions).File
Write-Host "  当前版本：$ver"

if ($VersionOnly) {
    Step '版本号同步结果'
    $after = Get-Versions
    Write-Host "  VERSION=$($after.File)  package.json=$($after.Package)  main.py=$($after.MainPy)  update-notes.json=$($after.Notes)"
    $same = ($after.File -eq $after.Package) -and ($after.File -eq $after.MainPy) -and ($after.File -eq $after.Notes)
    if ($same) { Ok '四处版本一致' } else { Die '四处版本仍不一致' }
    Write-Host "`n  (-VersionOnly：已跳过编译与打包)`n"
    exit 0
}

# 关键约束：只要版本号变了，后端就必须重编，不允许 -SkipBackend。
# 原因（真实踩过）：后端 exe 是**版本号的来源**（current_app_version 优先读
# exe 同级目录的 VERSION），而壳的版本号来自 package.json。若升版本时跳过
# 后端重编，就会出现「壳已是 1.0.2、界面仍显示 1.0.0」的错位 —— 1.0.2 那次
# 正是如此，事后才发现后端 exe 与 VERSION 都还是旧版。
if ($Bump -and $SkipBackend) {
    Warn '-Bump 与 -SkipBackend 不能同时使用：升版本号必须重编后端，已忽略 -SkipBackend'
    $SkipBackend = $false
}

if (-not $SkipBackend) {
    Step '重新编译后端二进制（PyInstaller）'
    Push-Location $root
    try {
        # 关键：原生命令（pyinstaller / npx）会把 INFO 日志写到 stderr。
        # 而脚本顶层设了 $ErrorActionPreference='Stop'，PowerShell 会把原生
        # 命令的 stderr 当成错误并**直接终止脚本** —— 即使该命令其实在正常构建。
        # 实测：pyinstaller 刚打印 "INFO: PyInstaller: 6.22.3" 就被中断。
        # 因此这里必须临时改成 'Continue'，并用 $LASTEXITCODE 判断成败。
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        # 用 cmd /c 执行并捕获全部输出，避免 stderr 触发 PowerShell 的错误机制
        $pyArgs = '--noconfirm --clean --onefile --name MGStudioServer' +
                  ' --distpath "' + (Join-Path $desktop 'resources\backend') + '"' +
                  ' --workpath "' + (Join-Path $root 'build\pyi') + '"' +
                  ' --specpath "' + (Join-Path $root 'build') + '" main.py'
        $pyLog = & cmd /c "pyinstaller $pyArgs 2>&1"
        $pyCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEap

        $pyLog | Select-String -Pattern 'completed successfully|ERROR|error:' | Select-Object -Last 3

        $exe = Join-Path $desktop 'resources\backend\MGStudioServer.exe'
        if ($pyCode -ne 0) { Die "PyInstaller 退出码 $pyCode" }
        if (-not (Test-Path $exe)) { Die "后端二进制未生成：$exe" }
        Ok "后端二进制已更新（$([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB）"
    } finally { Pop-Location }
}

# 后端版本文件同步（**在 -SkipBackend 之外**，必须始终执行）。
#
# current_app_version() 优先读 BASE_DIR/VERSION，PyInstaller onefile 的解包目录
# 里没有该文件，于是实际读到的是「exe 同级目录/VERSION」，即安装后的
# resources/backend/VERSION。
#
# 踩过的坑：这个文件**不是**从 resources/backend/VERSION 拷进去的。
# package.json 的 extraResources 写的是
#     { "from": ".version", "to": "backend/VERSION" }
# —— 真正进包的是 desktop/.version。只写 resources/backend/VERSION 完全无效，
# 结果就是壳已是 1.0.2、界面却一直显示 1.0.0（1.0.2 事故的直接原因）。
# 所以两个文件都要写，且必须放在 -SkipBackend 判断之外。
$verFile = Join-Path $desktop 'resources\backend\VERSION'
[IO.File]::WriteAllText($verFile, $ver + "`n", (New-Object System.Text.UTF8Encoding($false)))
$verFileDot = Join-Path $desktop '.version'
[IO.File]::WriteAllText($verFileDot, $ver + "`n", (New-Object System.Text.UTF8Encoding($false)))
Ok "后端版本文件已同步：$ver（resources/backend/VERSION 与 desktop/.version）"

Step '打包 Windows 安装包'
# 注意：PowerShell 5.1 不支持 $x = if(...){}else{}，必须显式赋值
$publishFlag = 'never'
if ($Publish) { $publishFlag = 'always' }
if ($Publish -and -not $env:GH_TOKEN) {
    Die '未设置 GH_TOKEN，无法发布。请先设置环境变量 GH_TOKEN'
}

# 打包前硬校验：所有版本来源必须全部等于目标版本。
# 这是最后一道闸门 —— 1.0.2 那次壳是 1.0.2、界面却显示 1.0.0，
# 用户完全看不懂发生了什么。
#
# 校验清单里**必须包含 desktop/.version**：它是 extraResources 里
# { from: ".version", to: "backend/VERSION" } 的来源，也就是最终装进包里、
# 被 current_app_version() 读到的那个文件。
# 之前只校验了 resources/backend/VERSION，校验的是错文件，因此给出了假绿灯。
Step '打包前版本一致性硬校验'
$final = Get-Versions
$mismatch = @()
if ($final.File -ne $ver) { $mismatch += "VERSION=$($final.File)" }
if ($final.Package -ne $ver) { $mismatch += "package.json=$($final.Package)" }
if ($final.MainPy -ne $ver) { $mismatch += "main.py=$($final.MainPy)" }
if ($final.Notes -ne $ver) { $mismatch += "update-notes.json=$($final.Notes)" }
# 真正进包的那个（extraResources 的 from 源）
$dotVerFile = Join-Path $desktop '.version'
if (Test-Path $dotVerFile) {
    $dv = (Get-Content $dotVerFile -Raw).Trim()
    if ($dv -ne $ver) { $mismatch += "desktop/.version=$dv （这个才是进包的）" }
} else {
    $mismatch += 'desktop/.version 不存在（extraResources 会因此缺文件）'
}
# 后端 exe 目录下那份（便于排查，非进包来源）
$backendVerFile = Join-Path $desktop 'resources\backend\VERSION'
if (Test-Path $backendVerFile) {
    $bv = (Get-Content $backendVerFile -Raw).Trim()
    if ($bv -ne $ver) { $mismatch += "resources/backend/VERSION=$bv" }
}
if ($mismatch.Count -gt 0) {
    Die ("版本号未全部对齐，已中止打包：`n    " + ($mismatch -join "`n    "))
}
Ok "全部版本号均为 $ver（含 desktop/.version —— 它是真正进包的那份）"

Push-Location $desktop
try {
    # 同 PyInstaller 那步：electron-builder 也把进度写到 stderr，
    # 在 $ErrorActionPreference='Stop' 下会误判为错误并中断脚本。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $builderLog = & cmd /c "npx electron-builder --win --publish $publishFlag 2>&1"
    $builderCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEap

    $builderLog | Select-String -Pattern 'building|error|⨯|published|Cannot|ENOENT' | Select-Object -First 8
    if ($builderCode -ne 0) { Die "electron-builder 退出码 $builderCode（见上方输出）" }
    $setup = Join-Path $desktop "release\MGStudio-Electron-Setup-$ver.exe"
    if (-not (Test-Path $setup)) { Die "安装包未生成：$setup" }
    $size = [math]::Round((Get-Item $setup).Length / 1MB, 2)
    $sha = (Get-FileHash $setup -Algorithm SHA256).Hash
    Ok "安装包：$size MB"
    Write-Host "  SHA-256: $sha"
} finally { Pop-Location }

Step '收尾'
if ($Publish) {
    Ok "已发布 Release v$ver（客户端启动 8 秒后会自动检查）"
} else {
    Warn "未发布。确认无误后执行：.\release.ps1 -Publish"
    Warn "版本号已是 $ver；如需再升一版请用 -Bump"
}
Write-Host ''
