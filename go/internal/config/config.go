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
	ToolTimeoutSecs    int
	ToolResultMaxBytes int
	FileWriteMaxBytes  int
	OutputFormat       OutputFormat
	Verbose            bool
	APIKey             string
	BaseURL            string
	Prompt             string
	MaxTurns           int
	MaxContextTokens   int
	MaxContextKeepPct  int
	MaxTurnsBeforeCompact int
	// DP compact strategy
	DPPInput        float64
	DPPCache       float64
	DPPOut         float64
	DPV            int
	DPS            int
	DPL            float64
	DPBaselineE    int
	DPEFixed       int
	DPR            float64
	DPBeta         float64
	DPMinKeepRatio float64
	Skills             []string
	Thinking string
	Effort   string

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
		ToolTimeoutSecs:    600,
		ToolResultMaxBytes: 100000,
		FileWriteMaxBytes:  1048576,
		OutputFormat:       OutputHuman,
		MaxTurns:           40,
		MaxContextTokens:  200000,
		MaxContextKeepPct: 25,
		MaxTurnsBeforeCompact: 100,
		DPPInput:       3.0,
		DPPCache:      0.30,
		DPV:            5000,
		DPPOut:         15.0,
		DPS:            500,
		DPL:            5.0,
		DPBaselineE:    8,
		DPEFixed:       0,
		DPR:            0.8,
		DPBeta:         0.03,
		DPMinKeepRatio: 0.12,
		Thinking: "adaptive",
		Effort:   "high",
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
			n, err := ParseSizeBytes(val)
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
				return cfg, fmt.Errorf("Invalid --max-context: %s", val)
			}
			cfg.MaxContextTokens = n
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
		case "--thinking":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.Thinking = val
			i = next
		case "--effort":
			val, next, err := requireValue(args, i)
			if err != nil {
				return cfg, err
			}
			cfg.Effort = val
			i = next
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
	if v := os.Getenv("THINKING"); v != "" {
		cfg.Thinking = v
	}
	if v := os.Getenv("EFFORT"); v != "" {
		cfg.Effort = v
	}
	if v := os.Getenv("MAX_TURNS_BEFORE_COMPACT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.MaxTurnsBeforeCompact = n
		}
	}
	// DP compact strategy env overrides
	if v := os.Getenv("DP_P_INPUT"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			cfg.DPPInput = f
		}
	}
	if v := os.Getenv("DP_P_CACHE"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			cfg.DPPCache = f
		}
	}
	if v := os.Getenv("DP_P_OUT"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			cfg.DPPOut = f
		}
	}
	if v := os.Getenv("DP_V"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.DPV = n
		}
	}
	if v := os.Getenv("DP_S"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.DPS = n
		}
	}
	if v := os.Getenv("DP_L"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			cfg.DPL = f
		}
	}
	if v := os.Getenv("DP_BASELINE_E"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			cfg.DPBaselineE = n
		}
	}
	if v := os.Getenv("DP_E_FIXED"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			cfg.DPEFixed = n
		}
	}
	if v := os.Getenv("DP_R"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 && f <= 1 {
			cfg.DPR = f
		}
	}
	if v := os.Getenv("DP_BETA"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 {
			cfg.DPBeta = f
		}
	}
	if v := os.Getenv("DP_MIN_KEEP_RATIO"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 && f < 1 {
			cfg.DPMinKeepRatio = f
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
