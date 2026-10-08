# ============================================================================
#  发布前预检 —— 在跑完整发版（约 10 分钟）之前，先确认发布链路是通的
# ----------------------------------------------------------------------------
#  检查四项：
#    1. GH_TOKEN 是否已设置
#    2. token 是否有效、能读到自己的账号
#    3. token 对该仓库是否有写权限（Contents: Read and write）
#    4. 本机是否能连上 GitHub（发版要上传约 180MB，网络不稳会白跑）
#
#  用法：
#    $env:GH_TOKEN = "github_pat_xxx"
#    .\preflight.ps1
#
#  任一项不通过就不要开始发版，先解决它。
# ============================================================================
[CmdletBinding()]
param(
    [string]$Owner = 'maoge19523-cpu',
    [string]$Repo = 'MGCanvas2.0'
)

$ErrorActionPreference = 'Stop'

function Item($ok, $name, $detail) {
    $mark = 'OK ' ; $color = 'Green'
    if (-not $ok) { $mark = 'XX ' ; $color = 'Red' }
    Write-Host ("  [{0}] {1,-28} {2}" -f $mark.Trim(), $name, $detail) -ForegroundColor $color
}

Write-Host "`n=== 发布前预检：$Owner/$Repo ===`n" -ForegroundColor Cyan
$fatal = $false

# ---------- 1. GH_TOKEN ----------
$token = $env:GH_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    Item $false 'GH_TOKEN 已设置' '未设置。请先 $env:GH_TOKEN = "github_pat_xxx"'
    Write-Host "`n  未设置 token，后续检查无法进行。`n" -ForegroundColor Yellow
    exit 1
}
Item $true 'GH_TOKEN 已设置' ("长度 {0}，前缀 {1}" -f $token.Length, $token.Substring(0, [Math]::Min(11, $token.Length)))

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'User-Agent'           = 'MGStudio-preflight'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# ---------- 2. token 有效性 ----------
try {
    $me = Invoke-RestMethod 'https://api.github.com/user' -Headers $headers -TimeoutSec 25
    Item $true 'token 有效' ("账号 $($me.login)")
} catch {
    Item $false 'token 有效' "调用 /user 失败：$($_.Exception.Message)"
    $fatal = $true
}

# ---------- 3. 仓库写权限 ----------
try {
    $repoInfo = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo" -Headers $headers -TimeoutSec 25
    Item $true '仓库可访问' ("private=$($repoInfo.private) 默认分支=$($repoInfo.default_branch)")
    if ($repoInfo.private -eq $true) {
        Item $false '仓库为公开' '私有仓库时 electron-updater 拿不到 latest.yml，自动更新会失效'
        $fatal = $true
    } else {
        Item $true '仓库为公开' '客户端可匿名取到 latest.yml'
    }
    # permissions.push 表示有写权限
    $canPush = $repoInfo.permissions.push
    if ($canPush) {
        Item $true 'token 有写权限' 'permissions.push = true'
    } else {
        Item $false 'token 有写权限' 'permissions.push = false —— 需要 Contents: Read and write'
        $fatal = $true
    }
} catch {
    Item $false '仓库可访问' "调用 /repos 失败：$($_.Exception.Message)"
    $fatal = $true
}

# ---------- 4. 网络连通（发版要上传大文件）----------
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-WebRequest 'https://api.github.com/rate_limit' -Headers $headers -UseBasicParsing -TimeoutSec 25
    $sw.Stop()
    Item $true 'GitHub 连通' ("往返 $($sw.ElapsedMilliseconds) ms")
} catch {
    Item $false 'GitHub 连通' "失败：$($_.Exception.Message)"
    $fatal = $true
}

# ---------- 附加提示：是否已有 Release ----------
try {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases?per_page=5" -Headers $headers -TimeoutSec 25
    if ($rel.Count -eq 0) {
        Write-Host "`n  提示：该仓库还没有任何 Release。第一个 Release 发布后，客户端才能检查到更新。" -ForegroundColor Yellow
    } else {
        Write-Host "`n  已有 Release："
        $rel | Select-Object -First 5 | ForEach-Object { Write-Host ("    {0}  draft={1} prerelease={2} 资源 {3} 个" -f $_.tag_name, $_.draft, $_.prerelease, $_.assets.Count) }
    }
} catch {
    Write-Host "`n  （查询 Release 列表失败，不影响发版）" -ForegroundColor DarkGray
}

Write-Host ''
if ($fatal) {
    Write-Host '预检未通过 —— 请先解决上面标 XX 的项，再执行 .\release.ps1 -Publish' -ForegroundColor Red
    exit 1
}
Write-Host '预检通过 ✅ 可以执行：.\release.ps1 -Bump -Publish' -ForegroundColor Green
Write-Host ''
exit 0
