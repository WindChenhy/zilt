const $ = (id) => document.getElementById(id);
const show = (t) => { $('out').textContent = t; };
window.show = show;

async function greet() {
  const g = await window.zilt.invoke('greet', { name: 'Zilt' });
  show(g.message);
}
window.greet = greet;

window.zilt.on('menu', (p) => show(`菜单: ${p.id}`));
window.zilt.on('hotkey', (p) => show(`快捷键: ${p.id}`));
