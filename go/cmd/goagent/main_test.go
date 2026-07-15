package main

import (
	"testing"

	agent "github.com/lloyd/claude-code/bash-agent/go2"
)

func TestApplyThinkingOptions(t *testing.T) {
	cfg := agent.Config{Thinking: "enabled", Effort: "max"}
	applyThinkingOptions(&cfg, "", "")
	if cfg.Thinking != "enabled" || cfg.Effort != "max" {
		t.Fatalf("空命令行参数修改了环境变量配置：thinking=%q effort=%q", cfg.Thinking, cfg.Effort)
	}

	applyThinkingOptions(&cfg, "disabled", "low")
	if cfg.Thinking != "disabled" || cfg.Effort != "low" {
		t.Fatalf("命令行参数未覆盖配置：thinking=%q effort=%q", cfg.Thinking, cfg.Effort)
	}
}
