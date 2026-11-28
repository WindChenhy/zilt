// 运行时脚本语法门禁（v0.6.2）。
//
// `src/zilt/ipc.zig` 的 runtime 是一个巨型 comptime 字符串（head ++ 版本行 ++ tail），
// 注入到页面后才由 WebView 解析——写错一个括号，单测/编译全绿，应用却白屏。
// 这里按同样的拼接规则还原出最终 JS，用 vm.Script 只做语法编译（不执行，不需要 DOM）。
//
// 用法：node scripts/check-runtime-js.mjs

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const ipc = fs.readFileSync(path.join(root, 'src/zilt/ipc.zig'), 'utf8');
const project = fs.readFileSync(path.join(root, 'src/project.zig'), 'utf8');

function zigMultiline(name) {
  const at = ipc.indexOf(`const ${name} =`);
  if (at < 0) throw new Error(`ipc.zig 缺少 ${name}`);
  const lines = ipc.slice(at).split('\n').slice(1);
  const out = [];
  for (const raw of lines) {
    if (raw.startsWith(';')) break;
    const line = raw.replace(/\r$/, '');
    // Zig 多行字符串每行以两个反斜杠开头（源文件里就是两个字符）
    const trimmed = line.replace(/^\s+/, '');
    if (trimmed.startsWith('\\\\')) out.push(trimmed.slice(2));
    else if (trimmed === '') out.push('');
    else break;
  }
  if (out.length === 0) throw new Error(`${name} 为空`);
  return out.join('\n');
}

const version = (project.match(/pub const version = "([^"]+)"/) ?? [])[1];
if (!version) throw new Error('project.zig 缺少 version');

const code = `${zigMultiline('runtime_js_head')}\n    version: '${version}',\n${zigMultiline('runtime_js_tail')}`;

try {
  new vm.Script(code, { filename: 'zilt-runtime.js' });
} catch (e) {
  console.error(`runtime JS 语法错误：${e.message}`);
  process.exit(1);
}
console.log(`runtime JS syntax OK (${code.split('\n').length} lines, zilt ${version})`);
