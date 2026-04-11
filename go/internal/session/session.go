package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Paths struct {
	BaseDir      string
	Conversation string
	Events       string
	Summary      string
	Todo         string
}

func ProjectKey(cwd string) string {
	clean := strings.TrimPrefix(filepath.Clean(cwd), string(filepath.Separator))
	clean = strings.ReplaceAll(clean, string(filepath.Separator), "-")
	var b strings.Builder
	b.WriteByte('-')
	lastDash := false
	for _, r := range clean {
		ok := (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-'
		if !ok {
			r = '-'
		}
		if r == '-' {
			if lastDash {
				continue
			}
			lastDash = true
		} else {
			lastDash = false
		}
		b.WriteRune(r)
	}
	return strings.TrimRight(b.String(), "-")
}

func PathsFor(home, cwd, sessionID string) Paths {
	projectDir := filepath.Join(home, ".bash-agent", "projects", ProjectKey(cwd))
	base := filepath.Join(projectDir, sessionID)
	return Paths{
		BaseDir:      projectDir,
		Conversation: base + ".jsonl",
		Events:       base + ".events.jsonl",
		Summary:      base + ".summary.txt",
		Todo:         base + ".todo.md",
	}
}

func EnsureDir(path string) error {
	return os.MkdirAll(path, 0o755)
}

func ContinueSession(home, cwd string) (string, error) {
	dir := filepath.Join(home, ".bash-agent", "projects", ProjectKey(cwd))
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var newest string
	var newestMod int64 = -1
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".jsonl") || strings.HasSuffix(name, ".events.jsonl") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if mod := info.ModTime().UnixNano(); mod > newestMod {
			newestMod = mod
			newest = strings.TrimSuffix(name, ".jsonl")
		}
	}
	if newest == "" {
		return "", fmt.Errorf("no sessions found")
	}
	return newest, nil
}
