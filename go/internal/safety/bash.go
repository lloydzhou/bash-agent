package safety

import "regexp"

var deviceWriteRE = regexp.MustCompile(`(^|[[:space:]])(of=|>|1>|>>|1>>)[[:space:]]*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([[:space:]]|$)`)

func DenyBashCommandReason(cmd string) string {
	if cmd == "" {
		return ""
	}
	switch {
	case hasAnyPrefix(cmd, "sudo ", "shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk"):
		return "blocked dangerous command prefix"
	case containsAny(cmd, "rm -rf /", "rm -fr /"):
		return "blocked destructive root deletion pattern"
	case deviceWriteRE.MatchString(cmd):
		return "blocked device write pattern"
	case containsAll(cmd, "find ", " -delete"):
		return "blocked destructive find -delete pattern"
	case containsAny(cmd, ":(){:|:&};:"):
		return "blocked fork bomb pattern"
	default:
		return ""
	}
}

func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if len(s) >= len(prefix) && s[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

func containsAny(s string, parts ...string) bool {
	for _, part := range parts {
		if part != "" && regexp.MustCompile(regexp.QuoteMeta(part)).FindStringIndex(s) != nil {
			return true
		}
	}
	return false
}

func containsAll(s string, parts ...string) bool {
	for _, part := range parts {
		if !containsAny(s, part) {
			return false
		}
	}
	return true
}
