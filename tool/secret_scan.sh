#!/usr/bin/env bash
# 提交前扫描（只看 **git 已跟踪** 的文件）：密钥 / 个人信息 / 大文件。
# 全绿才允许 push。用法：bash tool/secret_scan.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
git rev-parse --git-dir >/dev/null 2>&1 || { echo '不是 git 仓库'; exit 2; }
bad=0

scan() { # scan <正则> <说明> [白名单正则] [路径限定]
  local hits rc
  # ★★★ 规则自证（第 438 轮的真实事故）：`git grep -E` 用的是 POSIX ERE，
  #   不支持 `(?!…)` 这类 lookahead —— 写了它 grep 直接**语法报错退出 128**，
  #   而 `2>/dev/null` 把错误吃掉 ⇒ 恒判定"无命中" ⇒ **假绿**。
  #   这里先拿空输入压一遍：`grep -E` 语法错返回 2，无命中返回 1。
  printf '' | grep -E -e "$1" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '❌ 正则语法错误（本规则恒不命中，等于没检查）：%s\n' "$1"; bad=1; return
  fi
  hits=$(git grep -IlE -e "$1" -- ${4:-.} 2>/dev/null | grep -v '^tool/secret_scan\.sh$' || true)
  if [ -n "${3:-}" ]; then hits=$(printf '%s\n' "$hits" | grep -vE "$3" || true); fi
  if [ -n "${hits// /}" ]; then
    printf '❌ %s\n' "$2"; printf '%s\n' "$hits" | sed 's/^/    /' | head -20; bad=1
  else
    printf '✅ %s\n' "$2"
  fi
}

# ① 凭据 / 账号 / 内网地址 / 个人邮箱 / 绝对路径
scan 'passwd=[A-Za-z0-9%*:._-]{6,}'                    '明文 passwd= 字面量' 'cgi_encryption_test\.dart'
scan '_sid=[A-Za-z0-9]{24,}'                            '会话 sid 真值'
scan 'SynoToken=[A-Za-z0-9]{16,}'                       'SynoToken 真值'
# 真实内网 IP / 账号昵称一律走不进仓库的词表
scan '/Users/[a-z]+/'                                   '本机绝对路径' 'fs_bookmark_test\.dart|save_destination_test\.dart|ios_fs_export_test\.dart|image_edit_client_test\.dart'
scan '(ghp|gho|ghs)_[A-Za-z0-9]{20,}'                   'GitHub token'
scan 'AKIA[0-9A-Z]{16}'                                 'AWS access key'
scan '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'   '私钥' 'mock_nas_key\.pem|r296_macos_player_tls_probe_test\.dart'
# ★ r723：个人信息面（不是凭据，但同样不该进公开仓库）
# 私网地址只在**散文/台账**里算泄漏（代码与测试夹具里的 192.168.1.x 是通用占位）。
# 真实值同时在 `tool/secret_words.local` 里，双保险。
scan '(^|[^0-9])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' '私网地址 192.168.x.x（文档里）' '' '*.md'
scan '(^|[^0-9])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' '私网地址 172.16-31.x.x（文档里）' '' '*.md'
scan '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)'               '中国大陆手机号字面量（文档里）' '' '*.md'
scan '\.(synology|myds|ddns|diskstation)\.(me|net)'      '真实 DDNS 域名' 'serv_api_test\.dart'
scan '[A-Za-z0-9._%+-]+@(qq|163|126|sina|gmail|outlook|hotmail|icloud)\.com' '真实邮箱域名' 
# ③ 上游标识词表：**不进仓库**（`tool/secret_words.local`，一行一个，`#` 注释）
#    ★ 词表本身若进仓库，等于把要保护的名字公开 ⇒ 只读不存。
#   来源优先级：环境变量 SECRET_WORDS（CI 用 secrets 注入）→ tool/secret_words.local（本机）
alts="${SECRET_WORDS:-}"
if [ -z "${alts}" ] && [ -f tool/secret_words.local ]; then
  alts=$(grep -v '^#' tool/secret_words.local 2>/dev/null | grep -v '^[[:space:]]*$' | paste -sd'|' -)
fi
if [ -n "${alts}" ]; then
  scan "(${alts})" '上游标识词表命中' 'secret_scan\.sh'
else
  echo '（⚠️ 未提供词表（SECRET_WORDS / tool/secret_words.local）：上游标识此项未校验）'
fi

# ④ 签名材料 / 本地配置：**一律不许进仓库**
tracked_secret_files=$(git ls-files | grep -E '(^|/)(key\.properties|secret_words\.local)$|\.(jks|keystore|p12|mobileprovision)$|(^|/)\.env$' | head -10 || true)
if [ -n "${tracked_secret_files// /}" ]; then
  echo '❌ 签名材料/本地配置被跟踪'; printf '%s\n' "$tracked_secret_files" | sed 's/^/    /'; bad=1
else
  echo '✅ 签名材料/本地配置未跟踪'
fi

# ② 卫生：跟踪文件里不许有超大文件；不许跟踪产物目录
big=$(git ls-files -z | xargs -0 -I{} sh -c 'test -f "{}" && [ "$(wc -c <"{}")" -gt 5000000 ] && echo "{}"' 2>/dev/null | grep -v 'office_slides_o3/dynamic.oslides' || true)
if [ -n "${big// /}" ]; then echo '❌ 超过 5 MB 的跟踪文件（大样本请走 Release 附件）'; echo "$big" | sed 's/^/    /'; bad=1; fi
tracked_build=$(git ls-files | grep -E '^(build/|\.dart_tool/)|/build/' | head -5 || true)
if [ -n "${tracked_build// /}" ]; then echo '❌ 构建产物被跟踪'; echo "$tracked_build" | sed 's/^/    /'; bad=1; fi

if [ "$bad" -eq 0 ]; then echo "全部通过 ✔"; else echo "有命中，禁止 push"; fi
exit "$bad"
