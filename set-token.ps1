# ============================================================================
#  设置发布用的 GitHub Token
# ----------------------------------------------------------------------------
#  为什么单独做一个脚本：
#    · 直接写在命令行里（$env:GH_TOKEN = "github_pat_..."）会把 token 留在
#      PowerShell 历史记录文件里；
#    · 本脚本用安全输入（输入时不回显），并且只写进「用户环境变量」，
#      不进仓库、不进安装包、不进客户端。
#
#  用法：在仓库根目录执行
#      .\set-token.ps1
#  然后粘贴 token 回车即可。
#
#  需要什么样的 token（GitHub → Settings → Developer settings →
#  Personal access tokens → Fine-grained tokens → Generate new token）：
#      Repository access : Only select repositories → 选 MGCanvas2.0
#      Permissions       : Repository permissions → Contents → Read and write
#      （其余全部保持 No access）
# ============================================================================
[CmdletBinding()]
param(
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

Write-Host "`n=== 设置发布 token（GH_TOKEN）===" -ForegroundColor Cyan

if ($CheckOnly) {
    $u = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User')
    if ($u) {
        Write-Host "  已持久设置，长度 $($u.Length)，前缀 $($u.Substring(0, [Math]::Min(11, $u.Length)))..." -ForegroundColor Green
    } else {
        Write-Host "  尚未持久设置。运行 .\set-token.ps1 来设置。" -ForegroundColor Yellow
    }
    Write-Host ''
    exit 0
}

Write-Host @"
  请粘贴你的 fine-grained token（形如 github_pat_xxx）。
  输入时不显示字符，这是正常的；粘贴后直接回车。

  提示：GitHub 的 Personal access tokens 页面：
        https://github.com/settings/personal-access-tokens

"@ -ForegroundColor Gray

$secure = Read-Host -Prompt '  Token' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "`n  没有输入内容，已取消。`n" -ForegroundColor Red
    exit 1
}

# 粗校验：fine-grained 与经典 token 的常见前缀
if ($token -notmatch '^(github_pat_|ghp_)') {
    Write-Host "`n  警告：这个值看起来不像 GitHub token（通常以 github_pat_ 或 ghp_ 开头）。" -ForegroundColor Yellow
    $go = Read-Host '  仍要继续吗？(y/N)'
    if ($go -notmatch '^[Yy]') { Write-Host "  已取消。`n"; exit 1 }
}

# 写入用户级环境变量（持久；不进仓库）
[Environment]::SetEnvironmentVariable('GH_TOKEN', $token, 'User')
$env:GH_TOKEN = $token

Write-Host "`n  已保存到用户环境变量 GH_TOKEN（长度 $($token.Length)）" -ForegroundColor Green
Write-Host "  当前会话也已生效。`n" -ForegroundColor Green
Write-Host "  注意：其他已经开着的终端窗口读不到这个值，" -ForegroundColor Yellow
Write-Host "        请在本窗口继续执行 .\preflight.ps1。`n" -ForegroundColor Yellow
