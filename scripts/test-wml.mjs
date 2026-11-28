// WML 解释器行为测试（v0.6.2）——不依赖浏览器/WebView。
//
// runtime 的 WML 段是纯 DOM + window.zilt 调用，这里把该段从 ipc.zig 抽出来，
// 用最小 document/element 桩执行，覆盖：启用/停用、事件载荷、confirm 取消、
// 窗口动作顺序、未知动作的错误处理。CI 与本地都可跑：
//   node scripts/test-wml.mjs

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const ipc = fs.readFileSync(path.join(root, 'src/zilt/ipc.zig'), 'utf8').split('\n');

function source() {
  const start = ipc.findIndex((l) => l.includes('const WML_SEL ='));
  if (start < 0) throw new Error('ipc.zig 缺少 WML_SEL');
  const out = [];
  for (let i = start; i < ipc.length; i++) {
    const raw = ipc[i].replace(/\r$/, '');
    if (raw.includes('window.zilt = {')) break;
    const trimmed = raw.replace(/^\s+/, '');
    if (trimmed.startsWith('\\\\')) out.push(trimmed.slice(2));
    else throw new Error(`WML 段出现非字符串行: ${raw}`);
  }
  if (out.length < 20) throw new Error('WML 段提取失败');
  return `${out.join('\n')}\nreturn wmlApi;`;
}

const WML_SRC = source();

function makeElement(attrs = {}) {
  const map = { ...attrs };
  const el = {
    id: map.id ?? '',
    value: map.value,
    checked: map.checked,
    getAttribute: (k) => (k in map ? map[k] : null),
    setAttribute: (k, v) => { map[k] = String(v); },
    removeAttribute: (k) => { delete map[k]; },
    closest: () => el,
    attrs: map,
  };
  return el;
}

function harness({ confirmAnswer = 'ok' } = {}) {
  const calls = [];
  const docListeners = [];
  const document = {
    documentElement: { hasAttribute: () => false },
    readyState: 'complete',
    addEventListener: (t, fn) => docListeners.push({ t, fn }),
    removeEventListener: (t, fn) => {
      const i = docListeners.findIndex((l) => l.t === t && l.fn === fn);
      if (i >= 0) docListeners.splice(i, 1);
    },
    querySelectorAll: () => [1],
  };
  const window = {
    zilt: {
      emit: (name, payload) => calls.push(['emit', name, payload]),
      dialog: { messageBox: async () => confirmAnswer },
      shell: { openUrl: async (url) => calls.push(['open', url]) },
    },
  };
  const winApi = (action, extra) => {
    calls.push(['win', action, extra]);
    return Promise.resolve();
  };
  const factory = new Function('document', 'window', 'winApi', 'console', WML_SRC);
  const warnings = [];
  const api = factory(document, window, winApi, { warn: (...a) => warnings.push(a.join(' ')) });
  return { api, calls, docListeners, warnings };
}

const tick = () => new Promise((r) => setTimeout(r, 0));
let failed = 0;
const check = (name, ok, note) => {
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${note ? ` — ${note}` : ''}`);
};

// 1) 启用 / 载荷 / 动作顺序（emit → window）
{
  const h = harness();
  const el = makeElement({
    id: 'save',
    value: 'doc-1',
    'data-zilt-event': 'saveRequested',
    'data-zilt-window': 'center',
  });
  const n = h.api.enable();
  h.docListeners[0].fn({ button: 0, defaultPrevented: false, target: el, preventDefault() {} });
  await tick();
  check('enable 返回命中数', n === 1 && h.api.enabled === true, `n=${n}`);
  const emit = h.calls.find((c) => c[0] === 'emit');
  const win = h.calls.find((c) => c[0] === 'win');
  check('事件载荷', !!emit && emit[1] === 'saveRequested' && emit[2].id === 'save' && emit[2].value === 'doc-1', JSON.stringify(emit?.[2]));
  check('窗口动作', !!win && win[1] === 'center' && win[2].window_id === undefined, JSON.stringify(win?.[1]));
  check('执行顺序 emit→win', h.calls.findIndex((c) => c[0] === 'emit') < h.calls.findIndex((c) => c[0] === 'win'));
  check('busy 已清理', el.attrs['data-zilt-busy'] === undefined);
}

// 2) confirm 取消 → 什么都不做
{
  const h = harness({ confirmAnswer: 'cancel' });
  const el = makeElement({ id: 'x', 'data-zilt-event': 'e', 'data-zilt-confirm': 'sure?' });
  h.api.enable();
  h.docListeners[0].fn({ button: 0, defaultPrevented: false, target: el, preventDefault() {} });
  await tick();
  check('confirm 取消后不执行', h.calls.length === 0, JSON.stringify(h.calls));
}

// 3) disable 后不再触发
{
  const h = harness();
  const el = makeElement({ id: 'x', 'data-zilt-event': 'e' });
  h.api.enable();
  h.api.disable();
  check('disable 摘监听', h.docListeners.length === 0 && h.api.enabled === false);
  check('disable 后 click 无动作', h.calls.length === 0);
}

// 4) unmaximize 归一为 restore / 未知动作告警
{
  const h = harness();
  const el = makeElement({ id: 'u', 'data-zilt-window': 'unmaximize' });
  h.api.enable();
  h.docListeners[0].fn({ button: 0, defaultPrevented: false, target: el, preventDefault() {} });
  await tick();
  check('unmaximize → restore', h.calls[0]?.[1] === 'restore', JSON.stringify(h.calls[0]?.[1]));

  const h2 = harness();
  const bad = makeElement({ id: 'b', 'data-zilt-window': 'nope' });
  h2.api.enable();
  h2.docListeners[0].fn({ button: 0, defaultPrevented: false, target: bad, preventDefault() {} });
  await tick();
  check('未知动作告警', h2.warnings.some((w) => w.includes('unknown data-zilt-window')), h2.warnings.join('|'));
  check('未知动作后 busy 清理', bad.attrs['data-zilt-busy'] === undefined);
}

// 5) 右键不触发
{
  const h = harness();
  const el = makeElement({ id: 'x', 'data-zilt-event': 'e' });
  h.api.enable();
  h.docListeners[0].fn({ button: 2, defaultPrevented: false, target: el, preventDefault() {} });
  await tick();
  check('右键忽略', h.calls.length === 0);
}

if (failed > 0) {
  console.error(`${failed} 项失败`);
  process.exit(1);
}
console.log('WML 行为测试全部通过');
