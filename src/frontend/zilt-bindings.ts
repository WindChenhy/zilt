// 由 Zilt 自动生成（Zig comptime 反射）—— DO NOT EDIT.
// 重新生成：zig build gen

export interface ZiltGlobal {
  invoke(method: string, args?: unknown): Promise<unknown>;
  emit(name: string, payload?: unknown): void;
  on(name: string, cb: (payload: any) => void): void;
  version: string;
}

declare global {
  interface Window { zilt: ZiltGlobal }
}

export async function startTicker(args: { count: number; interval_ms: number }): Promise<void> {
  await window.zilt.invoke("startTicker", args ?? {});
}

export async function stopTicker(args: { }): Promise<void> {
  await window.zilt.invoke("stopTicker", args ?? {});
}

export async function greet(args: { name: string }): Promise<{ message: string; length: number }> {
  return window.zilt.invoke("greet", args ?? {}) as Promise<{ message: string; length: number }>;
}

export async function add(args: { a: number; b: number }): Promise<number> {
  return window.zilt.invoke("add", args ?? {}) as Promise<number>;
}

export async function failNow(args: { }): Promise<void> {
  await window.zilt.invoke("failNow", args ?? {});
}

export async function queryUser(args: { id: number }): Promise<{ user?: { id: number; name: string } }> {
  return window.zilt.invoke("queryUser", args ?? {}) as Promise<{ user?: { id: number; name: string } }>;
}

export async function setMode(args: { mode: "fast" | "slow" }): Promise<{ applied: string }> {
  return window.zilt.invoke("setMode", args ?? {}) as Promise<{ applied: string }>;
}

export type ZiltEventPayloads = {
  "frontendLog": { msg: string },
  "smokeResult": { greet?: boolean; add?: boolean; fail?: boolean; user?: boolean; event?: boolean; mode?: boolean; fatal?: string },
  "__reload": null,
};

export function onEvent<K extends keyof ZiltEventPayloads>(
  name: K,
  cb: (payload: ZiltEventPayloads[K]) => void,
): void {
  window.zilt.on(name, cb as (payload: any) => void);
}
