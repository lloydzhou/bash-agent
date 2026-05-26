//! Safe Rust wrappers around linenoise C library.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Error type for linenoise line reading.
#[derive(Debug)]
pub enum LineError {
    /// User pressed Ctrl+C.
    Interrupted,
    /// User pressed Ctrl+D (EOF).
    Eof,
    /// I/O or other error.
    Io(std::io::Error),
}

impl std::fmt::Display for LineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LineError::Interrupted => write!(f, "interrupted (Ctrl+C)"),
            LineError::Eof => write!(f, "EOF (Ctrl+D)"),
            LineError::Io(e) => write!(f, "I/O error: {e}"),
        }
    }
}

impl std::error::Error for LineError {}

unsafe extern "C" {
    fn linenoise(prompt: *const c_char) -> *mut c_char;
    fn linenoiseFree(ptr: *mut c_char);
    fn linenoiseHistoryAdd(line: *const c_char) -> libc::c_int;
    fn linenoiseHistorySetMaxLen(len: libc::c_int) -> libc::c_int;
    fn linenoiseHistorySave(filename: *const c_char) -> libc::c_int;
    fn linenoiseHistoryLoad(filename: *const c_char) -> libc::c_int;
    fn linenoiseSetMultiLine(ml: libc::c_int);
}

/// Read a line from stdin with the given prompt.
///
/// Returns:
/// - `Ok(String)` with the user input on success.
/// - `Err(LineError::Interrupted)` on Ctrl+C.
/// - `Err(LineError::Eof)` on Ctrl+D.
/// - `Err(LineError::Io(...))` on other errors.
pub fn line(prompt: &str) -> Result<String, LineError> {
    let c_prompt = CString::new(prompt).map_err(|e| {
        LineError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, e))
    })?;

    // Clear errno before calling linenoise
    #[cfg(target_os = "macos")]
    unsafe { *libc::__error() = 0 };
    #[cfg(target_os = "linux")]
    unsafe { *libc::__errno_location() = 0 };

    let ptr = unsafe { linenoise(c_prompt.as_ptr()) };

    if ptr.is_null() {
        #[cfg(target_os = "macos")]
        let err = unsafe { *libc::__error() };
        #[cfg(target_os = "linux")]
        let err = unsafe { *libc::__errno_location() };
        if err == libc::EAGAIN {
            Err(LineError::Interrupted)
        } else if err == libc::ENOENT || err == 0 {
            Err(LineError::Eof)
        } else {
            Err(LineError::Io(std::io::Error::from_raw_os_error(err)))
        }
    } else {
        let s = unsafe {
            let rust_str = CStr::from_ptr(ptr).to_string_lossy().into_owned();
            linenoiseFree(ptr);
            rust_str
        };
        Ok(s)
    }
}

/// Add a line to the history list. Returns true on success.
pub fn history_add(line: &str) -> bool {
    let c_line = match CString::new(line) {
        Ok(s) => s,
        Err(_) => return false,
    };
    unsafe { linenoiseHistoryAdd(c_line.as_ptr()) != 0 }
}

/// Set the maximum length of the history list. Returns true on success.
pub fn history_set_max_len(n: i32) -> bool {
    unsafe { linenoiseHistorySetMaxLen(n) != 0 }
}

/// Save history to a file. Returns true on success.
pub fn history_save(path: &str) -> bool {
    let c_path = match CString::new(path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    unsafe { linenoiseHistorySave(c_path.as_ptr()) != -1 }
}

/// Load history from a file. Returns true on success.
pub fn history_load(path: &str) -> bool {
    let c_path = match CString::new(path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    unsafe { linenoiseHistoryLoad(c_path.as_ptr()) != -1 }
}

/// Enable or disable multiline editing mode.
pub fn set_multiline(ml: bool) {
    unsafe { linenoiseSetMultiLine(if ml { 1 } else { 0 }) }
}
