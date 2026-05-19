#!/usr/bin/env bash
# install.sh — One-click installer for bash-agent (and optional goagent/rustagent)
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/lloydzhou/bash-agent/main/scripts/install.sh)
#        bash install.sh [--prefix=/usr/local] [--bash-only]

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────
REPO="lloydzhou/bash-agent"
VERSION="${BASH_AGENT_VERSION:-latest}"
PREFIX="${BASH_AGENT_PREFIX:-/usr/local}"
BASH_ONLY="${BASH_AGENT_BASH_ONLY:-false}"

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
error() { printf "${RED}✗${NC} %s\n" "$*" >&2; }
header(){ printf "\n${CYAN}==>${NC} %s\n" "$*"; }

# ─── Parse args ───────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#*=}" ;;
    --bash-only) BASH_ONLY=true ;;
    --help)
      echo "Usage: bash install.sh [options]"
      echo ""
      echo "Options:"
      echo "  --prefix=/path   Install to a custom prefix (default: /usr/local)"
      echo "  --bash-only      Install only the Bash edition (no Go/Rust)"
      echo "  --help           Show this help"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

BINDIR="$PREFIX/bin"
DOCDIR="$PREFIX/share/doc/bash-agent"

# ─── OS Detection ─────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  ;;
  Darwin) ;;
  *)
    error "Unsupported OS: $OS (only Linux and macOS are supported)"
    exit 1
    ;;
esac

# ─── Dependency checks ────────────────────────────────────────────────
check_deps() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      error "Missing dependency: $cmd"
      missing=1
    fi
  done
  return "$missing"
}

# ─── Detect package manager ───────────────────────────────────────────
detect_pm() {
  if command -v apt-get &>/dev/null; then echo "apt"
  elif command -v pacman &>/dev/null; then echo "pacman"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v brew &>/dev/null; then echo "brew"
  else echo "unknown"
  fi
}

# ─── Install mode selection ───────────────────────────────────────────
select_mode() {
  printf "\n"
  printf "${CYAN}╔══════════════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║${NC}        bash-agent — 一键安装脚本            ${CYAN}║${NC}\n"
  printf "${CYAN}╚══════════════════════════════════════════════╝${NC}\n"
  printf "\n"
  printf "  ${YELLOW}1${NC}) 精简安装 — 仅 Bash 版 (无编译依赖)\n"
  printf "  ${YELLOW}2${NC}) 完整安装 — Bash + Go + Rust (需要 go/rust)\n"
  printf "  ${YELLOW}3${NC}) 退出\n"
  printf "\n"

  if [[ "$BASH_ONLY" == "true" ]]; then
    info "使用 --bash-only 标志，自动选择精简安装"
    return 1
  fi

  read -rp "请选择 [1-3]: " choice </dev/tty
  case "$choice" in
    1) return 1 ;;  # bash-only
    2) return 0 ;;  # full
    *) exit 0 ;;
  esac
}

# ─── Install: Bash-only (download pre-built script) ──────────────────
install_bash_only() {
  header "安装 Bash 版 (精简模式)"

  # Resolve latest version if needed
  if [[ "$VERSION" == "latest" ]]; then
    info "获取最新版本信息..."
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)" \
      || VERSION="v3.0.3"
  fi

  local url="https://raw.githubusercontent.com/$REPO/$VERSION/scripts/install.sh"
  # Actually, we download agent.sh directly
  local agent_url="https://raw.githubusercontent.com/$REPO/$VERSION/dist/agent.sh"

  info "下载 bash-agent $VERSION..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  curl -fsSL "$agent_url" -o "$tmpdir/agent.sh" || {
    # Fallback: build from source
    warn "无法直接下载预构建脚本，尝试从源码构建..."
    install_bash_from_source
    rm -rf "$tmpdir"
    return
  }

  mkdir -p "$BINDIR" "$DOCDIR"
  install -m755 "$tmpdir/agent.sh" "$BINDIR/bash-agent"
  rm -rf "$tmpdir"

  # Try to download docs
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$VERSION/README.md" \
    -o "$DOCDIR/README.md" 2>/dev/null || true

  info "bash-agent 已安装到 $BINDIR/bash-agent"
}

