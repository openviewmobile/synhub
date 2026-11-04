// SynHub 设计生成器（Figma 本地插件 · r459 第 1 版）
//
// 为什么用插件而不是"直接调 Figma"：Figma 桌面端的 Dev Mode MCP（127.0.0.1:3845）
// 只做"读设计 → 出代码"，而且要求 Dev/Full 席位；**写**设计只能走插件 API。
// 本文件就是一个可在 Figma 里"Import plugin from manifest…"后运行的本地插件，
// 它会native 生成：设计令牌页 + 两屏手机画板（绝对定位，几何与 SVG 稿一致）。
//
// 只依赖 Figma 插件 API（1.0.0），不联网。

/* eslint-disable no-undef */

// ───────────────────────────── 设计令牌 ─────────────────────────────
const C = {
  bg: '#0D1014',
  phone: '#0F1216',
  surface: '#1A1F27',
  surfaceAlt: '#243040',
  line: '#2A3140',
  text: '#E9EDF2',
  muted: '#98A2AF',
  dim: '#6F7B8B',
  primary: '#4C8DFF',
  primarySoft: '#1D2C48',
  accent: '#8FB8FF',
  onPrimary: '#08111F',
  cover1: '#1B2534',
  cover2: '#2B3648',
};

const W = 393;
const H = 852;

// ───────────────────────────── 工具 ─────────────────────────────
const FONTS = {}; // weight -> fontName
let FALLBACK = { family: 'Inter', style: 'Regular' };

function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return {
    r: parseInt(h.slice(0, 2), 16) / 255,
    g: parseInt(h.slice(2, 4), 16) / 255,
    b: parseInt(h.slice(4, 6), 16) / 255,
  };
}

function paint(hex, opacity) {
  const p = { type: 'SOLID', color: hexToRgb(hex) };
  if (opacity !== undefined) p.opacity = opacity;
  return p;
}

async function setupFonts() {
  const candidates = [
    ['PingFang SC', ['Regular', 'Medium', 'Semibold', 'Bold']],
    ['Noto Sans SC', ['Regular', 'Medium', 'SemiBold', 'Bold']],
    ['Inter', ['Regular', 'Medium', 'Semi Bold', 'Bold']],
    ['Arial', ['Regular', 'Bold']],
  ];
  const avail = await figma.listAvailableFontsAsync();
  const has = (family, style) =>
    avail.some((f) => f.fontName.family === family && f.fontName.style === style);

  for (const [family, styles] of candidates) {
    const usable = styles.filter((s) => has(family, s));
    if (!usable.length) continue;
    const pick = (want) => {
      for (const s of want) if (usable.includes(s)) return s;
      return usable[0];
    };
    FONTS.regular = { family, style: pick(['Regular']) };
    FONTS.medium = { family, style: pick(['Medium', 'Regular']) };
    FONTS.semibold = { family, style: pick(['Semibold', 'SemiBold', 'Medium', 'Bold', 'Regular']) };
    FONTS.bold = { family, style: pick(['Bold', 'Semibold', 'SemiBold', 'Medium', 'Regular']) };
    FALLBACK = FONTS.regular;
    const uniq = new Set(Object.values(FONTS).map((f) => f.family + '/' + f.style));
    for (const key of uniq) {
      const [fam, sty] = key.split('/');
      await figma.loadFontAsync({ family: fam, style: sty });
    }
    figma.notify('字体：' + family);
    return;
  }
  await figma.loadFontAsync(FALLBACK);
}

function fontFor(weight) {
  if (weight >= 640) return FONTS.bold || FALLBACK;
  if (weight >= 560) return FONTS.semibold || FONTS.medium || FALLBACK;
  if (weight >= 450) return FONTS.medium || FALLBACK;
  return FONTS.regular || FALLBACK;
}

