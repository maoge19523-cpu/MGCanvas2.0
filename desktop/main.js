// MGStudio Desktop — Electron 主进程
// 职责：
//  1. 拉起 FastAPI 后端（python main.py 或 bundled 二进制）并等待端口就绪
//  2. 创建窗口加载本地页面（无边框 + 系统托盘，对齐现有 pywebview 桌面版体验）
//  3. 通过 IPC 提供 pywebview 兼容桥（原生对话框/窗口控制/数据目录/自启/主题）
//  4. 退出时确保结束后端进程，避免残留占用端口
//  5. iframe 子页面注入迷你桥（postMessage 转发），前端零改动获得完整桌面能力

const { app, BrowserWindow, shell, dialog, ipcMain, Tray, Menu } = require('electron');
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');

// 后端端口：与正式版一致使用 3000（数据目录也相同，Electron 版就是正式版的桌面壳）。
// 若 3000 上已有 MGStudio 后端在跑（正式版/网页版），直接复用而不重复启动；
// 若被无关程序占用，resolvePort 自动顺延到 3001+。
const DEFAULT_PORT = 3000;
let backendProc = null;
let mainWindow = null;
let tray = null;
let isQuitting = false;
let backendLog = [];
let dataDir = '';

// ---------- 日志文件（便于真机排查） ----------
let logFile = '';
function logToFile(msg) {
  try {
    if (!logFile) {
      const dir = app.isPackaged
        ? (process.env.APPDATA || app.getPath('appData'))
        : require('os').tmpdir();
      logFile = path.join(dir, 'mgstudio-electron.log');
    }
    fs.appendFileSync(logFile, '[' + new Date().toISOString() + '] ' + msg + String.fromCharCode(10));
  } catch (_) {}
}
function clog(area, msg) {
  console.log('[' + area + ']', msg);
  logToFile('[' + area + '] ' + msg);
}

// ---------- 路径解析 ----------
function resolveMainPy() {
  const candidates = [
    process.resourcesPath ? path.join(process.resourcesPath, 'backend', 'main.py') : null,
    path.join(__dirname, '..', 'main.py'),
    path.join(process.cwd(), 'main.py'),
  ];
  return candidates.find((p) => p && fs.existsSync(p)) || null;
}

function resolveBackendBinary() {
  if (app.isPackaged) {
    // 只检查 Resources/backend 下的 bundled 后端二进制。
    // 绝不能查 path.dirname(process.execPath)：那是 Electron 主程序自身所在目录，
    // 里面有一个叫 MGStudio 的可执行文件（就是本 app），误查会导致“把自己当后端 spawn 自己”。
    const binNames = process.platform === 'win32' ? ['MGStudioServer.exe', 'MGStudioServer.exe'] : ['MGStudioServer', 'MGStudio.app'];
    const base = process.resourcesPath ? path.join(process.resourcesPath, 'backend') : null;
    if (!base) return null;
    for (const name of binNames) {
      const p = path.join(base, name);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

// 数据目录：与正式版 launcher.py 完全一致（Windows = APPDATA/MGStudio，macOS/Linux = ~/MGStudio），
// 确保 Electron 版与正式版共享同一份用户数据（画布/配置/对话）——
// 用户从正式版换到 Electron 版无需迁移、无需重新下载任何数据。
// 独立于 .app 包内部（可写、非只读、升级不丢）。
function resolveDataDir() {
  if (!app.isPackaged) return path.join(__dirname, '..', 'data');
  const dir = path.join(process.env.APPDATA || require('os').homedir(), 'MGStudio');
  // 兼容早期 Electron 测试版（数据曾写到系统 appData/MGStudio，macOS 上与正式版不一致）：
  // 正式目录不存在而旧目录存在时整体搬迁，避免老测试用户数据"消失"。
  try {
    const legacy = path.join(app.getPath('appData'), 'MGStudio');
    if (legacy !== dir && !fs.existsSync(dir) && fs.existsSync(legacy)) {
      fs.renameSync(legacy, dir);
      clog('boot', '已迁移旧版 Electron 数据目录: ' + legacy + ' -> ' + dir);
    }
  } catch (_) {}
  return dir;
}

// ---------- 后端日志 ----------
function logBackend(line) {
  const s = String(line || '').trimEnd();
  if (s) {
    backendLog.push(s);
    if (backendLog.length > 500) backendLog.shift();
    console.log('[backend]', s);
    logToFile('[backend] ' + s);
  }
}

// ---------- 等待后端就绪 ----------
function waitForServer(url, timeoutMs = 180000, intervalMs = 400) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const attempt = () => {
      const req = http.get(url, (res) => {
        res.resume();
        resolve(true);
      });
      req.setTimeout(2000, () => req.destroy());
      req.on('error', () => {
        if (Date.now() - start > timeoutMs) {
          reject(new Error('等待后端服务启动超时'));
        } else {
          setTimeout(attempt, intervalMs);
        }
      });
    };
    attempt();
  });
}

