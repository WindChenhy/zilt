<script setup>
import { ref } from 'vue';

const out = ref('');
const loading = ref(false);

// 类型化绑定（zig build gen 生成；vite 直接打包 TS）
import { greet, notifyMe, pickFile } from '../bindings/zilt';

async function onGreet() {
  loading.value = true;
  try {
    const g = await greet({ name: 'Vue' });
    out.value = g.message;
  } finally {
    loading.value = false;
  }
}

async function onNotify() {
  await notifyMe({ title: 'Vue → Zig', body: '系统通知链路验证' });
}

async function onPick() {
  const r = await pickFile({});
  out.value = r.path ?? '已取消';
}

window.zilt.on('menu', (p) => { out.value = `菜单: ${p.id}`; });
window.zilt.on('hotkey', (p) => { out.value = `快捷键: ${p.id}`; });
</script>

<template>
  <main class="wrap">
    <h1>{{APP_NAME}} <span class="badge">Vue 3</span></h1>
    <p class="sub">Zilt · Vite HMR · IPC: window.zilt / 类型化绑定</p>
    <div class="row">
      <button :disabled="loading" @click="onGreet">greet → Zig</button>
      <button @click="onNotify">系统通知</button>
      <button @click="onPick">打开文件…</button>
    </div>
    <div class="out">{{ out }}</div>
  </main>
</template>

<style>
:root { color-scheme: dark; }
body { font-family: system-ui, sans-serif; background: #0b0f14; color: #e6edf3; margin: 0; }
.wrap { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; gap: 10px; }
h1 { font-size: 22px; margin: 0; }
.badge { font-size: 12px; background: #42b883; color: #0b2818; border-radius: 10px; padding: 2px 10px; vertical-align: middle; }
.sub { color: #8b98a5; font-size: 13px; margin: 0 0 12px; }
.row { display: flex; gap: 8px; }
button { padding: 8px 18px; border-radius: 8px; border: 1px solid #2b3640; background: #16202b; color: #e6edf3; cursor: pointer; }
button:disabled { opacity: 0.6; }
.out { font-family: monospace; color: #7ee787; min-height: 22px; margin-top: 8px; }
</style>