/** 画一个屏幕画板（393×852，绝对定位）。 */
function board(name, x, y) {
  const f = figma.createFrame();
  f.name = name;
  f.resize(W, H);
  f.x = x;
  f.y = y;
  f.fills = [paint(C.phone)];
  f.cornerRadius = 30;
  f.strokes = [paint(C.line)];
  f.strokeWeight = 1;
  f.clipsContent = true;
  return f;
}

function rect(parent, x, y, w, h, fill, r, stroke, opacity) {
  const n = figma.createRectangle();
  n.name = 'rect';
  n.resize(w, h);
  n.x = x;
  n.y = y;
  n.cornerRadius = r || 0;
  n.fills = fill ? [paint(fill, opacity)] : [];
  if (stroke) {
    n.strokes = [paint(stroke)];
    n.strokeWeight = 1;
  }
  parent.appendChild(n);
  return n;
}

function ellipse(parent, x, y, w, h, fill) {
  const n = figma.createEllipse();
  n.resize(w, h);
  n.x = x;
  n.y = y;
  n.fills = [paint(fill)];
  parent.appendChild(n);
  return n;
}

/**
 * 文本。`align` 支持 'left' | 'center' | 'right'（坐标按该基准对齐）。
 */
function text(parent, x, y, str, size, fill, weight, align) {
  const n = figma.createText();
  n.fontName = fontFor(weight || 400);
  n.characters = str;
  n.fontSize = size || 13;
  n.fills = [paint(fill || C.text)];
  n.textAutoResize = 'WIDTH_AND_HEIGHT';
  n.lineHeight = { unit: 'PERCENT', value: 132 };
  parent.appendChild(n);
  if (align === 'center') n.x = x - n.width / 2;
  else if (align === 'right') n.x = x - n.width;
  else n.x = x;
  n.y = y - n.height / 2; // 传入的是"视觉中线"
  return n;
}

function svgIcon(parent, x, y, size, body, strokeOrFill) {
  const markup =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" ` +
    `viewBox="0 0 24 24" fill="none">${body}</svg>`;
  const n = figma.createNodeFromSvg(markup);
  n.name = 'icon';
  n.x = x;
  n.y = y;
  parent.appendChild(n);
  return n;
}

const S = (c) => `stroke="${c}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"`;
const F = (c) => `fill="${c}"`;

// 图标路径
const ICON = {
  back: (c) => `<path d="M15 5 L8 12 L15 19" ${S(c)}/>`,
  heart: (c) => `<path d="M12 20s-7-4.5-7-9a4 4 0 0 1 7-2.6A4 4 0 0 1 19 11c0 4.5-7 9-7 9z" ${S(c)}/>`,
  search: (c) => `<circle cx="11" cy="11" r="6" ${S(c)}/><path d="M16 16 L20 20" ${S(c)}/>`,
  play: (c) => `<path d="M8 5.5 L18 12 L8 18.5 Z" ${F(c)}/>`,
  pause: (c) => `<rect x="8" y="6" width="3" height="12" rx="1" ${F(c)}/><rect x="14" y="6" width="3" height="12" rx="1" ${F(c)}/>`,
  prev: (c) => `<rect x="6" y="6" width="2.4" height="12" rx="1" ${F(c)}/><path d="M19 6.5 L10 12 L19 17.5 Z" ${F(c)}/>`,
  next: (c) => `<path d="M5 6.5 L14 12 L5 17.5 Z" ${F(c)}/><rect x="16" y="6" width="2.4" height="12" rx="1" ${F(c)}/>`,
  shuffle: (c) => `<path d="M4 7h3l8 10h4M4 17h3l8-10h4" ${S(c)}/><path d="M16 4l3 3-3 3M16 14l3 3-3 3" ${S(c)}/>`,
  repeat: (c) => `<path d="M6 8h9a3 3 0 0 1 3 3v1M18 16H9a3 3 0 0 1-3-3v-1" ${S(c)}/><path d="M13 5l3 3-3 3M11 19l-3-3 3-3" ${S(c)}/>`,
  close: (c) => `<path d="M7 7l10 10M17 7L7 17" ${S(c)}/>`,
};

