#!/usr/bin/env bash
# 从 dist/ 目录中的 .deb 构建标准 apt 仓库，输出到 apt-repo/。
# 用法：scripts/build-apt-repo.sh <version> [deb_dir] [out_dir]
#
# 产物结构（部署到 GitHub Pages 的 /debian/ 路径）：
#   pool/main/b/bash-agent/*.deb
#   dists/stable/main/binary-{amd64,arm64,all}/Packages(.gz)
#   dists/stable/Release (+ InRelease, 若提供 GPG_PRIVATE_KEY)
#
# 索引由内嵌 Python 生成（跨平台一致，不依赖 apt-ftparchive）。

set -euo pipefail

VERSION_INPUT="${1:-}"
DEB_DIR="${2:-dist}"
OUT_DIR="${3:-apt-repo}"

if [[ -z "$VERSION_INPUT" ]];then
  echo "用法：$0 <version> [deb_dir] [out_dir]" >&2
  exit 2
fi
VERSION="${VERSION_INPUT#v}"

[[ -d "$DEB_DIR" ]] || { echo "错误：deb 目录不存在：$DEB_DIR" >&2; exit 1; }

REPO_DIR="$OUT_DIR/debian"
POOL_DIR="$REPO_DIR/pool/main/b/bash-agent"
rm -rf "$OUT_DIR"
mkdir -p "$POOL_DIR"

# 1. 收集 .deb 到 pool（排除 *_all.deb，避免 apt 选择只含 bash 版的 all 包）
shopt -s nullglob
debs=( "$DEB_DIR"/bash-agent_*_amd64.deb "$DEB_DIR"/bash-agent_*_arm64.deb )
shopt -u nullglob
if (( ${#debs[@]} == 0 ));then
  echo "错误：$DEB_DIR 中没有架构 .deb 文件（*_amd64.deb / *_arm64.deb）" >&2
  exit 1
fi
for deb in "${debs[@]}"; do
  echo "收录：$(basename "$deb")"
  cp "$deb" "$POOL_DIR/"
done

# 2/3. 生成 Packages 索引与 Release 文件
#    优先使用 apt-ftparchive（官方工具，格式标准）；无则退回 Python fallback
if command -v apt-ftparchive >/dev/null 2>&1; then
  for arch in amd64 arm64; do
    bindir="$REPO_DIR/dists/stable/main/binary-$arch"
    mkdir -p "$bindir"
    ( cd "$REPO_DIR" && apt-ftparchive packages --arch "$arch" pool/main ) > "$bindir/Packages"
    gzip -9n -c "$bindir/Packages" > "$bindir/Packages.gz"
    echo "生成：dists/stable/main/binary-$arch/Packages.gz ($(grep -c '^Package:' "$bindir/Packages") 条)"
  done
  ( cd "$REPO_DIR" && apt-ftparchive release \
      -o APT::FTPArchive::Release::Origin=bash-agent \
      -o APT::FTPArchive::Release::Label=bash-agent \
      -o APT::FTPArchive::Release::Suite=stable \
      -o APT::FTPArchive::Release::Codename=stable \
      -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
      -o APT::FTPArchive::Release::Components=main \
      -o APT::FTPArchive::Release::Description="bash-agent APT repository" \
      dists/stable ) > "$REPO_DIR/dists/stable/Release"
  echo "生成：dists/stable/Release（apt-ftparchive）"
else
  echo "警告：无 apt-ftparchive，使用 Python 生成索引" >&2
  PYTHON_BIN="$(command -v python3 || command -v python)"
  export REPO_DIR VERSION
  "$PYTHON_BIN" - <<'PYEOF'
import gzip, hashlib, os, re, subprocess, sys

repo = os.environ["REPO_DIR"]
version = os.environ["VERSION"]
pool = os.path.join(repo, "pool/main/b/bash-agent")
comp = "main"
dist = os.path.join(repo, "dists/stable")

debs = sorted(f for f in os.listdir(pool) if f.endswith(".deb"))
if not debs:
    sys.exit("错误：pool 中没有 .deb")

def control_fields(deb_path):
    """读取 .deb 的 control 字段（ar + tar 解出 control.tar.*）"""
    import io, tarfile
    with open(deb_path, "rb") as f:
        data = f.read()
    # ar 归档解析
    idx = 8
    members = {}
    while idx + 60 <= len(data):
        name = data[idx:idx+16].decode().strip()
        size = int(data[idx+48:idx+58].decode().strip())
        idx += 60
        members[name] = data[idx:idx+size]
        idx += size + (size % 2)
    ctl = None
    for key in ("control.tar.gz", "control.tar.xz", "control.tar.zst"):
        if key in members:
            tf = tarfile.open(fileobj=io.BytesIO(members[key]), mode="r:*")
            for m in tf.getmembers():
                if os.path.basename(m.name) == "control":
                    ctl = tf.extractfile(m).read().decode()
            break
    if ctl is None:
        sys.exit(f"错误：无法读取 {deb_path} 的 control")
    fields = {}
    for line in ctl.splitlines():
        if line and not line.startswith(" "):
            k, _, v = line.partition(":")
            fields[k] = v.strip()
        elif line.startswith(" ") and "Description" in fields:
            fields["Description"] += "\n" + line.strip()
    return fields

def pkg_entry(relpath):
    full = os.path.join(repo, relpath)
    with open(full, "rb") as f:
        data = f.read()
    ctl = control_fields(full)
    size = len(data)
    sha256 = hashlib.sha256(data).hexdigest()
    sha1 = hashlib.sha1(data).hexdigest()
    md5 = hashlib.md5(data).hexdigest()
    lines = [
        f"Package: {ctl.get('Package', 'bash-agent')}",
        f"Version: {ctl.get('Version', version)}",
    ]
    if ctl.get("Architecture"):
        lines.append(f"Architecture: {ctl['Architecture']}")
    if ctl.get("Depends"):
        lines.append(f"Depends: {ctl['Depends']}")
    if ctl.get("Maintainer"):
        lines.append(f"Maintainer: {ctl['Maintainer']}")
    if ctl.get("Description"):
        lines.append(f"Description: {ctl['Description'].splitlines()[0]}")
    lines += [
        f"Filename: {relpath}",
        f"Size: {size}",
        f"MD5sum: {md5}",
        f"SHA1: {sha1}",
        f"SHA256: {sha256}",
    ]
    return "\n".join(lines) + "\n\n", size, md5, sha1, sha256

# 按架构生成 Packages
entries_by_arch = {}
for deb in debs:
    rel = os.path.join("pool/main/b/bash-agent", deb)
    entry, size, md5, sha1, sha256 = pkg_entry(rel)
    arch = control_fields(os.path.join(repo, rel)).get("Architecture", "amd64")
    entries_by_arch.setdefault(arch, []).append((rel, entry, size, md5, sha1, sha256))

archs = sorted(entries_by_arch)
for arch in archs:
    bindir = os.path.join(dist, comp, f"binary-{arch}")
    os.makedirs(bindir, exist_ok=True)
    pkgs_path = os.path.join(bindir, "Packages")
    with open(pkgs_path, "w") as f:
        for _, entry, *_ in entries_by_arch[arch]:
            f.write(entry)
    with open(pkgs_path + ".gz", "wb") as f:
        with open(pkgs_path, "rb") as raw:
            f.write(gzip.compress(raw.read()))
    print(f"生成：dists/stable/{comp}/binary-{arch}/Packages.gz ({len(entries_by_arch[arch])} 条)")

# 生成 Release 及校验和
def file_info(path):
    with open(path, "rb") as f:
        data = f.read()
    return len(data), hashlib.md5(data).hexdigest(), hashlib.sha1(data).hexdigest(), hashlib.sha256(data).hexdigest()

import datetime
release_extra = {
    "Origin": "bash-agent",
    "Label": "bash-agent",
    "Suite": "stable",
    "Codename": "stable",
    "Date": datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S UTC"),
    "Architectures": " ".join(archs),
    "Components": comp,
    "Description": "bash-agent APT repository",
}

indices = []
for arch in archs:
    for suffix in ("Packages", "Packages.gz"):
        p = os.path.join(dist, comp, f"binary-{arch}", suffix)
        indices.append((f"{comp}/binary-{arch}/{suffix}",) + file_info(p))

md5s, sha1s, sha256s = [], [], []
for path, size, md5, sha1, sha256 in indices:
    md5s.append(f"  {md5} {size:11} {path}\n")
    sha1s.append(f"  {sha1} {size:11} {path}\n")
    sha256s.append(f"  {sha256} {size:11} {path}\n")

with open(os.path.join(dist, "Release"), "w") as f:
    for k, v in release_extra.items():
        f.write(f"{k}: {v}\n")
    f.write("\nMD5Sum:\n" + "".join(md5s))
    f.write("\nSHA1:\n" + "".join(sha1s))
    f.write("\nSHA256:\n" + "".join(sha256s))

print("生成：dists/stable/Release")
print("APT 仓库构建完成：", repo)
PYEOF
fi

# 4. 可选 GPG 签名
if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --yes --import 2>/dev/null || \
  printf '%s\n' "$GPG_PRIVATE_KEY" | base64 -d 2>/dev/null | gpg --batch --yes --import 2>/dev/null || true
  key_id="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5; exit}')"
  if [[ -n "$key_id" ]]; then
    if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
      gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
        -abs -o "$REPO_DIR/dists/stable/InRelease" "$REPO_DIR/dists/stable/Release"
    else
      gpg --batch --yes -abs -o "$REPO_DIR/dists/stable/InRelease" "$REPO_DIR/dists/stable/Release"
    fi
    echo "已签名：$REPO_DIR/dists/stable/InRelease (key $key_id)"
  else
    echo "警告：GPG_PRIVATE_KEY 导入失败，仓库未签名" >&2
  fi
else
  echo "提示：未提供 GPG_PRIVATE_KEY，仓库未签名（安装需 trusted=yes）" >&2
fi
