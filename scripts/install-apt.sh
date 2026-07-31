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
REPO_URL="https://github.com/lloydzhou/bash-agent/releases/latest/download"

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
  local deb_name="bash-agent_*_${arch}.deb"
  local url
  url="$(curl -fsSL "$REPO_URL" 2>/dev/null | grep -oE "${deb_name}" | head -1 || true)"
  if [[ -z "$url" ]]; then
    # 无法解析 latest 页面时按已知文件名尝试
    curl -fsSL -o "/tmp/bash-agent_${arch}.deb" "$REPO_URL/$(basename "$deb_name")" || {
      echo "错误：无法下载 $REPO_URL/$deb_name" >&2
      return 1
    }
  else
    curl -fsSL -o "/tmp/bash-agent_${arch}.deb" "$REPO_URL/$url"
  fi
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