function dots(parent, cx, cy, r, gap) {
  const n = figma.createEllipse();
  n.name = 'more-dots';
  n.resize(r * 2, gap * 2 + r * 2);
  n.x = cx - r;
  n.y = cy - gap - r;
  // 用一个圆形 + 内部两条路径不稳妥 ⇒ 直接三个小圆
  n.remove();
  for (const dy of [-gap, 0, gap]) {
    const d = figma.createEllipse();
    d.resize(r * 2, r * 2);
    d.x = cx - r;
    d.y = cy + dy - r;
    d.fills = [paint(C.text)];
    parent.appendChild(d);
  }
}

/** 顶栏（返回 / 标题 / 右侧动作）。 */
function appBar(f, title, rightKind) {
  rect(f, 0, 52, W, 1, C.line);
  svgIcon(f, 18, 62, 22, ICON.back(C.text));
  text(f, 48, 74, title, 15, C.text, 620, 'left');
  if (rightKind === 'like') {
    svgIcon(f, W - 74, 62, 22, ICON.heart(C.text));
  } else {
    svgIcon(f, W - 74, 62, 20, ICON.search(C.text));
  }
  dots(f, W - 34, 73, 2.2, 5.5);
}

// ───────────────────────────── 屏 1：现在播放 ─────────────────────────────
function drawNowPlaying() {
  const f = board('01 · 现在播放', 0, 0);
  text(f, 20, 26, '9:41', 11, C.muted, 400, 'left');
  text(f, W - 20, 26, '⌁ 5G  ▮▮▮', 11, C.muted, 400, 'right');
  appBar(f, '正在播放', 'like');

  // 封面
  rect(f, 16, 108, W - 32, 176, C.cover1, 18, C.cover2);
  ellipse(f, W / 2 - 54, 168, 108, 108, C.surfaceAlt);
  text(f, W / 2, 196, '封面 / 主色律动', 11, '#94A9C7', 400, 'center');

  text(f, 16, 300, 'Demo Song', 17, C.text, 660, 'left');
  text(f, 16, 322, 'Demo Artist · 320 kbps · 无损直连', 12, C.muted, 400, 'left');

  // 进度
  rect(f, 16, 348, W - 32, 4, C.surfaceAlt, 3);
  rect(f, 16, 348, (W - 32) * 0.38, 4, C.primary, 3);
  ellipse(f, 16 + (W - 32) * 0.38 - 6, 342, 12, 12, '#FFFFFF');
  text(f, 16, 366, '1:32', 11, C.muted, 400, 'left');
  text(f, W - 16, 366, '−2:19', 11, C.muted, 400, 'right');

  // 传输控制
  const cy = 404;
  svgIcon(f, 26, cy - 11, 22, ICON.shuffle(C.muted));
  svgIcon(f, 92, cy - 12, 24, ICON.prev(C.text));
  ellipse(f, W / 2 - 30, cy - 30, 60, 60, C.primary);
  svgIcon(f, W / 2 - 11, cy - 11, 22, ICON.play(C.onPrimary));
  svgIcon(f, W - 116, cy - 12, 24, ICON.next(C.text));
  svgIcon(f, W - 48, cy - 11, 22, ICON.repeat(C.muted));

  // 歌词（当前行高亮居中）
  rect(f, 16, 452, W - 32, 214, C.surface, 14, C.line);
  text(f, 30, 476, '歌词', 11.5, C.muted, 620, 'left');
  text(f, W - 30, 476, 'lrclib · 带时间轴', 10.5, '#5C6675', 400, 'right');
  const lines = [
    ['Sample lyric line one', C.dim, 12.5, 400, 514],
    ['Sample lyric line two', C.dim, 12.5, 400, 544],
    ["Sample lyric line three", C.accent, 15, 660, 580],
    ['Sample lyric line four', C.dim, 12.5, 400, 610],
    ['Sample lyric line five', C.dim, 12.5, 400, 640],
  ];
  for (const [s, c, sz, w, y] of lines) text(f, W / 2, y, s, sz, c, w, 'center');

  // 底部快捷
  const qy = H - 58;
  const quick = [['≡', '播放队列'], ['⇄', '投送到'], ['♩', '音效'], ['⏱', '睡眠定时']];
  quick.forEach(([ic, lb], i) => {
    const cx = 16 + ((W - 32) * (i + 0.5)) / 4;
    rect(f, cx - 17, qy - 17, 34, 34, C.surface, 10);
    text(f, cx, qy, ic, 14, C.text, 400, 'center');
    text(f, cx, qy + 28, lb, 10.5, C.muted, 400, 'center');
  });

  return f;
}

