/* 透明无边框窗口 demo：窗口事件 + 关闭请求确认。 */
const showEv = (t) => { const el = document.getElementById('ev'); if (el) el.textContent = t; };

window.addEventListener('DOMContentLoaded', () => {
  window.zilt.on('windowMoved', (p) => showEv(`moved ${p.x},${p.y}`));
  window.zilt.on('windowResized', (p) => showEv(`resized ${p.width}x${p.height}`));
  window.zilt.on('windowFocus', () => showEv('focus'));
  window.zilt.on('windowBlur', () => showEv('blur'));
  window.zilt.on('windowThemeChanged', (p) => showEv(`theme ${p.theme}`));
  window.zilt.on('windowScaleFactorChanged', (p) => showEv(`scale ${p.scale_factor.toFixed(2)}`));
  window.zilt.on('windowCloseRequested', () => {
    showEv('close requested -> closing');
    window.zilt.invoke('windowControlDemo', { action: 'close' });
  });
});
