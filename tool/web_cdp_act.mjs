// r715：**CDP 动作器**（配合 `web_cdp_probe.mjs`／`--attach` 用）。
//
// 为什么：Web 的 C4（同源端到端，尤其"聊天能真发"）必须走**用户能做的动作**，
// 而 `flutter drive` 只能驱动它自己起的那个 origin。这里直接对一个
// **已经在跑的** Chrome（`--remote-debugging-port=9223`）做鼠标/键盘/截图，
// 页面可以是我们单端口伺服的 `build/web`（App 与 `/webapi` 同 origin）。
//
// 用法（一次一条动作，状态留在那个 Chrome 里）：
//   node tool/web_cdp_act.mjs --attach 9223 --goto http://127.0.0.1:18083/
//   node tool/web_cdp_act.mjs --attach 9223 --shot /tmp/a.png
//   node tool/web_cdp_act.mjs --attach 9223 --click 500,300 [--click …]
//   node tool/web_cdp_act.mjs --attach 9223 --type "hello" [--enter]
//   node tool/web_cdp_act.mjs --attach 9223 --key Tab
//   node tool/web_cdp_act.mjs --attach 9223 --eval "document.title"
//   node tool/web_cdp_act.mjs --attach 9223 --resize 1200x800
//
// 说明：Flutter Web（CanvasKit）把界面画在 canvas 上 —— **没有 DOM 可点**，
// 所以动作一律是"视口坐标"的鼠标事件（与真机走查同款口径）。
import {writeFileSync} from 'node:fs';

const argv = process.argv.slice(2);
const opt = {port: 9223, click: [], shot: '', type: '', eval: '', goto: '',
  key: '', enter: false, resize: '', wait: 0};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--attach') opt.port = Number(argv[++i]);
  else if (a === '--click') opt.click.push(argv[++i]);
  else if (a === '--shot') opt.shot = argv[++i];
  else if (a === '--type') opt.type = argv[++i];
  else if (a === '--eval') opt.eval = argv[++i];
  else if (a === '--goto') opt.goto = argv[++i];
  else if (a === '--key') opt.key = argv[++i];
  else if (a === '--enter') opt.enter = true;
  else if (a === '--resize') opt.resize = argv[++i];
  else if (a === '--wait') opt.wait = Number(argv[++i]);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function target() {
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${opt.port}/json`);
      const list = await res.json();
      // ★ 目标页选择：优先 **被测 origin**（headless 会额外开 omnibox/扩展等页，
      // 抓错页就会把动作打到 chrome:// 上 —— r715 真实踩到过）。
      const pages = list.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      const page =
        pages.find((t) => t.url.includes('18083')) ||
        pages.find((t) => !t.url.startsWith('chrome') && t.url !== '');
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch (_) { /* 等端口 */ }
    await sleep(250);
  }
  throw new Error('CDP 没起来');
}

const ws = new WebSocket(await target());
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let seq = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const {resolve} = pending.get(m.id);
    pending.delete(m.id);
    resolve(m.result ?? m.error ?? {});
  }
};
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++seq;
  pending.set(id, {resolve});
  ws.send(JSON.stringify({id, method, params}));
});

await send('Page.enable');
await send('Runtime.enable');

if (opt.resize) {
  const [w, h] = opt.resize.split('x').map(Number);
  await send('Emulation.setDeviceMetricsOverride',
      {width: w, height: h, deviceScaleFactor: 1, mobile: false});
  console.log(`RESIZE ${w}x${h}`);
}
if (opt.goto) {
  await send('Page.navigate', {url: opt.goto});
  console.log(`GOTO ${opt.goto}`);
  await sleep(6000);
}

for (const pair of opt.click) {
  const [x, y] = pair.split(',').map(Number);
  await send('Input.dispatchMouseEvent', {type: 'mouseMoved', x, y});
  await send('Input.dispatchMouseEvent',
      {type: 'mousePressed', x, y, button: 'left', clickCount: 1});
  await sleep(40);
  await send('Input.dispatchMouseEvent',
      {type: 'mouseReleased', x, y, button: 'left', clickCount: 1});
  console.log(`CLICK ${x},${y}`);
  await sleep(600); // 第一次点击常常只"激活窗口"（r713 同款）
}

if (opt.type) {
  await send('Input.insertText', {text: opt.type});
  console.log(`TYPE ${JSON.stringify(opt.type)}`);
  await sleep(300);
}
if (opt.enter) {
  for (const type of ['keyDown', 'keyUp']) {
    await send('Input.dispatchKeyEvent',
        {type, key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13});
  }
  console.log('ENTER');
  await sleep(300);
}
if (opt.key) {
  for (const type of ['keyDown', 'keyUp']) {
    await send('Input.dispatchKeyEvent', {type, key: opt.key, code: opt.key});
  }
  console.log(`KEY ${opt.key}`);
  await sleep(300);
}

if (opt.wait) await sleep(opt.wait);

if (opt.eval) {
  const r = await send('Runtime.evaluate',
      {expression: opt.eval, returnByValue: true, awaitPromise: true});
  console.log('EVAL ' + JSON.stringify(r.result?.value ?? null));
}
if (opt.shot) {
  const s = await send('Page.captureScreenshot', {format: 'png'});
  writeFileSync(opt.shot, Buffer.from(s.data, 'base64'));
  console.log(`SHOT ${opt.shot}`);
}
ws.close();
process.exit(0);
