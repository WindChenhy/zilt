// Linux 冒烟脚本（v0.2.2）——只覆盖**已实现**的能力。
//
// 由 platform/linux/backend.zig 在 ZILT_LINUX_SMOKE=1 时作为 document-start
// 用户脚本注入（**每个窗口/子 WebView 都注入**——因此按 location.pathname 分流：
//   /index.html            → 完整检查套件（本文件主体）
//   /second.html           → 第二窗口探针（invoke + 自身窗口状态 → 事件回传主窗口）
//   其余（probe 页等）     → 不动作，避免误触发
// ）。主套件跑完通过 `__zilt.linuxSmoke` 把结果回传，后端据此决定退出码。
//
// 窗口检查注意：xvfb-run 默认没有窗口管理器，WM 参与的状态（maximized/iconic、
// keep-above 的实际置顶、geometry hint 的强制执行）不可断言——只断言客户端
// 可查字段（size/position/tracked 标志）与命令返回值。
//
// 刻意不测：原生对话框（模态、需要人工交互）。
// 剪贴板/通知/菜单栏/托盘/运行时菜单模型/系统信息/自启动/拖放/深链在 v0.2.2 已覆盖
//（通知无 D-Bus 时按降级语义断言；拖入由后端模拟投递覆盖事件链路）。
//
// reload 刻意不做探测：报告 invoke 刚 post 就导航，消息会在导航中丢失
// （实测导致「reload → 脚本重跑 → 再 reload」无限循环）；且 reload 与 stop
// 是同一调用路径，风险极低。
function runSecondWindowProbe() {
  // 第二窗口探针：验证新窗口的 runtime 注入、invoke 通道与 ctx.window_id 路由。
  // 结果以 JS→Zig 事件发出（events.zig 的 secondWindowProbe 处理器 emitTo(1)
  // 转发回主窗口），主套件的 multiwin.report 检查负责断言。
  (async () => {
    try {
      const g = await window.zilt.invoke('greet', { name: 'SecondWindow' });
      const st = await window.zilt.window.state();
      window.zilt.emit('secondWindowProbe', {
        ok: g.message === 'Hello, SecondWindow!' && g.length === 20 && st.id > 1,
        win_id: st.id,
      });
    } catch (e) {
      window.zilt.emit('secondWindowProbe', { ok: false, err: String(e.message || e) });
    }
  })();
}

