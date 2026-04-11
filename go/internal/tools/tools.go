package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/safety"
)

type Result struct {
	Output string
	Err    error
}

type Runner struct {
	Config   config.Config
	TodoFile string
}

func (r Runner) Dispatch(name string, input json.RawMessage) Result {
	switch name {
	case "Read":
		var args struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Read(args.Path)
		return Result{Output: out, Err: err}
	case "Write":
		var args struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Write(args.Path, args.Content)
		return Result{Output: out, Err: err}
	case "Edit":
		var args struct {
			Path      string `json:"path"`
			OldString string `json:"old_string"`
			NewString string `json:"new_string"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Edit(args.Path, args.OldString, args.NewString)
		return Result{Output: out, Err: err}
	case "Bash":
		var args struct {
			Command string `json:"command"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Bash(args.Command)
		return Result{Output: out, Err: err}
	case "Glob":
		var args struct {
			Pattern string `json:"pattern"`
			Path    string `json:"path"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Glob(args.Pattern, args.Path)
		return Result{Output: out, Err: err}
	case "Grep":
		var args struct {
			Pattern string `json:"pattern"`
			Path    string `json:"path"`
			Glob    string `json:"glob"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.Grep(args.Pattern, args.Path, args.Glob)
		return Result{Output: out, Err: err}
	case "TodoWrite":
		var args struct {
			Todos []struct {
				Content string `json:"content"`
				Status  string `json:"status"`
			} `json:"todos"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.TodoWrite(args.Todos)
		return Result{Output: out, Err: err}
	default:
		return Result{Err: fmt.Errorf("unknown tool: %s", name)}
	}
}

func (r Runner) Read(path string) (string, error) {
	if path == "" {
		return "", errors.New("Error: no path provided")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("Error: file not found: %s", path)
		}
		if os.IsPermission(err) {
			return "", fmt.Errorf("Error: permission denied: %s", path)
		}
		return "", err
	}
	return string(data), nil
}

func (r Runner) Write(path, content string) (string, error) {
	if path == "" {
		return "", errors.New("Error: no path provided")
	}
	if len([]byte(content)) > r.Config.FileWriteMaxBytes {
		return "", fmt.Errorf("Error: content too large for write_file (%d bytes > %d bytes)", len([]byte(content)), r.Config.FileWriteMaxBytes)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return "", err
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("OK: wrote %d bytes to %s", info.Size(), path), nil
}

func (r Runner) Edit(path, oldString, newString string) (string, error) {
	if path == "" {
		return "", errors.New("Error: no path provided")
	}
	if oldString == "" {
		return "", errors.New("Error: empty old_string")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("Error: file not found: %s", path)
		}
		return "", err
	}
	if len(data) > r.Config.FileWriteMaxBytes {
		return "", fmt.Errorf("Error: file too large for edit_file (%d bytes > %d bytes)", len(data), r.Config.FileWriteMaxBytes)
	}
	content := string(data)
	idx := strings.Index(content, oldString)
	if idx < 0 {
		return "", fmt.Errorf("Error: old_string not found in %s", path)
	}
	updated := strings.Replace(content, oldString, newString, 1)
	if updated == "" {
		return "", errors.New("Error: edit produced empty result, reverted")
	}
	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return "", err
	}
	return fmt.Sprintf("OK: edited %s", path), nil
}

func (r Runner) Bash(command string) (string, error) {
	if command == "" {
		return "", errors.New("Error: no command provided")
	}
	if reason := safety.DenyBashCommandReason(command); reason != "" {
		return "", fmt.Errorf("Error: command blocked by bash safety policy (%s)", reason)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(r.Config.ToolTimeoutSecs)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-lc", command)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return out.String() + fmt.Sprintf("\n[... truncated, command timed out after %d seconds ...]", r.Config.ToolTimeoutSecs), nil
	}
	return out.String(), err
}

func (r Runner) Glob(pattern, path string) (string, error) {
	if pattern == "" {
		return "", errors.New("Error: no pattern provided")
	}
	if path == "" {
		path = "."
	}
	if info, err := os.Stat(path); err != nil || !info.IsDir() {
		return "", fmt.Errorf("Error: directory not found: %s", path)
	}
	if _, err := exec.LookPath("rg"); err != nil {
		return "", errors.New("Error: rg is required for glob")
	}
	cmd := exec.Command("rg", "--files", path, "-g", pattern)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = ioDiscard{}
	_ = cmd.Run()
	return out.String(), nil
}

func (r Runner) Grep(pattern, path, glob string) (string, error) {
	if pattern == "" {
		return "", errors.New("Error: no pattern provided")
	}
	if path == "" {
		path = "."
	}
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("Error: path not found: %s", path)
	}
	if _, err := exec.LookPath("rg"); err != nil {
		return "", errors.New("Error: rg is required for grep")
	}
	args := []string{"-n", "--color", "never"}
	if glob != "" {
		args = append(args, "--glob", glob)
	}
	args = append(args, "--", pattern, path)
	cmd := exec.Command("rg", args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = ioDiscard{}
	_ = cmd.Run()
	return out.String(), nil
}

func (r Runner) TodoWrite(todos []struct {
	Content string `json:"content"`
	Status  string `json:"status"`
}) (string, error) {
	if r.TodoFile == "" {
		return "", errors.New("Error: todo file not configured")
	}
	var completed, inProgress int
	lines := make([]string, 0, len(todos))
	for _, todo := range todos {
		if todo.Content == "" {
			return "", errors.New("Error: todo item content is required")
		}
		switch todo.Status {
		case "pending":
			lines = append(lines, "- [ ] "+todo.Content)
		case "in_progress":
			inProgress++
			lines = append(lines, "- [ ] "+todo.Content)
		case "completed":
			completed++
			lines = append(lines, "- [x] "+todo.Content)
		default:
			return "", fmt.Errorf("Error: invalid todo status: %s", todo.Status)
		}
	}
	if inProgress > 1 {
		return "", errors.New("Error: todo_write allows at most one in_progress item")
	}
	checklist := strings.Join(lines, "\n")
	if err := os.WriteFile(r.TodoFile, []byte(checklist+"\n"), 0o644); err != nil {
		return "", err
	}
	return checklist, nil
}

func StripANSI(s string) string {
	re := regexp.MustCompile(`\x1b\[[0-9;]*[[:alpha:]]`)
	return re.ReplaceAllString(s, "")
}

func FormatToolResult(s string, max int) string {
	if len([]byte(s)) <= max {
		return s
	}
	size := len([]byte(s))
	marker := fmt.Sprintf("\n[... omitted, original result was %d bytes ...]\n", size)
	available := max - len([]byte(marker))
	if available < 2 {
		if len(s) > max {
			return s[:max]
		}
		return s
	}
	head := available / 2
	tail := available - head
	if head > len(s) {
		head = len(s)
	}
	if tail > len(s)-head {
		tail = len(s) - head
	}
	return s[:head] + marker + s[len(s)-tail:]
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }
