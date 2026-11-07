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
  // 自动运行（供自动化冒烟测试；页面重载后亦会重跑）
  runChecks();
});
