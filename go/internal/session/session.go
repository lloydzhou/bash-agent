package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Paths struct {
	BaseDir      string
	SessionDir   string
	Conversation string
	Events       string
	Summary      string
	Plan         string
	PlanDraft    string
	Stats        string
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
	sessionDir := filepath.Join(projectDir, sessionID)
	return Paths{
		BaseDir:      projectDir,
		SessionDir:   sessionDir,
		Conversation: filepath.Join(sessionDir, "conversation.jsonl"),
		Events:       filepath.Join(sessionDir, "events.jsonl"),
		Summary:      filepath.Join(sessionDir, "summary.txt"),
		Plan:         filepath.Join(sessionDir, "plan.md"),
		PlanDraft:    filepath.Join(sessionDir, "plan.draft"),
		Stats:        filepath.Join(sessionDir, "stats.json"),
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
		if !entry.IsDir() {
			continue
		}
		if mod, ok := sessionActivityModTime(filepath.Join(dir, entry.Name())); ok && mod > newestMod {
			newestMod = mod
			newest = entry.Name()
		}
	}
	if newest == "" {
		return "", fmt.Errorf("no sessions found")
	}
	return newest, nil
}

func sessionActivityModTime(sessionDir string) (int64, bool) {
	events := filepath.Join(sessionDir, "events.jsonl")
	if info, err := os.Stat(events); err == nil {
		return info.ModTime().UnixNano(), true
	}
	if info, err := os.Stat(sessionDir); err == nil {
		return info.ModTime().UnixNano(), true
	}
	return 0, false
}
