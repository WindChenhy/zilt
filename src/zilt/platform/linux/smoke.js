// Linux 冒烟脚本（v0.2.1）——只覆盖**已实现**的能力。
//
// 由 platform/linux/backend.zig 在 ZILT_LINUX_SMOKE=1 时作为 document-start
// 用户脚本注入；跑完通过 `__zilt.linuxSmoke` 把结果回传，后端据此决定退出码。
//
// 窗口检查注意：xvfb-run 默认没有窗口管理器，WM 参与的状态（maximized/iconic、
// keep-above 的实际置顶、geometry hint 的强制执行）不可断言——只断言客户端
// 可查字段（size/position/tracked 标志）与命令返回值。
//
// 刻意不测：剪贴板 / 通知 / 对话框 / 多窗口（v0.2.2–v0.2.3 才实现）。
//
// reload 刻意不做探测：报告 invoke 刚 post 就导航，消息会在导航中丢失
// （实测导致「reload → 脚本重跑 → 再 reload」无限循环）；且 reload 与 stop
// 是同一调用路径，风险极低。
(async () => {
  const results = [];
  const check = (name, ok, note) => results.push({ name, ok: !!ok, note: String(note ?? '') });
  const Z = () => window.zilt;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

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

    // hide/show：可见性往返
    await W.hide();
    const hidOk = (await state()).visible === false;
    await W.show();
    const showOk = (await state()).visible === true;
    check('win.vis', hidOk && showOk, `hide=${hidOk} show=${showOk}`);

    // minimize/maximize/restore/startDragging：Xvfb 无 WM，只验证命令被接受不崩
    const rMin = await W.minimize();
    await W.restore();
    const rMax = await W.maximize();
    await W.restore();
    const rDrag = await W.startDragging();
    check('win.wmcalls', rMin === true && rMax === true && rDrag === true, `min=${rMin} max=${rMax} drag=${rDrag}`);

    // 未实现项：明确返回 false（不抛异常），错误名对齐 Windows 语义
    const rCursor = await W.setCursor('hand');
    check('win.unimpl', rCursor === false, `cursor=${rCursor}`);
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

    // 未实现项：print → NotSupported（错误名经 reject 稳定下发）
    let printErr = '';
    try { await V.print('browser'); } catch (e) { printErr = String(e.message || e); }
    check('webview.unimpl', printErr === 'NotSupported', printErr);
  } catch (e) { check('eval', false, String(e.message || e)); }

  const failed = results.filter((r) => !r.ok).map((r) => r.name);
  try {
    await Z().invoke('__zilt.linuxSmoke', {
      passed: results.length - failed.length,
      total: results.length,
      failed,
    });
  } catch (_) { /* 后端已退出 */ }
})();
