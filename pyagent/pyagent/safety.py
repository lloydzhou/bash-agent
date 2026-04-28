"""Bash command safety checks."""
import re

_DANGEROUS_PREFIXES = ("sudo ", "shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk")
_DEVICE_WRITE_RE = re.compile(
    r'(^|\s)(of=|>|1>|>>|1>>)\s*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|'
    r'nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)(\s|$)'
)


def deny_bash_command_reason(cmd: str) -> str | None:
    """Return reason string if command is blocked, else None."""
    if not cmd:
        return None
    for prefix in _DANGEROUS_PREFIXES:
        if cmd.startswith(prefix):
            return "blocked dangerous command prefix"
    if "rm -rf /" in cmd or "rm -fr /" in cmd:
        return "blocked destructive root deletion pattern"
    if _DEVICE_WRITE_RE.search(cmd):
        return "blocked device write pattern"
    if "find " in cmd and " -delete" in cmd:
        return "blocked destructive find -delete pattern"
    if ":(){:|:&};:" in cmd:
        return "blocked fork bomb pattern"
    return None
