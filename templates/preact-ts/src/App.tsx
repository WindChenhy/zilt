import { useState } from 'preact/hooks';

export default function App() {
  const [message, setMessage] = useState('点击按钮调用 Zig 命令');

  const greet = async () => {
    const g = await window.zilt.invoke('greet', { name: 'Preact' });
    setMessage(g.message);
  };

  return (
    <main>
      <h1>{{APP_NAME}}</h1>
      <p class="sub">Zilt · Preact + Vite · 纯 Zig 后端</p>
      <button onClick={greet}>greet → Zig</button>
      <button onClick={() => window.zilt.invoke('notifyMe', { title: '{{APP_NAME}}', body: '来自 Zig 的系统通知' })}>
        系统通知
      </button>
      <div class="mono">{message}</div>
    </main>
  );
}
