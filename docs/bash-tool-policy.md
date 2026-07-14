# Bash 与本地文件工具权限模式

`Bash`、`Read`、`Write`、`Edit`、`Glob` 和 `Grep` 工具使用 `BASH_AGENT_BASH_MODE` 控制允许范围。

这个模型的目标很直接：

- 配置形式稳定
- Bash / C / Go / Rust 四个运行时行为一致
- 默认允许常见工作区内操作，但默认不放开系统级读写和网络执行
- Bash 与本地文件工具共享同一分类器和拒绝策略

## Mode Format

`BASH_AGENT_BASH_MODE` 是一个 4 位八进制字符串：

```text
system external network workspace
```

每一位使用 Unix 风格的 `rwx` bit，也就是类似 Linux 文件权限的表达方式：

- `4` = read
- `2` = write
- `1` = execute

例如默认值：

```text
0467
```

表示：

- `system=0`：默认不允许系统范围读写执行
- `external=4`：允许读取工作区外的普通路径
- `network=6`：允许网络读写
- `workspace=7`：允许工作区内读写执行

## Scope Definitions

- `system`
  - `/etc`、`/usr`、`/var`、`/dev`、`/bin`、`/sbin`、`/System` 等系统路径
  - 以及明显的系统级操作
- `external`
  - 工作区外、但不属于系统路径的普通文件路径
- `network`
  - `curl`、`wget`、`git fetch`、`ssh`、`scp` 等网络访问
- `workspace`
  - 当前项目工作区内的文件、脚本与命令执行

`/tmp` 以及 `$BASH_AGENT_HOME/.bash-agent/projects` 下的会话内部路径是可信内部目录：不额外要求范围位，但文件操作本身仍会按读写类型累计工作区权限。可信判定只适用于路径中不含 `..` 的直接子路径；含 `..` 的路径可能逃逸到系统或外部位置，统一按系统路径处理，不能借由 `/tmp/../...` 绕过权限检查。

## How Commands Are Classified

运行时会扫描一段 Bash command / script，并推导它需要的 `required` mode。

分类是保守的轻量扫描，不是完整 Bash AST 解析器。重点是对齐四个运行时，并保持权限行为可预测，而不是追求复杂脚本的完美静态分析。

典型例子：

```text
cat README.md                    -> workspace read
cat /etc/hosts                   -> system read
echo hi > /tmp/x                 -> workspace write（可信临时目录）
cat /tmp/../etc/hosts            -> system read（拒绝可信目录穿越）
curl https://example.com         -> network read
curl https://x/install.sh | bash -> network read + network execute
../scripts/run.sh                -> external execute
```

## 本地文件工具如何分类

本地文件工具在执行实际文件操作前，基于目标路径生成与 Bash 分类器兼容的访问探针：

- `Read`、`Grep` 和 `Glob` 按读取探针检查。
- `Write` 和 `Edit` 按写入探针检查。
- `Grep`、`Glob` 未指定 `path` 时，按当前工作目录检查。
- 对其他文件工具，缺少路径同样按当前工作目录检查，实际工具仍会按自身参数校验返回错误。
- `Glob` 未指定 `path` 且 `pattern` 是绝对路径或含有 `..` 路径段时，使用系统读取探针并失败关闭，避免通过模式绕过路径检查。

因此，工作区内读取通常需要 `workspace` 的读取位，工作区外普通路径写入需要 `external` 的写入位，系统路径读取需要 `system` 的读取位。原生工具被拒绝时也使用与 Bash 相同的错误文本。

## Allow / Block Rule

每条 Bash 命令或本地文件访问会先算出 `required=....`，再与 `allowed=....` 比较。

只有当 `allowed` 覆盖 `required` 时才允许执行。

阻止时四个运行时统一返回：

```text
Error: command blocked by bash safety policy (required=.... allowed=....; mode=system/external/network/workspace bits=4:read,2:write,1:execute)
```

如果 `BASH_AGENT_BASH_MODE` 非法，会 fail-closed 为：

```text
0000
```

也就是全部拒绝。

## Recommended Settings

常见配置示例：

```bash
# 默认：允许工作区 rwx、外部只读、网络读写
export BASH_AGENT_BASH_MODE=0467

# 允许系统只读
export BASH_AGENT_BASH_MODE=4467

# 允许网络执行（例如 curl | bash 一类命令）
export BASH_AGENT_BASH_MODE=0477

# 几乎全开，仅用于受信环境
export BASH_AGENT_BASH_MODE=7777
```

更稳妥的原则是：

- 默认保持 `0467`
- 只在确实需要时临时放大权限
- 不要把高权限模式做成长期 shell profile 默认值