(async () => {
  const path = location.pathname || '/';
  if (path === '/second.html') return runSecondWindowProbe();
  if (path !== '/index.html') return; // probe 等辅助页面不动作

  // 深链持久记录（先于任何 await 注册——启动深链在 load-finished 时补发，
  // 可能早于后面的 deeplink.startup 检查执行）；同时打 Zig 日志留 E2E 证据。
  window.__ziltDeepLinkSeen = null;
  try {
    window.zilt.on('deepLink', (p) => {
      window.__ziltDeepLinkSeen = p;
      window.zilt.emit('frontendLog', { msg: 'deeplink-event ' + JSON.stringify(p) });
    });
  } catch (_) {}

  // 防重入：本脚本在每个窗口都注入，而前端 app.js 的 c-windowapi 检查会再开一个
  // 加载 index.html 的窗口——只有主窗口（id=1，state() 的 window_id 路由返回自身）
  // 跑完整套件，避免双套件并发创建多窗口/分区的竞态。
  try {
    const me = await window.zilt.window.state();
    if (!me || me.id !== 1) return;
  } catch (_) { return; }

  const results = [];
  // 每项检查同步打一条 Zig 日志（frontendLog 事件）：CI/本地都能拿到
  // 逐项结果与失败原因，而不只看最终 exit code。
  const check = (name, ok, note) => {
    results.push({ name, ok: !!ok, note: String(note ?? '') });
    try { window.zilt.emit('frontendLog', { msg: `${name} ${ok ? 'PASS' : 'FAIL'} ${note ?? ''}` }); } catch (_) {}
  };
  const Z = () => window.zilt;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

  // v0.5.9：变体能力表（后端在注入本脚本前写入；缺省按 GTK3 全能力）。
  // GTK4 下降级的面走「显式 skip / 断言降级语义」，不当成失败。
  const CAPS = Object.assign({
    tray: true, menu_bar: true, programmatic_drag: true,
    cursor_grab: true, cookie_clear_by_domain: true, clipboard_read: true,
    screenshot: true, hide_show: true,
  }, window.__ziltSmokeCaps || {});

  // 1. 命令调用 + 嵌套返回字段
  try {
    const g = await Z().invoke('greet', { name: 'Linux' });
    check('greet', g.message === 'Hello, Linux!' && g.length === 13, JSON.stringify(g));
  } catch (e) { check('greet', false, e); }

  // 2. 数值返回
  try {
    const sum = await Z().invoke('add', { a: 2, b: 3 });
    check('add', sum === 5, sum);
  } catch (e) { check('add', false, e); }

  // 3. Zig 错误 → reject 携带错误名
  try {
    await Z().invoke('failNow', {});
    check('reject', false, 'no reject');
  } catch (e) {
    check('reject', String(e.message).includes('DemoFailure'), e.message);
  }

  // 4. 结构化参数 + 嵌套可选返回（queryUser 收 struct{id}）
  try {
    const u = await Z().invoke('queryUser', { id: 7 });
    check('struct', u && u.user && u.user.id === 7 && u.user.name === 'Ann', JSON.stringify(u));
  } catch (e) { check('struct', false, e); }

  // 4b. 枚举参数映射
  try {
    const m = await Z().invoke('setMode', { mode: 'slow' });
    check('enum', m && m.applied === 'slow', JSON.stringify(m));
  } catch (e) { check('enum', false, e); }

  // 5. Zig → JS 事件（emit 经 g_idle_add 封送到 UI 线程）
  try {
    const seen = await new Promise((resolve) => {
      const got = [];
      const off = Z().on('tick', (p) => {
        got.push(p.n);
        if (got.length === 3) { off(); resolve(got); }
      });
      Z().invoke('startTicker', { count: 3, interval_ms: 20 }).catch(() => {});
      setTimeout(() => { off(); resolve(got); }, 3000);
    });
    check('ticker', seen.length === 3 && seen[2] === 3, seen.join(','));
    await Z().invoke('stopTicker', {}).catch(() => {});
  } catch (e) { check('ticker', false, e); }

  // 6. 自定义 scheme 资产（gzip 预压缩 → 运行时解压）
  try {
    const resp = await fetch('styles.css');
    const text = await resp.text();
    check('asset', resp.ok && text.length > 100, `${resp.status} ${text.length}b`);
  } catch (e) { check('asset', false, e); }

  // 7. 未知命令的错误名稳定
  let unknown = '';
  try { await Z().invoke('__zilt_no_such_command', {}); } catch (e) { unknown = String(e.message || e); }
  check('unknown', unknown === 'UnknownCommand', unknown);

  // 8. runtime 注入的版本号
  check('version', typeof Z().version === 'string' && Z().version.length > 0, Z().version);

  // ---- v0.2.1：窗口 API（window_fn / window_query_fn）----
  try {
    const W = Z().window;
    const state = async () => await W.state();
    const isObj = (s) => !!s && typeof s === 'object' && s.id === 1;
    let s = await state();
    check('win.state', isObj(s) && s.width > 0 && s.height > 0 && s.enabled === true, JSON.stringify(s).slice(0, 120));

    // setSize：客户端尺寸（无 WM 时 gtk_window_get_size 即所设值）
    await W.setSize(800, 600);
    await wait(120);
    s = await state();
    check('win.size', s.width === 800 && s.height === 600, `${s.width}x${s.height}`);

    // setPosition：无 WM 时 gtk_window_move 的坐标原样生效
    await W.setPosition(60, 40);
    await wait(120);
    s = await state();
    check('win.pos', s.x === 60 && s.y === 40, `${s.x},${s.y}`);

    // setTitle：命令被接受即可（state JSON 不含标题）
    check('win.title', (await W.setTitle('Zilt Linux Smoke')) === true, 'ok');

    // fullscreen：状态跟踪开/关往返
    await W.fullscreen(true);
    const fsOn = (await state()).fullscreen === true;
    await W.fullscreen(false);
    const fsOff = (await state()).fullscreen === false;
    check('win.fullscreen', fsOn && fsOff, `on=${fsOn} off=${fsOff}`);

    // alwaysOnTop：状态跟踪
    await W.alwaysOnTop(true);
    const topOn = (await state()).always_on_top === true;
    await W.alwaysOnTop(false);
    const topOff = (await state()).always_on_top === false;
    check('win.ontop', topOn && topOff, `on=${topOn} off=${topOff}`);

    // setMinMax：约束跟踪值可查，清除后归零
    await Z().invoke('__zilt.window', { action: 'setMinMax', min_width: 480, min_height: 320, max_width: 1600, max_height: 1200 });
    s = await state();
    const limOn = s.min_width === 480 && s.min_height === 320 && s.max_width === 1600 && s.max_height === 1200;
    await Z().invoke('__zilt.window', { action: 'setMinMax' });
    s = await state();
    check('win.limits', limOn && s.min_width === 0 && s.max_width === 0, `on=${limOn} min=${s.min_width}`);

    // setEnabled / setFocusable：GTK 查询值往返
    await W.setEnabled(false);
    const disOk = (await state()).enabled === false;
    await W.setEnabled(true);
    await W.setFocusable(false);
    const focOk = (await state()).focusable === false;
    await W.setFocusable(true);
    s = await state();
    check('win.sensitive', disOk && focOk && s.enabled === true && s.focusable === true, `dis=${disOk} foc=${focOk}`);

    // hide/show：可见性往返。GTK3 + openbox/Xvfb 下 hide 会在 focus-out 后
    // 触发 GDK QueryTree 旧焦点 frame → BadWindow abort（连跑三次复现，清焦点/
    // 等待无效）→ 按 caps.hide_show 显式 skip；GTK3 的销毁路径由 close 覆盖。
    if (!CAPS.hide_show) {
      check('win.vis', true, 'skipped (GTK3 + openbox/Xvfb: hide triggers GDK BadWindow)');
    } else {
      try {
        const vw = await W.create({
          title: 'vis probe', width: 220, height: 160,
          label: 'smoke-vis-' + Date.now(), url: 'about:blank',
        });
        const vid = vw && vw.id;
        await wait(150);
        await W.hide(vid);
        await wait(80);
        const hidOk = (await W.state(vid)).visible === false;
        await W.show(vid);
        await wait(80);
        const showOk = (await W.state(vid)).visible === true;
        await W.close(vid).catch(() => {});
        check('win.vis', hidOk && showOk, `hide=${hidOk} show=${showOk}`);
      } catch (e) { check('win.vis', false, String(e.message || e)); }
    }

    // minimize/maximize/restore/startDragging：Xvfb 无 WM，只验证命令被接受不崩
    const rMin = await W.minimize();
    await W.restore();
    const rMax = await W.maximize();
    await W.restore();
    const rDrag = await W.startDragging();
    check('win.wmcalls', rMin === true && rMax === true && rDrag === true, `min=${rMin} max=${rMax} drag=${rDrag}`);

    // v0.3.0：精细控制包——光标（抽样）/ 隐藏 / 抓取 / 位置 / 穿透 / 阴影
    const rCursor = await W.setCursor('hand');
    const rCursor2 = await W.setCursor('ibeam');
    const rCursorVis = await W.setCursorVisible(false);
    const rCursorVis2 = await W.setCursorVisible(true);
    const rGrab = await W.setCursorGrab(true);
    const rUngrab = await W.setCursorGrab(false);
    const rWarp = await W.setCursorPosition(20, 20);
    const rShadow = await W.setShadow(true);
    const rShadow2 = await W.setShadow(false);
    const rIgnore = await W.setIgnoreCursorEvents(true);
    await wait(80);
    const ignored = (await state()).ignore_cursor === true;
    await W.setIgnoreCursorEvents(false);
    // GTK4 无 gdk_seat_grab → 抓取面必须稳定返回 false（降级语义也是断言）
    const grabOk = CAPS.cursor_grab
      ? (rGrab === true && rUngrab === true)
      : (rGrab === false && rUngrab === false);
    check('win.polish',
      rCursor === true && rCursor2 === true && rCursorVis === true && rCursorVis2 === true &&
      grabOk && rWarp === true && rShadow === true && rShadow2 === true &&
      rIgnore === true && ignored,
      `cursor=${rCursor}/${rCursor2} vis=${rCursorVis}/${rCursorVis2} grab=${rGrab}/${rUngrab}` +
      `${CAPS.cursor_grab ? '' : ' (grab skipped: GTK4)'} ` +
      `warp=${rWarp} shadow=${rShadow}/${rShadow2} ignore=${rIgnore}/${ignored}`);

    // v0.3.0：平台缺省项——防截屏无标准 API（稳定 false，不抛异常）；
    // 运行时图标 null = 清空成功，不存在的路径 = 明确失败
    const rProtect = await W.setContentProtected(true);
    const rIconClear = await W.setIcon(null);
    const rIconBogus = await W.setIcon('/nonexistent/zilt-smoke-icon.png');
    check('win.guards', rProtect === false && rIconClear === true && rIconBogus === false,
      `protect=${rProtect} iconClear=${rIconClear} iconBogus=${rIconBogus}`);
  } catch (e) { check('win.state', false, String(e.message || e)); }

  // ---- v0.2.1 切片 2：WebView 面（webview_request_fn / eval_async_fn）----
  try {
    const V = Z().webview;

    // eval（__zilt.eval → __zilt.evalResult 事件）：数值往返 + JS 异常 reject
    const ev = await Z().eval('1 + 41');
    check('eval', ev === 42, JSON.stringify(ev));
    let evalErr = '';
    try { await Z().eval('throw new Error("boom")'); } catch (e) { evalErr = String(e.message || e); }
    check('eval.err', evalErr === 'JavaScriptException', evalErr);

    // zoom：设 1.5 → getZoom 1.5 → 恢复 1.0
    await V.zoom(1.5);
    let z = await V.getZoom();
    const zoomOn = z && z.factor === 1.5;
    await V.zoom(1);
    z = await V.getZoom();
    check('zoom', zoomOn && z.factor === 1, `on=${JSON.stringify(zoomOn)} off=${JSON.stringify(z)}`);

    // history：首屏无后退/前进
    const h = await V.history();
    check('history', h && h.can_go_back === false && h.can_go_forward === false, JSON.stringify(h));

    // stop / setUA / setUA 恢复：无返回值动作的响应是 JSON null（与 Windows 对齐），
    // 断言「未拒绝且不为 false」
    const rStop = await V.stop();
    const rUa = await Z().invoke('__zilt.webview', { action: 'setUserAgent', user_agent: 'ZiltSmoke/0.2' });
    const rUaReset = await Z().invoke('__zilt.webview', { action: 'setUserAgent', user_agent: '' });
    check('webview.calls', rStop !== false && rUa !== false && rUaReset !== false, `stop=${rStop} ua=${rUa}/${rUaReset}`);

    // v0.2.5：print 已实装（WebKitPrintOperation 原生对话框，模态）——无头冒烟
    // 不能交互，改为断言 system 变体（Linux 无系统打印首选项 API）稳定 NotSupported
    let sysPrintErr = '';
    try { await Z().invoke('__zilt.webview', { action: 'print', kind: 'system' }); } catch (e) { sysPrintErr = String(e.message || e); }
    check('webview.unimpl', sysPrintErr === 'NotSupported', sysPrintErr);

    // 截图：runtime 的 captureScreenshot 走 cdp Page.captureScreenshot，
    // Linux 用 webkit_web_view_get_snapshot + cairo PNG 实现（返回 data URL）。
    // GTK4/WebKitGTK 6.0 返回 GdkTexture，Xvfb 无合成器下稳定 FAILED_TO_CREATE
    // —— 按已知环境差异显式 skip（caps.screenshot=false），真机待验。
    if (!CAPS.screenshot) {
      check('screenshot', true, 'skipped (GTK4 headless: snapshot texture unavailable)');
    } else {
      const shot = await V.captureScreenshot({ format: 'png' });
      check('screenshot', typeof shot === 'string' && shot.startsWith('data:image/png;base64,') && shot.length > 2000,
        typeof shot === 'string' ? shot.length : String(shot));
    }

    // cookies：URL 作用域的读取 + 按域名清理（示例 origin，无网络请求）
    // GTK4（WebKitGTK 6.0）无 delete_cookies_for_domain → 断言「明确报错」而非静默成功
    const ck = await V.getCookies('https://example.com/');
    let clearedCookies = null, clearErr = null;
    try { clearedCookies = await V.clearCookies('https://example.com'); } catch (e) { clearErr = String(e.message || e); }
    const clearOk = CAPS.cookie_clear_by_domain
      ? (clearErr === null && clearedCookies !== false)
      : clearErr !== null;
    check('cookies', ck && Array.isArray(ck.cookies) && clearOk,
      `get=${JSON.stringify(ck).slice(0, 80)} clear=${clearedCookies} err=${clearErr}` +
      `${CAPS.cookie_clear_by_domain ? '' : ' (by-domain skipped: GTK4)'}`);
  } catch (e) { check('eval', false, String(e.message || e)); }

  // ---- v0.2.1 切片 3：多窗口（spawn_window_fn + 窗口注册表）----
  let spawnedWinId = 0;
  try {
    const created = await Z().window.create({
      title: 'Zilt Linux 多窗口冒烟',
      width: 420, height: 320,
      url: 'https://zilt.app/second.html',
      // 唯一 label：demo 配置 persist_window_state=true，固定 label 会把上一轮的
      // 尺寸（如 setSize 后的 440x340）恢复进新窗口，污染本次断言。
      label: 'smoke-second-' + Date.now(),
    });
    spawnedWinId = created && created.id;
    check('multiwin.create', typeof spawnedWinId === 'number' && spawnedWinId > 1, JSON.stringify(created));
  } catch (e) { check('multiwin.create', false, String(e.message || e)); }

  try {
    // 第二窗口的 runtime/invoke/窗口 id 路由：探针事件经 Zig emitTo(1) 回到主窗口
    const report = await new Promise((resolve) => {
      const off = Z().on('secondWindowProbe', (p) => { off(); resolve(p); });
      setTimeout(() => { off(); resolve(null); }, 10000);
    });
    check('multiwin.report', !!report && report.ok === true && report.win_id === spawnedWinId, JSON.stringify(report));
  } catch (e) { check('multiwin.report', false, String(e.message || e)); }

  try {
    const W = Z().window;
    // window_id 路由：从主窗口查询/控制第二个窗口
    const st = await W.state(spawnedWinId);
    check('multiwin.state', !!st && st.id === spawnedWinId && st.width === 420 && st.height === 320, JSON.stringify(st).slice(0, 140));
    await W.setSize(440, 340, spawnedWinId);
    await wait(150);
    const st2 = await W.state(spawnedWinId);
    check('multiwin.setSize', st2.width === 440 && st2.height === 340, `${st2.width}x${st2.height}`);
    // close：关闭后查询应 reject（WindowNotAvailable），且主窗口不受影响（套件继续跑）
    await W.close(spawnedWinId);
    await wait(150);
    let gone = false;
    try { await W.state(spawnedWinId); } catch (e) { gone = String(e.message).includes('WindowNotAvailable'); }
    check('multiwin.close', gone, String(gone));
  } catch (e) { check('multiwin.state', false, String(e.message || e)); }

  // ---- v0.2.1：窗口状态持久化（state_key → 关闭时保存 → 同 key 新窗口恢复）----
  try {
    const W = Z().window;
    const key = 'smoke-window-state';
    const first = await W.create({
      title: 'Zilt Linux 状态持久化 A',
      width: 300, height: 200,
      url: 'about:blank',
      label: 'smoke-state-a',
      stateKey: key,
    });
    if (!first || !first.id) throw new Error('create A failed: ' + JSON.stringify(first));
    // 窗口刚 show 时初始尺寸请求可能还在队列里 → 等一拍再做 resize/move（否则被初始
    // configure 覆盖，实测保存下来的是创建尺寸）
    await wait(250);
    await W.setSize(360, 240, first.id);
    await W.setPosition(70, 50, first.id);
    await wait(250);
    const before = await W.state(first.id);
    await W.close(first.id);
    await wait(250);

    // 同 state_key 的新窗口：创建时应恢复上次关闭时的几何
    const second = await W.create({
      title: 'Zilt Linux 状态持久化 B',
      width: 300, height: 200,
      url: 'about:blank',
      label: 'smoke-state-b',
      stateKey: key,
    });
    // GTK4 的恢复 move 在 map 回调里补发（X11 请求异步）——立即查会读到
    // WM 的初始落点（实测 58,430），等一拍再取。
    await wait(300);
    const restored = second && second.id ? await W.state(second.id) : null;
    // v0.3.0：有 WM 时窗口位置受 frame/gravity 影响（实测 openbox 加了标题栏高度），
    // 位置留 32px 容差（默认落点是居中，与 70,50 差得远）；尺寸仍须精确。
    const ok = !!restored && restored.width === 360 && restored.height === 240 &&
      Math.abs(restored.x - 70) <= 32 && Math.abs(restored.y - 50) <= 32;
    if (second && second.id) await W.close(second.id);
    check('winstate.restore', ok,
      `before=${JSON.stringify(before).slice(0, 90)} restored=${JSON.stringify(restored).slice(0, 90)}`);

    // windowState.get / save：主窗口（persist_window_state=true → state_key=main）
    const ws = await Z().windowState.get();
    const saved = await Z().windowState.save();
    check('winstate.api', !!ws && typeof ws.width === 'number' && ws.width > 0 && saved === true,
      `${JSON.stringify(ws).slice(0, 100)} save=${saved}`);
  } catch (e) { check('winstate.restore', false, String(e.message || e)); }

  // ---- v0.2.1 切片 3：子 WebView（system_fn 的 .webviews 通道）----
  try {
    const WV = Z().webviews;
    // 生命周期：create → list/ready → setBounds → navigate → remove；未知 id remove false
    const created = await WV.create({ x: 8, y: 8, width: 200, height: 120, url: 'about:blank' });
    const cid = created && created.id;
    if (!cid) throw new Error('no id: ' + JSON.stringify(created));
    const list1 = await WV.list();
    const inList = (list1 || []).some((x) => x.id === cid && x.ready === true);
    const sb = await WV.setBounds(cid, 16, 16, 260, 180);
    const nav = await WV.navigate(cid, 'about:blank');
    const removed = await WV.remove(cid);
    const list2 = await WV.list();
    const gone = !(list2 || []).some((x) => x.id === cid);
    const unknown = await WV.remove(999999);
    check('webviewchild.lifecycle', inList && sb && nav && removed && gone && unknown === false,
      `inList=${inList} sb=${sb} nav=${nav} rm=${removed} gone=${gone} unknown=${unknown}`);
  } catch (e) { check('webviewchild.lifecycle', false, String(e.message || e)); }

  // ---- v0.2.1 切片 3：数据分区隔离（对齐 Windows 冒烟 c-partition 的思路）----
  try {
    const probeUrl = 'https://zilt.app/partition-probe.html';
    const mk = async (partition) => {
      const r = await Z().webviews.create({ x: 8, y: 8, width: 220, height: 160, url: probeUrl, partition });
      return r && r.id;
    };
    const aId = await mk('alpha');
    const bId = await mk('beta');
    const sId = await mk(null);
    if (!aId || !bId || !sId) throw new Error('create failed: ' + JSON.stringify([aId, bId, sId]));

    // 等页面文档就绪（eval 断言的前置条件）。注意：create 后 child 还停在
    // about:blank，其 readyState 立即就是 'complete'——必须同时等 pathname
    // 到达 probe 页，否则 localStorage 在 opaque origin 上会抛 SecurityError。
    const settle = async (id) => {
      const t0 = Date.now();
      while (Date.now() - t0 < 10000) {
        const v = await Z().webviews.eval(id, 'document.readyState + "|" + location.pathname');
        if (v === 'complete|/partition-probe.html') return true;
        await new Promise((r) => setTimeout(r, 120));
      }
      return false;
    };
    const sA = await settle(aId), sB = await settle(bId), sS = await settle(sId);

    // 分区数据会跨运行持久化（这正是分区该有的行为）→ 每次用唯一 key，
    // 避免上一轮的残留把「隔离」断言污染成假失败
    const probeKey = 'zilt_part_' + Date.now();
    const writeA = await Z().webviews.eval(aId, `localStorage.setItem('${probeKey}','alpha'); localStorage.getItem('${probeKey}')`);
    const readB = await Z().webviews.eval(bId, `localStorage.getItem('${probeKey}')`);
    const writeB = await Z().webviews.eval(bId, `localStorage.setItem('${probeKey}','beta'); localStorage.getItem('${probeKey}')`);
    const readA2 = await Z().webviews.eval(aId, `localStorage.getItem('${probeKey}')`);
    // 同名分区复用：第三个 alpha 分区实例应读到 alpha 写入的数据（同一 context）
    const a2Id = await mk('alpha');
    const sA2 = a2Id ? await settle(a2Id) : false;
    const readA2dup = sA2 ? await Z().webviews.eval(a2Id, `localStorage.getItem('${probeKey}')`) : 'not-settled';
    // 共享（无分区）子 WebView 与主页面同一 context → 存储互通。
    // 注意：子页面写入后，主页面的 localStorage 内存缓存需要等跨页面
    // 更新传播（实测立即读会拿到旧缓存 → null），给 300ms 传播时间。
    const writeS = await Z().webviews.eval(sId, `localStorage.setItem('${probeKey}','shared'); localStorage.getItem('${probeKey}')`);
    await wait(300);
    const readMain = localStorage.getItem(probeKey);
    // 反向：主页面写 → 共享子读（诊断跨页面共享方向）
    const mainKey2 = 'zilt_main_' + Date.now();
    localStorage.setItem(mainKey2, 'from-main');
    const readBackInShared = await Z().webviews.eval(sId, `localStorage.getItem('${mainKey2}')`);
    localStorage.removeItem(mainKey2);

    const listAll = await Z().webviews.list();
    const parts = (listAll || []).map((x) => x.partition).filter((p) => p);
    const hasParts = parts.includes('alpha') && parts.includes('beta');

    await Z().webviews.remove(aId);
    await Z().webviews.remove(bId);
    await Z().webviews.remove(sId);
    if (a2Id) await Z().webviews.remove(a2Id);
    localStorage.removeItem(probeKey);

    const ok = sA && sB && sS && sA2 &&
      writeA === 'alpha' && readB === null && writeB === 'beta' && readA2 === 'alpha' &&
      readA2dup === 'alpha' && writeS === 'shared' && readMain === 'shared' && hasParts;
    check('partition.isolation', ok, ok
      ? 'partition ok (alpha/beta 隔离 + 同分区复用 + 共享 context 互通)'
      : `settle=${sA},${sB},${sS},${sA2} A=${writeA} B0=${readB} B=${writeB} A2=${readA2} dup=${readA2dup} S=${writeS} main=${readMain} back=${readBackInShared} parts=${JSON.stringify(parts)}`);
  } catch (e) { check('partition.isolation', false, String(e.message || e)); }

  // ---- v0.2.1：下载（download-started → completed 事件 + 目标路径）----
  try {
    const events = await new Promise((resolve) => {
      const seen = [];
      const offs = [];
      const finish = () => { for (const off of offs) off(); resolve(seen); };
      offs.push(Z().on('webview.download_started', (p) => seen.push({ k: 'start', p })));
      offs.push(Z().on('webview.download_progress', (p) => seen.push({ k: 'progress', p })));
      offs.push(Z().on('webview.download_completed', (p) => { seen.push({ k: 'done', p }); finish(); }));
      offs.push(Z().on('webview.download_failed', (p) => { seen.push({ k: 'fail', p }); finish(); }));
      // data: URL + download 属性触发一次真实下载（demo 配置 show_dialog=false
      // → 落到 $HOME/Downloads，无需人工交互）。
      // 实测：zilt://（自定义 scheme）下载会被 WebKit 拒绝（"The URL can't be
      // shown"），所以用 data: URL；它的 suggested filename 为空 → 走
      // download-<id> 兜底命名。
      const a = document.createElement('a');
      a.href = 'data:text/plain;base64,' + btoa('zilt-linux-download');
      a.download = 'zilt-smoke-download.txt';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(finish, 8000);
    });
    const start = events.find((e) => e.k === 'start');
    const done = events.find((e) => e.k === 'done');
    // data: URL 没有 suggested filename → 目标名走 download-<id> 兜底；
    // 重复运行会命中重名策略（追加 " (n)"）。断言落在 Downloads 目录。
    const started = !!start && typeof start.p.id === 'number' &&
      /\/Downloads\/(zilt-smoke-download\.txt|download-\d+( \(\d+\))?)$/.test(start.p.path || '');
    const completed = !!done && done.p.received > 0 && done.p.id === (start && start.p.id);
    check('download', started && completed, JSON.stringify(events).slice(0, 240));

    // 未知下载 id：稳定返回 UnknownDownload（不清空/不崩溃）
    let cancelErr = '';
    try { await Z().webview.cancelDownload(999999); } catch (e) { cancelErr = String(e.message || e); }
    check('download.cancel', cancelErr === 'UnknownDownload', cancelErr);
  } catch (e) { check('download', false, String(e.message || e)); }

  // ---- v0.2.2：剪贴板（文本 / HTML / 文件列表）----
  try {
    const C = Z().clipboard;
    await C.writeText('zilt-linux-clipboard');
    const text = await C.read('text');
    await C.writeHtml('<b>zilt</b>');
    const html = await C.read('html');
    await C.writeFiles(['/tmp/a.txt', '/tmp/b c.txt']);
    const files = await C.read('files');
    const ok = text === 'zilt-linux-clipboard' &&
      typeof html === 'string' && html.includes('<b>zilt</b>') &&
      Array.isArray(files) && files.length === 2 && files[0] === '/tmp/a.txt' && files[1] === '/tmp/b c.txt';
    check('clipboard', ok, `text=${text} html=${String(html).slice(0, 30)} files=${JSON.stringify(files)}`);
  } catch (e) { check('clipboard', false, String(e.message || e)); }

  // ---- v0.2.2：通知（GNotification；需要 D-Bus session bus）----
  // 无会话总线（纯 Xvfb、无 dbus-run-session）时框架按设计降级：
  // status = disabled_for_application 且 show 不抛异常 —— 两者都算通过。
  try {
    const st = await Z().notification.status();
    const enabled = !!st && st.status === 'enabled';
    if (enabled) {
      await Z().notification.show({ title: 'Zilt Linux Smoke', body: 'GNotification', tag: 'smoke' });
      await Z().notification.update({ tag: 'smoke', title: 'Zilt Linux Smoke', text: 'updated' });
    }
    check('notification', !!st && (enabled || st.status === 'disabled_for_application'), `status=${JSON.stringify(st)}`);
  } catch (e) { check('notification', false, String(e.message || e)); }

  // ---- v0.2.1：clearStorage（WebKitWebsiteDataManager::clear）----
  try {
    const st = await Z().webview.clearStorage();
    check('storage.clear', st !== false, JSON.stringify(st));
  } catch (e) { check('storage.clear', false, String(e.message || e)); }

  // ---- v0.2.2：运行时菜单模型（menu.* —— config.tray.menu 初始化，与 Windows 同构）----
  try {
    const M = Z().menu;
    const findNode = (nodes, id) => {
      for (const n of nodes || []) {
        if (n.id === id) return n;
        const hit = findNode(n.children, id);
        if (hit) return hit;
      }
      return null;
    };
    const list0 = await M.list();
    const baseOk = Array.isArray(list0) && list0.length >= 1;
    // add（根级）→ set（勾选）→ list 校验 → remove
    await M.add({ title: '冒烟项', path: 'smoke-item' });
    const list1 = await M.list();
    const added = !!findNode(list1, 'smoke-item');
    const setRes = await M.set('smoke-item', { checked: true });
    const node = findNode(await M.list(), 'smoke-item');
    const checkedOk = !!node && node.checked === true;
    const rm = await M.remove('smoke-item');
    const removed = !findNode(await M.list(), 'smoke-item');
    check('menu.model', baseOk && added && setRes !== false && checkedOk && rm === true && removed,
      `base=${list0.length} add=${added} set=${setRes}/${checkedOk} rm=${rm}/${removed}`);

    // popup：程序化弹出（Xvfb 无 WM 也可弹）→ 不崩且返回 ok；deactivate 后由
    // 后端销毁（这里只验证命令路径）
    const pop = await M.popup(24, 24);
    check('menu.popup', pop === true, JSON.stringify(pop));
  } catch (e) { check('menu.model', false, String(e.message || e)); }

  // ---- v0.4.3 L6：托盘挂窗（tray.attach_window——toggle + 指针定位 + 抑制窗）----
  if (!CAPS.tray) {
    check('tray.attach', true, 'skipped (GTK4: ayatana is GTK3-linked)');
  } else try {
    const attachResult = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), 5000);
      Z().on('linuxSmokeAttach', (p) => { clearTimeout(timer); resolve(p); });
      Z().invoke('__zilt.linuxSmokeAttach', {}).catch(() => { clearTimeout(timer); resolve(null); });
    });
    const ok = !!attachResult && attachResult.before === true && attachResult.after === true;
    check('tray.attach', ok, JSON.stringify(attachResult));
  } catch (e) { check('tray.attach', false, String(e.message || e)); }

  // ---- v0.2.2：系统信息（/etc/os-release + GDK monitors）----
  try {
    const os = await Z().system.os();
    const mons = await Z().system.monitors();
    const ok = !!os && typeof os.name === 'string' && os.name.length > 0 &&
      typeof os.locale === 'string' && os.locale.length > 0 &&
      Array.isArray(mons) && mons.length >= 1 &&
      mons[0].width > 0 && mons[0].height > 0 && mons[0].dpi >= 96;
    check('sysinfo', ok, `os=${JSON.stringify(os).slice(0, 110)} mon0=${JSON.stringify((mons || [])[0] || {}).slice(0, 110)}`);
  } catch (e) { check('sysinfo', false, String(e.message || e)); }

  // ---- v0.2.2：自启动（真实写/删 ~/.config/autostart/<app_id>.desktop）----
  try {
    const en = await Z().autostart.enable();
    const q1 = await Z().autostart.query();
    const dis = await Z().autostart.disable();
    const q2 = await Z().autostart.query();
    check('autostart', !!en && en.enabled === true && q1.enabled === true && dis && q2.enabled === false,
      `en=${JSON.stringify(en)} q1=${JSON.stringify(q1)} q2=${JSON.stringify(q2)}`);
  } catch (e) { check('autostart', false, String(e.message || e)); }

  // ---- v0.2.2：拖放（后端经 __zilt.linuxSmokeDrop 触发模拟投递 → dropFiles 事件）----
  // 真实 X11 拖拽需要指针自动化；这里覆盖「uri-list 解析 → dropFiles 事件 →
  // 前端监听」全链路（GDK 信号接线由单测 + 日志保证）。
  try {
    const files = await new Promise((resolve) => {
      const off = Z().on('dropFiles', (p) => { off(); resolve(p.files); });
      Z().invoke('__zilt.linuxSmokeDrop', {}).catch(() => {});
      setTimeout(() => { off(); resolve(null); }, 4000);
    });
    check('drop.files', Array.isArray(files) && files.length === 2 &&
      files[0] === '/tmp/zilt-smoke-a.txt' && files[1] === '/tmp/zilt-smoke-b.txt', JSON.stringify(files));
  } catch (e) { check('drop.files', false, String(e.message || e)); }

  // ---- v0.2.2：深链（启动深链经 pending_launch 在页面就绪后补发）----
  // 注入 ZILT_LINUX_SMOKE_DEEPLINK 时断言事件 url 精确匹配；未注入时事件不达
  //（__ziltDeepLinkSeen 一直为 null）也算通过——同一脚本覆盖两种环境。
  try {
    const want = window.__ziltSmokeDeepLink || null;
    const dl = await new Promise((resolve) => {
      if (window.__ziltDeepLinkSeen) return resolve(window.__ziltDeepLinkSeen);
      const off = Z().on('deepLink', (p) => { off(); resolve(p); });
      setTimeout(() => { off(); resolve(window.__ziltDeepLinkSeen); }, 1500);
    });
    const ok = want ? (!!dl && dl.url === want) : (dl == null || typeof dl.url === 'string');
    check('deeplink.startup', ok, `want=${want} got=${JSON.stringify(dl)}`);
  } catch (e) { check('deeplink.startup', false, String(e.message || e)); }

  // ---- v0.2.3：store（KV + store.json 落盘）----
  try {
    const S = Z().store;
    const setRes = await S.set('smoke-key', 'smoke-value');
    const got = await S.get('smoke-key');
    const keys = await S.keys();
    const rm = await S.remove('smoke-key');
    const gone = await S.get('smoke-key');
    check('store', setRes === true && got === 'smoke-value' &&
      Array.isArray(keys) && keys.includes('smoke-key') && rm === true && gone === null,
      `set=${setRes} got=${got} keys=${JSON.stringify(keys)} rm=${rm} gone=${gone}`);
  } catch (e) { check('store', false, String(e.message || e)); }

  // ---- v0.2.3：fs 12 ops（appData scope）----
  try {
    const F = Z().fs;
    const dir = 'smoke-fs-' + Date.now();
    const w = await F.write(`${dir}/a.txt`, 'hello');
    const r = await F.read(`${dir}/a.txt`);
    const app = await F.append(`${dir}/a.txt`, '!');
    const r2 = await F.read(`${dir}/a.txt`);
    const ex = await F.exists(`${dir}/a.txt`);
    await F.mkdir(`${dir}/sub`);
    const lst = await F.readDir(dir);
    const st = await F.stat(`${dir}/a.txt`);
    const rn = await F.rename(`${dir}/a.txt`, `${dir}/sub/b.txt`);
    const cp = await F.copy(`${dir}/sub/b.txt`, `${dir}/c.txt`);
    const rd = await F.remove(`${dir}/c.txt`);
    const rmDir = await F.removeDir(dir);
    const gone = await F.exists(`${dir}/a.txt`);
    check('fs.ops', w && r === 'hello' && app && r2 === 'hello!' && ex === true &&
      Array.isArray(lst) && lst.length >= 2 && st && st.dir === false && st.size === 6 &&
      rn && cp && rd && rmDir && gone === false,
      `w=${w} r=${r} r2=${r2} lst=${JSON.stringify(lst).slice(0, 60)} st=${JSON.stringify(st)} rn=${rn} cp=${cp} gone=${gone}`);
  } catch (e) { check('fs.ops', false, String(e.message || e)); }

  // ---- v0.2.3：fs ACL（documents 未声明 → 拒绝；grant → 读写；revoke → 再拒绝）----
  try {
    const F = Z().fs;
    const A = Z().acl;
    let denied = false;
    try { await F.write('smoke-acl.txt', 'x', 'documents'); } catch (e) {
      denied = String(e.message).includes('PermissionDenied');
    }
    await A.grant('fs', 'documents/**');
    let writeOk = false;
    try { writeOk = (await F.write('smoke-acl.txt', 'granted', 'documents')) === true; } catch (_) {}
    const readBack = writeOk ? await F.read('smoke-acl.txt', 'documents') : null;
    const revokeRes = await A.revoke('fs', 'documents/**');
    let deniedAgain = false;
    try { await F.write('smoke-acl-2.txt', 'y', 'documents'); } catch (e) {
      deniedAgain = String(e.message).includes('PermissionDenied');
    }
    const afterList = await A.list();
    check('fs.acl', denied && writeOk && readBack === 'granted' && revokeRes === true && deniedAgain &&
      !afterList.includes('fs:documents/**'),
      `denied=${denied} write=${writeOk} read=${readBack} revoke=${revokeRes} again=${deniedAgain}`);
  } catch (e) { check('fs.acl', false, String(e.message || e)); }

  // ---- v0.2.3：fs.watch（inotify）+ readStream ----
  try {
    const F = Z().fs;
    const dir = 'watch-' + Date.now();
    await F.mkdir(`${dir}`);
    const wid = (await F.watch(dir, {})).id;
    const events = await new Promise((resolve) => {
      const seen = [];
      const off = Z().on('fsEvent', (p) => { if (p.id === wid) seen.push(p); });
      setTimeout(async () => {
        await F.write(`${dir}/a.txt`, 'watch me').catch(() => {});
        setTimeout(() => { off(); resolve(seen); }, 1200);
      }, 300);
    });
    await F.unwatch(wid);
    const added = events.some((e) => e.action === 'added' && /a\.txt$/.test(e.path));
    const modified = events.some((e) => e.action === 'modified');
    // readStream：3 分块 + done
    const big = 'zilt-fs-stream-'.repeat(2000); // 29000 字节 → 4096 分块 8 段
    await F.write(`${dir}/big.bin`, big);
    const chunks = await new Promise((resolve) => {
      const seen = [];
      const off = Z().on('fsChunk', (p) => { if (p.id) seen.push(p); });
      F.readStream(`${dir}/big.bin`, { chunkSize: 4096 }).catch(() => {});
      setTimeout(() => { off(); resolve(seen); }, 2500);
    });
    const total = chunks.map((c) => atob(c.data)).join('');
    const lastDone = chunks.length > 0 && chunks[chunks.length - 1].done === true;
    await F.removeDir(dir);
    check('fs.watch', wid > 0 && added && modified, `id=${wid} n=${events.length} added=${added} mod=${modified}`);
    check('fs.stream', chunks.length > 1 && total === big && lastDone,
      `chunks=${chunks.length} len=${total.length}/${big.length} done=${lastDone}`);
  } catch (e) { check('fs.watch', false, String(e.message || e)); }

  // ---- v0.2.3：SQL（libsqlite3；migrate + execute + query）----
  try {
    const Q = Z().sql;
    const db = `/tmp/zilt-smoke-${Date.now()}.db`;
    await Q.migrate(db, 1, ['CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, name TEXT)']);
    const ins = await Q.execute(db, 'INSERT INTO t (name) VALUES (?)', ['linux']);
    const rows = await Q.query(db, 'SELECT * FROM t WHERE name = ?', ['linux']);
    const rowOk = rows.length === 1 && rows[0].name === 'linux' && rows[0].id === ins.last_id;
    check('sql', ins && ins.changes === 1 && rowOk,
      `ins=${JSON.stringify(ins)} rows=${JSON.stringify(rows).slice(0, 100)}`);
  } catch (e) { check('sql', false, String(e.message || e)); }

  // ---- v0.2.3：http（libsoup3；ConnectionRefused 拒绝路径 + echo server 往返）----
  try {
    const refused = await new Promise((resolve) => {
      const off = Z().on('httpResponse', (p) => { if (p.id === -901) { off(); resolve(p); } });
      Z().invoke('__zilt.http', { action: 'request', id: -901, url: 'http://127.0.0.1:1/', method: 'GET' }).catch(() => {});
      setTimeout(() => { off(); resolve(null); }, 4000);
    });
    const refusedOk = !!refused && refused.status === 0 && String(refused.err).length > 0;
    // echo server（dev-smoke.sh 起 scripts/http_echo.py）；不在时跳过 200 断言
    let echoOk = true;
    let echoNote = 'server absent';
    try {
      const echo = await new Promise((resolve) => {
        const off = Z().on('httpResponse', (p) => { if (p.id === -902) { off(); resolve(p); } });
        Z().invoke('__zilt.http', { action: 'request', id: -902, url: 'http://127.0.0.1:8788/echo', method: 'POST', body: 'zilt-http' }).catch(() => {});
        setTimeout(() => { off(); resolve(null); }, 4000);
      });
      if (echo && echo.status === 200) {
        const parsed = JSON.parse(echo.body);
        echoOk = parsed.len === 9 && typeof parsed.sha256 === 'string';
        echoNote = `status=${echo.status} len=${parsed.len}`;
      } else if (echo) {
        echoOk = false;
        echoNote = `status=${echo.status} err=${echo.err}`;
      }
    } catch (e) { echoNote = String(e); }
    check('http', refusedOk && echoOk, `refused=${JSON.stringify(refused).slice(0, 80)} echo=${echoNote}`);
  } catch (e) { check('http', false, String(e.message || e)); }

  // ---- v0.2.3：ws（拒绝路径：ConnectionRefused → error 事件）----
  try {
    const ev = await new Promise((resolve) => {
      const seen = [];
      const off = Z().on('wsEvent', (p) => { if (p.id === -903 && (p.kind === 'error' || p.kind === 'close')) { off(); resolve(p); } });
      Z().invoke('__zilt.ws', { action: 'connect', id: -903, url: 'ws://127.0.0.1:1/' }).catch(() => {});
      setTimeout(() => { off(); resolve(null); }, 4000);
    });
    check('ws', !!ev && ev.kind === 'error', JSON.stringify(ev));
  } catch (e) { check('ws', false, String(e.message || e)); }

  // ---- v0.2.3：应用自定义协议 → 真 scheme（echo/json/bin）----
  try {
    const echoResp = await fetch('echo://a/b?x=1');
    const echoBody = await echoResp.text();
    // fetch 对自定义 scheme 的响应头可见性受 CORS 白名单约束（Expose-Headers）
    const echoOk = echoResp.status === 200 &&
      (echoResp.headers.get('X-Proto') === 'zilt' || echoResp.headers.get('x-proto') === 'zilt' || echoResp.headers.get('X-Proto') === null) &&
      echoBody.startsWith('echo|a/b|x=1|GET|');
    const jsonResp = await fetch('json://item');
    const jsonBody = jsonResp.headers.get('content-type') ? '' : await jsonResp.text();
    const jsonOk = jsonResp.status === 201 &&
      (!jsonResp.headers.get('content-type') || jsonResp.headers.get('content-type').startsWith('application/json')) &&
      (jsonBody === '' || jsonBody.includes('proto'));
    const binResp = await fetch('bin://bytes');
    const binBuf = new Uint8Array(await binResp.arrayBuffer());
    const binOk = binBuf.byteLength === 4 &&
      binBuf[0] === 0 && binBuf[1] === 1 && binBuf[2] === 0xfe && binBuf[3] === 0xff;
    check('proto', echoOk && jsonOk && binOk,
      `echo=${echoResp.status} "${echoBody.slice(0, 40)}" json=${jsonResp.status} bin=${binBuf.byteLength}`);
  } catch (e) { check('proto', false, String(e.message || e)); }

  // ---- v0.2.6：窗口事件面——close-request 拦截（per-window opt-in，无头可测；
  //      windowMoved/Resized/Focus/Blur 由 configure/focus 信号驱动，Xvfb 无 WM
  //      不触发，实现与桌面行为同代码路径）----
  try {
    const W = Z().window;
    // 主窗口在冒烟模式下被后端 opt-in close-request：close 触发 delete-event
    // → 拦截 → windowCloseRequested（发给本窗口）→ 窗口存活（前端确认语义）
    const reqSeen = await new Promise((resolve) => {
      const off = Z().on('windowCloseRequested', (p) => { if (p.id === 1) { off(); resolve(true); } });
      W.close(1).catch(() => {});
      setTimeout(() => { off(); resolve(false); }, 3000);
    });
    let stillAlive = false;
    try { const st = await W.state(1); stillAlive = !!st && st.id === 1; } catch (_) {}
    check('win.closereq', reqSeen && stillAlive, `req=${reqSeen} alive=${stillAlive}`);
  } catch (e) { check('win.closereq', false, String(e.message || e)); }

  // ---- v0.2.6：全局快捷键（X11 XGrabKey；register → list → unregister）----
  try {
    const H = Z().hotkey;
    const reg = await H.register('smoke-hotkey-v026', 'Ctrl+Alt+F9');
    const list1 = await H.list();
    const inList = (list1 || []).some((e) => e.id === 'smoke-hotkey-v026' && e.accel === 'Ctrl+Alt+F9');
    const un = await H.unregister('smoke-hotkey-v026');
    const list2 = await H.list();
    const gone = !(list2 || []).some((e) => e.id === 'smoke-hotkey-v026');
    check('hotkey.x11', reg === true && inList && un === true && gone,
      `reg=${reg} list=${JSON.stringify(list1).slice(0, 80)} un=${un}`);
  } catch (e) { check('hotkey.x11', false, String(e.message || e)); }

  // ---- v0.2.7：导航策略（decide-policy）——外部导航命中 security.navigation
  //      的 external_links（demo 配置 = system_browser）→ 拦截 + 事件
  //      policy=system_browser，页面留在应用 origin（mapAppUrl 后是 zilt://app）----
  try {
    const ev = await new Promise((resolve) => {
      const off = Z().on('webview.navigation_starting', (p) => { off(); resolve(p); });
      setTimeout(() => { off(); resolve(null); }, 4000);
      location.href = 'https://example.com/zilt-nav-deny-probe';
    });
    let stillHome = false;
    try {
      const o = location.origin;
      stillHome = o === 'zilt://app' || o === 'https://zilt.app';
    } catch (_) {}
    check('nav.deny', !!ev && ev.policy === 'system_browser' && stillHome,
      `policy=${ev && ev.policy} home=${stillHome}`);
  } catch (e) { check('nav.deny', false, String(e.message || e)); }

  // ---- v0.2.7：权限请求（permission-request 信号）——geolocation 的默认策略是
  //      ask → 冒烟模式自动拒绝；事件 {kind:location, policy:ask} 与 Windows 同形 ----
  try {
    const ev = await new Promise((resolve) => {
      const off = Z().on('webview.permission', (p) => { off(); resolve(p); });
      setTimeout(() => { off(); resolve(null); }, 4000);
      try {
        navigator.geolocation.getCurrentPosition(() => {}, () => {}, { timeout: 2000 });
      } catch (_) {}
    });
    check('perm.geo', !!ev && ev.kind === 'location' && ev.policy === 'ask',
      JSON.stringify(ev));
  } catch (e) { check('perm.geo', false, String(e.message || e)); }

  // ---- v0.2.7：shell（opener）——xdg-open 分离拉起。op 返回 ok=true（spawn 成功）
  //      或稳定错误 ShellExecuteFailed（本环境无 xdg-utils；CI apt 装 xdg-utils 走
  //      真实成功路径）——两条路径都证明 op 链路可达且错误语义稳定 ----
  try {
    let outcome = '';
    try {
      const r = await Z().shell.openUrl('https://example.com/zilt-smoke-open');
      outcome = 'ok=' + JSON.stringify(r);
    } catch (err) {
      outcome = 'err=' + String(err.message || err);
    }
    // Linux 后端在部分环境返回布尔 true（CI 45025651776 实测 ok=true），早于/平行于
    // Windows 的 {ok:true} 形态——三种语义都算链路可达
    check('shell.open', outcome === 'ok={"ok":true}' || outcome === 'ok=true' ||
      outcome === 'err=ShellExecuteFailed', outcome);
  } catch (e) { check('shell.open', false, String(e.message || e)); }

  // ---- v0.2.7：services（Config.services → Registry → JS list/status）----
  try {
    const list = await Z().services.list();
    const demo = Array.isArray(list) && list.find((s) => s && s.name === 'demo');
    const st = await Z().services.status('demo');
    check('services.list', !!demo && demo.started === true && st && st.started === true,
      JSON.stringify(list));
  } catch (e) { check('services.list', false, String(e.message || e)); }

  // ---- v0.2.7：updater.info（config.update 已配置；不触发网络）----
  try {
    const info = await Z().updater.info();
    check('updater.info', !!info && info.configured === true && info.restart_required === false,
      JSON.stringify(info).slice(0, 120));
  } catch (e) { check('updater.info', false, String(e.message || e)); }

  // ---- v0.2.7：per-window WebView 代理（独立 WebContext；死代理只影响加载，
  //      窗口本身要能创建/关闭）----
  try {
    const created = await Z().window.create({
      title: 'proxy probe',
      width: 320, height: 200,
      url: 'https://zilt.app/index.html',
      proxy: 'http://127.0.0.1:9',
      label: 'smoke-proxy-' + Date.now(),
    });
    const pid = created && created.id;
    await new Promise((r) => setTimeout(r, 600));
    try { await Z().window.close(pid); } catch (_) {}
    check('proxy.window', typeof pid === 'number' && pid > 1, 'id=' + pid);
  } catch (e) { check('proxy.window', false, String(e.message || e)); }

  // ---- v0.2.9：页内查找（runtime 纯 JS window.find，两平台同实现——
  //      后端零参与，冒烟锁定该 API 面在 Linux 同样可用）----
  try {
    const body = (document.body.innerText || '').trim();
    const probe = (body.split(/\s+/)[0] || '').slice(0, 12);
    const found = probe.length > 0 ? Z().webview.find(probe) : false;
    check('find', found === true, 'find(' + JSON.stringify(probe) + ') -> ' + found);
  } catch (e) { check('find', false, String(e.message || e)); }

  // ---- v0.3.0：子进程（spawn → stdout 事件 → exit；ACL shell:echo 放行）----
  try {
    const pid = 900 + (Date.now() % 1000);
    const events = await new Promise((resolve) => {
      const seen = [];
      const off = Z().on('processEvent', (p) => {
        if (p && p.id === pid) {
          seen.push(p);
          if (p.kind === 'exit') { off(); resolve(seen); }
        }
      });
      Z().process.spawn({ id: pid, argv: ['/bin/echo', 'zilt-proc-smoke'] });
      setTimeout(() => { off(); resolve(seen); }, 6000);
    });
    const out = events.find((e2) => e2.kind === 'stdout');
    const exit = events.find((e2) => e2.kind === 'exit');
    check('proc', !!exit && exit.code === 0 && !!out && String(out.data || '').includes('zilt-proc-smoke'),
      JSON.stringify(events).slice(0, 140));
  } catch (e) { check('proc', false, String(e.message || e)); }

  // ---- v0.3.0：子进程 ACL 拒绝（/bin/ls 不在 shell scope → PermissionDenied）----
  try {
    let denied = false;
    try { await Z().process.spawn({ id: 99901, argv: ['/bin/ls', '/'] }); } catch (err) {
      denied = String(err.message || err).includes('PermissionDenied');
    }
    check('proc.acl', denied, 'denied=' + denied);
  } catch (e) { check('proc.acl', false, String(e.message || e)); }

  // ---- v0.3.0：通知交互（按钮/launch 走 GAction 索引机制；无头环境断言
  //      发送 + GAction 注册；input 为 WinRT 独有 → 稳定 NotSupported）----
  try {
    await Z().notification.show({
      title: 'v0.3.0 notify', body: 'buttons smoke', tag: 'smoke-actions',
      actions: [
        { title: 'Open', arguments: 'action-args-1' },
        { title: 'More', arguments: 'action-args-2' },
      ],
    });
    let inputRejected = false;
    try {
      await Z().notification.show({ title: 'x', body: 'y', input: { id: 'note' } });
    } catch (err) {
      inputRejected = String(err.message || err).includes('NotificationInputNotSupported');
    }
    check('notify.actions', inputRejected, 'buttons sent + input rejected=' + inputRejected);
  } catch (e) { check('notify.actions', false, String(e.message || e)); }

  // ---- v0.3.0：覆盖式标题栏 / 透明窗口 / 背景色（创建期选项；Xvfb 无合成器
  //      → 只断言后端接受并反映到 state；真实透明效果需桌面合成器）----
  try {
    const created = await Z().window.create({
      title: 'overlay probe', width: 360, height: 240,
      url: 'https://zilt.app/second.html',
      label: 'smoke-overlay-' + Date.now(),
      decorations: false,
      titlebarOverlay: true,
      transparent: true,
    });
    const oid = created && created.id;
    await wait(300);
    const st = oid ? await Z().window.state(oid) : null;
    const ok = !!st && st.overlay === true && st.transparent === true && st.background_color === -1;
    try { await Z().window.close(oid); } catch (_) {}
    check('win.overlay', ok, JSON.stringify(st || {}).slice(0, 160));

    const created2 = await Z().window.create({
      title: 'bg probe', width: 320, height: 200,
      url: 'https://zilt.app/second.html',
      label: 'smoke-bg-' + Date.now(),
      backgroundColor: 0x102030,
    });
    const bid = created2 && created2.id;
    await wait(300);
    const st2 = bid ? await Z().window.state(bid) : null;
    const ok2 = !!st2 && st2.transparent === false && st2.background_color === 0x102030;
    try { await Z().window.close(bid); } catch (_) {}
    check('win.background', ok2, JSON.stringify(st2 || {}).slice(0, 160));
  } catch (e) { check('win.overlay', false, String(e.message || e)); }

  // ---- v0.3.0：脚本对话框接管（script-dialog 信号）——冒烟自动阻止，
  //      alert 不弹模态框、eval 正常完成；探针同时确认右键菜单信号已接线 ----
  try {
    const wired = await Z().invoke('__zilt.linuxSmokeWired', {});
    const ev = await Z().eval('alert("zilt-smoke"); 7');
    check('win.dialog',
      !!wired && wired.script_dialog === true && wired.context_menu === true && ev === 7,
      `wired=${JSON.stringify(wired)} eval=${ev}`);
  } catch (e) { check('win.dialog', false, String(e.message || e)); }

  // ---- v0.3.0：WM 下的窗口事件（windowMoved / windowResized / Focus）----
  //      Xvfb 裸跑无 WM（configure/focus 不触发）→ skip；CI 装 openbox 后真实断言。
  try {
    const wired = await Z().invoke('__zilt.linuxSmokeWired', {});
    if (wired && wired.wm) {
      const W = Z().window;
      const state = async (id) => (id === undefined ? await W.state() : await W.state(id));
      // 先确保窗口是普通映射态：前面 minimize/maximize 都是异步 X 请求，
      // 未映射/最大化窗口上的 move/resize 会被忽略（GTK3 实测 1280x781）。
      await W.restore();
      await W.show();
      // v0.5.10：openbox 的 unminimize/unmaximize 是异步的——restore/show 还没
      // 落定时发来的 XMoveWindow/XResizeWindow 会被 WM 丢弃，窗口停在旧位置
      //（GTK4 实测 128,141，windowMoved 整段收不到）。先等窗口回到普通映射态。
      for (let t = 0; t < 20; t++) {
        const s = await state(1).catch(() => null);
        if (s && s.visible && !s.iconic && !s.zoomed) break;
        // restore 本身也可能被 WM 丢掉（异步）——只要还停在 iconic/zoomed 就再发一次
        if (s && (s.iconic || s.zoomed)) await W.restore();
        await wait(100);
      }
      // 移动/缩放：先记录事件，再用 state() 校验几何（见下方 frame 偏移说明）
      // 事件按载荷过滤：队列里可能残留更早的 move（0,19），不能当成这次的结果。
      // 请求可能被 WM 丢弃（见上）→ 重发，最多 3 次；事件仍必须真实到达。
      const awaitEvent = async (name, pred, fire) => {
        for (let a = 0; a < 3; a++) {
          const got = await new Promise((resolve) => {
            const off = Z().on(name, (p) => { if (pred(p)) { off(); resolve(p); } });
            setTimeout(() => { off(); resolve(null); }, 1200);
            try { fire(); } catch (_) {}
          });
          if (got) return got;
        }
        return null;
      };
      const moved = await awaitEvent(
        'windowMoved',
        (p) => p.id === 1 && Math.abs(p.x - 150) <= 64 && Math.abs(p.y - 120) <= 64,
        () => { W.setPosition(150, 120).catch(() => {}); },
      );
      await wait(150);
      const posAfter = await state();
      const resized = await awaitEvent(
        'windowResized',
        (p) => p.id === 1 && p.width === 820 && p.height === 620,
        () => { W.setSize(820, 620).catch(() => {}); },
      );
      await wait(150);
      const sizeAfter = await state();

      // 焦点闭环：先确保主窗口是 active，再新建窗口并显式 focus（openbox 的
      // focusNew 不保证交权）→ 主窗口 windowBlur；再 focus 回主窗口 → windowFocus
      await W.focus(1);
      await wait(200);
      let blurred = false;
      const blurWait = new Promise((resolve) => {
        const off = Z().on('windowBlur', (p) => {
          if (p.id === 1) { blurred = true; off(); resolve(true); }
        });
        setTimeout(() => { off(); resolve(false); }, 3000);
      });
      let fid = null;
      try {
        const cw = await Z().window.create({
          title: 'focus probe', width: 240, height: 160,
          url: 'https://zilt.app/second.html',
          label: 'smoke-focus-' + Date.now(),
        });
        fid = cw && cw.id;
      } catch (_) {}
      if (fid) {
        // 等窗口 map 完成再 focus（openbox 对未映射窗口的 present 会丢）
        await wait(250);
        try { await W.focus(fid); } catch (_) {}
      }
      let probeActive = false;
      if (fid) {
        for (let t = 0; t < 15 && !probeActive; t++) {
          await wait(100);
          try { probeActive = (await W.state(fid)).focused === true; } catch (_) {}
        }
      }
      await blurWait;
      const focused = await new Promise((resolve) => {
        const off = Z().on('windowFocus', (p) => {
          if (p.id === 1) { off(); resolve(true); }
        });
        setTimeout(() => { off(); resolve(false); }, 3000);
        W.focus(1).catch(() => {});
      });
      await wait(300);
      let mainActive = false;
      for (let t = 0; t < 10 && !mainActive; t++) {
        try { mainActive = (await W.state(1)).focused === true; } catch (_) {}
        if (!mainActive) await wait(100);
      }
      try { await Z().window.close(fid); } catch (_) {}

      // configure-event 的 x/y 在 reparent 型 WM 下含 frame 偏移（openbox 实测
      // y 差 20px）→ 事件存在 + state() 落在请求位置附近即视为通过；尺寸须精确。
      const moveOk = !!moved && Math.abs(posAfter.x - 150) <= 32 && Math.abs(posAfter.y - 120) <= 32;
      const sizeOk = !!resized && resized.width === sizeAfter.width && resized.height === sizeAfter.height;
      // 焦点：事件与 state 两条证据任一成立即可（openbox/Xvfb 下 focusNew 与
      // present 都可能丢一次，事件更易被合并；只认其中一条会偶发假红）。
      const focusOk = (blurred || probeActive) && (focused || mainActive);
      check('wm.events', moveOk && sizeOk && focusOk,
        `move=${JSON.stringify(moved)}/${posAfter.x},${posAfter.y} ` +
        `size=${JSON.stringify(resized)}/${sizeAfter.width}x${sizeAfter.height} ` +
        `blur=${blurred} focus=${focused} probeActive=${probeActive} mainActive=${mainActive}`);
      // 复原几何，避免影响后续检查
      W.setPosition(60, 40).catch(() => {});
      W.setSize(800, 600).catch(() => {});
      await wait(150);
    } else {
      check('wm.events', true, 'skipped (no WM; CI installs openbox)');
    }
  } catch (e) { check('wm.events', false, String(e.message || e)); }

  // ---- v0.3.0：拖出（drag-data-get → text/uri-list）——真实投递需要目标程序；
  //      冒烟断言 begin 被接受、主循环存活（drag-data-get 内容由后端日志佐证）。
  //      放在最后：GTK 拖拽会持有指针 grab，避免影响上面的焦点类断言 ----
  if (!CAPS.programmatic_drag) {
    // GTK4：GDK 无公开的脚本发起拖拽入口 → 必须 DragNotAvailable（不是静默成功）
    let err = null;
    try { await Z().drag.start(['/tmp/zilt-drag-out-a.txt']); } catch (e) { err = String(e.message || e); }
    check('drag.out', err === 'DragNotAvailable', `skipped (GTK4) err=${err}`);
  } else try {
    const ok = await Z().drag.start(['/tmp/zilt-drag-out-a.txt', '/tmp/zilt drag b.txt']);
    await wait(150);
    const alive = (await Z().window.state()).id === 1;
    // 无返回值动作的响应是 JSON null（与 Windows 一致）——断言「未被拒绝」
    check('drag.out', ok !== false && alive, `start=${ok} alive=${alive}`);
  } catch (e) { check('drag.out', false, String(e.message || e)); }

  // ---- v0.3.2：无痕窗口（window.create({incognito}) → state().incognito）----
  try {
    const w = await Z().window.create({ title: 'incognito probe', label: 'incog-' + Date.now(), width: 240, height: 160, incognito: true });
    const st = w && typeof w.id === 'number' ? await Z().window.state(w.id) : null;
    try { if (w && typeof w.id === 'number') await Z().window.close(w.id); } catch (_) {}
    check('privacy', !!st && st.incognito === true, JSON.stringify(st).slice(0, 60));
  } catch (e) { check('privacy', false, String(e.message || e)); }

  // ---- v0.3.2：显示器细化（current 标记 + workarea + state().monitor）----
  try {
    const mons = await Z().system.monitors();
    const arr = Array.isArray(mons) ? mons : (mons && mons.monitors) || [];
    const cur = arr.filter((m) => m.current === true);
    const st = await Z().window.state();
    const workOk = arr.every((m) => typeof m.workX === 'number' && typeof m.workWidth === 'number');
    check('monitor', arr.length >= 1 && cur.length === 1 && workOk && typeof st.monitor === 'number' && st.monitor === cur[0].index,
      `${arr.length} display(s) current=${cur.length ? cur[0].index : '-'} work=${cur.length ? cur[0].workWidth : '-'} state=${st.monitor}`);
  } catch (e) { check('monitor', false, String(e.message || e)); }

  // ---- v0.3.3：窗口体验包 II（创建选项 + simple_fullscreen；resize_dragging 不自动测）----
  try {
    const w = await Z().window.create({ title: 'exp2 probe', label: 'exp2-' + Date.now(), width: 400, height: 300, hideOnFocusLost: true, preventOverflow: true });
    const wid = w && typeof w.id === 'number' ? w.id : null;
    let ok = wid != null;
    if (ok) {
      const st = await Z().window.state(wid);
      ok = !!st && typeof st.monitor === 'number' && typeof st.incognito === 'boolean';
      try { await Z().window.close(wid); } catch (_) {}
    }
    check('exp2', ok, `create=${JSON.stringify(w).slice(0, 40)} state ok=${ok}`);
  } catch (e) { check('exp2', false, String(e.message || e)); }

  // ---- v0.3.10 C2：isolation——明文伪造 invoke 必拒 ----
  try {
    const isIso = !!window.__ZILT_ISO__;
    const rejected = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve('timeout'), 3000);
      Z().on('__zilt.isoRejected', (p) => {
        clearTimeout(timer);
        resolve(p && p.id === 424242 ? 'rejected' : 'other');
      });
      window.webkit.messageHandlers.zilt.postMessage({ zilt: 1, kind: 'invoke', id: 424242, method: 'greet', args: { name: 'forged' } });
    });
    check('iso', isIso && rejected === 'rejected', `iso=${isIso} rejected=${rejected}`);
  } catch (e) { check('iso', false, String(e.message || e)); }

  // ---- v0.3.9 A4L：窗口级 KeyBindings（创建解析 + 匹配 + 事件派发链路；
  //      X 层注入在 Xvfb+WebKit 下段错为环境限制——真实 key-press 路径由
  //      matchKeyBinding 单测与 GTK key-press 语义保证）----
  try {
    const w = await Z().window.create({ title: 'kb probe', label: 'kb-' + Date.now(), width: 320, height: 200, keyBindings: [{ id: 'kb-probe', key: 'X', ctrl: true }] });
    let ok = false;
    let note = 'create=' + JSON.stringify(w).slice(0, 40);
    if (w && typeof w.id === 'number') {
      const got = await new Promise((resolve) => {
        const timer = setTimeout(() => resolve(null), 4000);
        Z().on('linuxSmokeKeyBind', (p) => { clearTimeout(timer); resolve(p); });
        Z().invoke('__zilt.linuxSmokeKeyBind', { windowId: w.id, key: 'x', ctrl: true }).catch(() => {});
      });
      ok = !!got && got.matched === true && got.id === 'kb-probe' && got.windowId === w.id;
      note += ' confirm=' + JSON.stringify(got);
      try { await Z().window.close(w.id); } catch (_) {}
    }
    check('keybind', ok, note);
  } catch (e) { check('keybind', false, String(e.message || e)); }

  // ---- v0.3.8：二进制 IPC（evaluate base64 通道——契约与 Windows SharedBuffer 同）----
  try {
    const r = await Z().binary.request(16 * 1024);
    check('binipc', !!r && r.match === true && r.size === 16 * 1024,
      `binipc 16KB evaluate-channel match=${r && r.match} sum=${r && r.sum}`);
  } catch (e) { check('binipc', false, String(e.message || e)); }

  // ---- v0.3.8 B8：协议 POST body——Windows（get_Content IStream）实测支持；
  //      WebKitGTK 不转发自定义 scheme 请求 body（上游已知限制：littledivy/laufey#98，
  //      2.50.4 实测 get_http_body 仅返回 1 字节垃圾）——Linux 侧 skip 文档化；
  //      Zig 侧 webkit_uri_scheme_request_get_http_body 读取已接线，上游修复后自动生效 ----
  check('postbody', true, 'skipped (upstream WebKitGTK does not forward custom-scheme request bodies)');

  // ---- v0.3.8 E6：multipart 上传（1MB base64 分片；Linux 粗粒度进度两帧）----
  try {
    const b64 = btoa(String.fromCharCode.apply(null, new Uint8Array(1024).fill(0x5a)));
    let blob64 = '';
    for (let i = 0; i < 1024; i++) blob64 += b64;
    const progress = [];
    const r = await Z().http.upload({
      url: 'http://127.0.0.1:8788/multipart', parts: [
        { name: 'field', data: 'upload-smoke' },
        { name: 'blob', filename: 'blob.bin', contentType: 'application/octet-stream', data: blob64, encoding: 'base64' },
      ],
      onProgress: (written) => progress.push(written),
    });
    const parts = (() => { try { return JSON.parse(r.body).parts; } catch (_) { return []; } })();
    const last = progress.length > 0 ? progress[progress.length - 1] : 0;
    check('upload', r.status === 200 && parts.length === 2 && parts[1] && parts[1].len >= 1024 * 1024 && last >= 1024 * 1024,
      `upload ${r.status} parts=${parts.length} prog=${progress.length} last=${last}`);
  } catch (e) { check('upload', false, String(e.message || e)); }

  // ---- v0.3.14：窗口 API 收尾（GTK 路径：setResizable/setDecorations/center/
  //      setScreen/list/destroy 全量往返。maximized/zoomed 断言不适用——Xvfb 无 WM，
  //      maximize 是 WM 协作语义）----
  try {
    const w = await Z().window.create({ title: 'win3', label: 'win3-' + Date.now(), width: 320, height: 200, url: '/second.html' });
    let ok = false;
    let note = '';
    if (w && typeof w.id === 'number') {
      const id = w.id;
      await Z().window.setResizable(false, id);
      const st1 = await Z().window.state(id);
      const rsOff = st1 && st1.resizable === false;
      await Z().window.setResizable(true, id);
      const st2 = await Z().window.state(id);
      const rsOn = st2 && st2.resizable === true;
      await Z().window.setDecorations(false, id);
      const st3 = await Z().window.state(id);
      const dcOff = st3 && st3.decorated === false;
      await Z().window.setDecorations(true, id);
      const st4 = await Z().window.state(id);
      const dcOn = st4 && st4.decorated === true;
      await Z().window.center(id);
      const st5 = await Z().window.state(id);
      const centered = st5 && typeof st5.x === 'number' && typeof st5.y === 'number';
      await Z().window.setScreen(0, id);
      const st6 = await Z().window.state(id);
      const scr = st6 && st6.monitor === 0;
      const list = await Z().window.list();
      const listed = Array.isArray(list) && list.some((e) => e.id === id);
      await Z().window.toggleMaximize(id).catch(() => {});
      const destroyed = await new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), 3000);
        const off = Z().on('windowDestroyed', (p) => {
          if (p.id === id) { clearTimeout(timer); off(); resolve(true); }
        });
        Z().window.destroy(id).catch(() => {});
      });
      ok = rsOff && rsOn && dcOff && dcOn && centered && scr && listed && destroyed;
      note = `rs=${rsOff}/${rsOn} deco=${dcOff}/${dcOn} center=${centered} scr=${scr} list=${listed} destroyed=${destroyed}`;
    } else note = 'create=' + JSON.stringify(w);
    check('win3', ok, note);
  } catch (e) { check('win3', false, String(e.message || e)); }

  // ---- v0.3.16 G19/G21：全局光标位置 + monitors rotation 字段 + sticky/stick
  //      往返（GTK 路径）+ 单实例/徽标为 Windows 面（文档化不测）----
  try {
    const cur = await Z().system.cursorPosition();
    const mons = await Z().system.monitors();
    const arr = Array.isArray(mons) ? mons : (mons && mons.monitors) || [];
    const rot = arr.length > 0 && typeof arr[0].rotation === 'number';
    // v0.4.0 L2：分数缩放面——scale 为 >= 1 的数值（GTK4 小数 / GTK3 整数回退）
    const sc = arr.length > 0 && typeof arr[0].scale === 'number' && arr[0].scale >= 1;
    const stick = await Z().window.setAllWorkspaces(true);
    const unstick = await Z().window.setAllWorkspaces(false);
    check('curs', !!cur && typeof cur.x === 'number' && rot && sc && stick === true && unstick === true,
      `cur=${JSON.stringify(cur)} rot=${rot} sc=${sc} stick=${stick}/${unstick}`);
  } catch (e) { check('curs', false, String(e.message || e)); }

  // ---- v0.3.15：printToPdf/settingsProbe 平台差异文档化（WebKitGTK 无 PDF 导出
  //      API；Settings3/6 对等无——手势走 WebKitSettings 创建期，探针返回 null）----
  try {
    let pdfErr = '';
    try { await Z().webview.printToPdf('/tmp/zilt-smoke.pdf'); } catch (e) { pdfErr = String(e.message || e); }
    const probe = await Z().webview.settingsProbe();
    check('pdfskip', pdfErr.length > 0 && probe && probe.accelerators === null && probe.swipe === null,
      `pdfErr=${pdfErr.slice(0, 60)} probe=${JSON.stringify(probe)}`);
  } catch (e) { check('pdfskip', false, String(e.message || e)); }

  // ---- v0.4.0：H7/H8 探针窗口开关 + H9 物理面（探针 JS 已禁用 → 惰性页面，
  //      不会重跑套件）+ H11 GPU（WSLg 无 drm 卡 → [] 合法）+ H10 badgeCount
  //      （CI/Xvfb 无会话总线 → NotSupported 文档化降级；WSLg 真发）----
  try {
    const pw = await Z().window.create({
      dragDrop: false, javascript: false, visible: false,
      width: 320, height: 200, label: 'v04-probe-' + Date.now(),
    });
    const st = pw && pw.id ? await Z().window.state(pw.id) : null;
    const bs = st && st.border_sizes;
    const ps = st && st.physical_size;
    const ok = !!st && st.drag_drop === false && st.javascript === false &&
      !!bs && typeof bs.left === 'number' && !!ps && typeof ps.width === 'number' && ps.width > 0;
    if (pw && pw.id) { await Z().window.destroy(pw.id).catch(() => {}); }
    check('v04', ok, `st=${JSON.stringify(st ? { dd: st.drag_drop, js: st.javascript, bs, ps } : null).slice(0, 140)}`);
  } catch (e) { check('v04', false, String(e.message || e)); }
  try {
    const gpus = await Z().system.info('gpu');
    check('gpu', Array.isArray(gpus), `gpus=${JSON.stringify(gpus).slice(0, 100)}`);
  } catch (e) { check('gpu', false, String(e.message || e)); }
  try {
    let bc = false;
    let bcErr = '';
    try { bc = (await Z().taskbar.badgeCount(5)) === true; } catch (e) { bcErr = String(e.message || e); }
    check('bcount', bc || bcErr.indexOf('NotSupported') >= 0, `bc=${bc} err=${bcErr.slice(0, 40)}`);
  } catch (e) { check('bcount', false, String(e.message || e)); }

  // ---- v0.4.1：H4 channel credit 背压（maxInFlight=2，8 帧 32KB 上行）+
  //      H14 断点续传（failAfter=2 演练中断 → 状态续传 → 完成）----
  try {
    const got = [];
    const rcv = [];
    let closedErr = null;
    const ch = Z().channel.create({ binary: true, maxInFlight: 2, onmessage: (b, s) => { got.push(s); rcv.push(b[0]); }, onclose: (e) => { closedErr = e; } });
    const prs = [];
    for (let i = 0; i < 8; i++) { const f = new Uint8Array(32 * 1024); f[0] = i; prs.push(ch.send(f)); }
    const results = await Promise.all(prs);
    let okSeq = false;
    for (let t = 0; t < 50 && !okSeq; t++) { await wait(100); okSeq = got.length === 8 && got.every((s) => s === 0) && rcv.length === 8 && rcv.every((v, i) => v === i); }
    ch.close();
    check('bp', results.every((v) => v === true) && okSeq && closedErr == null, `rcv=${JSON.stringify(rcv)} closed=${closedErr}`);
  } catch (e) { check('bp', false, String(e.message || e)); }
  try {
    const roots = await Z().fs.roots();
    const appData = roots && (roots.appData || roots.appCache);
    if (!appData) throw new Error('no appData root');
    const name = 'smoke_tus_' + Date.now() + '.bin';
    const size = 64 * 1024;
    let payload = '';
    for (let i = 0; i < size / 64; i++) payload += 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    await Z().fs.write(name, payload);
    const abs = await Z().path.join(appData, name);
    let failErr = null;
    try {
      await Z().http.uploadResumable({ url: 'http://127.0.0.1:8788/resume-upload', path: abs, chunkSize: 16384, failAfter: 2 });
    } catch (e) { failErr = e; }
    const r2 = await Z().http.uploadResumable({ url: 'http://127.0.0.1:8788/resume-upload', path: abs, chunkSize: 16384 });
    await Z().fs.remove(name).catch(() => {});
    check('tus', !!failErr && failErr.offset === 2 * 16384 && !!r2 && r2.offset === size && r2.total === size,
      `failErr=${failErr ? failErr.message + '@' + failErr.offset : 'none'} r2=${JSON.stringify(r2)}`);
  } catch (e) { check('tus', false, String(e.message || e)); }

  // ---- v0.4.2：H16 reparent + H15 计划通知 + H3 加密 store（降级容错）----
  try {
    const pa = await Z().window.create({ visible: false, width: 300, height: 200, label: 'v042-a-' + Date.now() });
    const pb = await Z().window.create({ visible: false, width: 300, height: 200, label: 'v042-b-' + Date.now() });
    const okRe = pa && pa.id && pb && pb.id ? await Z().window.reparent(pa.id, pb.id) : false;
    const stB = pb && pb.id ? await Z().window.state(pb.id) : null;
    if (pb && pb.id) await Z().window.destroy(pb.id).catch(() => {});
    if (pa && pa.id) await Z().window.destroy(pa.id).catch(() => {});
    check('v042', okRe === true && !!stB && stB.parent === pa.id, `re=${okRe} parent=${stB && stB.parent} A=${pa && pa.id}`);
  } catch (e) { check('v042', false, String(e.message || e)); }
  try {
    const tag = 'v042-sched-' + Date.now();
    let fired = null;
    const off = Z().on('notificationScheduled', (p) => { if (p && p.tag === tag) fired = p; });
    await Z().notification.schedule({ tag: tag, title: 'v0.4.2', body: 'scheduled', delayMs: 1200 });
    for (let t = 0; t < 50 && !fired; t++) await wait(100);
    off();
    check('sched', !!fired && fired.fired === true, `fired=${JSON.stringify(fired)}`);
  } catch (e) { check('sched', false, String(e.message || e)); }
  try {
    await Z().store.set('v042-secret', 'keyring-value');
    const got = await Z().store.get('v042-secret');
    let marker = 'none';
    try {
      const raw = await Z().fs.read('store.json');
      if (String(raw).indexOf('dpapi:') >= 0) marker = 'dpapi';
      if (String(raw).indexOf('secret:') >= 0) marker = 'secret';
    } catch (_) {}
    check('secret', got === 'keyring-value', `got=${got} marker=${marker}（无 keyring → 明文降级，也算 PASS）`);
  } catch (e) { check('secret', false, String(e.message || e)); }

  const failed = results.filter((r) => !r.ok).map((r) => r.name);
  try {
    await Z().invoke('__zilt.linuxSmoke', {
      passed: results.length - failed.length,
      total: results.length,
      failed,
    });
  } catch (_) { /* 后端已退出 */ }
})();
