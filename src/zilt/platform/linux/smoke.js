// Linux 冒烟脚本（v0.2.1）——只覆盖**已实现**的能力。
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
// 刻意不测：剪贴板 / 通知 / 对话框（v0.2.2 才实现）。
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

    // 截图：runtime 的 captureScreenshot 走 cdp Page.captureScreenshot，
    // Linux 用 webkit_web_view_get_snapshot + cairo PNG 实现（返回 data URL）
    const shot = await V.captureScreenshot({ format: 'png' });
    check('screenshot', typeof shot === 'string' && shot.startsWith('data:image/png;base64,') && shot.length > 2000,
      typeof shot === 'string' ? shot.length : String(shot));

    // cookies：URL 作用域的读取 + 按域名清理（示例 origin，无网络请求）
    const ck = await V.getCookies('https://example.com/');
    const clearedCookies = await V.clearCookies('https://example.com');
    check('cookies', ck && Array.isArray(ck.cookies) && clearedCookies !== false,
      `get=${JSON.stringify(ck).slice(0, 80)} clear=${clearedCookies}`);
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
    const restored = second && second.id ? await W.state(second.id) : null;
    const ok = !!restored && restored.width === 360 && restored.height === 240 && restored.x === 70 && restored.y === 50;
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

  // ---- v0.2.1：clearStorage（WebKitWebsiteDataManager::clear）----
  try {
    const st = await Z().webview.clearStorage();
    check('storage.clear', st !== false, JSON.stringify(st));
  } catch (e) { check('storage.clear', false, String(e.message || e)); }

  const failed = results.filter((r) => !r.ok).map((r) => r.name);
  try {
    await Z().invoke('__zilt.linuxSmoke', {
      passed: results.length - failed.length,
      total: results.length,
      failed,
    });
  } catch (_) { /* 后端已退出 */ }
})();
