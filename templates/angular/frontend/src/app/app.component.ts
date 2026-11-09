import { Component, signal } from '@angular/core';

declare global {
  interface Window {
    zilt: {
      invoke: (method: string, args?: unknown) => Promise<any>;
      on: (name: string, cb: (payload: any) => void) => () => void;
    };
  }
}

@Component({
  selector: 'app-root',
  standalone: true,
  template: `
    <main>
      <h1>{{ title }}</h1>
      <p class="sub">Zilt · Angular 19 standalone · 纯 Zig 后端</p>
      <button (click)="greet()">greet → Zig</button>
      <button (click)="notify()">系统通知</button>
      <div class="mono">{{ message() }}</div>
    </main>
  `,
})
export class AppComponent {
  title = '{{APP_NAME}}';
  message = signal('点击按钮调用 Zig 命令');

  async greet() {
    const g = await window.zilt.invoke('greet', { name: 'Angular' });
    this.message.set(g.message);
  }

  notify() {
    window.zilt.invoke('notifyMe', { title: this.title, body: '来自 Zig 的系统通知' });
  }
}
