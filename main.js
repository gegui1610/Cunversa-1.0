// Cunversa — app de desktop (Electron).
// Abre o SEU site (GitHub Pages). Atualizou o site no GitHub => o app já abre a versão nova, sem reinstalar.
const { app, BrowserWindow, session, desktopCapturer, shell, ipcMain, Menu } = require('electron');
const path = require('path'), fs = require('fs');

app.setAppUserModelId('com.cunversa.app');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required'); // toque de chamada e áudio sem precisar clicar antes

if (!app.requestSingleInstanceLock()) { app.quit(); return; }

const readJSON = p => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const LOCAL = path.join(__dirname, 'app', 'index.html');
let win = null;

// URL do site: variável CUNVERSA_URL > %APPDATA%\Cunversa\config.json > config.json embutido.
function siteUrl() {
  const user = readJSON(path.join(app.getPath('userData'), 'config.json')) || {};
  const bundled = readJSON(path.join(__dirname, 'config.json')) || {};
  const u = process.env.CUNVERSA_URL || user.siteUrl || bundled.siteUrl || '';
  return /^https?:\/\//i.test(u) ? u : '';
}
const originOf = u => { try { return new URL(u).origin; } catch { return ''; } };

function loadState() { return readJSON(path.join(app.getPath('userData'), 'window.json')) || {}; }
function saveState() {
  if (!win || win.isDestroyed()) return;
  try {
    const b = win.getNormalBounds();
    fs.writeFileSync(path.join(app.getPath('userData'), 'window.json'), JSON.stringify({ ...b, max: win.isMaximized() }));
  } catch {}
}

function pickSource(sources) {
  return new Promise(resolve => {
    const w = new BrowserWindow({
      parent: win, modal: true, width: 780, height: 540, resizable: false, minimizable: false, maximizable: false,
      backgroundColor: '#0b0b0d', autoHideMenuBar: true, title: 'Compartilhar tela',
      webPreferences: { preload: path.join(__dirname, 'picker-preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true }
    });
    w.setMenu(null);
    let done = false;
    const finish = v => { if (done) return; done = true; ipcMain.removeListener('picker:choose', onChoose); resolve(v); if (!w.isDestroyed()) w.close(); };
    const onChoose = (e, id) => { if (e.sender !== w.webContents) return; finish(id ? sources.find(s => s.id === id) || null : null); };
    ipcMain.on('picker:choose', onChoose);
    w.on('closed', () => finish(null));
    w.loadFile(path.join(__dirname, 'picker.html'));
    w.webContents.once('did-finish-load', () =>
      w.webContents.send('picker:sources', sources.map(s => ({ id: s.id, name: s.name, thumb: s.thumbnail.toDataURL() }))));
  });
}

function setupSession(trustedOrigin) {
  const ses = session.defaultSession;
  const ok = new Set(['media', 'display-capture', 'fullscreen', 'notifications', 'clipboard-sanitized-write', 'clipboard-read']);
  const trusted = o => !o || o.startsWith('file:') || o === trustedOrigin || o === 'null';
  ses.setPermissionRequestHandler((wc, perm, cb, details) => cb(ok.has(perm) && trusted(originOf(details && details.requestingUrl || wc.getURL()))));
  ses.setPermissionCheckHandler((wc, perm, origin) => ok.has(perm) && trusted(origin ? originOf(origin) || origin : ''));
  // Compartilhar tela: o Electron não tem seletor próprio, então mostramos o nosso.
  ses.setDisplayMediaRequestHandler(async (request, callback) => {
    try {
      const sources = await desktopCapturer.getSources({ types: ['screen', 'window'], thumbnailSize: { width: 400, height: 250 }, fetchWindowIcons: false });
      if (!sources.length) return callback({});
      const chosen = await pickSource(sources);
      if (!chosen) return callback({});
      const out = { video: chosen };
      if (request.audioRequested && process.platform === 'win32') out.audio = 'loopback'; // som do computador (só se o site pedir)
      callback(out);
    } catch { callback({}); }
  });
}

async function createWindow() {
  const st = loadState(), url = siteUrl(), origin = originOf(url);
  setupSession(origin);
  win = new BrowserWindow({
    width: st.width || 1280, height: st.height || 800, x: st.x, y: st.y, minWidth: 900, minHeight: 560,
      backgroundColor: '#050506', title: 'Cunversa', autoHideMenuBar: true, show: false,
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true,
      backgroundThrottling: false /* senão o microfone/ chamada engasga com a janela minimizada */ }
  });
  if (st.max) win.maximize();
  win.once('ready-to-show', () => win.show());
  win.on('close', saveState);

  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Cunversa', submenu: [{ role: 'reload', label: 'Recarregar' }, { role: 'forceReload', label: 'Recarregar (limpar cache)' },
      { type: 'separator' }, { role: 'togglefullscreen', label: 'Tela cheia' }, { role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' },
      { type: 'separator' }, { role: 'toggleDevTools', label: 'Ferramentas de desenvolvedor' }, { role: 'quit', label: 'Sair' }] }
  ]));

  // Links externos abrem no navegador, não dentro do app.
  win.webContents.setWindowOpenHandler(({ url: u }) => { if (/^https?:/i.test(u)) shell.openExternal(u); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, u) => { if (!u.startsWith('file:') && originOf(u) !== origin) { e.preventDefault(); if (/^https?:/i.test(u)) shell.openExternal(u); } });

  // Se o site estiver fora do ar / sem internet, abre a cópia que veio junto no app.
  let fellBack = false;
  win.webContents.on('did-fail-load', (_e, code, _d, _u, isMain) => {
    if (!isMain || code === -3 || fellBack) return;
    fellBack = true;
    if (fs.existsSync(LOCAL)) win.loadFile(LOCAL);
  });

  if (url) {
    try { await session.defaultSession.clearCache(); } catch {} // sempre pega a versão mais nova do site
    win.loadURL(url);
  } else if (fs.existsSync(LOCAL)) {
    win.loadFile(LOCAL);
  } else {
    win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent('<body style="background:#050506;color:#fff;font:16px sans-serif;padding:40px"><h2>Cunversa</h2><p>Nenhuma URL do site configurada. Edite config.json (siteUrl).</p>'));
  }
}

app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