// ───────────────────────────── 屏 2：网络电台 ─────────────────────────────
function drawRadio() {
  const f = board('02 · 网络电台', W + 64, 0);
  text(f, 20, 26, '9:41', 11, C.muted, 400, 'left');
  text(f, W - 20, 26, '⌁ 5G  ▮▮▮', 11, C.muted, 400, 'right');
  appBar(f, '网络电台', 'search');

  // 分类 chips
  const chips = [['全部', true], ['收藏', false], ['最近播放', false], ['我的电台', false]];
  let cx = 16;
  for (const [lb, on] of chips) {
    const w = 26 + lb.length * 12;
    rect(f, cx, 100, w, 32, on ? C.primarySoft : C.surface, 9, on ? '#2F4A7A' : null);
    text(f, cx + w / 2, 116, lb, 12, on ? C.accent : C.muted, on ? 620 : 400, 'center');
    cx += w + 8;
  }

  // 电台行
  const rows = [
    ['BBC Radio 1', 'Shoutcast · 128 kbps', '#8FB8FF', true],
    ['Radio Paradise', 'MP3 · 320 kbps', '#FFD28F', false],
    ['Jazz24', 'AAC · 96 kbps', '#A6E3C5', false],
    ['Classic FM', 'HLS · 128 kbps', '#F0A8C8', false],
  ];
  let ry = 150;
  for (const [name, meta, col, playing] of rows) {
    rect(f, 16, ry, W - 32, 62, C.surface, 13);
    rect(f, 26, ry + 11, 40, 40, col, 11);
    text(f, 46, ry + 31, '♫', 14, '#0B121E', 700, 'center');
    text(f, 78, ry + 22, name, 13, C.text, 620, 'left');
    text(f, 78, ry + 42, meta, 11, C.muted, 400, 'left');
    const bx = W - 46;
    if (playing) {
      ellipse(f, bx - 20, ry + 11, 40, 40, C.primary);
      svgIcon(f, bx - 9, ry + 22, 18, ICON.pause(C.onPrimary));
    } else {
      ellipse(f, bx - 20, ry + 11, 40, 40, C.surfaceAlt);
      svgIcon(f, bx - 8, ry + 23, 16, ICON.play(C.accent));
    }
    ry += 70;
  }
  // 添加自定义
  rect(f, 16, ry, W - 32, 56, C.surface, 13, null, 0.55);
  rect(f, 26, ry + 8, 40, 40, '#2A3341', 11);
  text(f, 46, ry + 28, '＋', 15, C.muted, 400, 'center');
  text(f, 78, ry + 22, '添加自定义电台', 13, '#B9C3D0', 620, 'left');
  text(f, 78, ry + 40, '粘贴播放列表或直链', 11, C.muted, 400, 'left');

  // 迷你播放器（新增：暂停 / 关闭）
  const my = H - 78;
  rect(f, 12, my, W - 24, 64, '#1D2531', 16, '#2C3646');
  rect(f, 24, my + 12, 40, 40, '#22314A', 10, '#2B3648');
  text(f, 80, my + 24, 'BBC Radio 1', 12.5, C.text, 620, 'left');
  text(f, 80, my + 42, '正在播放 · 网络电台', 10.5, C.muted, 400, 'left');
  ellipse(f, W - 101, my + 15, 34, 34, C.primary);
  svgIcon(f, W - 92, my + 23, 16, ICON.pause(C.onPrimary));
  svgIcon(f, W - 48, my + 23, 18, ICON.close(C.muted));

  return f;
}