# ─── Install: Bash from source (requires git + make) ─────────────────
install_bash_from_source() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone --depth 1 "https://github.com/$REPO.git" "$tmpdir/bash-agent"

  (cd "$tmpdir/bash-agent" && bash scripts/build.sh dist/agent.sh)

  mkdir -p "$BINDIR" "$DOCDIR"
  install -m755 "$tmpdir/bash-agent/dist/agent.sh" "$BINDIR/bash-agent"
  install -m644 "$tmpdir/bash-agent/README.md" "$DOCDIR/README.md" 2>/dev/null || true
  install -m644 "$tmpdir/bash-agent/CHANGELOG.md" "$DOCDIR/CHANGELOG.md" 2>/dev/null || true

  rm -rf "$tmpdir"
}

# ─── Install: Full (Bash + Go + Rust from source) ────────────────────
install_full() {
  header "完整安装 Bash + Go + Rust (从源码构建)"

  check_deps curl git bash python3 || {
    error "缺少基础依赖，请安装 curl, git, bash, python3"
    exit 1
  }

  # Check build dependencies
  local has_go=false has_rust=false
  command -v go &>/dev/null && has_go=true
  command -v cargo &>/dev/null && has_rust=true

  if ! $has_go; then
    warn "未找到 Go — 将跳过 goagent 的构建"
  fi
  if ! $has_rust; then
    warn "未找到 Rust/Cargo — 将跳过 rustagent 的构建"
  fi
  if ! $has_go && ! $has_rust; then
    warn "既没有 Go 也没有 Rust，将只安装 Bash 版"
  fi

  # Clone
  local tmpdir
  tmpdir="$(mktemp -d)"
  info "克隆仓库..."
  git clone --depth 1 "https://github.com/$REPO.git" "$tmpdir/bash-agent"
  cd "$tmpdir/bash-agent"

  # Build Bash
  info "构建 Bash 版..."
  bash scripts/build.sh dist/agent.sh

  # Build Go (if available)
  if $has_go; then
    info "构建 Go 版..."
    mkdir -p go/.gocache go/.gomodcache dist
    GOCACHE="$PWD/go/.gocache" GOMODCACHE="$PWD/go/.gomodcache" go -C go mod download
    GOCACHE="$PWD/go/.gocache" GOMODCACHE="$PWD/go/.gomodcache" \
      go -C go build -ldflags="-s -w" -trimpath -o "$PWD/dist/goagent" ./cmd/goagent
  fi

  # Build Rust (if available)
  if $has_rust; then
    info "构建 Rust 版..."
    (cd rust && cargo build --release -j "$(nproc 2>/dev/null || echo 4)")
    cp rust/target/release/rustagent dist/rustagent 2>/dev/null || true
  fi

  # Install
  info "安装到 $BINDIR..."
  mkdir -p "$BINDIR" "$DOCDIR"
  install -m755 dist/agent.sh "$BINDIR/bash-agent"
  [[ -f dist/goagent ]] && install -m755 dist/goagent "$BINDIR/goagent"
  [[ -f dist/rustagent ]] && install -m755 dist/rustagent "$BINDIR/rustagent"
  install -m644 README.md "$DOCDIR/README.md" 2>/dev/null || true
  install -m644 CHANGELOG.md "$DOCDIR/CHANGELOG.md" 2>/dev/null || true

  cd /
  rm -rf "$tmpdir"

  info "安装完成！"
  info "  $BINDIR/bash-agent"
  [[ -f "$BINDIR/goagent" ]] && info "  $BINDIR/goagent"
  [[ -f "$BINDIR/rustagent" ]] && info "  $BINDIR/rustagent"
}

# ─── Post-install message ─────────────────────────────────────────────
post_install_msg() {
  printf "\n"
  printf "${GREEN}╔══════════════════════════════════════════════╗${NC}\n"
  printf "${GREEN}║${NC}        bash-agent 安装成功！                ${GREEN}║${NC}\n"
  printf "${GREEN}╚══════════════════════════════════════════════╝${NC}\n"
  printf "\n"
  printf "  运行:  ${CYAN}bash-agent${NC}\n"
  printf "\n"
  printf "  文档:  https://github.com/$REPO\n"
  printf "\n"
}

# ─── Main ─────────────────────────────────────────────────────────────
main() {
  # Need root for default prefix
  if [[ "$PREFIX" == "/usr/local" && "$EUID" -ne 0 ]]; then
    # Try sudo
    if command -v sudo &>/dev/null; then
      warn "安装到 $PREFIX/bin 需要管理员权限，将自动使用 sudo..."
      exec sudo "$0" "$@"
    else
      warn "建议以 root 身份运行，或使用 --prefix=\$HOME/.local"
    fi
  fi

  if select_mode; then
    install_full
  else
    install_bash_only
  fi

  post_install_msg
}

main "$@"
