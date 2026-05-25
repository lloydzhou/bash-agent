package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/lloyd/claude-code/bash-agent/go2/linenoise"
)

// Readline runs linenoise in a dedicated goroutine and communicates
// with the agent main goroutine via channels.
//
// Architecture (mirrors c/readline.c):
//
//	[readline goroutine] --inputCh--> [agent main goroutine]
//	   linenoise.Line()                  RunLoop()
//	   waits on doneCh                   signals doneCh when finished
type Readline struct {
	inputCh  chan string // lines read from terminal
	doneCh   chan struct{} // agent signals "done processing"
	histPath string
}

// NewReadline creates a Readline with history stored at ~/.bash-agent/history.
func NewReadline(home string) *Readline {
	histPath := filepath.Join(home, ".bash-agent", "history")
	_ = os.MkdirAll(filepath.Dir(histPath), 0o755)

	return &Readline{
		inputCh:  make(chan string, 1),
		doneCh:   make(chan struct{}, 1),
		histPath: histPath,
	}
}

// Start launches the background readline goroutine.
func (r *Readline) Start() {
	linenoise.HistorySetMaxLen(4096)
	linenoise.HistoryLoad(r.histPath)

	go r.loop()
}

// Input returns the channel on which user input lines are delivered.
func (r *Readline) Input() <-chan string {
	return r.inputCh
}

// Done signals the readline goroutine that the agent has finished
// processing the current input and the next prompt may be shown.
func (r *Readline) Done() {
	r.doneCh <- struct{}{}
}

const promptStr = "\x1b[32m> \x1b[0m"

func (r *Readline) loop() {
	for {
		line, err := linenoise.Line(promptStr)
		if err != nil {
			if err == linenoise.ErrInterrupted {
				// Ctrl+C — linenoise already displayed ^C and newline
				continue
			}
			// Ctrl+D or I/O error — exit
			fmt.Fprint(os.Stderr, "\n")
			close(r.inputCh)
			return
		}

		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		if line == "exit" || line == "quit" {
			close(r.inputCh)
			return
		}

		linenoise.HistoryAdd(line)
		linenoise.HistorySave(r.histPath)

		// Send to agent and wait for it to finish processing
		r.inputCh <- line
		<-r.doneCh
	}
}
