/* Zilt Phase 2 示例前端。
 * window.zilt 由 Zig 侧注入（ipc.runtime_js）：invoke/emit/on。
 * 真实 TS 工程可改用生成的 zilt-bindings.ts（zig build gen）获得完整类型。 */

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function setCheck(id, ok, note = '') {
  const el = $(id);
  el.textContent = ok ? 'PASS' : 'FAIL' + (note ? ` (${note})` : '');
  el.className = ok ? 'pass' : 'fail';
}

// ---- v0.1.5 对话框扩展 demo ----
function showOut(text) {
  const el = document.getElementById('out');
  if (el) el.textContent = text;
}

async function pickFolderDemo() {
  try {
    const r = await window.zilt.invoke('pickFolderDemo', {});
    showOut('文件夹: ' + (r.path ?? '已取消'));
  } catch (e) { showOut('错误: ' + e); }
}

async function pickFilesDemo() {
  try {
    const r = await window.zilt.invoke('pickFilesDemo', {});
    showOut('已选 ' + r.count + ' 个文件' + (r.paths ? ': ' + r.paths.join(' ; ') : ''));
  } catch (e) { showOut('错误: ' + e); }
}

async function pickColorDemo() {
  try {
    const r = await window.zilt.invoke('pickColorDemo', {});
    if (r.rgb == null) return showOut('颜色已取消');
    showOut('颜色: #' + r.rgb.toString(16).padStart(6, '0'));
  } catch (e) { showOut('错误: ' + e); }
}

async function pickFontDemo() {
  try {
    const r = await window.zilt.invoke('pickFontDemo', {});
    if (r.name == null) return showOut('字体已取消');
    showOut('字体: ' + r.name + ' ' + r.size + 'pt' + (r.bold ? ' bold' : ''));
  } catch (e) { showOut('错误: ' + e); }
}

// ---- v0.1.6：多窗口 / 窗口控制 / 剪贴板 / 拖放 / 深链接 ----
function winOut(text) {
  const el = document.getElementById('winout');
  if (el) el.textContent = text;
}

async function newWindowDemo() {
  try {
    const r = await window.zilt.invoke('newWindowDemo', {});
    winOut(`已创建窗口 #${r.id}`);
  } catch (e) { winOut('新建窗口失败: ' + e); }
}

// ---- v0.1.7：窗口模型 demo ----
async function newWindowWith(opts, note) {
  try {
    const r = await window.zilt.invoke('newWindowDemo', opts);
    winOut(`${note}：窗口 #${r.id}`);
  } catch (e) { winOut(note + '失败: ' + e); }
}

function newFramelessWindow() {
  return newWindowWith({ title: 'Zilt 无边框窗口', decorations: false, width: 620, height: 420, path: '/second.html' }, '无边框窗口');
}

function newTransparentWindow() {
  return newWindowWith({
    title: 'Zilt 透明窗口', decorations: false, transparent: true,
    width: 560, height: 400, path: '/transparent.html', close_requested_event: true,
  }, '透明窗口');
}

function newTopmostWindow() {
  return newWindowWith({ title: 'Zilt 置顶窗口', always_on_top: true, width: 600, height: 420, path: '/second.html?autoshow=1' }, '置顶窗口');
}

function newSkipTaskbarWindow() {
  return newWindowWith({ title: 'Zilt 隐藏任务栏窗口', skip_taskbar: true, width: 600, height: 420, path: '/second.html' }, '隐藏任务栏窗口');
}

function newHiddenWindow() {
  return newWindowWith({
    title: 'Zilt 隐藏创建窗口', visible: false, width: 600, height: 420,
    path: '/second.html?autoshow=1',
  }, '隐藏创建窗口');
}

async function winCtl(action, extra = {}) {
  try {
    const r = await window.zilt.invoke('windowControlDemo', Object.assign({ action }, extra));
    winOut(`窗口操作 ${action}: ${r.ok ? 'ok' : '失败'}`);
  } catch (e) { winOut('窗口操作失败: ' + e); }
}

async function clipboardWriteDemo() {
  try {
    await window.zilt.invoke('clipboardWriteDemo', { text: $('clipin').value || 'Zilt clipboard' });
    winOut('已写入剪贴板');
  } catch (e) { winOut('写剪贴板失败: ' + e); }
}

