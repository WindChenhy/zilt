<script>
  // 类型化绑定（zig build gen 生成）
  import { greet, notifyMe, pickFile } from '../bindings/zilt';

  let out = $state('');

  async function onGreet() {
    const g = await greet('Svelte');
    out = g.message;
  }
  async function onNotify() {
    await notifyMe('Svelte → Zig', '系统通知链路验证');
  }
  async function onPick() {
    const r = await pickFile();
    out = r.path ?? '已取消';
  }
  window.zilt.on('menu', (p) => { out = `菜单: ${p.id}`; });
  window.zilt.on('hotkey', (p) => { out = `快捷键: ${p.id}`; });
</script>

<main class="wrap">
  <h1>{{APP_NAME}} <span class="badge">Svelte 5</span></h1>
  <p class="sub">Zilt · Vite HMR · IPC: window.zilt / 类型化绑定</p>
  <div class="row">
    <button onclick={onGreet}>greet → Zig</button>
    <button onclick={onNotify}>系统通知</button>
    <button onclick={onPick}>打开文件…</button>
  </div>
  <div class="out">{out}</div>
</main>

<style>
  :root { color-scheme: dark; }
  body { font-family: system-ui, sans-serif; background: #0b0f14; color: #e6edf3; margin: 0; }
  .wrap { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; gap: 10px; }
  h1 { font-size: 22px; margin: 0; }
  .badge { font-size: 12px; background: #ff3e00; color: #fff; border-radius: 10px; padding: 2px 10px; vertical-align: middle; }
  .sub { color: #8b98a5; font-size: 13px; margin: 0 0 12px; }
  .row { display: flex; gap: 8px; }
  button { padding: 8px 18px; border-radius: 8px; border: 1px solid #2b3640; background: #16202b; color: #e6edf3; cursor: pointer; }
  .out { font-family: monospace; color: #7ee787; min-height: 22px; margin-top: 8px; }
</style>