// ───────────────────────────── 设计令牌页 ─────────────────────────────
function drawTokens(x, y) {
  const f = figma.createFrame();
  f.name = '00 · 设计令牌';
  f.resize(W, H);
  f.x = x;
  f.y = y;
  f.fills = [paint(C.bg)];
  f.cornerRadius = 24;
  f.clipsContent = true;

  text(f, 20, 30, '设计令牌 · Design Tokens', 15, C.text, 660, 'left');
  text(f, 20, 52, '所有界面只许引用这些值（颜色 / 字阶 / 圆角 / 点击区）', 10.5, C.muted, 400, 'left');

  const swatches = [
    ['bg', C.bg], ['surface', C.surface], ['surfaceAlt', C.surfaceAlt],
    ['line', C.line], ['text', C.text], ['muted', C.muted],
    ['primary', C.primary], ['primarySoft', C.primarySoft], ['accent', C.accent],
  ];
  let sy = 78;
  swatches.forEach(([name, hex], i) => {
    const col = i % 3;
    const row = Math.floor(i / 3);
    const sx = 20 + col * 120;
    const yy = sy + row * 74;
    rect(f, sx, yy, 110, 44, hex, 10, C.line);
    text(f, sx, yy + 56, name, 10.5, C.muted, 500, 'left');
    text(f, sx, yy + 70, hex, 9.5, '#5C6675', 400, 'left');
  });

  let ty = 78 + 3 * 74 + 26;
  text(f, 20, ty, '字阶', 12, C.accent, 620, 'left');
  const scale = [[17, 660, '标题 · 17/660'], [15, 620, '小节 · 15/620'], [13, 500, '正文 · 13/500'], [11.5, 400, '辅助 · 11.5/400'], [10.5, 400, '微型 · 10.5/400']];
  ty += 24;
  for (const [sz, w, label] of scale) {
    text(f, 20, ty, label, sz, C.text, w, 'left');
    ty += sz + 14;
  }

  ty += 10;
  text(f, 20, ty, '硬指标', 12, C.accent, 620, 'left');
  ty += 22;
  const rules = [
    '点击区 ≥ 48×48dp（图标画在 24dp 网格内）',
    '一屏最多一个 ⋮；行内"更多"不与顶栏 ⋮ 同层',
    '高频动作外露：播放/暂停/下载/分享/删除/刷新/搜索',
    '任何可点元素必须有可见形态（禁透明按钮）',
    '歌词由播放位置驱动：当前行高亮 + 居中 + 240ms',
    '圆角：卡片 13–18 / 图标底 10–11 / 画板 30',
  ];
  for (const r of rules) {
    text(f, 24, ty, '· ' + r, 11, '#C3CCD8', 400, 'left');
    ty += 20;
  }
  return f;
}

// ───────────────────────────── 主流程 ─────────────────────────────
(async () => {
  try {
    await setupFonts();
    // 直接画在当前页上（不建/不改页面 ⇒ 兼容 `documentAccess: dynamic-page` 也兼容老 manifest）
    const baseY = 0;
    drawTokens(0, H + 64 + baseY);
    drawNowPlaying();
    drawRadio();
    figma.viewport.scrollAndZoomIntoView([...figma.currentPage.children]);
    figma.notify('已生成：设计令牌 + 2 屏画板（393×852）。重复运行会叠加，建议在新文件里跑。');
  } catch (e) {
    figma.notify('生成失败：' + (e && e.message ? e.message : String(e)), { error: true });
    console.error(e);
  } finally {
    figma.closePlugin();
  }
})();