async function clipboardReadDemo() {
  try {
    const r = await window.zilt.invoke('clipboardReadDemo', {});
    winOut('剪贴板: ' + (r.text ?? '(空)'));
  } catch (e) { winOut('读剪贴板失败: ' + e); }
}

async function runChecks() {
  try {
    // 1. greet：嵌套返回字段
    const g = await window.zilt.invoke('greet', { name: 'Zilt' });
    setCheck('c-greet', g.message === 'Hello, Zilt!' && g.length === 12, JSON.stringify(g));
    $('out').textContent = g.message;

    // 2. add：数值
    const sum = await window.zilt.invoke('add', { a: 2, b: 3 });
    setCheck('c-add', sum === 5, String(sum));

    // 3. failNow：reject 携带 Zig 错误名
    try {
      await window.zilt.invoke('failNow', {});
      setCheck('c-fail', false, 'no reject');
    } catch (e) {
      setCheck('c-fail', String(e.message).includes('DemoFailure'), e.message);
    }

    // 4. queryUser：可选嵌套对象
    const u = await window.zilt.invoke('queryUser', { id: 7 });
    setCheck('c-user', !!u.user && u.user.name === 'Ann' && u.user.id === 7, JSON.stringify(u));

    // 5. Zig→JS 事件（后台线程 emit）
    let ticks = 0;
    const onTick = () => ticks++;
    window.zilt.on('tick', onTick);
    await window.zilt.invoke('startTicker', { count: 3, interval_ms: 100 });
    await sleep(900);
    window.zilt.invoke('stopTicker', {});
    window.zilt.on('tick', (n) => { $('ticks').textContent = `tick #${n.n}`; });
    setCheck('c-event', ticks >= 3, `${ticks} ticks`);

    // 6. 枚举参数
    const m = await window.zilt.invoke('setMode', { mode: 'fast' });
    setCheck('c-mode', m.applied === 'fast', JSON.stringify(m));

    // 7. 剪贴板往返（v0.1.6）
    const cb = await window.zilt.invoke('clipboardRoundtrip', { text: 'zilt-clip-0.1.6' });
    setCheck('c-clip', cb.ok === true, JSON.stringify(cb));

    // 8. 窗口控制（标题设置 + 还原；v0.1.6）
    const w1 = await window.zilt.invoke('windowTitleDemo', { title: 'Zilt v0.1.7 — 冒烟' });
    const w2 = await window.zilt.invoke('windowTitleDemo', { title: 'Zilt — v0.1.7 示例' });
    setCheck('c-win', w1.ok === true && w2.ok === true);

    // 9. 窗口事件（v0.1.7）：resize 后应收到 windowResized
    let resized = false;
    window.zilt.on('windowResized', (p) => { if (p.id === 1) resized = true; });
    await window.zilt.invoke('windowControlDemo', { action: 'set_size', width: 900, height: 650 });
    await sleep(400);
    await window.zilt.invoke('windowControlDemo', { action: 'set_size', width: 960, height: 700 });
    await sleep(300);
    setCheck('c-winevent', resized, 'no windowResized');

    // 10. Range/206 资产分块（v0.1.6）
    try {
      const rr = await fetch('/styles.css', { headers: { Range: 'bytes=0-9' } });
      const ab = await rr.arrayBuffer();
      setCheck('c-range', rr.status === 206 && ab.byteLength === 10, `status=${rr.status} len=${ab.byteLength}`);
    } catch (e) {
      setCheck('c-range', false, String(e));
    }

    // 11. 系统通知（托盘气球 → Toast；冒烟断言走 Zig 日志）
    await window.zilt.invoke('notifyMe', { title: 'Zilt 冒烟', body: '系统通知链路验证' });

    // 12. v0.1.11 window.zilt.window：创建并关闭子窗口
    try {
      const apiOk = typeof window.zilt.window.create === 'function' && typeof window.zilt.window.setSize === 'function';
      const created = await window.zilt.window.create({ title: 'Zilt v0.1.11 冒烟', width: 320, height: 240, label: 'smoke-' + Date.now() });
      const childOk = !!created && created.id > 1;
      if (childOk) {
        await sleep(600); // 等 controller 异步创建完成，再走正常关闭路径
        await window.zilt.window.close(created.id);
      }
      setCheck('c-windowapi', apiOk && childOk, JSON.stringify(created));
    } catch (e) { setCheck('c-windowapi', false, String(e)); }

    // 13. v0.1.9 eval Promise（异步 completion 回传）
    try {
      const v = await window.zilt.eval('1 + 41');
      setCheck('c-eval', v === 42, JSON.stringify(v));
    } catch (e) { setCheck('c-eval', false, String(e)); }

    // 14. v0.1.10 运行时 WebView API（缩放回读）
    try {
      const z = await window.zilt.webview.getZoom();
      setCheck('c-webview', !!z && typeof z.factor === 'number' && z.factor > 0, JSON.stringify(z));
    } catch (e) { setCheck('c-webview', false, String(e)); }

    // 15. v0.1.11 capability 清单随构建生成并嵌入资产
    try {
      const res = await fetch('/bindings/capabilities.json');
      const cap = await res.json();
      const ok = res.status === 200 && Array.isArray(cap.capabilities) && cap.capabilities.length >= 1 &&
                 Array.isArray(cap.deny_commands) && cap.deny_commands.includes('blockedDemo');
      setCheck('c-capability', ok, JSON.stringify(cap));
    } catch (e) { setCheck('c-capability', false, String(e)); }

    // 16. v0.1.12 剪贴板多格式（text / html 读写）
    try {
      await window.zilt.clipboard.writeText('zilt-v0.1.12-smoke');
      const text = await window.zilt.clipboard.read('text');
      await window.zilt.clipboard.writeHtml('<b>zilt-html</b>');
      const html = await window.zilt.clipboard.read('html');
      setCheck('c-clipmulti', text === 'zilt-v0.1.12-smoke' && typeof html === 'string' && html.includes('zilt-html'), `${text} / ${html}`);
    } catch (e) { setCheck('c-clipmulti', false, String(e)); }

    // 17. v0.1.12 通知权限/状态查询
    try {
      const st = await window.zilt.notification.status();
      setCheck('c-notification', !!st && typeof st.status === 'string', JSON.stringify(st));
    } catch (e) { setCheck('c-notification', false, String(e)); }

    // 18. v0.1.11 ACL：显式拒绝名单中的命令必须返回 PermissionDenied
    try {
      let denied = false;
      try { await window.zilt.invoke('blockedDemo', {}); }
      catch (e) { denied = String(e.message).includes('PermissionDenied'); }
      setCheck('c-acl', denied, denied ? 'PermissionDenied' : 'not denied');
    } catch (e) { setCheck('c-acl', false, String(e)); }

    // 19. v0.1.8 SPA History 路由回退：/account/settings 应以 document context 命中 index.html
    // sandbox 只开 allow-same-origin（不执行脚本），避免 iframe 内再次触发 runChecks。
    try {
      const spaOk = await Promise.race([
        new Promise((resolve) => {
          const frame = document.createElement('iframe');
          frame.setAttribute('sandbox', 'allow-same-origin');
          frame.style.display = 'none';
          frame.onload = () => {
            const html = frame.contentDocument ? frame.contentDocument.documentElement.innerHTML : '';
            frame.remove();
            resolve(html.includes('id="checks"'));
          };
          frame.onerror = () => { frame.remove(); resolve(false); };
          frame.src = '/account/settings';
          document.body.appendChild(frame);
        }),
        sleep(3000).then(() => false),
      ]);
      setCheck('c-spa', spaOk, spaOk ? 'index.html fallback' : 'no fallback');
    } catch (e) { setCheck('c-spa', false, String(e)); }

    // 19. v0.1.13：托盘菜单勾选态同步（模型 → HMENU → JSON 快照）
    try {
      await window.zilt.menu.set('tray-check', { checked: true });
      const snapshot = await window.zilt.menu.list();
      const synced = JSON.stringify(snapshot).includes('"checked":true');
      setCheck('c-traycheck', synced, synced ? 'checked=true' : 'not synced');
      await window.zilt.menu.set('tray-check', { checked: false });
    } catch (e) { setCheck('c-traycheck', false, String(e)); }

    // 20. v0.1.13：任务栏进度 + 闪烁
    try {
      const progress = await window.zilt.taskbar.progress(0.5, 'normal');
      const flash = await window.zilt.taskbar.flash(1);
      setTimeout(() => { window.zilt.taskbar.clearProgress().catch(() => {}); }, 400);
      // progress 返回 false 表示本机 COM 未暴露 ITaskbarList3（能力探测失败，非错误）
      const wired = typeof progress === 'boolean' && typeof flash === 'boolean';
      const applied = progress === true;
      setCheck('c-taskbar', wired, wired
        ? (applied ? 'progress 50% + flash' : 'API wired / ITaskbarList3 unsupported')
        : 'progress/flash failed');
    } catch (e) { setCheck('c-taskbar', false, String(e)); }

    // 21. v0.1.13：运行时快捷键注册 / 查询 / 注销
    try {
      await window.zilt.hotkey.register('smoke-hotkey', 'Ctrl+Alt+F9');
      const list = await window.zilt.hotkey.list();
      const registered = Array.isArray(list) && list.some((h) => h.id === 'smoke-hotkey');
      await window.zilt.hotkey.unregister('smoke-hotkey');
      const after = await window.zilt.hotkey.list();
      const removed = Array.isArray(after) && !after.some((h) => h.id === 'smoke-hotkey');
      setCheck('c-hotkey', registered && removed, registered && removed ? 'Ctrl+Alt+F9 ok' : 'register/unregister mismatch');
    } catch (e) { setCheck('c-hotkey', false, String(e)); }

    // 22. v0.1.14：系统信息（OS + 显示器）
    try {
      const info = await window.zilt.system.info('all');
      const ok = !!info && !!info.os && info.os.build > 0 &&
        Array.isArray(info.monitors) && info.monitors.length > 0;
      setCheck('c-sysinfo', ok, ok
        ? `${info.os.name} ${info.os.version} / ${info.monitors.length} 显示器`
        : 'missing fields');
    } catch (e) { setCheck('c-sysinfo', false, String(e)); }

    // 23. v0.1.14：窗口外观（暗色标题栏 + Mica）
    try {
      const applied = await window.zilt.appearance.apply({ dark_titlebar: true, backdrop: 'mica' });
      setCheck('c-appearance', applied === true, applied ? 'mica + dark titlebar' : 'not applied');
    } catch (e) { setCheck('c-appearance', false, String(e)); }

    // 24. v0.1.14：开机自启状态往返（启用后立即关闭，避免污染系统设置）
    try {
      const on = await window.zilt.autostart.enable();
      const off = await window.zilt.autostart.disable();
      const ok = !!on && on.enabled === true && !!off && off.enabled === false;
      setCheck('c-autostart', ok, ok ? 'enable → disable' : 'state mismatch');
    } catch (e) { setCheck('c-autostart', false, String(e)); }

    $('ver').textContent = window.zilt.version;
    $('conn').textContent = '已连接（IPC 正常）';
    // 上报给 Zig 侧断言（events.smokeResult → 通过则退出码 0）
    window.zilt.emit('smokeResult', {
      greet: $('c-greet').className === 'pass',
      add: $('c-add').className === 'pass',
      fail: $('c-fail').className === 'pass',
      user: $('c-user').className === 'pass',
      event: $('c-event').className === 'pass',
      mode: $('c-mode').className === 'pass',
      clip: $('c-clip').className === 'pass',
      win: $('c-win').className === 'pass',
      range: $('c-range').className === 'pass',
      winevent: $('c-winevent').className === 'pass',
      windowapi: $('c-windowapi').className === 'pass',
      eval: $('c-eval').className === 'pass',
      webview: $('c-webview').className === 'pass',
      capability: $('c-capability').className === 'pass',
      clipmulti: $('c-clipmulti').className === 'pass',
      notification: $('c-notification').className === 'pass',
      acl: $('c-acl').className === 'pass',
      spa: $('c-spa').className === 'pass',
      traycheck: $('c-traycheck').className === 'pass',
      taskbar: $('c-taskbar').className === 'pass',
      hotkey: $('c-hotkey').className === 'pass',
      sysinfo: $('c-sysinfo').className === 'pass',
      appearance: $('c-appearance').className === 'pass',
      autostart: $('c-autostart').className === 'pass',
    });
  } catch (e) {
    window.zilt.emit('smokeResult', { fatal: String(e) });
  }
}

