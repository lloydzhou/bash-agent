package config

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type OutputFormat string

const (
	OutputHuman      OutputFormat = "human"
	OutputStreamJSON OutputFormat = "stream-json"
)

type Config struct {
	Provider           string
	Model              string
	MaxTokens          int
	SummaryMaxTokens   int
	ToolTimeoutSecs    int
	ToolResultMaxBytes int
	FileWriteMaxBytes  int
	OutputFormat       OutputFormat
	Verbose            bool
	APIKey             string
	BaseURL            string
	Prompt             string
	MaxTurns           int
	MaxContextBytes    int
	MaxContextKeepPct  int
	Skills             []string
	ThinkingBudget     int

	Interactive     bool
	SessionMode     bool
	SessionID       string
	ContinueSession bool
	ListSessions    bool
}

func Default() Config {
	return Config{
		Provider:           "claude",
		MaxTokens:          4096,
		SummaryMaxTokens:   1024,
		ToolTimeoutSecs:    600,
		ToolResultMaxBytes: 50000,
		FileWriteMaxBytes:  1048576,
		OutputFormat:       OutputHuman,
		MaxTurns:           40,
		MaxContextBytes:    200000,
		MaxContextKeepPct:  25,
		ThinkingBudget:     2048,
	}
}

func ParseArgs(args []string) (Config, error) {
	cfg := Default()
	for i := 0; i < len(args); {
		arg := args[i]
		switch arg {
		case "-p", "--provider":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.Provider = val
			i = next
		case "-m", "--model":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.Model = val
			i = next
		case "--max-tokens":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			n, err := strconv.Atoi(val)
			if err != nil {
				return cfg, fmt.Errorf("invalid --max-tokens value: %s", val)
			}
			cfg.MaxTokens = n
			i = next
		case "--tool-timeout":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			n, err := strconv.Atoi(val)
			if err != nil {
				return cfg, fmt.Errorf("invalid --tool-timeout value: %s", val)
			}
			cfg.ToolTimeoutSecs = n
			i = next
		case "--skill":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.Skills = append(cfg.Skills, val)
			i = next
		case "--max-turns":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			n, err := strconv.Atoi(val)
			if err != nil {
				return cfg, fmt.Errorf("invalid --max-turns value: %s", val)
			}
			cfg.MaxTurns = n
			i = next
		case "--max-context":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			n, err := ParseSizeBytes(val)
			if err != nil {
				return cfg, fmt.Errorf("invalid --max-context value: %s", val)
			}
			cfg.MaxContextBytes = n
			i = next
		case "--api-key":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.APIKey = val
			i = next
		case "--base-url":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.BaseURL = val
			i = next
		case "--output-format":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.OutputFormat = OutputFormat(val)
			i = next
		case "--print":
			cfg.OutputFormat = OutputStreamJSON
			i++
		case "--session":
			cfg.SessionMode = true
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				cfg.SessionID = args[i+1]
				i += 2
			} else {
				i++
			}
		case "--continue":
			cfg.SessionMode = true
			cfg.ContinueSession = true
			i++
		case "--list-sessions":
			cfg.ListSessions = true
			i++
		case "-v", "--verbose":
			cfg.Verbose = true
			i++
		case "-i", "--interactive":
			cfg.Interactive = true
			i++
		case "-h", "--help":
			return cfg, io.EOF
		default:
			if strings.HasPrefix(arg, "-") {
				return cfg, fmt.Errorf("unknown option: %s", arg)
			}
			cfg.Prompt = arg
			i++
		}
	}

	switch cfg.OutputFormat {
	case OutputHuman, OutputStreamJSON:
	default:
		return cfg, fmt.Errorf("unknown output format: %s", cfg.OutputFormat)
	}

	// Allow environment variable overrides for limits
	if v := os.Getenv("TOOL_RESULT_MAX_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.ToolResultMaxBytes = n
		}
	}
	if v := os.Getenv("FILE_WRITE_MAX_BYTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.FileWriteMaxBytes = n
		}
	}
	if v := os.Getenv("THINKING_BUDGET"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			cfg.ThinkingBudget = n
		}
	}

	return cfg, nil
}
func ApplyProviderDefaults(cfg *Config, env map[string]string) error {
	switch cfg.Provider {
	case "claude":
		if cfg.APIKey == "" {
			cfg.APIKey = env["ANTHROPIC_API_KEY"]
		}
		if cfg.BaseURL == "" {
			cfg.BaseURL = env["ANTHROPIC_BASE_URL"]
		}
		if cfg.Model == "" {
			cfg.Model = "claude-sonnet-4-20250514"
		}
	case "openai":
		if cfg.APIKey == "" {
			cfg.APIKey = env["OPENAI_API_KEY"]
		}
		if cfg.BaseURL == "" {
			cfg.BaseURL = env["OPENAI_BASE_URL"]
		}
		if cfg.Model == "" {
			cfg.Model = "gpt-4o"
		}
	default:
		return fmt.Errorf("unknown provider: %s (use claude|openai)", cfg.Provider)
	}
	if cfg.APIKey == "" && cfg.BaseURL == "" {
		switch cfg.Provider {
		case "claude":
			return errors.New("no API key. Set ANTHROPIC_API_KEY or use --api-key")
		case "openai":
			return errors.New("no API key. Set OPENAI_API_KEY or use --api-key")
		}
	}
	return nil
}

func APIURL(cfg Config) string {
	switch cfg.Provider {
	case "claude":
		base := cfg.BaseURL
		if base == "" {
			base = "https://api.anthropic.com/v1"
		}
		return strings.TrimRight(base, "/") + "/messages"
	case "openai":
		base := cfg.BaseURL
		if base == "" {
			base = "https://api.openai.com/v1"
		}
		return strings.TrimRight(base, "/") + "/chat/completions"
	default:
		return ""
	}
}

func ToolsFile(root string) string {
	return filepath.Join(root, "src", "tools.json")
}

func requireValue(args []string, i int) (string, int, error) {
	if i+1 >= len(args) {
		return "", i, fmt.Errorf("missing value for %s", args[i])
	}
	return args[i+1], i + 2, nil
}

func ParseSizeBytes(raw string) (int, error) {
	if raw == "" {
		return 0, errors.New("empty size")
	}
	lower := strings.ToLower(raw)
	multiplier := 1
	switch {
	case strings.HasSuffix(lower, "k"):
		multiplier = 1000
		lower = strings.TrimSuffix(lower, "k")
	case strings.HasSuffix(lower, "m"):
		multiplier = 1000 * 1000
		lower = strings.TrimSuffix(lower, "m")
	case strings.HasSuffix(lower, "g"):
		multiplier = 1000 * 1000 * 1000
		lower = strings.TrimSuffix(lower, "g")
	}
	n, err := strconv.Atoi(lower)
	if err != nil {
		return 0, err
	}
	return n * multiplier, nil
}
