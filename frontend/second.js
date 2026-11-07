/* 子窗口脚本：验证命令命名空间全局共享、事件按窗口路由。 */
const out = (t) => { const el = document.getElementById('out'); if (el) el.textContent = t; };

window.addEventListener('DOMContentLoaded', () => {
  // 只在子窗口处理命令（主窗口也会收到广播事件如 windowDestroyed）
  window.zilt.on('tick', (p) => out(`收到 tick #${p.n}（本窗口）`));
  window.zilt.on('windowCloseRequested', () => {
    out('收到 windowCloseRequested -> 关闭');
    window.zilt.invoke('windowControlDemo', { action: 'close' });
  });
  window.zilt.on('windowThemeChanged', (p) => out(`主题: ${p.theme}`));
  window.zilt.on('windowScaleFactorChanged', (p) => out(`缩放: ${p.scale_factor.toFixed(2)}`));
  // visible:false 创建的演示窗口：加载完成后自行显示
  if (location.search.includes('autoshow=1')) {
    window.zilt.invoke('windowControlDemo', { action: 'show' });
  }
});

async function greetHere() {
  try {
    const g = await window.zilt.invoke('greet', { name: '子窗口' });
    out(g.message);
  } catch (e) {
    out('错误: ' + e);
  }
}