function greetInteractive() {
  window.zilt.invoke('greet', { name: $('name').value || 'anon' })
    .then((g) => { $('out').textContent = g.message; })
    .catch((e) => { $('out').textContent = 'error: ' + e.message; });
}

function addInteractive() {
  window.zilt.invoke('add', { a: parseFloat($('a').value), b: parseFloat($('b').value) })
    .then((s) => { $('out').textContent = `= ${s}`; })
    .catch((e) => { $('out').textContent = 'error: ' + e.message; });
}

window.addEventListener('DOMContentLoaded', () => {
  $('btn-checks').addEventListener('click', runChecks);
  // 更新器事件展示
  window.zilt.on('updateInfo', (p) => { $('upout').textContent = p.version ? `发现新版本 ${p.version}: ${p.notes}` : p.notes; });
  window.zilt.on('updateStaged', (p) => { $('upout').textContent = `已就绪 ${p.version}（重启应用生效）`; });
  window.zilt.on('updaterFailed', (p) => { $('upout').textContent = `更新失败[${p.stage}]: ${p.err}`; });
  // 菜单 / 快捷键 / 对话框
  const dlg = (t) => { $('dlgout').textContent = t; };
  window.showDlg = dlg;
  window.zilt.on('menu', async (p) => {
    dlg(`菜单: ${p.id}`);
    if (p.id === 'exit') window.zilt.invoke('exitApp', {});
    if (p.id === 'about') window.zilt.invoke('alertBox', { text: 'Zilt v0.1.7 — Zig WebView GUI Framework', title: '关于 Zilt' });
    if (p.id === 'new-window') newWindowDemo();
    if (p.id === 'open') {
      try {
        const r = await window.zilt.invoke('pickFile', {});
        dlg(r.path ? `已选文件: ${r.path}` : '已取消');
      } catch (e) { dlg('打开文件失败: ' + e); }
    }
  });
  window.zilt.on('hotkey', (p) => dlg(`快捷键: ${p.id}`));

  // 托盘右键菜单（v0.1.6）
  window.zilt.on('trayMenu', (p) => {
    winOut(`托盘菜单: ${p.id}`);
    if (p.id === 'show-window') winCtl('show');
    else if (p.id === 'hide-window') winCtl('hide');
    else if (p.id === 'new-window') newWindowDemo();
    else if (p.id === 'about') window.zilt.invoke('alertBox', { text: 'Zilt v0.1.7 — Zig WebView GUI Framework', title: '关于 Zilt' });
    else if (p.id === 'exit') window.zilt.invoke('exitApp', {});
  });

  // 文件拖放（v0.1.6）：把文件拖进窗口
  window.zilt.on('dropFiles', (p) => {
    winOut(`拖入 ${p.files.length} 个文件: ${p.files.join(' ; ')}`);
  });

  // 深链接 / 第二实例参数转发（v0.1.6）
  window.zilt.on('deepLink', (p) => {
    const parts = [];
    if (p.url) parts.push(`URL=${p.url}`);
    if (p.files && p.files.length) parts.push(`文件=${p.files.join(' ; ')}`);
    winOut('深链接: ' + (parts.length ? parts.join(' ') : '(空)'));
  });

  // 窗口模型事件（v0.1.7）
  window.zilt.on('windowMoved', (p) => { if (p.id !== 1) winOut(`窗口#${p.id} moved ${p.x},${p.y}`); });
  window.zilt.on('windowResized', (p) => { if (p.id !== 1) winOut(`窗口#${p.id} resized ${p.width}x${p.height}`); });
  window.zilt.on('windowFocus', (p) => { if (p.id !== 1) winOut(`窗口#${p.id} focus`); });
  window.zilt.on('windowBlur', (p) => { if (p.id !== 1) winOut(`窗口#${p.id} blur`); });
  window.zilt.on('windowThemeChanged', (p) => winOut(`主题: ${p.theme}`));
  window.zilt.on('windowScaleFactorChanged', (p) => winOut(`DPI 缩放: ${p.scale_factor.toFixed(2)}`));
  window.zilt.on('windowCloseRequested', (p) => winOut(`窗口#${p.id} 请求关闭（前端确认）`));

  // 子窗口销毁通知（v0.1.7 由 windowClosed 更名）
  window.zilt.on('windowDestroyed', (p) => winOut(`窗口 #${p.id} 已销毁`));

  // 自动运行（供自动化冒烟测试；页面重载后亦会重跑）
  runChecks();
});
