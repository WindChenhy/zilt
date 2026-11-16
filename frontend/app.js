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
    // 单独 try：剪贴板是**整机互斥**资源，别的进程占着时 OpenClipboard 会失败
    // （远程会话/剪贴板管理器/截图工具都可能造成）。这种环境问题不该让后面
    // 41 项检查全部瞎掉——失败仍然如实记在 c-clip 上。
    try {
      const cb = await window.zilt.invoke('clipboardRoundtrip', { text: 'zilt-clip-0.1.6' });
      setCheck('c-clip', cb.ok === true, JSON.stringify(cb));
    } catch (e) {
      setCheck('c-clip', false, String(e.message || e));
    }

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

    // 25. v0.1.16：KV 存储 + 受限 fs（含路径逃逸拒绝）
    try {
      await window.zilt.store.set('smoke', 'ok');
      const stored = await window.zilt.store.get('smoke');
      await window.zilt.fs.write('smoke-note.txt', 'hello-fs');
      const text = await window.zilt.fs.read('smoke-note.txt');
      const exists = await window.zilt.fs.exists('smoke-note.txt');
      let escapeDenied = false;
      try {
        await window.zilt.fs.read('../outside.txt');
      } catch (e) {
        escapeDenied = String(e.message).includes('PathEscape');
      }
      const ok = stored === 'ok' && text === 'hello-fs' && exists === true && escapeDenied;
      setCheck('c-storage', ok, ok ? 'store+fs ok, escape denied' : `store=${stored} fs=${text} exists=${exists} escape=${escapeDenied}`);
    } catch (e) { setCheck('c-storage', false, String(e)); }

    // 26. v0.1.16：周边 API（path / log / windowState）
    try {
      const joined = await window.zilt.path.join('a', 'b', 'c.txt');
      const base = await window.zilt.path.basename(joined);
      const ext = await window.zilt.path.extname(joined);
      await window.zilt.log('info', 'smoke peripheral api');
      const state = await window.zilt.windowState.get();
      const saved = await window.zilt.windowState.save();
      const ok = /c\.txt$/.test(joined) && base === 'c.txt' && ext === '.txt' &&
        !!state && state.width > 0 && state.height > 0 && saved === true;
      setCheck('c-peripheral', ok, ok
        ? `path/log/state ok (${state.width}x${state.height})`
        : `join=${joined} base=${base} ext=${ext} saved=${saved}`);
    } catch (e) { setCheck('c-peripheral', false, String(e)); }

    // 27. v0.1.16：服务注册表（Config 声明 → 框架 init/start → JS 可查）
    try {
      const list = await window.zilt.services.list();
      const demo = (list || []).find(x => x.name === 'demo');
      const st = await window.zilt.services.status('demo');
      const unknown = await window.zilt.services.status('nope');
      const ok = !!demo && demo.started === true && demo.scope === 'demo:read' &&
        !!st && st.started === true && unknown === null;
      setCheck('c-services', ok, ok
        ? `services ok (${list.length} registered, demo started)`
        : `list=${JSON.stringify(list)} st=${JSON.stringify(st)} unknown=${JSON.stringify(unknown)}`);
    } catch (e) { setCheck('c-services', false, String(e)); }

    // 28. v0.1.16：HTTP 异步请求。冒烟用必然拒绝连接的地址（不依赖外网），
    // 断言错误穿过 后台线程 → PostMessage → httpResponse 事件 → Promise reject 全链路。
    try {
      let httpErr = null;
      try {
        await window.zilt.http.request({ url: 'http://127.0.0.1:1/', timeout_ms: 2000 });
      } catch (e) { httpErr = String(e.message || e); }
      const ok = !!httpErr;
      setCheck('c-http', ok, ok ? `http error path ok (${httpErr})` : 'expected failure but resolved');
    } catch (e) { setCheck('c-http', false, String(e)); }

    // 29. v0.1.16：WebSocket 全链路。依赖本机 echo 服务端（scripts/ws_echo.py :8765）：
    // connect → open 事件 → send → 服务端 welcome + echo 两条 message → close → close 事件。
    try {
      // 错误路径：必然拒绝连接的地址 → error 事件（与 http 同策略，不依赖外部环境）
      let errPathOk = false;
      try {
        const errId = await window.zilt.ws.connect('ws://127.0.0.1:1/');
        const errEvents = [];
        const errOff = window.zilt.ws.on(errId, (p) => errEvents.push(p));
        await new Promise((resolve, reject) => {
          const t0 = Date.now();
          const tick = () => {
            if (errEvents.some((e) => e.kind === 'error')) return resolve();
            if (Date.now() - t0 > 4000) return reject(new Error('no error event: ' + JSON.stringify(errEvents)));
            setTimeout(tick, 100);
          };
          tick();
        });
        errOff();
        errPathOk = true;
      } catch (e) { errPathOk = false; }

      const wsEvents = [];
      const wsId = await window.zilt.ws.connect('ws://127.0.0.1:8765/smoke');
      const wsOff = window.zilt.ws.on(wsId, (p) => wsEvents.push(p));
      let sent = false;
      await new Promise((resolve, reject) => {
        const t0 = Date.now();
        const tick = () => {
          if (!sent && wsEvents.some((e) => e.kind === 'open')) {
            sent = true;
            window.zilt.ws.send(wsId, 'smoke-payload').catch(reject);
          }
          const msgs = wsEvents.filter((e) => e.kind === 'message');
          if (sent && msgs.length >= 2) return resolve();
          if (wsEvents.some((e) => e.kind === 'error')) return reject(new Error('ws error: ' + JSON.stringify(wsEvents)));
          if (Date.now() - t0 > 6000) return reject(new Error('ws timeout: ' + JSON.stringify(wsEvents.map((e) => e.kind))));
          setTimeout(tick, 100);
        };
        tick();
      });
      await window.zilt.ws.close(wsId, 1000, 'smoke done');
      // close 事件到达后再断言（超时不失败 —— 主链路已验证，清理是收尾）
      await new Promise((resolve) => {
        const t0 = Date.now();
        const tick = () => {
          if (wsEvents.some((e) => e.kind === 'close') || Date.now() - t0 > 3000) resolve();
          else setTimeout(tick, 100);
        };
        tick();
      });
      wsOff();
      const payloadOk = wsEvents.some((e) => e.kind === 'message' && e.data === 'smoke-payload');
      const welcomeOk = wsEvents.some((e) => e.kind === 'message' && (e.data || '').includes('welcome'));
      const closeOk = wsEvents.some((e) => e.kind === 'close');
      const ok = errPathOk && payloadOk && welcomeOk && closeOk;
      setCheck('c-ws', ok, ok
        ? 'ws ok (error 路径 + open→welcome→echo→close 全链路)'
        : `errPathOk=${errPathOk} events=${JSON.stringify(wsEvents.map((e) => e.kind))}`);
    } catch (e) { setCheck('c-ws', false, String(e.message || e)); }

    // 30. v0.1.16：单窗口多 WebView。create → 等 controller ready → setBounds/navigate →
    // remove → list 移除；未知 id 的 remove 返回 false。
    // 注意时序：controller 异步就绪需百毫秒级；在就绪前 remove 子 HWND 会让
    // WebView2 完成回调报 E_ABORT（官方文档行为：父窗口销毁中止创建）。
    try {
      const created = await window.zilt.webviews.create({ x: 300, y: 100, width: 320, height: 200, url: 'about:blank' });
      const id = created && created.id;
      if (!id) throw new Error('no id returned: ' + JSON.stringify(created));
      const list1 = await window.zilt.webviews.list();
      const inList = (list1 || []).some((c) => c.id === id);
      // 等 controller 就绪（ready 字段由 Zig 侧 webview 非空驱动）
      let ready = false;
      const t0 = Date.now();
      while (Date.now() - t0 < 8000) {
        const l = await window.zilt.webviews.list();
        const c = (l || []).find((x) => x.id === id);
        if (c && c.ready) { ready = true; break; }
        await new Promise((r) => setTimeout(r, 100));
      }
      const sb = await window.zilt.webviews.setBounds(id, 300, 100, 400, 260);
      const nav = await window.zilt.webviews.navigate(id, 'about:blank');
      const removed = await window.zilt.webviews.remove(id);
      const list2 = await window.zilt.webviews.list();
      const gone = !(list2 || []).some((c) => c.id === id);
      const unknown = await window.zilt.webviews.remove(999999);
      const ok = inList && ready && sb && nav && removed && gone && unknown === false;
      setCheck('c-webviews', ok, ok
        ? `webviews ok (create→ready→bounds→navigate→remove, unknown=${unknown})`
        : `inList=${inList} ready=${ready} sb=${sb} nav=${nav} removed=${removed} gone=${gone} unknown=${unknown}`);
    } catch (e) { setCheck('c-webviews', false, String(e.message || e)); }

    // 31. v0.1.16：子进程。spawn cmd /c echo → stdout 事件 + exit 事件；
    // kill/list 走错误路径（list 返回数组）。dialog 为模态 UI，不进自动冒烟。
    try {
      const procEvents = [];
      const pid = 1;
      const pOff = window.zilt.process.on(pid, (p) => procEvents.push(p));
      await window.zilt.process.spawn({ id: pid, argv: ['cmd', '/c', 'echo', 'zilt-proc-smoke'] });
      await new Promise((resolve, reject) => {
        const t0 = Date.now();
        const tick = () => {
          const hasOut = procEvents.some((e) => e.kind === 'stdout' && (e.data || '').includes('zilt-proc-smoke'));
          if (hasOut && procEvents.some((e) => e.kind === 'exit' && e.code === 0)) return resolve();
          if (Date.now() - t0 > 8000) return reject(new Error('timeout: ' + JSON.stringify(procEvents.map((e) => e.kind))));
          setTimeout(tick, 100);
        };
        tick();
      });
      pOff();
      const lst = await window.zilt.process.list();
      const ok = Array.isArray(lst);
      setCheck('c-proc', ok, ok ? `process ok (stdout→echo 命中, exit code=0, list=${lst.length})` : 'list=' + JSON.stringify(lst));
    } catch (e) { setCheck('c-proc', false, String(e.message || e)); }

    // 32. v0.1.17：多 WebView 数据分区（独立 Environment）。三个子 webview 载入
    // 同 origin 的 partition-probe.html：两个各带分区（alpha/beta），一个不带（共享）。
    // 断言：alpha 写入后 beta 读不到（隔离）；alpha 自己仍读得到（持久）；
    // 共享实例写入后主页面能读到（同 Environment 共享存储）。
    try {
      const probeUrl = 'https://zilt.app/partition-probe.html';
      const mk = async (partition) => {
        const r = await window.zilt.webviews.create({ x: 20, y: 20, width: 220, height: 160, url: probeUrl, partition });
        return r && r.id;
      };
      const waitReady = async (id) => {
        const t0 = Date.now();
        while (Date.now() - t0 < 12000) {
          const l = await window.zilt.webviews.list();
          const c = (l || []).find((x) => x.id === id);
          if (c && c.ready) return true;
          await new Promise((r) => setTimeout(r, 120));
        }
        return false;
      };
      const aId = await mk('alpha');
      const bId = await mk('beta');
      const sId = await mk(null);
      if (!aId || !bId || !sId) throw new Error('create failed: ' + JSON.stringify([aId, bId, sId]));
      const rA = await waitReady(aId);
      const rB = await waitReady(bId);
      const rS = await waitReady(sId);
      // 等首帧文档就绪（eval 前把 readyState 打完）
      const settle = async (id) => {
        const t0 = Date.now();
        while (Date.now() - t0 < 8000) {
          const v = await window.zilt.webviews.eval(id, 'document.readyState');
          if (v === 'complete' || v === 'interactive') return true;
          await new Promise((r) => setTimeout(r, 120));
        }
        return false;
      };
      const sA = await settle(aId), sB = await settle(bId), sS = await settle(sId);

      // 分区数据会跨运行持久化（这正是分区该有的行为）→ 每次用唯一 key，
      // 避免上一轮的残留把「隔离」断言污染成假失败
      const probeKey = 'zilt_part_' + Date.now();
      const js = (code) => `${code}`;
      const writeA = await window.zilt.webviews.eval(aId, `localStorage.setItem('${probeKey}','alpha'); localStorage.getItem('${probeKey}')`);
      const readB = await window.zilt.webviews.eval(bId, `localStorage.getItem('${probeKey}')`);
      const writeB = await window.zilt.webviews.eval(bId, `localStorage.setItem('${probeKey}','beta'); localStorage.getItem('${probeKey}')`);
      const readA2 = await window.zilt.webviews.eval(aId, `localStorage.getItem('${probeKey}')`);
      const writeS = await window.zilt.webviews.eval(sId, `localStorage.setItem('${probeKey}','shared'); localStorage.getItem('${probeKey}')`);
      const readMain = localStorage.getItem(probeKey);

      const listAll = await window.zilt.webviews.list();
      const parts = (listAll || []).map((c) => c.partition).filter((p) => p);
      const hasParts = parts.includes('alpha') && parts.includes('beta');

      await window.zilt.webviews.remove(aId);
      await window.zilt.webviews.remove(bId);
      await window.zilt.webviews.remove(sId);
      localStorage.removeItem(probeKey);

      const ok = rA && rB && rS && sA && sB && sS &&
        writeA === 'alpha' && readB === null && writeB === 'beta' && readA2 === 'alpha' &&
        writeS === 'shared' && readMain === 'shared' && hasParts;
      setCheck('c-partition', ok, ok
        ? 'partition ok (alpha/beta 隔离 + 共享 env 互通)'
        : `ready=${rA},${rB},${rS} settle=${sA},${sB},${sS} A=${writeA} B0=${readB} B=${writeB} A2=${readA2} S=${writeS} main=${readMain} parts=${JSON.stringify(parts)}`);
    } catch (e) { setCheck('c-partition', false, String(e.message || e)); }

    // 33. v0.1.18：窗口精细控制（光标/穿透/截屏保护/置底/可聚焦/尺寸约束/主题/图标/全屏）
    try {
      const S = () => window.zilt.window.state();
      const s0 = await S();
      const rCursor = await window.zilt.window.setCursor('hand');
      const rIgnore = await window.zilt.window.setIgnoreCursorEvents(true);
      const sIgnore = await S();
      await window.zilt.window.setIgnoreCursorEvents(false);
      const rProtect = await window.zilt.window.setContentProtected(true);
      const sProtect = await S();
      await window.zilt.window.setContentProtected(false);
      const rFocus = await window.zilt.window.setFocusable(false);
      const sFocus = await S();
      await window.zilt.window.setFocusable(true);
      const rBottom = await window.zilt.window.setAlwaysOnBottom(true);
      const sBottom = await S();
      await window.zilt.window.setAlwaysOnBottom(false);
      const rLimits = await window.zilt.window.setMinMax({ minWidth: 480, minHeight: 320, maxWidth: 1600, maxHeight: 1200 });
      const sLimits = await S();
      await window.zilt.window.setMinMax({ minWidth: 0, minHeight: 0, maxWidth: 0, maxHeight: 0 });
      const rShadow = await window.zilt.window.setShadow(true);
      const rTheme = await window.zilt.window.setTheme({ dark: true, captionColor: 0x1F2937 });
      const rIcon = await window.zilt.window.setIcon(null);
      const rVis = await window.zilt.window.setCursorVisible(false);
      await window.zilt.window.setCursorVisible(true);
      const rEnabled = await window.zilt.window.setEnabled(false);
      const sDisabled = await S();
      await window.zilt.window.setEnabled(true);
      const rFs = await window.zilt.window.fullscreenOnMonitor(0);
      const sFs = await S();
      await window.zilt.window.fullscreen(false);

      const ok = !!s0 && s0.width > 0 && s0.enabled === true && s0.focusable === true &&
        rCursor === true && rIgnore === true && sIgnore.ignore_cursor === true &&
        rProtect === true && sProtect.content_protected === true &&
        rFocus === true && sFocus.focusable === false &&
        rBottom === true && sBottom.always_on_bottom === true &&
        rLimits === true && sLimits.min_width === 480 && sLimits.max_height === 1200 &&
        rShadow === true && rTheme === true && rIcon === true && rVis === true &&
        rEnabled === true && sDisabled.enabled === false &&
        rFs === true && sFs.fullscreen === true;
      setCheck('c-wincontrol', ok, ok
        ? 'win-control ok (cursor/ignore/protect/bottom/focusable/limits/theme/shadow/icon/fullscreen)'
        : `state0=${JSON.stringify(s0)} ignore=${sIgnore.ignore_cursor} protect=${sProtect.content_protected} focusable=${sFocus.focusable} bottom=${sBottom.always_on_bottom} limits=${JSON.stringify(sLimits)} disabled=${sDisabled.enabled} fs=${sFs.fullscreen} r=${JSON.stringify([rCursor,rIgnore,rProtect,rFocus,rBottom,rLimits,rShadow,rTheme,rIcon,rVis,rEnabled,rFs])}`);
    } catch (e) { setCheck('c-wincontrol', false, String(e.message || e)); }

    // 34. v0.1.19：fs 全量（多目录 scope + 目录树操作 + 越权拒绝）
    try {
      const roots = await window.zilt.fs.roots();
      const base = 'e2e_fs_' + Date.now();
      const f1 = base + '/a.txt';
      const w1 = await window.zilt.fs.write(f1, 'hello');
      const w2 = await window.zilt.fs.append(f1, ' world');
      const txt = await window.zilt.fs.read(f1);
      const st = await window.zilt.fs.stat(f1);
      await window.zilt.fs.mkdir(base + '/deep/nested');
      await window.zilt.fs.write(base + '/deep/nested/b.bin', 'z');
      const entries = await window.zilt.fs.readDir(base + '/deep');
      const nested = (entries || []).find((e) => e.name === 'nested');
      const renamed = await window.zilt.fs.rename(f1, base + '/c.txt');
      const copied = await window.zilt.fs.copy(base + '/c.txt', base + '/d.txt');
      const existsC = await window.zilt.fs.exists(base + '/c.txt');
      const existsD = await window.zilt.fs.exists(base + '/d.txt');
      let denied = false;
      try { await window.zilt.fs.read('any.txt', 'documents'); } catch (e) { denied = String(e && e.message || e).includes('PermissionDenied'); }
      const cleaned = await window.zilt.fs.removeDir(base);
      const existsAfter = await window.zilt.fs.exists(base);

      const ok = !!roots && typeof roots.appData === 'string' && roots.appData.length > 0 &&
        w1 === true && w2 === true && txt === 'hello world' &&
        !!st && st.size === 11 && st.dir === false &&
        !!nested && nested.dir === true && entries.length === 1 &&
        renamed === true && copied === true && existsC === true && existsD === true &&
        denied === true && cleaned === true && existsAfter === false;
      setCheck('c-fs', ok, ok
        ? 'fs ok (write/append/read/stat/mkdir/readDir/rename/copy/removeDir + scope 拒绝)'
        : `roots=${!!roots} r=${JSON.stringify([w1,w2,renamed,copied,existsC,existsD,denied,cleaned,existsAfter])} txt=${txt} st=${JSON.stringify(st)} entries=${JSON.stringify(entries)}`);
    } catch (e) { setCheck('c-fs', false, String(e.message || e)); }

    // 35. v0.1.19：流式通道（后台线程推送 → JS onmessage/onclose 有序到达）
    try {
      const chunks = [];
      let closed = null;
      const ch = window.zilt.channel.create({
        onmessage: (data, seq) => chunks.push({ seq, n: data.n, label: data.label }),
        onclose: (err) => { closed = err == null ? 'ok' : String(err); },
      });
      await window.zilt.invoke('streamDemo', { id: ch.id, count: 5 });
      const t0 = Date.now();
      while (closed === null && Date.now() - t0 < 8000) await new Promise((r) => setTimeout(r, 40));
      const ordered = chunks.length === 5 && chunks.every((c, i) => c.seq === i && c.n === i && c.label === 'chunk');
      const ok = ordered && closed === 'ok';
      setCheck('c-channel', ok, ok
        ? 'channel ok (5 chunks in order, closed)'
        : `chunks=${JSON.stringify(chunks)} closed=${closed}`);
    } catch (e) { setCheck('c-channel', false, String(e.message || e)); }

    // 36. v0.1.19：初始化脚本（document-start）+ 更新器状态
    try {
      const init = window.__ziltInit;
      const initOk = !!init && typeof init.version === 'string' && init.version === window.zilt.version;
      const u = await window.zilt.updater.info();
      const updaterOk = !!u && typeof u.configured === 'boolean' &&
        (u.configured === false || (typeof u.current_version === 'string' && typeof u.restart_required === 'boolean'));
      const ok = initOk && updaterOk;
      setCheck('c-init', ok, ok
        ? `init-script ok (version=${init.version}) + updater configured=${u.configured}`
        : `init=${JSON.stringify(init)} updater=${JSON.stringify(u)}`);
    } catch (e) { setCheck('c-init', false, String(e.message || e)); }

    // 37. v0.1.20：WinHTTP —— multipart / 重定向 / 流式 / 超时
    try {
      const base = 'http://127.0.0.1:8788';
      const echo = JSON.parse((await window.zilt.http.request({
        url: base + '/echo', method: 'POST', body: 'hello-zilt',
        headers: { 'Content-Type': 'text/plain' },
      })).body);
      const mpRes = await window.zilt.http.request({
        url: base + '/multipart', method: 'POST',
        multipart: [
          { name: 'field', data: 'v' },
          { name: 'file', filename: 'a.txt', contentType: 'text/plain', data: 'payload' },
        ],
      });
      const mp = JSON.parse(mpRes.body);
      const redir = await window.zilt.http.request({ url: base + '/redirect' });
      const noFollow = await window.zilt.http.request({ url: base + '/redirect', followRedirects: false });
      const seqs = [];
      const streamRes = await window.zilt.http.stream({ url: base + '/stream?chunks=4&size=8' }, (b, seq) => seqs.push(seq));

      const ok = echo.len === 10 && echo.preview === 'hello-zilt' && echo.ctype.includes('text/plain') &&
        mp.parts.length === 2 && mp.parts[1].filename === 'a.txt' && mp.parts[1].len === 7 && mp.parts[1].text === 'payload' &&
        redir.status === 200 && redir.body === 'hello' && noFollow.status === 302 &&
        streamRes.status === 200 && streamRes.bytes.length === 32 && streamRes.chunks >= 1 && seqs.every((v, i) => v === i);
      setCheck('c-http2', ok, ok
        ? `http2 ok (multipart 2 parts, redirect 200/302, stream ${streamRes.chunks} chunks/32B)`
        : `echo=${JSON.stringify(echo)} mp=${JSON.stringify(mp)} redir=${redir.status}/${JSON.stringify(redir.body).slice(0,20)} noFollow=${noFollow.status} stream=${streamRes.status}/${streamRes.bytes.length}/${streamRes.chunks} seqs=${JSON.stringify(seqs)}`);
    } catch (e) { setCheck('c-http2', false, String(e.message || e)); }

    // 38. v0.1.20：wss（WinHTTP/Schannel + 自签证书 + 忽略证书校验）
    try {
      const ev = [];
      const id = await window.zilt.ws.connect('wss://127.0.0.1:8766/tls', { insecureTls: true });
      const off = window.zilt.ws.on(id, (p) => ev.push(p));
      let sent = false;
      await new Promise((resolve, reject) => {
        const t0 = Date.now();
        const tick = () => {
          if (!sent && ev.some((e) => e.kind === 'open')) {
            sent = true;
            window.zilt.ws.send(id, 'wss-payload').catch(reject);
          }
          if (sent && ev.filter((e) => e.kind === 'message').length >= 2) return resolve();
          if (ev.some((e) => e.kind === 'error')) return reject(new Error('wss error: ' + JSON.stringify(ev)));
          if (Date.now() - t0 > 8000) return reject(new Error('wss timeout: ' + JSON.stringify(ev.map((e) => e.kind))));
          setTimeout(tick, 100);
        };
        tick();
      });
      await window.zilt.ws.close(id, 1000, 'wss done');
      await new Promise((resolve) => {
        const t0 = Date.now();
        const tick = () => {
          if (ev.some((e) => e.kind === 'close') || Date.now() - t0 > 3000) resolve();
          else setTimeout(tick, 100);
        };
        tick();
      });
      off();
      // close 帧由 WinHTTP 在等待对端 close 时可能晚到（实测 3s+），
      // 断言只要求「TLS 建连 + welcome + echo」；close 仅作为附加信息。
      const gotClose = ev.some((e) => e.kind === 'close');
      const ok = ev.some((e) => e.kind === 'message' && e.data === 'wss-payload') && !ev.some((e) => e.kind === 'error');
      setCheck('c-wss', ok, ok
        ? `wss ok (TLS 握手 + echo${gotClose ? ' + close' : ''})`
        : `events=${JSON.stringify(ev.map((e) => e.kind))} msgs=${JSON.stringify(ev.filter((e) => e.kind === 'message').map((e) => (e.data || '').slice(0, 20)))}`);
    } catch (e) { setCheck('c-wss', false, String(e.message || e)); }

    // 39. v0.1.20：Zig 侧订阅内置窗口事件（events 命名空间）
    try {
      const before = (await window.zilt.invoke('builtinEventHits', {})).hits;
      const jx = 90 + Math.floor(Math.random() * 120);
      const jy = 80 + Math.floor(Math.random() * 120);
      await window.zilt.window.setPosition(jx, jy);
      await new Promise((r) => setTimeout(r, 400));
      const after = (await window.zilt.invoke('builtinEventHits', {})).hits;
      const ok = after > before;
      setCheck('c-zigev', ok, ok
        ? `zig events ok (windowMoved hits ${before} → ${after})`
        : `hits before=${before} after=${after}`);
    } catch (e) { setCheck('c-zigev', false, String(e.message || e)); }

    // 40. v0.1.21：ACL —— 越权拒绝 / 运行时授权 / 撤销
    try {
      // 启动时若 acl.json 里预置了 downloads 授权，说明持久化加载生效；
      // 本轮顺手撤销它（幂等），并据此断言「跨进程持久化 + 撤销落盘」。
      const seededList = await window.zilt.acl.list();
      const hadSeed = Array.isArray(seededList) && seededList.includes('fs:downloads/**');
      if (hadSeed) await window.zilt.acl.revoke('fs', 'downloads/**');
      const seededRevoked = !(await window.zilt.acl.list()).includes('fs:downloads/**');
      const seedOk = !hadSeed || seededRevoked;
      await window.zilt.acl.revoke('fs', 'documents/**'); // 幂等：清掉上次残留
      const denyMsg = async (fn) => {
        try { await fn(); return ''; } catch (e) { return String((e && e.message) || e); }
      };
      const d0 = await denyMsg(() => window.zilt.fs.write('zilt_acl_probe.txt', 'x', 'documents'));
      const g = await window.zilt.acl.grant('fs', 'documents/**');
      const listed = await window.zilt.acl.list();
      const w = await window.zilt.fs.write('zilt_acl_probe.txt', 'acl-ok', 'documents');
      const r = await window.zilt.fs.read('zilt_acl_probe.txt', 'documents');
      const rm = await window.zilt.fs.remove('zilt_acl_probe.txt', 'documents');
      const rv = await window.zilt.acl.revoke('fs', 'documents/**');
      const d1 = await denyMsg(() => window.zilt.fs.read('zilt_acl_probe.txt', 'documents'));
      const httpDenied = await denyMsg(() => window.zilt.http.request({ url: 'https://example.com/' }));

      // v0.1.21：freezePrototype 生效 → window.zilt 与 Object.prototype 被冻结
      const frozen = Object.isFrozen(window.zilt) && Object.isFrozen(Object.prototype);
      const ok = frozen && seedOk && d0.includes('PermissionDenied') && g === true &&
        Array.isArray(listed) && listed.includes('fs:documents/**') &&
        w === true && r === 'acl-ok' && rm === true && rv === true &&
        d1.includes('PermissionDenied') && httpDenied.includes('PermissionDenied');
      setCheck('c-acl2', ok, ok
        ? 'acl ok (documents 拒绝 → 授权 → 读写 → 撤销 → 再拒绝；https 未授权拒绝)'
        : `frozen=${frozen} seed=${hadSeed}/${seededRevoked} d0=${d0} g=${g} listed=${JSON.stringify(listed)} w=${w} r=${JSON.stringify(r)} rm=${rm} rv=${rv} d1=${d1} http=${httpDenied}`);
    } catch (e) { setCheck('c-acl2', false, String(e.message || e)); }

    // 41. v0.1.22：fs.watch（ReadDirectoryChangesW）+ fs.readStream（分块）
    try {
      const dir = 'watch_' + Date.now();
      await window.zilt.fs.mkdir(dir);
      const evs = [];
      const offEv = window.zilt.on('fsEvent', (p) => evs.push(p));
      const w = await window.zilt.fs.watch(dir);
      const target = dir + '/a.txt';
      const payload = 'stream-' + 'x'.repeat(10000);
      await window.zilt.fs.write(target, payload);

      const waitFor = async (pred, ms) => {
        const t0 = Date.now();
        while (Date.now() - t0 < ms) {
          if (pred()) return true;
          await new Promise((r) => setTimeout(r, 60));
        }
        return false;
      };
      const sawAdd = await waitFor(() => evs.some((e) => e.action === 'added' && e.path === 'a.txt'), 4000);

      const all = [];
      const offChunk = window.zilt.on('fsChunk', (p) => all.push(p));
      const sres = await window.zilt.fs.readStream(target, { chunkSize: 4096 });
      const sid = sres && sres.id;
      await waitFor(() => all.some((p) => p.id === sid && p.done), 5000);
      const mine = all.filter((p) => p.id === sid && !p.done);
      const text = mine.map((p) => atob(p.data)).join('');
      const unw = await window.zilt.fs.unwatch(w.id);
      offEv(); offChunk();
      await window.zilt.fs.removeDir(dir);

      const ok = !!w && typeof w.id === 'number' && sawAdd && unw === true &&
        text.length === payload.length && text === payload && mine.length >= 2;
      setCheck('c-fs2', ok, ok
        ? `fs watch/stream ok (${mine.length} chunks, ${text.length} bytes)`
        : `w=${JSON.stringify(w)} sawAdd=${sawAdd} events=${JSON.stringify(evs.slice(0, 4))} sid=${sid} chunks=${mine.length} len=${text.length}/${payload.length} unw=${unw}`);
    } catch (e) { setCheck('c-fs2', false, String(e.message || e)); }

    // 42. v0.1.23：CDP 逃生口（Browser.getVersion）
    try {
      const v = await window.zilt.webview.cdp('Browser.getVersion', {});
      const ok = !!v && typeof v.product === 'string' && /Chrome\/|Edg\//.test(v.product);
      setCheck('c-cdp', ok, ok ? `cdp ok (${v.product})` : `resp=${JSON.stringify(v).slice(0, 120)}`);
    } catch (e) { setCheck('c-cdp', false, String(e.message || e)); }

    // 43. v0.1.23：截屏（PNG data URL）
    try {
      const url = await window.zilt.webview.captureScreenshot();
      const ok = typeof url === 'string' && url.startsWith('data:image/png;base64,') && url.length > 2000;
      setCheck('c-shot', ok, ok ? `screenshot ok (${url.length} chars)` : `url=${String(url).slice(0, 60)} len=${String(url).length}`);
    } catch (e) { setCheck('c-shot', false, String(e.message || e)); }

    // 44. v0.1.23：每请求头（CDP Network.setExtraHTTPHeaders）
    try {
      let r1;
      try { r1 = await window.zilt.webview.cdp('Network.enable', {}); }
      catch (e1) { window.zilt.log('warn', 'cdp Network.enable failed: ' + String(e1.message || e1)); throw e1; }
      let r2;
      try { r2 = await window.zilt.webview.cdp('Network.setExtraHTTPHeaders', { headers: { 'X-Zilt-Smoke': 'v23' } }); }
      catch (e2) { window.zilt.log('warn', 'cdp setExtraHTTPHeaders failed: ' + String(e2.message || e2)); throw e2; }
      const ok = r1 !== undefined && r2 !== undefined;
      setCheck('c-hdrs', ok, ok ? 'extra headers applied' : `enable=${JSON.stringify(r1)} set=${JSON.stringify(r2)}`);
    } catch (e) {
      setCheck('c-hdrs', false, String(e.message || e));
    }

    // 45. v0.1.23：页内查找（用页面上真实存在的词做探针）
    try {
      const body = (document.body.innerText || '').trim();
      const probe = (body.split(/\s+/)[0] || '').slice(0, 12);
      const found = probe.length > 0 ? window.zilt.webview.find(probe) : false;
      setCheck('c-find', found === true, `find(${JSON.stringify(probe)}) -> ${found}`);
    } catch (e) { setCheck('c-find', false, String(e.message || e)); }

    // 46. v0.1.23：每窗口代理（独立 Environment + profile；Zig 日志可见 env ready）
    try {
      const w = await window.zilt.window.create({
        title: 'proxy probe', url: 'https://zilt.app/index.html', label: 'proxy-probe-' + Date.now(),
        width: 300, height: 200, proxy: '127.0.0.1:9',
      });
      const ok = !!w && typeof w.id === 'number';
      setCheck('c-proxy', ok, ok ? `proxy window #${w.id} created` : `resp=${JSON.stringify(w)}`);
      if (ok) setTimeout(() => { window.zilt.window.close(w.id).catch(() => {}); }, 1200);
    } catch (e) { setCheck('c-proxy', false, String(e.message || e)); }

    // 47. v0.1.23：覆盖式标题栏（ZILT_SMOKE_OVERLAY=1 时客户区=整个窗口）
    try {
      const st = await window.zilt.window.state();
      const overlay = !!st && st.overlay === true;
      const dw = Math.abs(window.outerWidth - window.innerWidth);
      const dh = Math.abs(window.outerHeight - window.innerHeight);
      const ok = !overlay || (dw <= 2 && dh <= 2);
      setCheck('c-overlay', ok, overlay
        ? `overlay on (outer ${window.outerWidth}x${window.outerHeight} / inner ${window.innerWidth}x${window.innerHeight})`
        : 'overlay off (skipped)');
    } catch (e) { setCheck('c-overlay', false, String(e.message || e)); }

    // 48. v0.1.24：应用自定义协议（文本 / 自定义头 / JSON+201 / 二进制）
    try {
      const stamp = Date.now();
      const r = await fetch(`/__proto/echo/a/b?x=1&y=${stamp}`);
      const text = await r.text();
      const hdr = r.headers.get('X-Proto');
      const jr = await fetch(`/__proto/json?t=${stamp}`);
      const jt = await jr.json();
      const br = await fetch(`/__proto/bin?t=${stamp}`);
      const bytes = new Uint8Array(await br.arrayBuffer());
      const ok = text.startsWith(`echo|a/b|x=1&y=${stamp}|GET|`) && hdr === 'zilt' &&
        jr.status === 201 && jt.proto === true && jt.framework === 'zilt' &&
        bytes.length === 4 && bytes[2] === 0xfe && bytes[3] === 0xff;
      setCheck('c-proto', ok, ok
        ? `protocol ok (echo/json-201/bin ${bytes.length}B)`
        : `text=${String(text).slice(0, 60)} xproto=${hdr} json=${jr.status}/${JSON.stringify(jt)} bin=${bytes.join(',')}`);
    } catch (e) { setCheck('c-proto', false, String(e.message || e)); }

    // 49. v0.1.24：每窗口 UA（独立窗口创建时指定 → 该窗口请求头可见）
    // 注意：WebView2 的 put_UserAgent 只对下一次导航生效，所以必须用新窗口验证，
    // 在当前文档里改 UA 后立刻 fetch 仍是旧 UA（子资源沿用文档 UA）。
    try {
      const marker = 'ZiltUA/1.0 (win)';
      const seen = await new Promise(async (resolve, reject) => {
        const ch = new BroadcastChannel('zilt-smoke-ua');
        const timer = setTimeout(() => { ch.close(); reject(new Error('ua probe timeout')); }, 12000);
        ch.onmessage = (e) => { clearTimeout(timer); ch.close(); resolve(String(e.data)); };
        try {
          const w = await window.zilt.window.create({
            title: 'ua probe', url: 'https://zilt.app/ua-probe.html',
            label: 'ua-probe-' + Date.now(), width: 320, height: 200, userAgent: marker,
          });
          setTimeout(() => { if (w && typeof w.id === 'number') window.zilt.window.close(w.id).catch(() => {}); }, 6000);
        } catch (err) { clearTimeout(timer); ch.close(); reject(err); }
      });
      const ok = seen.endsWith('|' + marker);
      setCheck('c-ua', ok, ok
        ? `per-window UA ok (${marker})`
        : `probe=${String(seen).slice(-80)}`);
    } catch (e) { setCheck('c-ua', false, String(e.message || e)); }


    // 50. v0.3.2：真 scheme 协议（<scheme>://<path>?<query>，两平台同约定）。
    // 断言形态 = iframe 导航（onload 即「注册→filter→处理器→响应→渲染」全链）。
    // **文档化限制**：https 页面对自定义 scheme 的 fetch/XHR（cors 模式）实测被
    // WebView2 的 CORS 判定拒绝——响应带 Access-Control-Allow-Origin（精确或 *）、
    // AllowedOrigins（精确/通配）均不生效；iframe 导航与 no-cors fetch 正常。
    // JS 侧需要可读响应体时用同源路径式 /__proto/<name>/…（fetch 全功能）。
    try {
      const stamp = Date.now();
      const loaded = await new Promise((resolve) => {
        const f = document.createElement('iframe');
        f.style.display = 'none';
        let done = false;
        const finish = (v) => { if (!done) { done = true; try { f.remove(); } catch (_) {} resolve(v); } };
        const timer = setTimeout(() => finish(false), 6000);
        f.onload = () => { clearTimeout(timer); finish(true); };
        f.onerror = () => { clearTimeout(timer); finish(false); };
        f.src = `echo://a/b?x=1&y=${stamp}`;
        document.body.appendChild(f);
      });
      setCheck('c-scheme', loaded, loaded
        ? 'real scheme ok (iframe navigation served by protocol handler)'
        : 'iframe navigation failed');
      if (!loaded) window.zilt.log('warn', 'c-scheme note: iframe navigation failed');
    } catch (e) {
      setCheck('c-scheme', false, String(e.message || e));
      window.zilt.log('warn', 'c-scheme error: ' + String(e.message || e));
    }

    // 51. v0.3.2：无痕窗口（window.create({incognito}) → state().incognito=true）
    try {
      const id0 = await window.zilt.window.create({
        title: 'incognito probe', label: 'incognito-probe-' + Date.now(),
        width: 240, height: 160, incognito: true, hidden: false,
      });
      const wid = id0 && typeof id0.id === 'number' ? id0.id : null;
      let st = null;
      if (wid != null) {
        st = await window.zilt.window.state(wid);
        await window.zilt.window.close(wid).catch(() => {});
      }
      const ok = !!st && st.incognito === true;
      setCheck('c-privacy', ok, ok
        ? 'incognito window ok (state().incognito=true)'
        : `state=${JSON.stringify(st).slice(0, 80)}`);
    } catch (e) { setCheck('c-privacy', false, String(e.message || e)); }

    // 52. v0.3.2：显示器细化（current 标记 + workarea + window.state().monitor）
    try {
      const mons = await window.zilt.system.monitors();
      const arr = Array.isArray(mons) ? mons : (mons && mons.monitors) || [];
      const cur = arr.filter((m) => m.current === true);
      const workOk = arr.every((m) => typeof m.workX === 'number' && typeof m.workWidth === 'number');
      const st = await window.zilt.window.state();
      const ok = arr.length >= 1 && cur.length === 1 && workOk && typeof st.monitor === 'number' &&
        st.monitor === cur[0].index;
      setCheck('c-monitor', ok, ok
        ? `monitors ok (${arr.length} display(s), current=${cur[0].index}, work=${cur[0].workWidth}x${cur[0].workHeight}, state.monitor=${st.monitor})`
        : `mons=${JSON.stringify(arr).slice(0, 120)} state=${JSON.stringify(st).slice(0, 80)}`);
    } catch (e) { setCheck('c-monitor', false, String(e.message || e)); }


    // 53. v0.3.3：窗口体验包 II（创建选项全量 + 运行时 setter 往返）
    try {
      const w = await window.zilt.window.create({
        title: 'exp2 probe', label: 'exp2-' + Date.now(),
        width: 400, height: 300,
        hideOnFocusLost: true, preventOverflow: true,
        moveDebounceMs: 80, closable: false, minimizable: true,
      });
      const wid = w && typeof w.id === 'number' ? w.id : null;
      let apiOk = wid != null;
      if (apiOk) {
        await window.zilt.window.setButtonState({ closable: true }, wid);
        await window.zilt.window.setMoveDebounce(120, wid);
        await window.zilt.window.setMoveDebounce(0, wid);
        await window.zilt.window.setSimpleFullscreen(false, wid);
        const st = await window.zilt.window.state(wid);
        apiOk = !!st && typeof st.monitor === 'number';
        await window.zilt.window.close(wid).catch(() => {});
      }
      setCheck('c-exp2', apiOk, apiOk
        ? 'exp2 ok (create{mask-free opts} + setButtonState/setMoveDebounce/setSimpleFullscreen roundtrip)'
        : `create=${JSON.stringify(w).slice(0, 60)}`);
      if (!apiOk) window.zilt.log('warn', 'c-exp2 note: ' + JSON.stringify({ w: w, st: typeof st !== 'undefined' ? st : null }).slice(0, 140));
    } catch (e) { setCheck('c-exp2', false, String(e.message || e)); window.zilt.log('warn', 'c-exp2 error: ' + String(e.message || e)); }


    // 54. v0.3.4：侧车资源（path.resource 解析 + 存在性；dev 下 exe 旁 resources/）
    try {
      const r = await window.zilt.invoke('__zilt.path', { action: 'resource', path: 'demo/manifest.json' });
      const ok = !!r && typeof r.path === 'string' && r.path.length > 0 && r.exists === true;
      setCheck('c-res', ok, ok
        ? `resource ok (${String(r.path).slice(-60)})`
        : `resource=${JSON.stringify(r)}`);
    } catch (e) { setCheck('c-res', false, String(e.message || e)); }


    // 55. v0.3.5：DPAPI 加密 store（往返 + dpapi: 前缀标记经 Zig 日志佐证）
    try {
      const secret = 'dpapi-smoke-' + Date.now();
      await window.zilt.store.set('dpapi-smoke', secret);
      const back = await window.zilt.store.get('dpapi-smoke');
      const ok = back === secret;
      setCheck('c-dpapi', ok, ok
        ? 'dpapi store roundtrip ok (get auto-decrypts)'
        : `roundtrip=${JSON.stringify(back).slice(0, 60)} want=${secret.slice(0, 30)}`);
    } catch (e) { setCheck('c-dpapi', false, String(e.message || e)); }

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
      storage: $('c-storage').className === 'pass',
      peripheral: $('c-peripheral').className === 'pass',
      services: $('c-services').className === 'pass',
      http: $('c-http').className === 'pass',
      ws: $('c-ws').className === 'pass',
      webviews: $('c-webviews').className === 'pass',
      proc: $('c-proc').className === 'pass',
      partition: $('c-partition').className === 'pass',
      wincontrol: $('c-wincontrol').className === 'pass',
      fsops: $('c-fs').className === 'pass',
      channel: $('c-channel').className === 'pass',
      initupd: $('c-init').className === 'pass',
      http2: $('c-http2').className === 'pass',
      wss: $('c-wss').className === 'pass',
      zigev: $('c-zigev').className === 'pass',
      acl2: $('c-acl2').className === 'pass',
      fs2: $('c-fs2').className === 'pass',
      cdp: $('c-cdp').className === 'pass',
      shot: $('c-shot').className === 'pass',
      hdrs: $('c-hdrs').className === 'pass',
      find: $('c-find').className === 'pass',
      proxy: $('c-proxy').className === 'pass',
      overlay: $('c-overlay').className === 'pass',
      proto: $('c-proto').className === 'pass',
      ua: $('c-ua').className === 'pass',
      scheme: $('c-scheme').className === 'pass',
      privacy: $('c-privacy').className === 'pass',
      monitor: $('c-monitor').className === 'pass',
      exp2: $('c-exp2').className === 'pass',
      res: $('c-res').className === 'pass',
      dpapi: $('c-dpapi').className === 'pass',
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
