use crate::traits::Display as _;
    use crate::types::StreamEvent;

    /// 终端显示实现
    pub struct TerminalDisplay {
        pub verbose: bool,
    }

    impl TerminalDisplay {
        pub fn new(verbose: bool) -> Self {
            Self { verbose }
        }

        pub fn handle_event(&self, event: &StreamEvent) {
            match event {
                StreamEvent::TextDelta { delta } => {
                    print!("{}", delta);
                }
                StreamEvent::ThinkingDelta { delta } => {
                    if self.verbose {
                        eprint!("[思考] {}", delta);
                    }
                }
                StreamEvent::ToolUseStart { id, name, input } => {
                    if self.verbose {
                        eprintln!("[工具调用] {} (id: {})", name, id);
                        eprintln!("  参数: {}", serde_json::to_string(input).unwrap_or_default());
                    }
                }
                StreamEvent::ToolResult { tool_use_id, content, is_error } => {
                    if self.verbose {
                        if *is_error {
                            eprintln!("[工具错误] (id: {}): {}", tool_use_id, content);
                        } else {
                            eprintln!("[工具结果] (id: {}): {}", tool_use_id, content);
                        }
                    }
                }
                StreamEvent::Usage { input_tokens, output_tokens } => {
                    if self.verbose {
                        eprintln!("[用量] 输入: {} 输出: {}", input_tokens, output_tokens);
                    }
                }
                StreamEvent::Done => {
                    eprintln!();
                }
            }
        }

        pub fn print_message(&self, role: &str, content: &str) {
            match role {
                "assistant" => {
                    println!("{}", content);
                }
                "user" => {
                    if self.verbose {
                        eprintln!("[用户] {}", content);
                    }
                }
                "system" => {
                    if self.verbose {
                        eprintln!("[系统] {}", content);
                    }
                }
                _ => {}
            }
        }

        pub fn print_error(&self, err: &str) {
            eprintln!("[错误] {}", err);
        }
    }

    impl crate::traits::Display for TerminalDisplay {
        fn ensure_newline(&self) {
            eprintln!();
        }

        fn human_text(&self, text: &str) {
            print!("{}", text);
        }

        fn event(&self, event: &crate::protocol::Event) {
            match event {
                crate::protocol::Event::Text(e) => print!("{}", e.content),
                crate::protocol::Event::Thinking(e) => {
                    if self.verbose {
                        eprint!("[思考] {}", e.content);
                    }
                }
                crate::protocol::Event::ToolCall(e) => {
                    if self.verbose {
                        eprintln!("[工具调用] {} (id: {})", e.name, e.id);
                    }
                }
                crate::protocol::Event::Usage(e) => {
                    if self.verbose {
                        eprintln!("[用量] 输入: {} 输出: {}", e.input_tokens, e.output_tokens);
                    }
                }
                crate::protocol::Event::Stop(e) => {
                    if self.verbose {
                        eprintln!("[停止] {}", e.reason);
                    }
                }
                crate::protocol::Event::Error(e) => eprintln!("[错误] {}", e.message),
                crate::protocol::Event::Retry(_) => {}
            }
        }

        fn term_title(&self, title: &str) {
            let _ = title;
        }
    }

    pub fn display_ensure_newline(display: &TerminalDisplay) {
        display.ensure_newline();
    }

    pub fn display_human_text(display: &TerminalDisplay, text: &str) {
        display.human_text(text);
    }

    pub fn display_event(display: &TerminalDisplay, event: &crate::protocol::Event) {
        display.event(event);
    }

    pub fn display_term_title(display: &TerminalDisplay, title: &str) {
        display.term_title(title);
    }
