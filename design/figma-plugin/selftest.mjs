// Figma 插件自检（不打开 Figma 也能抓运行时错误）
//
// 作用：用最小假 Figma API 跑一遍 code.js，验证：
//   ① 语法/引用没错（真跑，不是 `node --check` 那种只查语法）
//   ② 会生成 3 个画板（令牌 + 2 屏），且每屏节点数在合理区间
//   ③ 文本节点都设过字体/字号（否则 Figma 里会报 "Cannot write to node with unloaded font"）
//
// 用法：node design/figma-plugin/selftest.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';

const here = path.dirname(fileURLToPath(import.meta.url));

let created = [];
let loadedFonts = new Set();
let notified = [];

class Node {
  constructor(type) {
    this.type = type;
    this.name = type;
    this.children = [];
    this.x = 0; this.y = 0;
    this.width = 100; this.height = 100;
    this.fills = []; this.strokes = [];
    this.cornerRadius = 0; this.strokeWeight = 1;
    this.characters = '';
    this.fontSize = 13;
    this.fontName = null;
    this.fontLoadRequired = type === 'TEXT';
    created.push(this);
  }
  resize(w, h) { this.width = w; this.height = h; }
  appendChild(n) {
    // 真 Figma：createXxx() 会自动挂到 currentPage；appendChild 再改父节点
    if (n.parent && n.parent.children) {
      n.parent.children = n.parent.children.filter((c) => c !== n);
    }
    this.children.push(n);
    n.parent = this;
    if (n.type === 'TEXT') {
      // 粗估自动尺寸（真 Figma 里由字体度量决定；这里只保证"非零"）
      n.width = Math.max(8, n.characters.length * n.fontSize * 0.56);
      n.height = n.fontSize * 1.34;
    }
    return n;
  }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this);
    this.removed = true;
  }
  set textAutoResize(_v) {}
  set lineHeight(_v) {}
}

const page = { type: 'PAGE', name: 'Page 1', children: [], appendChild(n) { this.children.push(n); } };
const figma = {
  root: { children: [page] },
  currentPage: page,
  viewport: { scrollAndZoomIntoView() {} },
  notify(msg, opts) { notified.push({ msg, error: !!(opts && opts.error) }); },
  closePlugin() { globalThis.__closed = true; },
  async listAvailableFontsAsync() {
    return ['Regular', 'Medium', 'Semibold', 'Bold'].map((style) => ({
      fontName: { family: 'PingFang SC', style },
    }));
  },
  async loadFontAsync(f) { loadedFonts.add(f.family + '/' + f.style); },
  createPage() {
    const p = { type: 'PAGE', name: '', children: [], appendChild(n) { this.children.push(n); } };
    figma.root.children.push(p);
    return p;
  },
  createFrame() { return makeNode('FRAME'); },
  createRectangle() { return makeNode('RECTANGLE'); },
  createEllipse() { return makeNode('ELLIPSE'); },
  createText() { return makeNode('TEXT'); },
  createNodeFromSvg(_svg) { return makeNode('FRAME'); },
};

function makeNode(type) {
  const n = new Node(type);
  figma.currentPage.children.push(n);
  n.parent = figma.currentPage;
  return n;
}

const src = readFileSync(path.join(here, 'code.js'), 'utf8');
const ctx = vm.createContext({ figma, console, Set, Math, Number, String, Array, Object, JSON, globalThis: {} });
ctx.figma = figma;

let failed = null;
try {
  await vm.runInContext(src, ctx, { filename: 'code.js' });
  // 等 async IIFE 跑完
  await new Promise((r) => setTimeout(r, 300));
} catch (e) {
  failed = e;
}

function fail(msg) {
  console.error('❌ ' + msg);
  process.exitCode = 1;
}

if (failed) fail('code.js 抛异常：' + failed.message);

// 插件现在直接画在 currentPage 上
const boards = figma.currentPage.children;
console.log(`画板数 = ${boards.length}（期望 3）`);
for (const b of boards) {
  console.log(`  · ${b.name}: ${b.children.length} 个节点, ${b.width}x${b.height}`);
}
if (boards.length !== 3) fail('画板数不是 3');
for (const b of boards) {
  if (b.children.length < 10) fail(`画板「${b.name}」节点过少（${b.children.length}），大概率某段绘制没执行`);
  if (b.width !== 393 || b.height !== 852) fail(`画板「${b.name}」尺寸不是 393x852`);
}

const texts = created.filter((n) => n.type === 'TEXT' && !n.removed);
const noFont = texts.filter((t) => !t.fontName);
const noSize = texts.filter((t) => !t.fontSize || t.fontSize < 8);
console.log(`文本节点 = ${texts.length}，缺字体 = ${noFont.length}，字号异常 = ${noSize.length}`);
if (noFont.length) fail(`${noFont.length} 个文本没设字体（真机 Figma 会报 unloaded font）`);
if (noSize.length) fail('有文本字号 < 8');

console.log(`加载过的字体 = ${[...loadedFonts].join(', ')}`);
if (!loadedFonts.size) fail('一个字体都没 loadFontAsync —— Figma 里会崩');

console.log('通知：' + notified.map((n) => (n.error ? '❌' : '·') + n.msg).join(' | '));
if (notified.some((n) => n.error)) fail('插件内 notify 报了 error');

if (!process.exitCode) console.log('\n✅ 自检通过（3 画板 / 字体已加载 / 文本设置完整）');