// ---------- 端口占用检测 ----------
function isPortInUse(port) {
  return new Promise((resolve) => {
    const socket = require('net').connect({ host: '127.0.0.1', port, timeout: 800 });
    socket.on('connect', () => { socket.destroy(); resolve(true); });
    socket.on('error', () => { socket.destroy(); resolve(false); });
  });
}

async function resolvePort(preferred) {
  if (!(await isPortInUse(preferred))) return preferred;
  for (let p = preferred + 1; p < preferred + 50; p++) {
    if (!(await isPortInUse(p))) return p;
  }
  return preferred;
}

// 判断指定端口上跑的是不是"同一个版本"的 MGStudio 后端（而非碰巧占端口的无关程序、
// 也不是另一个版本的旧安装）。
//
// 依据：/static/update-notes.json 是 MGStudio 特有的接口，返回含 version 字段的 JSON。
//
// ⚠️ 为什么必须比对版本号：
// 前端资源（index.html 等）是由后端进程按自己的 static/ 目录提供的，不是由 Electron 壳提供。
// 若只判断"是不是同类后端"就复用，新壳会连到旧版后端上，于是整个界面（含品牌标识、
// 版本号）都还是旧版的 —— 装完新包却看到旧界面、甚至看到旧品牌名，就是这个原因。
// 曾经只判断种类不判断版本，导致新装版本复用老版本后端。
function probeBackend(port) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/static/update-notes.json', timeout: 1500 }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; if (body.length > 8192) req.destroy(); });
      res.on('end', () => {
        try {
          const data = JSON.parse(body);
          resolve(data && data.version ? String(data.version).trim() : null);
        } catch (_) { resolve(null); }
      });
      res.on('error', () => resolve(null));
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

// ---------- 陈旧后端检测 ----------
// 事故背景（真实发生）：安装新版时若旧后端进程仍在运行，
//   · 后端 exe 被占用 → 安装程序跳过替换 → 机器上留下旧 exe
//   · 但 VERSION 文件是普通文本，安装程序换掉了 → 旧 exe 也回报新版本号
//   · 新壳探测到"版本一致" → 判定同版本、直接复用 → 一直用旧后端
// 结果是：壳已升级，界面资源与更新源配置却全是旧的，且用户完全看不出来
// （版本号显示正常、重启也没用，因为进程从来没退）。
//
// 这里按端口找出监听进程，确认它**属于当前安装目录**（避免误杀其它软件），
// 再比较 exe 时间戳：比当前进程启动时间还早的，就是在本次启动之前遗留的
// 陈旧后端，结束它，让新壳正常拉起自带的后端。

function findListeningPids(port) {
  // 返回监听指定端口的 PID 列表（Windows: netstat；其它平台返回空）
  if (process.platform !== 'win32') return [];
  try {
    const out = require('child_process').execSync('netstat -ano -p TCP', {
      encoding: 'utf8', timeout: 5000, windowsHide: true,
    });
    const pids = new Set();
    for (const line of out.split(/\r?\n/)) {
      // 形如：  TCP    127.0.0.1:3000    0.0.0.0:0    LISTENING    24148
      const m = line.match(/^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/i);
      if (m && Number(m[1]) === Number(port)) pids.add(m[2]);
    }
    return Array.from(pids);
  } catch (_) { return []; }
}

function processPathOf(pid) {
  // 取进程可执行文件路径。优先 PowerShell（在受限语言模式下也可用 Get-Process），
  // 失败则返回空串 —— 调用方据此决定是否放宽判定，而不是直接放弃清理。
  for (const cmd of [
    `powershell -NoProfile -Command "(Get-Process -Id ${pid} -ErrorAction Stop).Path"`,
    `wmic process where "ProcessId=${pid}" get ExecutablePath /value`,
  ]) {
    try {
      const out = require('child_process')
        .execSync(cmd, { encoding: 'utf8', timeout: 6000, windowsHide: true })
        .trim();
      const m = out.match(/^ExecutablePath=(.+)$/mi);
      const p = (m ? m[1] : out).trim();
      if (p) return p;
    } catch (_) { /* 换下一种方式 */ }
  }
  return '';
}

