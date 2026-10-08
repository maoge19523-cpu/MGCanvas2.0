# 发版流程（可持续更新）

本文件说明如何发布一个新版本，以及客户端如何拿到更新。

---

## 一、更新是怎么工作的

有**两条独立通道**，不要混淆：

| 通道 | 机制 | 能更新什么 |
|---|---|---|
| **Electron 壳** | `electron-updater`，启动 8 秒后检查 GitHub Releases | 整个应用（安装包），**推荐日常只用这条** |
| 后端静态热更 | 后端 `/api/update-from-github`，从仓库 `main` 分支拉 `static/` 文件 | 只有 HTML/CSS/JS，**换不了 exe 和 Electron 壳** |

**日常发版只需走第一条**（`release.ps1`）。

客户端行为：启动 → 8 秒后 `autoUpdater.checkForUpdates()` →
发现新版本弹窗询问 → 同意则下载 → 下载完成提示重启安装。
`autoDownload = false`，所以不会偷偷下载。

### 硬约束（务必知道）

`electron-updater` 的 **GitHub provider 不支持私有仓库**：
它请求 `https://github.com/<owner>/<repo>/releases.atom`，且不带任何认证头
（源码实测：`GitHubProvider.js` / `Provider.js`，`builder-util-runtime` 里
搜不到 `GH_TOKEN` / `GITHUB_TOKEN`）。

而 GitHub **不允许"代码私有 + Releases 公开"** —— Releases 可见性跟随仓库。
所以：**仓库必须是 Public**，否则客户端拿不到 `latest.yml`。

---

## 二、发版前的一次性准备

### 1. 确认仓库是 Public

仓库 → Settings → General → 页面最下方 Danger Zone → Change visibility → Make public。

验证（换掉 `<owner>`）：

```powershell
try { (Invoke-WebRequest 'https://github.com/<owner>/MGCanvas2.0' -UseBasicParsing -MaximumRedirection 2).StatusCode }
catch { [int]$_.Exception.Response.StatusCode }   # 200 = 公开；404 = 私有
```

> 注意：不要用 `api.github.com` 判断 —— 匿名 API 每小时只有 60 次配额，
> 用完会返回 **403**（不是 404），容易误判成"私有"。

### 2. 建发布用的 Token

GitHub → Settings → Developer settings → Personal access tokens →
**Fine-grained tokens** → Generate new token：

- Repository access：**Only select repositories** → 选 `MGCanvas2.0`
- Permissions → Repository permissions → **Contents: Read and write**
- 其余全部保持 No access

把 token 设为环境变量（**不要提交进仓库**）：

```powershell
$env:GH_TOKEN = "github_pat_xxxxx"
```

> 这个 token 只用于**本机发版上传**，不会进入安装包，也不存在于客户端。

---

## 三、发一个新版本

在仓库根目录执行（`.ps1` 用 Windows PowerShell 5.1 运行即可）：

```powershell
# 0) 先做发布前预检 —— 避免跑完 10 分钟构建才在最后一步因 token 权限失败
$env:GH_TOKEN = "github_pat_xxxxx"
.\preflight.ps1

# 1) 只升版本号并构建，不发布 —— 先本地验证
.\release.ps1 -Bump

# 2) 确认没问题后发布到 GitHub Releases
.\release.ps1 -Publish

# 常用组合
.\release.ps1 -Bump -Publish        # 升版本 + 构建 + 发布
.\release.ps1 -VersionOnly          # 只同步四处版本号，不构建（自检用）
.\release.ps1 -SkipBackend          # 跳过后端重编译（只改了前端时更快）
```

`preflight.ps1` 会检查四件事，任一项不通过就别开始发版：

1. `GH_TOKEN` 是否已设置
2. token 是否有效（能否读到自己的账号）
3. token 对该仓库是否有**写权限**（`permissions.push`）
4. 本机能否连上 GitHub —— 发版要上传约 180MB，网络不稳会白跑

它还会顺带报告仓库是否公开、以及是否已有 Release。

脚本会依次：

