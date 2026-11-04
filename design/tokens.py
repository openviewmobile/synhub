#!/usr/bin/env python3
"""设计令牌 —— 双主题唯一真源（暗色 / 亮色）。

SVG 设计稿与 Flutter 代码都从这里取色，所以**主题切换在设计与代码里是同一份定义**。
命名与 design/README.md 一致；新增令牌必须两个主题都补。
"""

PALETTES = {
    'dark': {
        'bg': '#0B0E12', 'phone': '#0F1216', 'surface': '#1A1F27', 'surface2': '#243040',
        'line': '#2A3140', 'text': '#E9EDF2', 'muted': '#98A2AF', 'dim': '#8D9AA8',
        'primary': '#6FA3FF', 'primarySoft': '#1D2C48', 'accent': '#8FB8FF',
        'onPrimary': '#08111F', 'danger': '#FF7B72', 'ok': '#57C08B',
        'navBar': '#12161C', 'playerBar': '#1D2531',
    },
    'light': {
        'bg': '#E9EEF5', 'phone': '#F2F5F9', 'surface': '#FFFFFF', 'surface2': '#E8EEF6',
        'line': '#DFE6EF', 'text': '#0F172A', 'muted': '#566578', 'dim': '#5C6A7E',
        'primary': '#1D4ED8', 'primarySoft': '#DBEAFE', 'accent': '#1E40AF',
        'onPrimary': '#FFFFFF', 'danger': '#C81E1E', 'ok': '#16A34A',
        'navBar': '#F7F9FC', 'playerBar': '#FFFFFF',
    },
}

# ★ 字号 / 字重 / 行高（与主题无关，真源）。Material 的 TextTheme 角色名 →
# (size, weight, height, letterSpacing, 颜色角色)。颜色角色：text / muted / dim。
#
# 为什么要有这张表：此前 `DesignTheme` 直接 `Typography.material2021(...).white`，
# 于是"设计稿说行标题 13/600、副标题 11.5"只活在组件里（`DesignRowTile` 自己写死），
# 任何**没走组件**的 Text 都会退回 Material 默认（14/400）⇒ 同一屏密 1–2 px，
# 而且换主题时字色也不是令牌。表在这里，组件与 ThemeData 都从它取。
TYPE = {
    'headlineSmall':  (20.0, 600, 1.25, 0.0,  'text'),
    'titleLarge':     (17.0, 600, 1.25, -0.1, 'text'),
    'titleMedium':    (15.0, 600, 1.25, -0.1, 'text'),
    'titleSmall':     (13.0, 600, 1.3,  0.0,  'text'),
    'bodyLarge':      (14.0, 400, 1.4,  0.0,  'text'),
    'bodyMedium':     (12.5, 400, 1.4,  0.0,  'text'),
    'bodySmall':      (11.5, 400, 1.35, 0.1,  'muted'),
    'labelLarge':     (13.0, 600, 1.2,  0.1,  'text'),
    'labelMedium':    (12.0, 500, 1.2,  0.2,  'muted'),
    'labelSmall':     (11.0, 500, 1.2,  0.2,  'dim'),
}

# 圆角 / 间距 / 点击区（与主题无关）
RADIUS = {'card': 13, 'iconTile': 11, 'chip': 9, 'board': 30, 'pill': 16}
MIN_TAP = 48


def hex_to_rgb(h: str):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