function killStaleBackendOnPort(port) {
  // 结束"是 MGStudio 后端、且 exe 早于本次启动"的残留进程。
  // 返回被结束的 PID 数组，便于记日志。
  //
  // 为什么要按 exe 时间判断，而不是直接杀掉端口上的后端：
  //   同一份安装被启动两次（多实例）时，复用已有后端是正确的，不能误杀；
  //   只有"exe 比本次启动还早"才说明它是上次安装遗留的进程。
  if (process.platform !== 'win32' || !app.isPackaged) return [];
  const backendDir = path.join(process.resourcesPath, 'backend');
  const currentExe = path.join(backendDir, 'MGStudioServer.exe');
  // exe 不存在或读不到时间，则跳过清理（不冒险误杀）
  try { fs.statSync(currentExe); } catch (_) { return []; }
  const processStartMs = Date.now() - Math.round(process.uptime() * 1000);
  const norm = (p) => path.resolve(p).toLowerCase();
  const killed = [];
  for (const pid of findListeningPids(port)) {
    try {
      // ① 必须是 MGStudioServer（用 tasklist 判定进程名，最可靠；
      //    wmic/PowerShell 在受限环境可能不可用，故不作唯一依据）
      let imageName = '';
      try {
        const tl = require('child_process')
          .execSync(`tasklist /FI "PID eq ${pid}" /FO CSV /NH`,
            { encoding: 'utf8', timeout: 5000, windowsHide: true })
          .trim();
        const m = tl.match(/^"([^"]+)"/);
        imageName = m ? m[1] : '';
      } catch (_) { continue; }
      if (imageName.toLowerCase() !== 'mgstudioserver.exe') continue;

      // ② 取进程路径做归属确认；取不到路径时，仅凭进程名也允许清理
      //    —— 否则一旦 wmic/PowerShell 都不可用，残留进程就永远清不掉，
      //       又会退回"新壳连旧后端"的老问题。
      const exePath = processPathOf(pid);
      if (exePath && norm(path.dirname(exePath)) !== norm(backendDir)) continue;

      // ③ exe 比本次启动还早 → 上次安装遗留的陈旧后端
      let mtime = 0;
      try { mtime = fs.statSync(exePath || currentExe).mtimeMs; } catch (_) {}
      if (!mtime || mtime >= processStartMs) continue;

      require('child_process').execSync(`taskkill /PID ${pid} /F /T`, {
        stdio: 'ignore', timeout: 8000, windowsHide: true,
      });
      killed.push(pid);
    } catch (_) { /* 进程已消失或无权限，忽略 */ }
  }
  return killed;
}

