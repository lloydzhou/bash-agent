package session

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestContinueSessionUsesEventsMtime(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(cwd, 0o755); err != nil {
		t.Fatal(err)
	}

	projectDir := filepath.Join(home, ".bash-agent", "projects", ProjectKey(cwd))
	aDir := filepath.Join(projectDir, "session-a")
	bDir := filepath.Join(projectDir, "session-b")
	if err := os.MkdirAll(aDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(bDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(aDir, "events.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bDir, "events.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	if err := os.Chtimes(filepath.Join(bDir, "events.jsonl"), now.Add(-2*time.Hour), now.Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(aDir, "events.jsonl"), now.Add(2*time.Hour), now.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}

	got, err := ContinueSession(home, cwd)
	if err != nil {
		t.Fatal(err)
	}
	if got != "session-a" {
		t.Fatalf("expected session-a, got %s", got)
	}
}
