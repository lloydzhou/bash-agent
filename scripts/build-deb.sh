#!/usr/bin/env bash
# build-deb.sh — Build a .deb package from pre-built artifacts
# Usage: ./scripts/build-deb.sh <version> <dist-dir> <output-dir>
#   version    e.g. "4.2.5" (without 'v' prefix)
#   dist-dir   directory containing pre-built binaries (default: dist)
#   output-dir where to write the .deb (default: dist)
#
# The script expects these files in dist-dir:
#   agent.sh, goagent-linux-amd64, rustagent-linux-amd64,
#   cagent-linux-amd64, tcode
#
# It produces architecture-specific .deb packages:
#   bash-agent_<version>_all.deb           (bash-only, any arch)
#   bash-agent_<version>_amd64.deb         (all binaries, amd64)
#   bash-agent_<version>_arm64.deb         (all binaries, arm64) — if arm64 artifacts exist

set -euo pipefail

VERSION="${1:?Usage: build-deb.sh <version> [dist-dir] [output-dir]}"
VERSION="${VERSION#v}"  # strip leading 'v' if present
DIST_DIR="${2:-dist}"
OUTPUT_DIR="${3:-dist}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Helper: build a single .deb ---
build_deb() {
  local arch="$1"        # all | amd64 | arm64
  local pkg_name="bash-agent"
  local pkg_dir
  pkg_dir="$(mktemp -d)"

  echo "==> Building ${pkg_name}_${VERSION}_${arch}.deb ..."

  # ── DEBIAN/control ──
  mkdir -p "$pkg_dir/DEBIAN"
  cat > "$pkg_dir/DEBIAN/control" << EOF
Package: ${pkg_name}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${arch}
Depends: bash (>= 4.0), gawk, curl, ripgrep
Recommends: jq
Maintainer: Lloyd Zhou <lloydzhou@users.noreply.github.com>
Description: Minimal AI coding agent runtime
 A minimal AI coding agent runtime written in pure bash + awk.
 Supports Claude and OpenAI compatible providers.
 Features: zero runtime dependencies, cache-aware compression,
 session persistence, skill system, sub-agent orchestration.
Homepage: https://github.com/nicepkg/bash-agent
EOF

  # ── DEBIAN/postinst ──
  cat > "$pkg_dir/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
# Update alternatives so 'agent' points to bash-agent
if command -v update-alternatives &>/dev/null; then
  update-alternatives --install /usr/bin/agent agent /usr/local/bin/bash-agent 50 2>/dev/null || true
fi
# Show welcome message on first install
if [ "$1" = "configure" ] && [ -z "$2" ]; then
  echo ""
  echo "✓ bash-agent installed successfully!"
  echo "  Run: bash-agent"
  echo "  Docs: https://github.com/nicepkg/bash-agent"
  echo ""
fi
EOF
  chmod 755 "$pkg_dir/DEBIAN/postinst"

  # ── DEBIAN/prerm ──
  cat > "$pkg_dir/DEBIAN/prerm" << 'EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] && command -v update-alternatives &>/dev/null; then
  update-alternatives --remove agent /usr/local/bin/bash-agent 2>/dev/null || true
fi
EOF
  chmod 755 "$pkg_dir/DEBIAN/prerm"

  # ── Install binaries ──
  local bindir="$pkg_dir/usr/local/bin"
  mkdir -p "$bindir"

  # bash-agent (agent.sh) — always present
  if [[ -f "$DIST_DIR/agent.sh" ]]; then
    install -m 755 "$DIST_DIR/agent.sh" "$bindir/bash-agent"
  else
    echo "Warning: $DIST_DIR/agent.sh not found, skipping" >&2
  fi

  # Architecture-specific binaries
  if [[ "$arch" != "all" ]]; then
    local suffix="${arch}"
    # goagent
    if [[ -f "$DIST_DIR/goagent-linux-${suffix}" ]]; then
      install -m 755 "$DIST_DIR/goagent-linux-${suffix}" "$bindir/goagent"
    fi
    # rustagent
    if [[ -f "$DIST_DIR/rustagent-linux-${suffix}" ]]; then
      install -m 755 "$DIST_DIR/rustagent-linux-${suffix}" "$bindir/rustagent"
    fi
    # cagent
    if [[ -f "$DIST_DIR/cagent-linux-${suffix}" ]]; then
      install -m 755 "$DIST_DIR/cagent-linux-${suffix}" "$bindir/cagent"
    fi
  fi

  # tcode — always include
  if [[ -f "$DIST_DIR/tcode" ]]; then
    install -m 755 "$DIST_DIR/tcode" "$bindir/tcode"
  fi

  # ── Documentation ──
  local docdir="$pkg_dir/usr/share/doc/bash-agent"
  mkdir -p "$docdir"
  [[ -f "$ROOT_DIR/README.md" ]]      && install -m 644 "$ROOT_DIR/README.md" "$docdir/"
  [[ -f "$ROOT_DIR/CHANGELOG.md" ]]   && install -m 644 "$ROOT_DIR/CHANGELOG.md" "$docdir/"
  [[ -f "$ROOT_DIR/LICENSE" ]]        && install -m 644 "$ROOT_DIR/LICENSE" "$docdir/"

  # ── Build .deb ──
  mkdir -p "$OUTPUT_DIR"
  local deb_file="${OUTPUT_DIR}/${pkg_name}_${VERSION}_${arch}.deb"
  dpkg-deb --root-owner-group --build "$pkg_dir" "$deb_file"
  rm -rf "$pkg_dir"

  local size
  size=$(du -h "$deb_file" | cut -f1)
  echo "    -> $deb_file ($size)"
}

# ── Main ──
echo "Building .deb packages for bash-agent v${VERSION}..."
echo "  Source: $DIST_DIR"
echo "  Output: $OUTPUT_DIR"
echo ""

# 1. bash-only package (architecture: all)
build_deb "all"

# 2. Full amd64 package (if linux-amd64 binaries exist)
if [[ -f "$DIST_DIR/goagent-linux-amd64" ]] || [[ -f "$DIST_DIR/cagent-linux-amd64" ]]; then
  build_deb "amd64"
fi

# 3. Full arm64 package (if linux-arm64 binaries exist)
if [[ -f "$DIST_DIR/goagent-linux-arm64" ]] || [[ -f "$DIST_DIR/cagent-linux-arm64" ]]; then
  build_deb "arm64"
fi

echo ""
echo "✓ All .deb packages built successfully."
echo ""
echo "Install with:"
echo "  sudo dpkg -i bash-agent_${VERSION}_all.deb      # bash-only"
echo "  sudo dpkg -i bash-agent_${VERSION}_amd64.deb     # all binaries (amd64)"
echo "  sudo dpkg -i bash-agent_${VERSION}_arm64.deb     # all binaries (arm64)"