// ---------- 启动后端 ----------
function startBackend(port) {
  return new Promise(async (resolve, reject) => {
    const mainPy = resolveMainPy();
    const binary = resolveBackendBinary();

    // 后端环境：数据/输出/素材写入用户数据目录（可写、独立于 .app、升级不丢）；
    // 资源目录（static/workflows）按 NOVAI_APP_DIR 定位（打包后为 app 内 backend 目录）。
    const backendEnv = Object.assign({}, process.env, {
      NOVAI_DATA_DIR: resolveDataDir(),
      NOVAI_APP_DIR: app.isPackaged
        ? path.dirname(mainPy || binary || '')
        : path.dirname(mainPy || ''),
      PYTHONUTF8: "1",
      PYTHONIOENCODING: "utf-8",
    });
    // Win 安装根目录传给后端：素材默认跟随安装目录（用户安装时选的大容量盘）。
    // 仅 win32 设置——mac 的 .app 包内只读、linux AppImage 挂载只读，
    // 后端写探测失败会自动回落到数据目录（~/MGStudio 或 APPDATA/MGStudio）。
    if (app.isPackaged && process.platform === 'win32') {
      backendEnv.NOVAI_INSTALL_DIR = path.dirname(process.execPath);
    }
    if (app.isPackaged) {
      try { fs.mkdirSync(backendEnv.NOVAI_DATA_DIR, { recursive: true }); } catch (_) {}
    }

    if (binary) {
      const cwd = path.dirname(binary);
      backendProc = spawn(binary, ['--port', String(port)], { cwd, env: backendEnv, stdio: ['ignore', 'pipe', 'pipe'] });
      backendProc.stdout.on('data', logBackend);
      backendProc.stderr.on('data', logBackend);
      backendProc.on('exit', (code, signal) => {
        // 只在"非退出流程中"才报异常。
        // 正常退出时我们自己调 shutdownBackend() 强杀子进程，
        // Windows 上被终止的进程 exit code 是 null（不是 0），
        // 若不看 isQuitting 就会把正常退出误报成"后端异常退出"。
        clog('boot', '后端进程退出，code = ' + code + (signal ? ' signal = ' + signal : ''));
        if (!isQuitting && app.isPackaged && code !== 0) {
          dialog.showErrorBox("MGStudio 后端异常退出", "后端进程已退出（code " + code + "）。日志：" + (logFile || "") + (backendLog.length ? String.fromCharCode(10) + backendLog.slice(-12).join(String.fromCharCode(10)) : ""));
        }
      });
      clog('boot', '启动 bundled 后端: ' + binary + ' port ' + port + ' dataDir ' + backendEnv.NOVAI_DATA_DIR);
      return resolve(backendProc);
    }

    if (!mainPy) {
      return reject(new Error('未找到后端入口 main.py，且没有 bundled 后端二进制。'));
    }

    const cwd = path.dirname(mainPy);
    const pythonCmd = process.platform === 'win32' ? 'python' : 'python3';
    const args = [mainPy, String(port)];
    backendProc = spawn(pythonCmd, args, { cwd, env: backendEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    backendProc.stdout.on('data', logBackend);
    backendProc.stderr.on('data', logBackend);
    backendProc.on('exit', (code, signal) => {
      clog('boot', '后端进程退出，code = ' + code + (signal ? ' signal = ' + signal : ''));
      // 同上：退出流程中的终止不算异常
      if (!isQuitting && app.isPackaged && code !== 0) {
        dialog.showErrorBox('MGStudio 后端异常退出', 'Python 后端未能启动，请确认已安装 Python 3.10+ 及依赖。');
      }
    });
    clog('boot', '启动 Python 后端: ' + pythonCmd + ' ' + mainPy + ' port ' + port + ' cwd ' + cwd + ' dataDir ' + backendEnv.NOVAI_DATA_DIR);
    resolve(backendProc);
  });
}

// ---------- 清理 ----------
function shutdownBackend() {
  if (backendProc && !backendProc.killed) {
    try { backendProc.kill(); } catch (_) {}
  }
}

// ---------- 托盘 ----------
function createTray() {
  if (tray) return;
  try {
    const iconPath = path.join(__dirname, 'icons', 'icon.png');
    tray = new Tray(fs.existsSync(iconPath) ? iconPath : path.join(__dirname, 'icons', 'icon.png'));
    tray.setToolTip('猫歌映画 · 无限画布');
    const menu = Menu.buildFromTemplate([
      { label: '显示主界面', click: () => { showMainWindow(); } },
      { type: 'separator' },
      {
        label: '退出猫歌映画',
        click: () => {
          isQuitting = true;
          app.quit();
        },
      },
    ]);
    tray.setContextMenu(menu);
    tray.on('click', () => showMainWindow());
  } catch (err) {
    clog('tray', '托盘创建失败: ' + err.message);
  }
}

function showMainWindow() {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

// ---------- iframe 子页面迷你桥注入 ----------
const IFRAME_SHIM = `(function(){
  if (window.__novaiShimInjected) return;
  window.__novaiShimInjected = true;
  var pending = {};
  var seq = 0;
  window.addEventListener('message', function(e){
    if (!e.data || e.data.__novaiRes !== true) return;
    var p = pending[e.data.seq];
    if (p) { delete pending[e.data.seq]; p.resolve(e.data.result); }
  });
  function call(method, payload) {
    return new Promise(function(resolve){
      var id = ++seq;
      pending[id] = { resolve: resolve };
      try {
        (window.parent.postMessage || function(){})({ __novaiReq: true, seq: id, method: method, payload: payload }, '*');
      } catch(err) { resolve(null); }
    });
  }
  window.pywebview = {
    api: {
      minimize: function(){ return call('window', {action:'minimize'}); },
      maximize: function(){ return call('window', {action:'maximize'}); },
      close: function(){ return call('window', {action:'close'}); },
      quit_app: function(){ return call('window', {action:'quit'}); },
      save_file: function(d,f){ return call('save-file', {dataUrl:d, filename:f}); },
      select_directory: function(){ return call('select-directory'); },
      open_data_dir: function(){ return call('open-data-dir'); },
      get_data_dir: function(){ return call('get-data-dir'); },
      set_auto_start: function(v){ return call('set-auto-start', {value: v}); },
      get_app_info: function(){ return call('get-app-info'); },
    }
  };
  try { window.dispatchEvent(new Event('pywebviewready')); } catch(_) {}
})();`;

function injectIframeShims(webContents) {
  const frameHandler = async (event, details) => {
    const frame = details.frame;
    if (!frame || frame === webContents.mainFrame) return;
    try {
      const url = frame.url || '';
      if (!(url.startsWith('http://127.0.0.1') || url.startsWith('http://localhost'))) return;
      await frame.executeJavaScript(IFRAME_SHIM, true);
    } catch (err) {
      // 注入失败静默
    }
  };
  webContents.on('frame-created', frameHandler);
}

// ---------- IPC：pywebview 兼容桥 ----------
function registerIpc() {
  ipcMain.handle('novai:window', async (e, { action }) => {
    if (!mainWindow) return null;
    switch (action) {
      case 'minimize': mainWindow.minimize(); break;
      case 'maximize':
        if (mainWindow.isMaximized()) mainWindow.unmaximize();
        else mainWindow.maximize();
        break;
      case 'close':
        mainWindow.hide();
        break;
      case 'quit': isQuitting = true; app.quit(); break;
      default: break;
    }
    return true;
  });

  ipcMain.handle('novai:save-file', async (e, { dataUrl, filename }) => {
    try {
      const win = BrowserWindow.fromWebContents(e.sender) || mainWindow;
      const result = await dialog.showSaveDialog(win, {
        title: '保存文件',
        defaultPath: filename || 'download.png',
        filters: [
          { name: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'] },
          { name: '全部文件', extensions: ['*'] },
        ],
      });
      if (result.canceled || !result.filePath) return { ok: true, saved: false };
      const m = /^data:([^;]+);base64,(.+)$/.exec(dataUrl || '');
      if (!m) return { ok: true, saved: false };
      fs.writeFileSync(result.filePath, Buffer.from(m[2], 'base64'));
      return { ok: true, saved: true, path: result.filePath };
    } catch (err) {
      return { ok: false, saved: false, error: String(err && err.message || err) };
    }
  });

  ipcMain.handle('novai:select-directory', async (e) => {
    const win = BrowserWindow.fromWebContents(e.sender) || mainWindow;
    const res = await dialog.showOpenDialog(win, {
      title: '选择文件夹',
      properties: ['openDirectory', 'createDirectory'],
    });
    if (res.canceled || !res.filePaths.length) return null;
    return res.filePaths[0];
  });

  ipcMain.handle('novai:get-data-dir', () => dataDir);
  ipcMain.handle('novai:open-data-dir', () => {
    if (dataDir && fs.existsSync(dataDir)) shell.openPath(dataDir);
    return true;
  });

  ipcMain.handle('novai:set-auto-start', (e, { value }) => {
    try { app.setLoginItemSettings({ openAtLogin: !!value }); } catch (_) {}
    return true;
  });

  ipcMain.handle('novai:set-titlebar-theme', (e, { r, g, b }) => {
    if (mainWindow && process.platform === 'darwin') {
      try { mainWindow.setBackgroundColor(`rgb(${r}, ${g}, ${b})`); } catch (_) {}
    }
    return true;
  });

  ipcMain.handle('novai:get-app-info', () => ({
    version: app.getVersion(),
    platform: process.platform,
    electron: process.versions.electron,
  }));
}

// ---------- 自动更新 ----------
let autoUpdater = null;
// 更新进度窗：electron-updater 自己没有下载进度界面，若不监听
// download-progress，用户点完「立即更新」会在整个 180MB 下载期间
// 看不到任何反馈，极易误判为"没反应"或重复点击。
let updateProgressWin = null;
let updateProgressState = { percent: 0, transferred: 0, total: 0, bytesPerSecond: 0 };

function fmtMB(n) { return (Number(n || 0) / 1048576).toFixed(1); }

function openUpdateProgressWin() {
  if (updateProgressWin && !updateProgressWin.isDestroyed()) return updateProgressWin;
  updateProgressWin = new BrowserWindow({
    width: 460,
    height: 190,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    parent: mainWindow || undefined,
    modal: false,
    show: false,
    title: '正在下载更新',
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin:0; padding:16px 18px; font-family:"Microsoft YaHei",system-ui,sans-serif;
           background:#1c1c1e; color:#f2f2f2; user-select:none; }
    h1 { font-size:14px; margin:0 0 10px; font-weight:600; letter-spacing:.02em; }
    .bar { height:8px; border-radius:5px; background:#3a3a3c; overflow:hidden; }
    .fill { height:100%; width:0%; border-radius:5px;
            background:linear-gradient(135deg,#FF6A00,#FF8A2B); transition:width .18s ease-out; }
    .meta { display:flex; justify-content:space-between; margin-top:9px;
            font-size:12px; color:#b9b9be; }
    .hint { margin-top:11px; font-size:12px; color:#8e8e93; line-height:1.5; }
    .pct { font-size:20px; font-weight:700; color:#FF8A2B; margin-top:2px; }
  </style></head><body>
    <h1>正在下载新版本…</h1>
    <div class="bar"><div class="fill" id="f"></div></div>
    <div class="meta"><span id="l">准备中…</span><span id="r"></span></div>
    <div class="pct" id="p">0%</div>
    <div class="hint">下载完成后会提示重启安装。请勿关闭本窗口。</div>
    <script>
      window.__setProgress = function (s) {
        var pct = Math.max(0, Math.min(100, Number(s.percent) || 0));
        document.getElementById('f').style.width = pct.toFixed(1) + '%';
        document.getElementById('p').textContent = pct.toFixed(1) + '%';
        var mb = function (n) { return (Number(n||0)/1048576).toFixed(1); };
        document.getElementById('l').textContent =
          mb(s.transferred) + ' MB / ' + mb(s.total) + ' MB';
        document.getElementById('r').textContent =
          s.bytesPerSecond ? (mb(s.bytesPerSecond) + ' MB/s') : '';
      };
      window.__setDone = function () {
        document.getElementById('f').style.width = '100%';
        document.getElementById('p').textContent = '100%';
        document.getElementById('l').textContent = '下载完成';
        document.getElementById('r').textContent = '';
        document.querySelector('.hint').textContent = '下载完成，正在准备安装…';
      };
      window.__setError = function (msg) {
        document.getElementById('p').textContent = '失败';
        document.getElementById('p').style.color = '#ff453a';
        document.getElementById('l').textContent = String(msg || '下载失败');
        document.querySelector('.hint').textContent = '可关闭本窗口后重试，或前往发布页手动下载安装包。';
      };
    </script>
  </body></html>`;
  updateProgressWin.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
  updateProgressWin.once('ready-to-show', () => {
    // 立刻推一次当前状态，避免窗口空白
    pushUpdateProgress(updateProgressState);
    updateProgressWin.show();
  });
  updateProgressWin.on('closed', () => { updateProgressWin = null; });
  return updateProgressWin;
}

function pushUpdateProgress(state) {
  updateProgressState = Object.assign({}, updateProgressState, state || {});
  if (!updateProgressWin || updateProgressWin.isDestroyed()) return;
  const s = JSON.stringify(updateProgressState);
  updateProgressWin.webContents
    .executeJavaScript(`window.__setProgress && window.__setProgress(${s})`)
    .catch(() => {});
}

function closeUpdateProgressWin(done, errMsg) {
  if (!updateProgressWin || updateProgressWin.isDestroyed()) return;
  const js = errMsg
    ? `window.__setError && window.__setError(${JSON.stringify(String(errMsg))})`
    : 'window.__setDone && window.__setDone()';
  updateProgressWin.webContents.executeJavaScript(js).catch(() => {});
  // 完成/失败后留一点时间让用户看到结果
  setTimeout(() => {
    if (updateProgressWin && !updateProgressWin.isDestroyed()) updateProgressWin.close();
  }, errMsg ? 6000 : 1200);
}

function setupAutoUpdate() {
  if (!app.isPackaged) return;
  try {
    autoUpdater = autoUpdater || require('electron-updater').autoUpdater;
    if (!autoUpdater) return;
  } catch (_) { return; }
  autoUpdater.autoDownload = false;
  // 测试版（版本号含 -，如 1.0.112-beta.1）允许接收 prerelease 更新；正式版只看正式 Release。
  autoUpdater.allowPrerelease = app.getVersion().includes('-');
  // 说明：原上游版本在这里挂了一个"国内镜像"兜底，指向 ModelScope 的
  // /resolve/master/... 路径。换标后更新源改为本仓库的 GitHub Releases，
  // 那种魔搭式路径在 GitHub 上必然 404，属于死代码，已移除。
  // 需要国内加速时，请在仓库里配置自己的镜像源（GitHub Releases 的
  // latest.yml 必须能直接取到，不能用网页版仓库路径）。

  // 下载进度：必须监听，否则 180MB 下载期间界面毫无反馈
  let lastLoggedPct = -10;
  autoUpdater.on('download-progress', (p) => {
    const st = {
      percent: p && p.percent,
      transferred: p && p.transferred,
      total: p && p.total,
      bytesPerSecond: p && p.bytesPerSecond,
    };
    pushUpdateProgress(st);
    // 每推进 10% 记一次日志，便于事后排查"到底下到哪一步"
    const pct = Math.floor(Number(st.percent) || 0);
    if (pct >= lastLoggedPct + 10) {
      lastLoggedPct = pct;
      clog('updater', `下载进度 ${pct}% (${fmtMB(st.transferred)}/${fmtMB(st.total)} MB, ${fmtMB(st.bytesPerSecond)} MB/s)`);
    }
  });
  autoUpdater.on('update-available', (info) => {
    const current = app.getVersion();
    const next = info && info.version;
    if (!next || next === current) return;
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: '发现新版本',
      message: `MGStudio 有新版本可用：v${next}（当前 v${current}）`,
      detail: '是否现在下载并安装？下载完成后需重启应用。',
      buttons: ['立即更新', '稍后'],
      defaultId: 0,
      cancelId: 1,
    }).then(({ response }) => {
      if (response !== 0) return;
      // 打开进度窗，并重置进度状态；downloadUpdate 的失败必须捕获，
      // 否则下载启动异常会被静默吞掉（用户只看到"没反应"）。
      updateProgressState = { percent: 0, transferred: 0, total: 0, bytesPerSecond: 0 };
      openUpdateProgressWin();
      clog('updater', `开始下载 v${next}`);
      autoUpdater.downloadUpdate().catch((err) => {
        const msg = (err && err.message) || String(err);
        clog('updater', '下载失败: ' + msg);
        closeUpdateProgressWin(false, '下载失败：' + msg);
      });
    }).catch(() => {});
  });
  autoUpdater.on('update-downloaded', () => {
    closeUpdateProgressWin(true);
    clog('updater', '下载完成，等待用户确认重启安装');
    if (process.platform === 'darwin') {
      dialog.showMessageBox(mainWindow, {
        type: 'info',
        title: '更新已就绪',
        message: '新版本已下载完成，但 macOS 未签名构建不支持自动安装，请手动下载安装包覆盖安装（数据不会丢失）。',
        buttons: ['打开发布页', '稍后'],
        defaultId: 0,
        cancelId: 1,
      }).then(({ response }) => {
        if (response === 0) shell.openExternal('https://github.com/maoge19523-cpu/MGCanvas2.0/releases');
      }).catch(() => {});
      return;
    }
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: '更新已就绪',
      message: '新版本已下载完成，是否立即重启安装？',
      buttons: ['立即重启', '稍后'],
      defaultId: 0,
      cancelId: 1,
    }).then(({ response }) => {
      if (response === 0) autoUpdater.quitAndInstall();
    }).catch(() => {});
  });
  autoUpdater.on('error', (err) => {
    const msg = (err && err.message) || String(err || '未知错误');
    // 区分「检查阶段失败」与「下载阶段失败」：两者给用户的建议不同。
    const downloading = !!updateProgressWin && !updateProgressWin.isDestroyed();
    clog('updater', (downloading ? '下载失败: ' : '检查更新失败: ') + msg);
    if (downloading) closeUpdateProgressWin(false, msg);
    if (!mainWindow) return;
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: downloading ? '更新下载失败' : '自动更新不可用',
      message: downloading ? '新版本下载未完成' : '暂时无法自动检查更新',
      detail: `${msg}\n\n`
        + '常见原因：网络无法连接 GitHub，或下载过程被中断。\n'
        + '可前往发布页手动下载最新安装包覆盖安装，数据不会丢失。',
      buttons: ['前往下载', '稍后'],
      defaultId: 0,
      cancelId: 1,
    }).then(({ response }) => {
      if (response === 0) shell.openExternal('https://github.com/maoge19523-cpu/MGCanvas2.0/releases');
    }).catch(() => {});
  });
  // checkForUpdates 也返回 Promise，失败要落日志，避免"检查阶段"静默无痕
  setTimeout(() => {
    try {
      const p = autoUpdater.checkForUpdates();
      if (p && typeof p.catch === 'function') {
        p.catch((err) => clog('updater', '检查更新异常: ' + ((err && err.message) || err)));
      }
    } catch (err) {
      clog('updater', '检查更新抛错: ' + ((err && err.message) || err));
    }
  }, 8000);
}

// ---------- 窗口 ----------
function createWindow(url) {
  clog('win', '创建窗口，加载 ' + url);
  const useFrameless = process.platform === 'win32';
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 900,
    minHeight: 600,
    title: '猫歌映画 · 无限画布',
    backgroundColor: '#0f1115',
    autoHideMenuBar: true,
    frame: !useFrameless,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow.webContents.setUserAgent(
    mainWindow.webContents.getUserAgent().replace('Electron', 'Electron pywebview')
  );

  mainWindow.loadURL(url).then(() => {
    clog('win', 'loadURL resolved');
  }).catch((err) => {
    clog('win', 'loadURL failed: ' + (err && err.message || err));
  });

  mainWindow.webContents.once('ready-to-show', () => {
    clog('win', 'ready-to-show, 显示窗口');
    try { mainWindow.show(); } catch (err) { clog('win', 'show error: ' + err.message); }
  });

  mainWindow.webContents.on('did-fail-load', (e, code, desc) => {
    clog('win', 'did-fail-load ' + code + ' ' + desc);
  });

  mainWindow.on('show', () => clog('win', '窗口已显示'));
  mainWindow.on('hide', () => clog('win', '窗口已隐藏'));

  mainWindow.webContents.setWindowOpenHandler(({ url: target }) => {
    if (target && target.startsWith('http')) shell.openExternal(target);
    return { action: 'deny' };
  });

  mainWindow.webContents.on('will-navigate', (e, target) => {
    const allowed = target.startsWith(url.split('/').slice(0, 3).join('/'));
    if (!allowed) { e.preventDefault(); shell.openExternal(target); }
  });

  mainWindow.on('close', (e) => {
    if (!isQuitting && tray) {
      e.preventDefault();
      mainWindow.hide();
    }
  });

  mainWindow.on('closed', () => { mainWindow = null; });

  createTray();
  injectIframeShims(mainWindow.webContents);
}

// ---------- 生命周期 ----------
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  clog('lock', '已有实例在运行，本实例退出');
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) { showMainWindow(); }
  });

  app.whenReady().then(async () => {
    dataDir = resolveDataDir();
    registerIpc();

    const requested = Number(process.env.NOVAI_PORT) || DEFAULT_PORT;
    // 端口上若已有"同一版本"的 MGStudio 后端在跑（同一份安装被启动两次）则直接复用——
    // 数据目录相同，再起一个后端写同一数据目录会互相踩踏。
    //
    // 版本不一致时**绝不复用**：前端资源由后端进程提供，复用旧版后端会把整个界面
    // （含品牌标识与版本号）变成旧版的。此时另起本包自带的后端到下一个空闲端口。
    let port = requested;
    let reuseExisting = false;
    let existingVersion = null;

    // 先清掉"上次安装遗留、只因 VERSION 文件被换而伪装成同版本"的后端。
    // 不做这一步的话，下面的版本相等判断会误判为可复用，导致新壳一直连旧后端
    // （壳是新的、界面资源与更新源配置却是旧的，且重启无效）。
    const stalePids = killStaleBackendOnPort(requested);
    if (stalePids.length) {
      clog('boot', '已结束陈旧后端进程（exe 早于本次启动）: ' + stalePids.join(', '));
      // 给操作系统一点时间真正释放端口
      await new Promise((r) => setTimeout(r, 1200));
    }

    if (await isPortInUse(requested)) {
      existingVersion = await probeBackend(requested);
      const isSameKind = !!existingVersion;
      const isSameVersion = isSameKind && existingVersion === app.getVersion();
      if (isSameVersion) {
        reuseExisting = true;
      } else {
        port = await resolvePort(requested);
        clog('boot',
          (isSameKind
            ? '端口 ' + requested + ' 上是另一个版本的 MGStudio 后端（v' + existingVersion +
              '，本版本 v' + app.getVersion() + '）'
            : '端口 ' + requested + ' 被无关程序占用') +
          '，改在端口 ' + port + ' 启动本版本自带的后端');
      }
    }
    const baseUrl = process.env.NOVAI_URL || `http://127.0.0.1:${port}`;

    try {
      clog('boot', '数据目录: ' + dataDir);
      if (reuseExisting) {
        clog('boot', '端口 ' + port + ' 已有同版本(v' + existingVersion + ') MGStudio 后端运行，直接复用（不重复启动）');
        createWindow(baseUrl);
        setupAutoUpdate();
      } else {
        clog('boot', '开始启动后端, 端口 ' + port);
        await startBackend(port);
        clog('boot', '后端进程已启动');
        await waitForServer(baseUrl + '/');
        clog('boot', '后端服务就绪: ' + baseUrl);
        createWindow(baseUrl);
        setupAutoUpdate();
      }
    } catch (err) {
      clog('boot', '启动失败: ' + err.message);
      clog('boot', '后端日志: ' + backendLog.join(' | '));
      console.error('启动失败:', err.message, String.fromCharCode(10) + '后端日志:' + String.fromCharCode(10) + backendLog.join(String.fromCharCode(10)));
      const _bundled = !!resolveBackendBinary();
      const _hint = _bundled
        ? ("这是安装包内置的后端，不需要安装 Python。完整日志：" + (logFile || "见 %APPDATA%\\mgstudio-electron.log"))
        : "请确认已安装 Python 3.10+ 并已安装依赖。";
      const _tail = backendLog.slice(-12).join(String.fromCharCode(10));
      dialog.showErrorBox("MGStudio 启动失败",
        "无法启动后端服务：" + String.fromCharCode(10) + String.fromCharCode(10) + err.message +
        String.fromCharCode(10) + String.fromCharCode(10) + _hint +
        (_tail ? String.fromCharCode(10) + String.fromCharCode(10) + "--- 后端日志（末尾） ---" + String.fromCharCode(10) + _tail : ""));
      app.quit();
      return;
    }

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow(baseUrl);
    });
  });

  app.on('before-quit', () => { isQuitting = true; shutdownBackend(); });
  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