1. **同步四处版本号**（必须一致，否则更新判断错乱）：
   - `VERSION`
   - `desktop/package.json` 的 `version`
   - `main.py` 的 `APP_VERSION`
   - `static/update-notes.json` 的 `version`（就是应用内「更新说明」面板读的那个）
2. **重新编译后端二进制**（`desktop/resources/backend/MGStudioServer.exe`）
   —— 只要 `main.py` / `server/` / `static/` 有改动就必须重编，
   否则安装包里仍是旧后端。
3. **打包 NSIS 安装包** → `desktop/release/MGStudio-Electron-Setup-<版本>.exe`
4. **发布 Release**（带 `-Publish` 时）：electron-builder 上传
   安装包 + `latest.yml` + `.blockmap`。

### 发布后自检

```powershell
# latest.yml 必须能匿名取到（这是客户端检查更新的入口）
(Invoke-WebRequest 'https://github.com/<owner>/MGCanvas2.0/releases/latest/download/latest.yml' -UseBasicParsing).Content
```

能拿到 YAML 且 `version:` 是新版本号，说明更新链路已通。

---

## 四、本次实现踩过的坑（避免重犯）

### 1. `.ps1` 必须存成「UTF-8 **带 BOM**」

PowerShell 5.1 读取**无 BOM** 的脚本时按 ANSI/GBK 解码，脚本里的中文注释
会被误解码，进而让**引号与括号配对错乱**，报出毫无关系的语法错误
（实测：报"第 19 行逗号后缺少表达式"，而真正原因是编码）。

现象与修法：

```powershell
# 现象：同一个文件，写成无 BOM 报 4 处语法错，写成带 BOM 完全通过
$raw = [IO.File]::ReadAllText($path)
[IO.File]::WriteAllText($path, $raw, (New-Object System.Text.UTF8Encoding($true)))  # true = 带 BOM
```

编辑工具（含 AI 编辑）保存后常会丢 BOM，**每次改完这个脚本都要确认 BOM 还在**：

```powershell
([IO.File]::ReadAllBytes('release.ps1'))[0..2] -join ','   # 应为 239,187,191
```

### 2. PowerShell 5.1 不支持 `$x = if (...) {...} else {...}`

这是 PS7 的语法。5.1 下会报"表达式或语句中包含意外的标记 }"。必须写成：

```powershell
$flag = 'never'
if ($Publish) { $flag = 'always' }
```

### 3. 替换版本号不能用「拼接的替换串」

```powershell
# 错误：拼接后 $1 的语义不可控，实测把 package.json 写成 `$11.0.0"`，一次损坏三个文件
[regex]::Replace($s, $pat, ('$1' + $ver + '$2'), 1)

# 正确：模式与替换串都用单引号整体写出，并用 ${1}/${2} 显式界定
[regex]::Replace($s, '(?m)^(\s*"version"\s*:\s*")[^"]+(")', ('${1}' + $ver + '${2}'), 1)
```

并且替换后要**校验结果等于目标值**，不能比较"替换前后是否变化" ——
目标版本与当前版本相同时字符串不变，会误判失败。

另外 `package.json` 的替换必须**行首锚定** (`(?m)^\s*"version"`)，
否则会误伤 `build.win.artifactName` 里的 `${version}`。

### 4. 后端二进制不入库

`.gitignore` 里忽略了 `desktop/resources/backend/` 与 `MGStudioServer.exe`。
发版时由脚本重新编译，所以**不要**指望从仓库里拿到后端。

### 5. 后端「三源兜底」目前是假的

`main.py` 里 `GITEE_*` 与 `MODELSCOPE_*` 三组 URL **全都指向 GitHub**
（`main.py:245-262`），所谓"多源兜底"实际是同一个源。
本次未处理；若以后后端静态热更变得重要，需要真正配置国内镜像地址。

---

## 五、版本号规范

- 正式版：`1.0.0`、`1.0.1` …（`main.js` 里 `allowPrerelease = 版本号含 '-'`）
- 测试版：`1.0.1-beta.1`（含 `-`，会接收 prerelease 更新）
- 升版本统一用 `.\release.ps1 -Bump`，**不要手改**，否则四处容易不一致。
