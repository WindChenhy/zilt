import { useState } from 'react';
// 类型化绑定（zig build gen 生成）
import { greet, notifyMe, pickFile } from '../bindings/zilt';

export default function App() {
  const [out, setOut] = useState('');

  const onGreet = async () => {
    const g = await greet({ name: 'React' });
    setOut(g.message);
  };
  const onNotify = async () => {
    await notifyMe({ title: 'React → Zig', body: '系统通知链路验证' });
  };
  const onPick = async () => {
    const r = await pickFile({});
    setOut(r.path ?? '已取消');
  };
  window.zilt.on('menu', (p) => setOut(`菜单: ${p.id}`));
  window.zilt.on('hotkey', (p) => setOut(`快捷键: ${p.id}`));

  return (
    <main className="wrap">
      <h1>{{APP_NAME}} <span className="badge">React</span></h1>
      <p className="sub">Zilt · Vite HMR · IPC: window.zilt / 类型化绑定</p>
      <div className="row">
        <button onClick={onGreet}>greet → Zig</button>
        <button onClick={onNotify}>系统通知</button>
        <button onClick={onPick}>打开文件…</button>
      </div>
      <div className="out">{out}</div>
    </main>
  );
}
