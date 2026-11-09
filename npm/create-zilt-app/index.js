#!/usr/bin/env node
/**
 * create-zilt-app — Zilt 项目脚手架（npm 入口）。
 *
 * 优先使用 `zilt` CLI（`zilt new <dir> -t <template>`）；
 * 找不到时回退到框架仓库的 `zig build init`（需 cwd 在框架仓库根）。
 *
 * 用法：
 *   npm create zilt-app my-app
 *   npm create zilt-app my-app -- --template solid
 *   ZILT_BIN=/path/to/zilt npm create zilt-app my-app -t htmx
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const TEMPLATES = ['vanilla', 'vue', 'react', 'svelte', 'solid', 'preact', 'htmx', 'angular'];

function usage() {
  console.log(`create-zilt-app — Zilt 桌面应用脚手架

用法:
  create-zilt-app <dir> [-t <template>] [-n <name>]

选项:
  -t, --template <name>   ${TEMPLATES.join(' | ')}（默认 vanilla）
  -n, --name <name>       项目显示名（默认取目录名）
  -l, --list              列出可用模板
  -h, --help              显示帮助

环境变量:
  ZILT_BIN   指定 zilt 可执行文件路径（默认在 PATH 里找 zilt）
`);
}

function parseArgs(argv) {
  const out = { dir: null, template: 'vanilla', name: null, list: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') out.help = true;
    else if (a === '-l' || a === '--list') out.list = true;
    else if (a === '-t' || a === '--template') out.template = argv[++i] ?? out.template;
    else if (a === '-n' || a === '--name') out.name = argv[++i] ?? null;
    else if (!a.startsWith('-')) out.dir = a;
  }
  return out;
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', shell: process.platform === 'win32', ...opts });
  return r.status ?? 1;
}

function whichZilt() {
  if (process.env.ZILT_BIN && existsSync(process.env.ZILT_BIN)) return process.env.ZILT_BIN;
  const probe = spawnSync('zilt', ['version'], { stdio: 'ignore', shell: process.platform === 'win32' });
  if ((probe.status ?? 1) === 0) return 'zilt';
  return null;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return usage(), 0;
  if (args.list) {
    console.log(TEMPLATES.join('\n'));
    return 0;
  }
  if (!args.dir) {
    usage();
    console.error('\n错误: 缺少项目目录名');
    return 2;
  }
  if (!TEMPLATES.includes(args.template)) {
    console.error(`错误: 未知模板 '${args.template}'（可选: ${TEMPLATES.join('/')}）`);
    return 2;
  }

  const zilt = whichZilt();
  if (zilt) {
    const argv = ['new', args.dir, '-t', args.template];
    if (args.name) argv.push('-n', args.name);
    console.log(`[create-zilt-app] ${zilt} ${argv.join(' ')}`);
    return run(zilt, argv);
  }

  // 回退：框架仓库根的 zig build init（需要 repo 内有 templates/ 与 src/zilt）
  const cwdFiles = (() => {
    try {
      return readdirSync(process.cwd());
    } catch {
      return [];
    }
  })();
  if (!cwdFiles.includes('build.zig') || !cwdFiles.includes('templates')) {
    console.error(
      '[create-zilt-app] 找不到 zilt 可执行文件，且当前目录不是 Zilt 框架仓库根。\n' +
        '  请先安装/构建 zilt CLI（或设置 ZILT_BIN），再重新运行。'
    );
    return 1;
  }
  console.log('[create-zilt-app] 未找到 zilt，回退 zig build init');
  const env = {
    ...process.env,
    ZILT_INIT_TEMPLATE: args.template,
    ZILT_INIT_DEST: args.dir,
    ...(args.name ? { ZILT_INIT_NAME: args.name } : {}),
  };
  return run('zig', ['build', 'init'], { env });
}

process.exit(main());
