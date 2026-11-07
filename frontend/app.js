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
    const w1 = await window.zilt.invoke('windowTitleDemo', { title: 'Zilt v0.1.6 — 冒烟' });
    const w2 = await window.zilt.invoke('windowTitleDemo', { title: 'Zilt — v0.1.6 示例' });
    setCheck('c-win', w1.ok === true && w2.ok === true);

    // 9. Range/206 资产分块（v0.1.6）
    try {
      const rr = await fetch('/styles.css', { headers: { Range: 'bytes=0-9' } });
      const ab = await rr.arrayBuffer();
      setCheck('c-range', rr.status === 206 && ab.byteLength === 10, `status=${rr.status} len=${ab.byteLength}`);
    } catch (e) {
      setCheck('c-range', false, String(e));
    }

    // 10. 系统通知（托盘气球 → Toast；冒烟断言走 Zig 日志）
    await window.zilt.invoke('notifyMe', { title: 'Zilt 冒烟', body: '系统通知链路验证' });

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
    if (p.id === 'about') window.zilt.invoke('alertBox', { text: 'Zilt v0.1.6 — Zig WebView GUI Framework', title: '关于 Zilt' });
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
    else if (p.id === 'about') window.zilt.invoke('alertBox', { text: 'Zilt v0.1.6 — Zig WebView GUI Framework', title: '关于 Zilt' });
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

  // 子窗口关闭通知
  window.zilt.on('windowClosed', (p) => winOut(`窗口 #${p.id} 已关闭`));

  // 自动运行（供自动化冒烟测试；页面重载后亦会重跑）
  runChecks();
});
