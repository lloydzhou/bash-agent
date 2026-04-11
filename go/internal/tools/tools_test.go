package tools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lloydzhou/bash-agent/internal/config"
)

func TestEditMatchesBashErrors(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(path, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := Runner{Config: config.Default()}
	if _, err := r.Edit(path, "", "x"); err == nil || err.Error() != "Error: empty old_string" {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := r.Edit(path, "zzz", "x"); err == nil || !strings.Contains(err.Error(), "Error: old_string not found in "+path) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDispatchTodoWrite(t *testing.T) {
	dir := t.TempDir()
	todoFile := filepath.Join(dir, "todo.md")
	r := Runner{Config: config.Default(), TodoFile: todoFile}
	input := json.RawMessage(`{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"pending"}]}`)
	result := r.Dispatch("TodoWrite", input)
	if result.Err != nil {
		t.Fatal(result.Err)
	}
	if result.Output != "- [x] one\n- [ ] two" {
		t.Fatalf("unexpected checklist: %q", result.Output)
	}
}
