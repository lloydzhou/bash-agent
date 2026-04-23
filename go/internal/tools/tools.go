package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/prompt"
	"github.com/lloydzhou/bash-agent/internal/safety"
)

type Result struct {
	Output string
	Err    error
}

type Runner struct {
	Config   config.Config
	TodoFile string
	Cwd      string
	Home     string
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
	case "Skill":
		var args struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.ToolSkill(args.Name)
		return Result{Output: out, Err: err}
	case "WebSearch":
		var args struct {
			Query string `json:"query"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.WebSearch(args.Query)
		return Result{Output: out, Err: err}
	case "WebFetch":
		var args struct {
			URL string `json:"url"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return Result{Err: err}
		}
		out, err := r.WebFetch(args.URL)
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
	// Preserve existing file permissions, default to 0o644 for new files
	perm := os.FileMode(0o644)
	if info, err := os.Stat(path); err == nil {
		perm = info.Mode().Perm()
	}
	if err := os.WriteFile(path, []byte(content), perm); err != nil {
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
		return "", fmt.Errorf("Error: old_string not found in %s. Hint: Read the file and copy exact bytes (including whitespace/indent/newlines) before retrying Edit.", path)
	}
	updated := strings.Replace(content, oldString, newString, 1)
	if updated == "" {
		return "", errors.New("Error: edit produced empty result, reverted")
	}
	// Preserve original file permissions
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("Error: cannot stat file: %s", path)
	}
	perm := info.Mode().Perm()
	diffOut, diffErr := unifiedDiffColor(path, content, updated)
	if err := os.WriteFile(path, []byte(updated), perm); err != nil {
		return "", err
	}
	if diffErr != nil {
		return "", diffErr
	}
	// Match bash tool_edit: output = summary_line + "\n" + colorized_diff + "\n"
	added, removed := countDiffLines(diffOut)
	summary := fmt.Sprintf("Edit(%s) [+%d -%d lines]", path, added, removed)
	if diffOut == "" {
		return fmt.Sprintf("Edit(%s) [no changes]", path), nil
	}
	return summary + "\n" + diffOut + "\n", nil
}

func unifiedDiffColor(path, oldContent, newContent string) (string, error) {
	oldFile, err := os.CreateTemp("", "edit-old-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(oldFile.Name())
	defer oldFile.Close()
	newFile, err := os.CreateTemp("", "edit-new-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(newFile.Name())
	defer newFile.Close()
	if _, err := oldFile.WriteString(oldContent); err != nil {
		return "", err
	}
	if _, err := newFile.WriteString(newContent); err != nil {
		return "", err
	}
	label := strings.TrimPrefix(path, "/")
	// Try with --color=always first (match bash tool_edit behavior)
	out, err := exec.Command("diff", "-u", "--color=always", "--label", "a/"+label, "--label", "b/"+label, oldFile.Name(), newFile.Name()).CombinedOutput()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// diff returns 1 when differences found — check if --color was unsupported
			if strings.Contains(string(out), "unsupported --color") || strings.Contains(string(out), "unrecognized option '--color'") {
				// Fallback: no color
				out2, err2 := exec.Command("diff", "-u", "--label", "a/"+label, "--label", "b/"+label, oldFile.Name(), newFile.Name()).CombinedOutput()
				if err2 != nil {
					if exitErr2, ok := err2.(*exec.ExitError); ok && exitErr2.ExitCode() == 1 {
						return string(out2), nil
					}
					return "", fmt.Errorf("Error: diff failed")
				}
				return string(out2), nil
			}
			return string(out), nil
		}
		return "", fmt.Errorf("Error: diff failed")
	}
	return string(out), nil
}

// countDiffLines counts added/removed lines in unified diff output (works with ANSI color codes).
func countDiffLines(diff string) (added, removed int) {
	for _, line := range strings.Split(diff, "\n") {
		// Strip ANSI escape sequences for prefix check
		stripped := stripAnsi(line)
		if strings.HasPrefix(stripped, "+") && !strings.HasPrefix(stripped, "+++") {
			added++
		}
		if strings.HasPrefix(stripped, "-") && !strings.HasPrefix(stripped, "---") {
			removed++
		}
	}
	return
}

// stripAnsi removes ANSI escape sequences from a string.
func stripAnsi(s string) string {
	var out strings.Builder
	out.Grow(len(s))
	i := 0
	for i < len(s) {
		if s[i] == '\033' && i+1 < len(s) && s[i+1] == '[' {
			// Skip CSI sequence: ESC [ ... final_byte
			j := i + 2
			for j < len(s) && ((s[j] >= 0x30 && s[j] <= 0x3f) || (s[j] >= 0x20 && s[j] <= 0x2f)) {
				j++
			}
			if j < len(s) && s[j] >= 0x40 && s[j] <= 0x7e {
				j++
			}
			i = j
		} else {
			out.WriteByte(s[i])
			i++
		}
	}
	return out.String()
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

func (r Runner) ToolSkill(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("Error: no skill name provided")
	}
	skillFile := prompt.ResolveSkillFile(r.Cwd, r.Home, name)
	if skillFile == "" {
		return "", fmt.Errorf("Error: skill not found: %s", name)
	}
	data, err := os.ReadFile(skillFile)
	if err != nil {
		return "", err
	}
	baseDir := filepath.Dir(skillFile)
	content := strings.ReplaceAll(string(data), "${BASH_AGENT_SKILL_DIR}", baseDir)
	return fmt.Sprintf("Skill: %s\nBase directory: %s\n\n%s", name, baseDir, content), nil
}

func (r Runner) WebSearch(query string) (string, error) {
	if query == "" {
		return "", errors.New("Error: no query provided")
	}
	apiKey := os.Getenv("JINA_API_KEY")
	req, err := http.NewRequest("GET", "https://s.jina.ai/", nil)
	if err != nil {
		return "", fmt.Errorf("Error: creating search request: %w", err)
	}
	q := req.URL.Query()
	q.Set("q", query)
	req.URL.RawQuery = q.Encode()
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	req.Header.Set("X-Respond-With", "no-content")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req = req.WithContext(ctx)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("Error: search request failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("Error: reading search response: %w", err)
	}
	return string(body), nil
}

func (r Runner) WebFetch(url string) (string, error) {
	if url == "" {
		return "", errors.New("Error: no url provided")
	}
	apiKey := os.Getenv("JINA_API_KEY")
	req, err := http.NewRequest("GET", "https://r.jina.ai/", nil)
	if err != nil {
		return "", fmt.Errorf("Error: creating fetch request: %w", err)
	}
	q := req.URL.Query()
	q.Set("url", url)
	req.URL.RawQuery = q.Encode()
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req = req.WithContext(ctx)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("Error: fetch request failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("Error: reading fetch response: %w", err)
	}
	return string(body), nil
}

func FormatToolResult(s string, max int) string {
	b := []byte(s)
	if len(b) <= max {
		return s
	}
	size := len(b)
	marker := fmt.Sprintf("\n\n[... truncated: showing first/last portions of %d bytes ...]\n\n", size)
	markerLen := len(marker) + 20 // extra room for size digits
	tailLines := 5
	tailText := lastNLines(s, tailLines)
	tailLen := len(tailText)
	headLen := max - markerLen - tailLen
	if headLen <= 0 {
		headLen = max / 2
	}
	if headLen > size {
		headLen = size
	}
	headText := string(b[:headLen])
	return headText + marker + tailText
}

func lastNLines(s string, n int) string {
	count := 0
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '\n' {
			count++
			if count >= n {
				return s[i+1:]
			}
		}
	}
	return s
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }
