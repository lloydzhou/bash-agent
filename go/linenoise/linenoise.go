package linenoise

/*
#cgo CFLAGS: -Wall -O2
#include "linenoise.h"
#include <errno.h>
#include <stdlib.h>

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
*/
import "C"
import (
	"errors"
	"unsafe"
)

var (
	ErrInterrupted = errors.New("interrupted")
	ErrEOF         = errors.New("EOF")
)

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
