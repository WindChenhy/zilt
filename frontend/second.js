/* 子窗口脚本：验证命令命名空间全局共享、事件按窗口路由。 */
const out = (t) => { const el = document.getElementById('out'); if (el) el.textContent = t; };

window.addEventListener('DOMContentLoaded', () => {
  // 只在子窗口处理命令（主窗口也会收到广播事件如 windowClosed）
  window.zilt.on('tick', (p) => out(`收到 tick #${p.n}（本窗口）`));
});

async function greetHere() {
  try {
    const g = await window.zilt.invoke('greet', { name: '子窗口' });
    out(g.message);
  } catch (e) {
    out('错误: ' + e);
  }
}
