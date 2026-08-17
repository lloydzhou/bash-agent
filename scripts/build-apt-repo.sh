#!/usr/bin/env bash
# 从 dist/ 目录中的 .deb 构建标准 apt 仓库，输出到 apt-repo/。
# 用法：scripts/build-apt-repo.sh <version> [deb_dir] [out_dir] [repo_slug]
#
# .deb 文件存放于仓库内 pool/ 目录（部署走 Pages artifact，不进任何 git 分支）。
# Packages 索引的 Filename 字段使用相对路径（apt 所有版本均不支持绝对 URL，
# 会将其直接拼接在源 base URL 之后导致 404）。
#
# 产物结构（部署到 GitHub Pages 的 /debian/ 路径）：
#   dists/stable/main/binary-{amd64,arm64}/Packages(.gz)
#   dists/stable/Release (+ InRelease, 若提供 GPG_PRIVATE_KEY)
#
# 索引由内嵌 Python 生成（跨平台一致，不依赖 apt-ftparchive）。

set -euo pipefail

VERSION_INPUT="${1:-}"
DEB_DIR="${2:-dist}"
OUT_DIR="${3:-apt-repo}"
REPO_SLUG="${4:-lloydzhou/bash-agent}"

if [[ -z "$VERSION_INPUT" ]];then
  echo "用法：$0 <version> [deb_dir] [out_dir] [repo_slug]" >&2
  exit 2
fi
VERSION="${VERSION_INPUT#v}"

[[ -d "$DEB_DIR" ]] || { echo "错误：deb 目录不存在：$DEB_DIR" >&2; exit 1; }

# .deb 与索引同源托管（pool/），Filename 使用相对路径
REPO_DIR="$OUT_DIR/debian"
rm -rf "$OUT_DIR"
mkdir -p "$REPO_DIR/dists/stable"

# 收集 .deb 文件名（只收架构包）
shopt -s nullglob
debs=( "$DEB_DIR"/bash-agent_*_amd64.deb "$DEB_DIR"/bash-agent_*_arm64.deb )
shopt -u nullglob
if (( ${#debs[@]} == 0 ));then
  echo "错误：$DEB_DIR 中没有架构 .deb 文件（*_amd64.deb / *_arm64.deb）" >&2
  exit 1
fi

# 生成 Packages 索引（Python，跨平台一致）
# Filename 字段指向 GitHub Releases URL，.deb 不写入 gh-pages
PYTHON_BIN="$(command -v python3 || command -v python)"
export REPO_DIR VERSION DEB_DIR

"$PYTHON_BIN" - <<'PYEOF'
import gzip, hashlib, os, io, shutil, tarfile, sys, datetime

repo       = os.environ["REPO_DIR"]
version    = os.environ["VERSION"]
deb_dir    = os.environ["DEB_DIR"]
comp       = "main"
dist       = os.path.join(repo, "dists/stable")

debs = sorted(f for f in os.listdir(deb_dir) if f.endswith(".deb") and "_all" not in f)
if not debs:
    sys.exit("错误：没有架构 .deb")

def control_fields(deb_path):
    """读取 .deb 的 control 字段（ar + tar 解出 control.tar.*）"""
    with open(deb_path, "rb") as f:
        data = f.read()
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

def pkg_entry(deb_name):
    full = os.path.join(deb_dir, deb_name)
    with open(full, "rb") as f:
        data = f.read()
    ctl = control_fields(full)
    size = len(data)
    sha256 = hashlib.sha256(data).hexdigest()
    sha1 = hashlib.sha1(data).hexdigest()
    md5 = hashlib.md5(data).hexdigest()
    # 相对路径（相对于 apt 源 base URL），.deb 复制到 pool/main/
    filename_rel = f"pool/main/{deb_name}"
    # 复制 .deb 到 pool（与索引同源，所有 apt 版本可下载）
    pool_dir = os.path.join(repo, "pool", comp)
    os.makedirs(pool_dir, exist_ok=True)
    shutil.copy2(full, os.path.join(pool_dir, deb_name))
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
        f"Filename: {filename_rel}",
        f"Size: {size}",
        f"MD5sum: {md5}",
        f"SHA1: {sha1}",
        f"SHA256: {sha256}",
    ]
    return "\n".join(lines) + "\n\n"

# 按架构生成 Packages
entries_by_arch = {}
for deb in debs:
    entry = pkg_entry(deb)
    arch = control_fields(os.path.join(deb_dir, deb)).get("Architecture", "amd64")
    entries_by_arch.setdefault(arch, []).append(entry)

archs = sorted(entries_by_arch)
for arch in archs:
    bindir = os.path.join(dist, comp, f"binary-{arch}")
    os.makedirs(bindir, exist_ok=True)
    pkgs_path = os.path.join(bindir, "Packages")
    with open(pkgs_path, "w") as f:
        for entry in entries_by_arch[arch]:
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

# 生成空的 cnf/Commands-<arch>（apt ≥2.4 会请求该文件，Release 无条目会报
# "W: No Hash entry in Release file"）
cnf_dir = os.path.join(dist, comp, "cnf")
os.makedirs(cnf_dir, exist_ok=True)
for arch in archs:
    p = os.path.join(cnf_dir, f"Commands-{arch}")
    open(p, "w").close()
    indices.append((f"{comp}/cnf/Commands-{arch}",) + file_info(p))

md5s, sha1s, sha256s = [], [], []
for path, size, md5, sha1, sha256 in indices:
    md5s.append(f"  {md5} {size:11} {path}\n")
    sha1s.append(f"  {sha1} {size:11} {path}\n")
    sha256s.append(f"  {sha256} {size:11} {path}\n")

with open(os.path.join(dist, "Release"), "w") as f:
    for k, v in release_extra.items():
        f.write(f"{k}: {v}\n")
    # 注意：hash 块之间不能有空行——apt 的 tagfile 解析器遇空行即认为
    # 记录结束，空行后的块会被丢弃（导致 "W: No Hash entry" 警告）
    f.write("MD5Sum:\n" + "".join(md5s))
    f.write("SHA1:\n" + "".join(sha1s))
    f.write("SHA256:\n" + "".join(sha256s))

print("生成：dists/stable/Release")
print("APT 仓库构建完成：", repo)
PYEOF

# 可选 GPG 签名
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
