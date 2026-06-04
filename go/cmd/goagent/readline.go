package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/lloyd/claude-code/bash-agent/go2/linenoise"
)

// Readline runs linenoise in a dedicated goroutine and communicates
// with the agent main goroutine via channels.
//
// Display output uses linenoiseWrite which handles Hide/OPOST/Show internally.
type Readline struct {
	inputCh     chan string
	histPath    string
	interruptCb func() // called on Ctrl+C to interrupt running agent
}

// NewReadline creates a Readline with history stored at ~/.bash-agent/history.
func NewReadline(home string) *Readline {
	histPath := filepath.Join(home, ".bash-agent", "history")
	_ = os.MkdirAll(filepath.Dir(histPath), 0o755)

	return &Readline{
		inputCh:  make(chan string, 1),
		histPath: histPath,
	}
}

// Start launches the background readline goroutine.
func (r *Readline) Start() {
	linenoise.SetMultiLine(true)
	linenoise.HistorySetMaxLen(4096)
	linenoise.HistoryLoad(r.histPath)

	go r.loop()
}

// SetImagePasteCallback registers a function to be called when Ctrl+V is pressed.
func (r *Readline) SetImagePasteCallback(fn func() string) {
	linenoise.SetImagePasteCallback(fn)
}

// Input returns the channel on which user input lines are delivered.
func (r *Readline) Input() <-chan string {
	return r.inputCh
}

// SetInterruptCallback registers a function to be called when Ctrl+C is pressed
// during agent execution. The callback should cancel the current agent turn.
func (r *Readline) SetInterruptCallback(fn func()) {
	r.interruptCb = fn
}

const promptStr = "\x1b[32m> \x1b[0m"

func (r *Readline) loop() {
	buf := make([]byte, 65536)
	stdinFd := int(os.Stdin.Fd())

	for {
		// Start a new editing session
		ls, err := linenoise.EditStart(stdinFd, 2, buf, promptStr)
		if err != nil {
			// Failed to start editing (e.g., not a terminal)
			fmt.Fprint(os.Stderr, "\n")
			close(r.inputCh)
			return
		}

		// Register state for LinenoiseWrite to use Hide/Show
		linenoise.RegisterState(ls)
		linenoise.SetActive(true)

		// Non-blocking poll + feed loop
		var line string
		var feedErr error
		for {
			// Poll stdin with 50ms timeout to allow display worker to acquire lock
			linenoise.PollStdin(stdinFd, 50)

			line, feedErr = linenoise.EditFeed(ls)
			if feedErr == nil {
				// Got a complete line
				break
			}
			if feedErr == linenoise.ErrMore {
				// Still editing, poll again
				continue
			}
			// ErrInterrupted or ErrEOF
			break
		}

		// Unregister state
		linenoise.SetActive(false)
		linenoise.RegisterState(nil)

		linenoise.EditStop(ls)

		if feedErr != nil {
			if feedErr == linenoise.ErrInterrupted {
				// Ctrl+C — linenoise already displayed ^C and newline
				// Notify agent to interrupt if running
				if r.interruptCb != nil {
					r.interruptCb()
				}
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

		// Send to agent — no done wait
		r.inputCh <- line
	}
}

// SetRawStdin sets stdin to raw mode (used for non-blocking poll compatibility).
func SetRawStdin() func() {
	// This is handled internally by linenoise EditStart/EditStop
	return func() {}
}

// StdinFd returns the file descriptor for stdin.
func StdinFd() int {
	return int(syscall.Stdin)
}
