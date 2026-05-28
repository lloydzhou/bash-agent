use anyhow::{Result, anyhow, bail};
use rustagent::agent::agent_run;
use rustagent::config::{Config, OutputFormat, apply_provider_defaults, parse_size_bytes};
use rustagent::store;
use rustagent::util::format_system_time;
use std::path::Path;

fn main() {
    std::panic::set_hook(Box::new(|info| {
        let _ = crossterm::terminal::disable_raw_mode();
        eprintln!("{info}");
    }));

    if let Err(err) = run() {
        eprintln!("Error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut cfg = match parse_args(std::env::args().skip(1).collect()) {
        Ok(cfg) => cfg,
        Err(err) if err.to_string() == "__HELP__" => {
            print_usage();
            return Ok(());
        }
        Err(err) => return Err(err),
    };
    let cwd = std::env::current_dir()?;
    let home = std::path::PathBuf::from(
        std::env::var("BASH_AGENT_HOME")
            .or_else(|_| std::env::var("HOME"))
            .unwrap_or_else(|_| String::from(".")),
    );

    if cfg.list_sessions {
        list_sessions(&home, &cwd)?;
        return Ok(());
    }

    apply_provider_defaults(&mut cfg)?;
    agent_run(cfg, cwd, home)
}

fn parse_args(args: Vec<String>) -> Result<Config> {
    let mut cfg = Config::default();
    let mut i = 0usize;

    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "-p" | "--provider" => {
                cfg.provider = require_value(&args, i)?;
                i += 2;
            }
            "-m" | "--model" => {
                cfg.model = require_value(&args, i)?;
                i += 2;
            }
            "--max-tokens" => {
                cfg.max_tokens = parse_size_bytes(&require_value(&args, i)?)? as i32;
                i += 2;
            }
            "--tool-timeout" => {
                cfg.tool_timeout_secs = require_value(&args, i)?.parse()?;
                i += 2;
            }
            "--effort" => {
                cfg.effort = require_value(&args, i)?;
                i += 2;
            }
            "--thinking" => {
                cfg.thinking = require_value(&args, i)?;
                i += 2;
            }
            "--skill" => {
                cfg.skills.push(require_value(&args, i)?);
                i += 2;
            }
            "--max-turns" => {
                cfg.max_turns = require_value(&args, i)?.parse()?;
                i += 2;
            }
            "--max-context" => {
                let val = require_value(&args, i)?;
                cfg.max_context_tokens = parse_size_bytes(&val)
                    .map_err(|_| anyhow!("Invalid --max-context: {}", val))?;
                i += 2;
            }
            "--api-key" => {
                cfg.api_key = require_value(&args, i)?;
                i += 2;
            }
            "--base-url" => {
                cfg.base_url = require_value(&args, i)?;
                i += 2;
            }
            "--output-format" => {
                let v = require_value(&args, i)?;
                cfg.output_format = match v.as_str() {
                    "human" => OutputFormat::Human,
                    "stream-json" => OutputFormat::StreamJson,
                    _ => bail!("unknown output format: {v}"),
                };
                i += 2;
            }
            "--print" => {
                cfg.output_format = OutputFormat::StreamJson;
                i += 1;
            }
            "--session" => {
                cfg.session_mode = true;
                if i + 1 < args.len() && !args[i + 1].starts_with('-') {
                    cfg.session_id = args[i + 1].clone();
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--continue" => {
                cfg.session_mode = true;
                cfg.continue_session = true;
                i += 1;
            }
            "--list-sessions" => {
                cfg.list_sessions = true;
                i += 1;
            }
            "-v" | "--verbose" => {
                cfg.verbose = true;
                i += 1;
            }
            "-i" | "--interactive" => {
                cfg.interactive = true;
                i += 1;
            }
            "-h" | "--help" => {
                return Err(anyhow!("__HELP__"));
            }
            _ => {
                if arg.starts_with('-') {
                    bail!("unknown option: {arg}");
                }
                cfg.prompt = arg.clone();
                i += 1;
            }
        }
    }

    Ok(cfg)
}

fn require_value(args: &[String], i: usize) -> Result<String> {
    if i + 1 >= args.len() {
        bail!("missing value for {}", args[i]);
    }
    Ok(args[i + 1].clone())
}

fn print_usage() {
    println!("Usage: rustagent [options] [prompt]");
    println!();
    println!("Options:");
    println!("  -p, --provider PROV     LLM provider: claude | openai (default: claude)");
    println!("  -m, --model MODEL       Model name");
    println!("  --max-tokens N          Max output tokens (default: 4096)");
    println!("  --tool-timeout N        Tool execution timeout in seconds (default: 600)");
    println!("  --effort LEVEL          Thinking effort: low|medium|high|xhigh|max (default: high)");
    println!("  --thinking MODE         Thinking mode: adaptive|enabled|disabled (default: adaptive)");
    println!(
        "  --skill NAME            Load skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)"
    );
    println!("  --max-turns N           Max agent turns (default: 40)");
    println!("  --max-context N         Max stored context bytes before compact (default: 200000)");
    println!("  --api-key KEY           API key (default from env)");
    println!("  --base-url URL          Override API base URL");
    println!("  --output-format FMT     Output format: human | stream-json");
    println!("  --print                 Alias for --output-format stream-json");
    println!("  --session [NAME]        Use named session");
    println!("  --continue              Continue most recent session");
    println!("  --list-sessions         List saved sessions");
    println!("  -v, --verbose           Verbose mode");
    println!("  -i, --interactive       Interactive mode (REPL)");
    println!("  -h, --help              Show this help");
    println!();
    println!("Environment:");
    println!("  ANTHROPIC_API_KEY       API key for Claude");
    println!("  OPENAI_API_KEY          API key for OpenAI");
    println!("  DEEPSEEK_API_KEY        API key for DeepSeek (auto-configures provider)");
    println!("  ANTHROPIC_BASE_URL      Claude API base URL");
    println!("  OPENAI_BASE_URL         OpenAI API base URL");
    println!("  BASH_AGENT_HOME         Override base directory for session storage");
    println!("  BASH_AGENT_BASH_MODE    Bash tool permissions as 4 octal rwx digits: system/external/network/workspace (default: 0447)");
    println!("  MODEL                   Default model name");
}

fn list_sessions(home: &Path, cwd: &Path) -> Result<()> {
    let rows = store::store_list_sessions(home, cwd)?;
    if rows.is_empty() {
        println!("No sessions found.");
        return Ok(());
    }
    println!("{:<40} {:<16} PREVIEW", "NAME", "MODIFIED");
    for row in rows {
        let raw_preview = row.summary;
        let preview = if raw_preview.chars().count() > 60 {
            let mut s: String = raw_preview.chars().take(57).collect();
            s.push_str("...");
            s
        } else {
            raw_preview
        };
        let formatted = format_system_time(&row.modified);
        println!("{:<40} {:<16} {}", row.name, formatted, preview);
    }
    Ok(())
}
