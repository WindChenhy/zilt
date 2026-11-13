// Linux 冒烟脚本（v0.2.0）——只覆盖本版**已实现**的能力。
//
// 由 platform/linux/backend.zig 在 ZILT_LINUX_SMOKE=1 时作为 document-start
// 用户脚本注入；跑完通过 `__zilt.linuxSmoke` 把结果回传，后端据此决定退出码。
//
// 刻意不测：剪贴板 / 通知 / 对话框 / 多窗口（v0.2.1–v0.2.3 才实现）。
(async () => {
  const results = [];
  const check = (name, ok, note) => results.push({ name, ok: !!ok, note: String(note ?? '') });
  const Z = () => window.zilt;

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

  const failed = results.filter((r) => !r.ok).map((r) => r.name);
  try {
    await Z().invoke('__zilt.linuxSmoke', {
      passed: results.length - failed.length,
      total: results.length,
      failed,
    });
  } catch (_) { /* 后端已退出 */ }
})();
