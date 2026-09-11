#!/usr/bin/env bash
# 从各仓库 GitHub Releases 下载最新版本的 .deb 到指定目录（聚合 apt 源用）。
# 用法：scripts/apt/fetch-debs.sh <out_dir> [repo_slug ...]
#
# 默认聚合三个仓库：bash-agent / mcpc / oapi；也可显式传仓库列表，
# 例如 release job 本地已有 bash-agent deb 时只拉另外两个：
#   scripts/apt/fetch-debs.sh dist lloydzhou/mcpc lloydzhou/oapi
#
# 公开仓库匿名 API 即可读取（CI 中无需 PAT）；可选设置 GITHUB_TOKEN（PAT）
# 提升 API 限流。任一指定仓库的 latest release 缺少 deb 资产时报错退出，
# 防止发布缺包的源。

set -euo pipefail

OUT_DIR="${1:-dist}"
shift || true
REPOS=("$@")
(( ${#REPOS[@]} > 0 )) || REPOS=(lloydzhou/bash-agent lloydzhou/mcpc lloydzhou/oapi)

mkdir -p "$OUT_DIR"

api_curl() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
  else
    curl -fsSL "$@"
  fi
}

total=0
for repo in "${REPOS[@]}"; do
  echo "==> $repo 最新 release 的 deb"
  urls="$(api_curl "https://api.github.com/repos/$repo/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | sed 's/"browser_download_url": *"//; s/"$//' \
    | grep -E '_(amd64|arm64)\.deb$' || true)"
  if [[ -z "$urls" ]]; then
    echo "错误：$repo 的 latest release 没有 amd64/arm64 deb 资产，中止（防止发布缺包的源）" >&2
    exit 1
  fi
  count=0
  for url in $urls; do
    name="$(basename "$url")"
    curl -fsSL -o "$OUT_DIR/$name" "$url"
    echo "    下载 $name"
    count=$((count + 1))
  done
  total=$((total + count))
done

echo "==> 共下载 $total 个 deb 到 $OUT_DIR"
