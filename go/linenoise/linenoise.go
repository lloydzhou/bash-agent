package linenoise

/*
#cgo CFLAGS: -Wall -O2
#include "linenoise.h"
#include <errno.h>
#include <stdlib.h>
#include <poll.h>

// Wrapper struct to carry both result and errno across CGo boundary safely.
struct ln_result {
	char *line;
	int  errnum;
};

static struct ln_result linenoise_safe(const char *prompt) {
	struct ln_result r;
	errno = 0;
	r.line = linenoise(prompt);
	r.errnum = errno;
	return r;
}

// Non-blocking API wrappers
static int linenoise_edit_start(struct linenoiseState *l, int ifd, int ofd,
                                char *buf, size_t buflen, const char *prompt) {
	return linenoiseEditStart(l, ifd, ofd, buf, buflen, prompt);
}

static char *linenoise_edit_feed(struct linenoiseState *l) {
	return linenoiseEditFeed(l);
}

static void linenoise_edit_stop(struct linenoiseState *l) {
	linenoiseEditStop(l);
}

static void linenoise_hide(struct linenoiseState *l) {
	linenoiseHide(l);
}

static void linenoise_show(struct linenoiseState *l) {
	linenoiseShow(l);
}

// poll stdin with timeout (milliseconds). Returns >0 if data available, 0 on timeout, -1 on error.
static int poll_stdin(int ifd, int timeout_ms) {
	struct pollfd pfd;
	pfd.fd = ifd;
	pfd.events = POLLIN;
	return poll(&pfd, 1, timeout_ms);
}

// EditFeed with errno capture
struct edit_feed_result {
	char *line;
	int  errnum;
};

static struct edit_feed_result linenoise_edit_feed_safe(struct linenoiseState *l) {
	struct edit_feed_result r;
	errno = 0;
	r.line = linenoiseEditFeed(l);
	r.errnum = errno;
	return r;
}

// C wrapper that calls the Go export below.
extern void goImagePasteCallback(char **out, size_t *outlen);
*/
import "C"
import (
	"errors"
	"unsafe"
)

var (
	ErrInterrupted = errors.New("interrupted")
	ErrEOF         = errors.New("EOF")
	ErrMore        = errors.New("edit more") // sentinel: still editing
)

// LinenoiseState wraps the C struct linenoiseState for non-blocking editing.
type LinenoiseState C.struct_linenoiseState

// imagePasteFn is set by SetImagePasteCallback.
var imagePasteFn func() string

//export goImagePasteCallback
func goImagePasteCallback(cout **C.char, coutlen *C.size_t) {
	if imagePasteFn == nil {
		return
	}
	s := imagePasteFn()
	if s == "" {
		return
	}
	*cout = C.CString(s)
	*coutlen = C.size_t(len(s))
}

// SetImagePasteCallback registers a function to be called when
// Ctrl+V is pressed in linenoise. The function should return
// a string (e.g. "[Image #N]") to insert at cursor, or "" to ignore.
func SetImagePasteCallback(fn func() string) {
	imagePasteFn = fn
	C.linenoiseSetImagePasteCallback(C.linenoiseImagePasteCallback(C.goImagePasteCallback))
}

// Line reads a line of input using linenoise's blocking API.
// Returns ErrInterrupted on Ctrl+C, ErrEOF on Ctrl+D or I/O error.
func Line(prompt string) (string, error) {
	cprompt := C.CString(prompt)
	defer C.free(unsafe.Pointer(cprompt))

	r := C.linenoise_safe(cprompt)
	if r.line == nil {
		if r.errnum == C.EAGAIN {
			return "", ErrInterrupted
		}
		return "", ErrEOF
	}
	defer C.linenoiseFree(unsafe.Pointer(r.line))
	return C.GoString(r.line), nil
}

func HistoryAdd(line string) {
	cline := C.CString(line)
	defer C.free(unsafe.Pointer(cline))
	C.linenoiseHistoryAdd(cline)
}

func HistorySetMaxLen(n int) {
	C.linenoiseHistorySetMaxLen(C.int(n))
}

func HistorySave(path string) int {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	return int(C.linenoiseHistorySave(cpath))
}

func HistoryLoad(path string) int {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	return int(C.linenoiseHistoryLoad(cpath))
}

func SetMultiLine(ml bool) {
	if ml {
		C.linenoiseSetMultiLine(1)
	} else {
		C.linenoiseSetMultiLine(0)
	}
}

// EditStart initializes a non-blocking line editing session.
// Returns a LinenoiseState pointer for subsequent EditFeed/EditStop/Hide/Show calls.
func EditStart(stdinFd, stdoutFd int, buf []byte, prompt string) (*LinenoiseState, error) {
	cprompt := C.CString(prompt)
	defer C.free(unsafe.Pointer(cprompt))

	ls := &LinenoiseState{}
	rc := C.linenoise_edit_start((*C.struct_linenoiseState)(ls),
		C.int(stdinFd), C.int(stdoutFd),
		(*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)),
		cprompt)
	if rc == -1 {
		return nil, ErrEOF
	}
	return ls, nil
}

// EditFeed processes one character / event from stdin.
// Returns ("line", nil) when the user presses Enter.
// Returns ("", ErrMore) when more input is needed.
// Returns ("", ErrInterrupted) on Ctrl+C.
// Returns ("", ErrEOF) on Ctrl+D or error.
func EditFeed(ls *LinenoiseState) (string, error) {
	r := C.linenoise_edit_feed_safe((*C.struct_linenoiseState)(ls))
	if r.line == C.linenoiseEditMore {
		return "", ErrMore
	}
	if r.line == nil {
		// Check errno: EAGAIN = Ctrl+C, ENOENT or 0 = Ctrl+D/EOF
		if r.errnum == C.EAGAIN {
			return "", ErrInterrupted
		}
		return "", ErrEOF
	}
	// result is a strdup'd copy; caller must free
	line := C.GoString(r.line)
	C.linenoiseFree(unsafe.Pointer(r.line))
	return line, nil
}

// EditStop exits raw mode and cleans up the editing session.
func EditStop(ls *LinenoiseState) {
	C.linenoise_edit_stop((*C.struct_linenoiseState)(ls))
}

// Hide clears the current prompt line from the terminal.
func Hide(ls *LinenoiseState) {
	C.linenoise_hide((*C.struct_linenoiseState)(ls))
}

// Show restores the prompt line to the terminal.
func Show(ls *LinenoiseState) {
	C.linenoise_show((*C.struct_linenoiseState)(ls))
}

// PollStdin polls stdin for available data with a timeout in milliseconds.
// Returns >0 if data available, 0 on timeout, -1 on error.
func PollStdin(fd int, timeoutMs int) int {
	return int(C.poll_stdin(C.int(fd), C.int(timeoutMs)))
}
