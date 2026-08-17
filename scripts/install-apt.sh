#!/usr/bin/env bash
# bash-agent 一键安装（APT 仓库优先，失败时回退到直接下载 .deb）
#
#   curl -fsSL https://lloydzhou.github.io/bash-agent/install.sh | sudo bash
#
# 亦可直接使用 APT 源（支持后续 apt upgrade 自动升级）：
#   echo "deb [trusted=yes] https://lloydzhou.github.io/bash-agent/debian stable main" \
#     | sudo tee /etc/apt/sources.list.d/bash-agent.list
#   sudo apt update && sudo apt install bash-agent

set -euo pipefail

BASE_URL="https://lloydzhou.github.io/bash-agent"
GITHUB_REPO="https://github.com/lloydzhou/bash-agent"

[[ "$(id -u)" -eq 0 ]] || { echo "错误：需要 root 权限（使用 sudo bash）" >&2; exit 1; }

arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
echo "==> 目标架构：$arch"

install_via_apt() {
  echo "==> 配置 APT 源并安装"
  echo "deb [trusted=yes] $BASE_URL/debian stable main" > /etc/apt/sources.list.d/bash-agent.list
  apt-get update -o Dir::Etc::sourcelist="sources.list.d/bash-agent.list" \
                  -o Dir::Etc::sourceparts="-" \
                  -o APT::Get::List-Cleanup="0" -qq || {
    echo "警告：apt update 失败，回退到直接下载 .deb" >&2
    rm -f /etc/apt/sources.list.d/bash-agent.list
    return 1
  }
  apt-get install -y -qq bash-agent
}

install_via_deb() {
  echo "==> 直接下载 .deb 安装"
  # 从 releases/latest 的 302 Location 提取 tag（release 页面 HTML 为异步渲染，
  # 不含 asset 文件名，无法从页面解析；URL 中也不支持通配符）
  local tag ver url
  tag="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$GITHUB_REPO/releases/latest" \
         2>/dev/null | grep -oE '[^/]+$' || true)"
  ver="${tag#v}"
  if [[ -z "$ver" ]]; then
    echo "错误：无法解析最新 release tag（$GITHUB_REPO/releases/latest）" >&2
    return 1
  fi
  url="$GITHUB_REPO/releases/download/${tag}/bash-agent_${ver}_${arch}.deb"
  curl -fsSL --retry 2 -o "/tmp/bash-agent_${arch}.deb" "$url" || {
    echo "错误：无法下载 $url" >&2
    return 1
  }
  dpkg -i "/tmp/bash-agent_${arch}.deb" || apt-get install -f -y -qq
  rm -f "/tmp/bash-agent_${arch}.deb"
}

echo "==> 验证 APT 仓库可用性"
if curl -fsSL --retry 2 --connect-timeout 8 "$BASE_URL/debian/dists/stable/Release" >/dev/null 2>&1; then
  install_via_apt || install_via_deb
else
  install_via_deb
fi

# 验证安装
for cmd in bash-agent goagent rustagent cagent; do
  command -v "$cmd" >/dev/null 2>&1 || continue
  echo "==> 已安装：$cmd"
done
echo "==> 完成。运行 bash-agent 开始使用。"
