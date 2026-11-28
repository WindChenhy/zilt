# WML —— 声明式 HTML 绑定（v0.6.2）

> 目标：把「点击 → 原生动作」这条最常见的样板代码从 JS 里挪到 HTML 属性上。
> 对标 Wails WML；Zilt 的差异是**委托分发**（动态插入的元素自动生效）与
> **默认关闭**（不改变既有页面的点击语义）。

## 1. 启用方式

三种，任选其一：

```html
<!-- ① 页面级：<html> 上标记，DOM 就绪后自动启用 -->
<html data-zilt-wml>
```

```js
// ② 显式启用（SPA 通常在首屏渲染后调用）
window.zilt.wml.enable();
```

```js
// ③ 动态 DOM 场景：委托分发已自动覆盖，通常不需要 reload；
//    需要重置监听（例如切换了 document）时可用
window.zilt.wml.reload();
window.zilt.wml.disable();
```

`enable()` 返回启用瞬间命中的触发器数量（信息性，仅用于日志/自检）；重复调用返回 `0`。
`enabled` 是只读布尔。

## 2. 属性

所有属性统一 `data-zilt-*` 前缀（与框架既有的 `data-zilt-drag-region`、
`data-zilt-iso` 一致）。一个元素可以同时带多个属性，执行顺序固定为
**confirm → event → openurl → window**。

| 属性 | 取值 | 行为 |
|---|---|---|
| `data-zilt-event` | 事件名 | `zilt.emit(name, { id, value, checked })` |
| `data-zilt-window` | 窗口动作（见下） | 对目标窗口执行动作 |
| `data-zilt-target-window` | 窗口 id（数字） | `data-zilt-window` 的目标；省略 = 当前窗口 |
| `data-zilt-openurl` | URL | `zilt.shell.openUrl(url)` |
| `data-zilt-confirm` | 提示文本 | 先弹原生确认框；取消则整个动作不执行 |

窗口动作（`data-zilt-window`）：

| 值 | 实际调用 |
|---|---|
| `close` / `minimize` / `maximize` / `restore` / `center` / `hide` / `show` / `focus` | 同名 `zilt.window.*` |
| `unmaximize` | `zilt.window.restore`（对齐 Wails 动作名） |
| `toggleMaximize` | `zilt.window.toggleMaximize` |
| `fullscreen` / `unfullscreen` | `zilt.window.fullscreen(true/false)` |

事件载荷：

```ts
interface ZiltWmlEventDetail {
  id: string | null;      // 元素 id（无则 null）
  value: string | null;   // input/button 的 value（无则 null）
  checked?: boolean;      // 仅带 checked 的控件存在
}
```

## 3. 示例

```html
<html data-zilt-wml>
<body>
  <!-- 关闭窗口 -->
  <button data-zilt-window="close">关闭</button>

  <!-- 先确认，再最小化 -->
  <button data-zilt-window="minimize" data-zilt-confirm="确定要最小化吗？">最小化</button>

  <!-- 点击发事件；前端/后端各自订阅 -->
  <button id="save" data-zilt-event="saveRequested" value="doc-1">保存</button>

  <!-- 打开外部链接 -->
  <a data-zilt-openurl="https://example.com/docs">文档</a>
</body>
</html>
```

```js
window.zilt.wml.enable();
window.zilt.on('saveRequested', (p) => console.log(p.id, p.value)); // "save" "doc-1"
```

## 4. 与 Wails WML 的对照

| Wails | Zilt | 说明 |
|---|---|---|
| `wml-event` | `data-zilt-event` | 相同；Zilt 额外带 `{id,value,checked}` 载荷 |
| `wml-window` | `data-zilt-window` | 动作名对齐，`unmaximize` 归一为 `restore` |
| `wml-target-window` | `data-zilt-target-window` | Zilt 用窗口 id（Wails 用窗口名） |
| `wml-openurl` | `data-zilt-openurl` | 相同 |
| `wml-confirm` | `data-zilt-confirm` | Zilt 走原生 messageBox（`ok_cancel`） |
| `WML.Enable()` / `Reload()` | `zilt.wml.enable()` / `reload()` | Zilt 委托分发，`reload` 基本不需要 |

## 5. 边界（有意不做）

- **不做 `if` / `for` / 双向绑定**：那是前端框架的职责；WML 只消除「点击 → 原生动作」样板。
- **不做全局快捷键/菜单**：走既有 `zilt.hotkey` / 菜单 API。
- **不自动绑定 `input` 事件**：`data-zilt-event` 只在 `click` 上触发；表单监听仍用 JS。
- `data-zilt-target-window` 只接受数字 id（Zilt 窗口 id 是 u32；label → id 需先 `window.list()`）。

## 6. 安全与兼容

- 事件名受 capability ACL 约束：启用 capabilities 后，`data-zilt-event` 的目标事件
  必须在允许列表内，否则后端拒绝（与 `zilt.emit` 同一条路径）。
- `data-zilt-openurl` 走 `shell.openUrl`，受 shell 能力与协议白名单约束。
- 默认关闭：未调用 `enable()` 且 `<html>` 无 `data-zilt-wml` 时，运行时**不注册任何监听**。
- 与 `data-zilt-drag-region` 互不干扰（后者在 `mousedown`，WML 在 `click`）。
- 同一元素在动作执行期间带 `data-zilt-busy="1"`（防重复点击，动作结束自动移除）。

## 7. 验证

- 代码生成：`ZiltWmlApi` / `ZiltWmlWindowAction` / `ZiltWmlEventDetail` 随
  `zig build gen` 输出到 `frontend/bindings/zilt.ts`（`ZiltGlobal.wml`）。
- 行为：Linux 冒烟 `wml.bind` —— 创建带 `data-zilt-event` + `data-zilt-window`
  的按钮，断言 `enable()` 命中数、点击后事件载荷、`disable()` 后不再触发。
- 语法：`node scripts/check-runtime-js.mjs` 按运行时拼接规则还原 JS 并做语法编译
  （CI Windows 作业的 `Runtime JS syntax` 步骤）。
- 逻辑：`node scripts/test-wml.mjs` 把 WML 段抽出来，用最小 DOM 桩覆盖启用/载荷/
  confirm 取消/`unmaximize` 归一/未知动作/停用（同一 CI 步骤）。
