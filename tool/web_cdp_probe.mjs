// r715：**无驱动浏览器的取证探针**（Web 站 C2/C3 的仪器）。
//
// 为什么要它：`flutter drive` 只能跑 integration_test（App 内部断言），
// 而 C2（`go_router` 的 URL 在**刷新**后是否 404）与 C3（CanvasKit 首屏
// 体积/帧率）都发生在 **App 之外**：要的是"浏览器导航到某个 URL 之后
// 页面里到底有没有 Flutter 视图"。
//
// 做法：用 Chrome 自带 CDP（`--remote-debugging-port`），**不引第三方包**
// （Node 24 自带 `fetch` 与全局 `WebSocket`）。
//
// 用法：
//   node tool/web_cdp_probe.mjs --url http://127.0.0.1:18082/settings \
//        --out /tmp/r715_web_settings.png --eval "document.querySelector('flt-glass-pane')!==null"
//
// 参数：
//   --url     要导航到的地址（默认 http://127.0.0.1:18082/）
//   --out     截图输出路径（PNG）
//   --eval    在页面里求值的 JS 表达式（结果打印为 `EVAL <json>`）
//   --wait    导航后等多少毫秒再判决（默认 12000 —— CanvasKit 首帧要下载 wasm）
//   --chrome  Chrome 可执行文件（默认走 /Applications）
import {spawn} from 'node:child_process';
import {writeFileSync} from 'node:fs';

const argv = process.argv.slice(2);
const opt = {url: 'http://127.0.0.1:18082/', out: '', evalExpr: '', wait: 12000,
  chrome: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  port: 9222};
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--url') opt.url = argv[++i];
  else if (argv[i] === '--out') opt.out = argv[++i];
  else if (argv[i] === '--eval') opt.evalExpr = argv[++i];
  else if (argv[i] === '--wait') opt.wait = Number(argv[++i]);
  else if (argv[i] === '--chrome') opt.chrome = argv[++i];
  else if (argv[i] === '--port') opt.port = Number(argv[++i]);
}

const profile = `/tmp/r715_cdp_${process.pid}`;
const chrome = spawn(opt.chrome, [
  '--headless=new',
  `--remote-debugging-port=${opt.port}`,
  `--user-data-dir=${profile}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu-sandbox',
  '--use-gl=angle',
  '--use-angle=swiftshader',
  'about:blank',
], {stdio: ['ignore', 'pipe', 'pipe']});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function target() {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${opt.port}/json`);
      const list = await res.json();
      const page = list.find((t) => t.type === 'page');
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch (_) { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('CDP 没起来');
}

const wsUrl = await target();
const ws = new WebSocket(wsUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let seq = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const {resolve} = pending.get(msg.id);
    pending.delete(msg.id);
    resolve(msg.result ?? msg.error ?? {});
  }
};
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++seq;
  pending.set(id, {resolve});
  ws.send(JSON.stringify({id, method, params}));
});

await send('Page.enable');
await send('Runtime.enable');
const t0 = Date.now();
await send('Page.navigate', {url: opt.url});
await sleep(opt.wait);

if (opt.evalExpr) {
  const r = await send('Runtime.evaluate',
      {expression: opt.evalExpr, returnByValue: true, awaitPromise: true});
  console.log('EVAL ' + JSON.stringify(r.result?.value ?? null));
}
if (opt.out) {
  const shot = await send('Page.captureScreenshot', {format: 'png'});
  if (shot.data) {
    writeFileSync(opt.out, Buffer.from(shot.data, 'base64'));
    console.log(`SHOT ${opt.out}`);
  } else {
    console.log('SHOT-FAIL ' + JSON.stringify(shot).slice(0, 200));
  }
}
console.log(`ELAPSED_MS ${Date.now() - t0}`);
ws.close();
chrome.kill('SIGKILL');
process.exit(0);
