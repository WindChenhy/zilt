const $ = (id) => document.getElementById(id);
const show = (t) => { $('out').textContent = t; };

/** htmx 拿到的 JSON 资产转成列表（htmx 直接 swap JSON 不友好） */
document.body.addEventListener('htmx:afterRequest', (e) => {
  const target = e.detail.target;
  if (!target || target.id !== 'items') return;
  try {
    const items = JSON.parse(e.detail.xhr.responseText);
    target.innerHTML = items.map((it) => `<li>${it.name} — ${it.desc}</li>`).join('');
  } catch {
    target.textContent = e.detail.xhr.responseText;
  }
});

async function ziltGreet() {
  const g = await window.zilt.invoke('greet', { name: 'htmx' });
  show(g.message);
}
window.ziltGreet = ziltGreet;

// Zig → JS 事件可以反过来触发 htmx 请求 / DOM 更新
window.zilt.on('menu', (p) => show(`菜单: ${p.id}`));
window.zilt.on('hotkey', (p) => show(`快捷键: ${p.id}`));
