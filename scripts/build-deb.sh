#!/usr/bin/env bash
# 从持续集成生成的 Linux 产物构建 Debian 软件包。
# 用法：scripts/build-deb.sh <版本> [产物目录] [输出目录]

set -euo pipefail

PACKAGE="bash-agent"
MAINTAINER="Lloyd Zhou <lloydzhou@qq.com>"
HOMEPAGE="https://github.com/lloydzhou/bash-agent"
VERSION_INPUT="${1:-}"
DIST_DIR="${2:-dist}"
OUTPUT_DIR="${3:-dist}"

if [[ -z "$VERSION_INPUT" ]]; then
  echo "用法：$0 <版本> [产物目录] [输出目录]" >&2
  exit 2
fi

VERSION="${VERSION_INPUT#v}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v dpkg-deb >/dev/null 2>&1 || {
  echo "错误：需要 dpkg-deb。" >&2
  exit 1
}
command -v strip >/dev/null 2>&1 || {
  echo "错误：需要 strip。" >&2
  exit 1
}
command -v aarch64-linux-gnu-strip >/dev/null 2>&1 || {
  echo "错误：需要 aarch64-linux-gnu-strip（Ubuntu 软件包：binutils-aarch64-linux-gnu）。" >&2
  exit 1
}

if command -v dpkg >/dev/null 2>&1; then
  dpkg --validate-version "$VERSION" >/dev/null 2>&1 || {
    echo "错误：不是合法的 Debian 版本：$VERSION" >&2
    exit 1
  }
elif [[ ! "$VERSION" =~ ^[0-9][0-9A-Za-z.+:~_-]*$ ]]; then
  echo "错误：不是合法的 Debian 版本：$VERSION" >&2
  exit 1
fi

[[ -d "$DIST_DIR" ]] || {
  echo "错误：产物目录不存在：$DIST_DIR" >&2
  exit 1
}
[[ -f "$ROOT_DIR/packaging/debian/copyright" ]] || {
  echo "错误：缺少 packaging/debian/copyright。" >&2
  exit 1
}

required=(
  agent.sh
  tcode
  goagent-linux-amd64
  goagent-linux-arm64
  rustagent-linux-amd64
  rustagent-linux-arm64
  cagent-linux-amd64
  cagent-linux-arm64
)
for artifact in "${required[@]}"; do
  [[ -f "$DIST_DIR/$artifact" ]] || {
    echo "错误：缺少必需产物：$DIST_DIR/$artifact" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" log -1 --format=%ct)"
  else
    SOURCE_DATE_EPOCH=0
  fi
fi
# Debian 规范检查将 1980 年以前的时间视为异常；无版本库时使用安全基线。
if (( SOURCE_DATE_EPOCH < 315532800 )); then
  SOURCE_DATE_EPOCH=315532800
fi
export SOURCE_DATE_EPOCH

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bash-agent-deb.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

write_control() {
  local pkg_dir="$1"
  local arch="$2"
  local description="$3"
  local dependencies="bash (>= 4.0), gawk, curl, ca-certificates, ripgrep, tmux, procps, libc6 (>= 2.31), libgcc-s1, libcurl4t64 | libcurl4"

  cat > "$pkg_dir/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: utils
Priority: optional
Architecture: $arch
Maintainer: $MAINTAINER
Depends: $dependencies
Homepage: $HOMEPAGE
Description: minimal AI coding agent runtime
 $description
 Supports Claude, OpenAI-compatible providers, persistent sessions,
 skills, context compression and sub-agent orchestration.
EOF
}

install_docs() {
  local pkg_dir="$1"
  local doc_dir="$pkg_dir/usr/share/doc/$PACKAGE"
  mkdir -p "$doc_dir"
  install -m 0644 "$ROOT_DIR/packaging/debian/copyright" "$doc_dir/copyright"

  if [[ -f "$ROOT_DIR/README.md" ]]; then
    gzip -9n < "$ROOT_DIR/README.md" > "$doc_dir/README.md.gz"
    chmod 0644 "$doc_dir/README.md.gz"
  fi
  {
    printf '%s (%s) unstable; urgency=medium\n\n' "$PACKAGE" "$VERSION"
    printf '  * Upstream release %s.\n\n' "$VERSION"
    printf ' -- %s  %s\n' "$MAINTAINER" "$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH" -R)"
  } | gzip -9n > "$doc_dir/changelog.gz"
  chmod 0644 "$doc_dir/changelog.gz"

  if [[ -f "$ROOT_DIR/CHANGELOG.md" ]]; then
    gzip -9n < "$ROOT_DIR/CHANGELOG.md" > "$doc_dir/changelog.md.gz"
    chmod 0644 "$doc_dir/changelog.md.gz"
  fi
}

write_md5sums() {
  local pkg_dir="$1"
  (
    cd "$pkg_dir"
    find usr -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum
  ) > "$pkg_dir/DEBIAN/md5sums"
  chmod 0644 "$pkg_dir/DEBIAN/md5sums"
}

normalize_timestamps() {
  local pkg_dir="$1"
  find "$pkg_dir" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
}

build_package() {
  local arch="$1"
  local pkg_dir="$WORK_DIR/$arch"
  local bin_dir="$pkg_dir/usr/bin"
  local output="$OUTPUT_DIR/${PACKAGE}_${VERSION}_${arch}.deb"

  mkdir -p "$pkg_dir/DEBIAN" "$bin_dir"
  chmod 0755 "$pkg_dir/DEBIAN"
  install -m 0755 "$DIST_DIR/agent.sh" "$bin_dir/bash-agent"

  install -m 0755 "$DIST_DIR/goagent-linux-$arch" "$bin_dir/goagent"
  install -m 0755 "$DIST_DIR/rustagent-linux-$arch" "$bin_dir/rustagent"
  install -m 0755 "$DIST_DIR/cagent-linux-$arch" "$bin_dir/cagent"
  if [[ "$arch" == "arm64" ]]; then
    aarch64-linux-gnu-strip --strip-unneeded "$bin_dir/cagent"
  else
    strip --strip-unneeded "$bin_dir/cagent"
  fi
  install -m 0755 "$DIST_DIR/tcode" "$bin_dir/tcode"
  write_control "$pkg_dir" "$arch" \
    "This package contains the Bash, Go, Rust and C implementations plus tcode."

  install_docs "$pkg_dir"
  chmod 0644 "$pkg_dir/DEBIAN/control"
  write_md5sums "$pkg_dir"
  normalize_timestamps "$pkg_dir"
  rm -f "$output"
  dpkg-deb --root-owner-group -Zxz -z9 --build "$pkg_dir" "$output"
  echo "已生成：$output"
}

build_package amd64
build_package arm64
