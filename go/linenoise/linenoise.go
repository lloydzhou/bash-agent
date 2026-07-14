package linenoise

/*
#cgo CFLAGS: -Wall -O2 -Wno-unused-function
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
extern int goInjectCallback(char *buf, size_t len);

static void linenoise_write(const char *s, size_t len) {
	linenoiseWrite(s, len);
}

static void linenoise_register_state(void *state) {
	linenoiseRegisterState(state);
}

static void linenoise_set_active(int active) {
	linenoiseSetActive(active);
}
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

// LinenoiseState owns C-allocated linenoise state, input buffer and prompt.
// All three must stay alive until EditStop; linenoiseState stores pointers to
// the buffer and prompt internally.
type LinenoiseState struct {
	ptr    *C.struct_linenoiseState
	buf    unsafe.Pointer
	prompt *C.char
}

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

// injectFn is set by SetInjectCallback.
var injectFn func(string)

//export goInjectCallback
func goInjectCallback(cbuf *C.char, clen C.size_t) C.int {
	if injectFn == nil || clen == 0 {
		return 1
	}
	injectFn(C.GoStringN(cbuf, C.int(clen)))
	return 0
}

// SetInjectCallback registers a function to be called when
// Ctrl+O is pressed in linenoise. The function receives
// the current edit buffer text.
func SetInjectCallback(fn func(string)) {
	injectFn = fn
	C.linenoiseSetInjectCallback(C.linenoiseInjectCallback(C.goInjectCallback))
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

// RestoreTerminal restores the terminal from raw mode. Safe to call from a
// signal handler or panic recovery — internally only uses async-signal-safe
// C functions (tcsetattr, write).
func RestoreTerminal() {
	C.linenoiseRestoreTerminal()
}

// EditStart initializes a non-blocking line editing session.
// Returns a LinenoiseState pointer for subsequent EditFeed/EditStop/Hide/Show calls.
func EditStart(stdinFd, stdoutFd int, buf []byte, prompt string) (*LinenoiseState, error) {
	bufLen := len(buf)
	if bufLen == 0 {
		bufLen = 65536
	}
	// Allocate buffer in C memory so linenoiseState never holds a Go pointer.
	cbuf := C.malloc(C.size_t(bufLen))
	if cbuf == nil {
		return nil, ErrEOF
	}
	cprompt := C.CString(prompt) // also C-allocated
	cls := (*C.struct_linenoiseState)(C.malloc(C.size_t(unsafe.Sizeof(C.struct_linenoiseState{}))))
	if cls == nil {
		C.free(cbuf)
		C.free(unsafe.Pointer(cprompt))
		return nil, ErrEOF
	}
	rc := C.linenoise_edit_start(cls,
		C.int(stdinFd), C.int(stdoutFd),
		(*C.char)(cbuf), C.size_t(bufLen),
		cprompt)
	if rc == -1 {
		C.free(unsafe.Pointer(cls))
		C.free(cbuf)
		C.free(unsafe.Pointer(cprompt))
		return nil, ErrEOF
	}
	return &LinenoiseState{ptr: cls, buf: cbuf, prompt: cprompt}, nil
}

// EditFeed processes one character / event from stdin.
// Returns ("line", nil) when the user presses Enter.
// Returns ("", ErrMore) when more input is needed.
// Returns ("", ErrInterrupted) on Ctrl+C.
// Returns ("", ErrEOF) on Ctrl+D or error.
func EditFeed(ls *LinenoiseState) (string, error) {
	if ls == nil || ls.ptr == nil {
		return "", ErrEOF
	}
	r := C.linenoise_edit_feed_safe(ls.ptr)
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
	if ls == nil || ls.ptr == nil {
		return
	}
	C.linenoise_edit_stop(ls.ptr)
	C.free(unsafe.Pointer(ls.ptr))
	C.free(ls.buf)
	C.free(unsafe.Pointer(ls.prompt))
	ls.ptr = nil
	ls.buf = nil
	ls.prompt = nil
}

// Hide clears the current prompt line from the terminal.
func Hide(ls *LinenoiseState) {
	if ls != nil && ls.ptr != nil {
		C.linenoise_hide(ls.ptr)
	}
}

// Show restores the prompt line to the terminal.
func Show(ls *LinenoiseState) {
	if ls != nil && ls.ptr != nil {
		C.linenoise_show(ls.ptr)
	}
}

// PollStdin polls stdin for available data with a timeout in milliseconds.
// Returns >0 if data available, 0 on timeout, -1 on error.
func PollStdin(fd int, timeoutMs int) int {
	return int(C.poll_stdin(C.int(fd), C.int(timeoutMs)))
}

// LinenoiseWrite writes a string to stdout with automatic Hide/OPOST/Show management.
// Each call is atomic — Lock → Hide → write → Show → Unlock.
func LinenoiseWrite(s string) {
	if len(s) == 0 {
		return
	}
	C.linenoise_write((*C.char)(unsafe.Pointer(unsafe.StringData(s))), C.size_t(len(s)))
}

// RegisterState registers the linenoise state with the display system.
// Must be called when starting an editing session so that LinenoiseWrite
// knows which state to Hide/Show.
func RegisterState(ls *LinenoiseState) {
	if ls != nil && ls.ptr != nil {
		C.linenoise_register_state(unsafe.Pointer(ls.ptr))
	}
}

// SetActive sets whether the editor is active.
// Must be called (true before EditFeed, false after) so that LinenoiseWrite
// knows when to apply Hide/OPOST/Show.
func SetActive(active bool) {
	if active {
		C.linenoise_set_active(1)
	} else {
		C.linenoise_set_active(0)
	}
}
