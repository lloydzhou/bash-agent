//! Safe Rust wrappers around linenoise C library.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::OnceLock;

/// Global image directory path, set once during agent initialization.
/// Used by the image paste callback to know where to save clipboard images.
static IMAGE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Set the global image directory path for the paste callback.
/// Should be called once during agent initialization.
pub fn set_image_dir(dir: PathBuf) {
    let _ = IMAGE_DIR.set(dir);
}

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
    fn linenoiseSetImagePasteCallback(cb: Option<unsafe extern "C" fn(*mut *mut libc::c_char, *mut libc::size_t)>);

    // Non-blocking API
    fn linenoiseEditStart(
        l: *mut LinenoiseState,
        stdin_fd: libc::c_int,
        stdout_fd: libc::c_int,
        buf: *mut c_char,
        buflen: libc::size_t,
        prompt: *const c_char,
    ) -> libc::c_int;
    fn linenoiseEditFeed(l: *mut LinenoiseState) -> *mut c_char;
    fn linenoiseEditStop(l: *mut LinenoiseState);
    fn linenoiseHide(l: *mut LinenoiseState);
    fn linenoiseShow(l: *mut LinenoiseState);
    static linenoiseEditMore: *mut c_char;
}

/// Opaque type matching C's struct linenoiseState.
/// We only ever hold a pointer to it — the layout is managed by linenoise.c.
#[repr(C)]
pub struct LinenoiseState {
    _opaque: [u8; 0],
}

/// Result of a non-blocking EditFeed call.
#[derive(Debug)]
pub enum FeedResult {
    /// More input is needed (user is still typing).
    More,
    /// User pressed Enter; contains the complete line.
    Done(String),
    /// User pressed Ctrl+C.
    Interrupted,
    /// User pressed Ctrl+D or I/O error.
    Eof,
}

/// Start editing and return a raw pointer (caller manages lifetime).
/// # Safety
/// Caller must ensure the buf outlives the editing session.
pub unsafe fn edit_start_raw(
    ls: *mut LinenoiseState,
    stdin_fd: i32,
    stdout_fd: i32,
    buf: *mut c_char,
    buflen: usize,
    prompt: *const c_char,
) -> i32 {
    unsafe { linenoiseEditStart(ls, stdin_fd, stdout_fd, buf, buflen, prompt) }
}

/// Feed one character using raw pointer.
/// # Safety
/// ls must be a valid pointer from edit_start_raw.
pub unsafe fn edit_feed_raw(ls: *mut LinenoiseState) -> *mut c_char {
    unsafe { linenoiseEditFeed(ls) }
}

/// Get the linenoiseEditMore sentinel pointer for comparison.
pub fn edit_more_ptr() -> *mut c_char {
    unsafe { linenoiseEditMore }
}

/// Stop editing using raw pointer.
/// # Safety
/// ls must be valid.
pub unsafe fn edit_stop_ptr(ls: *mut LinenoiseState) {
    unsafe { linenoiseEditStop(ls); }
}

/// Hide the current prompt line.
/// # Safety
/// ls must be a valid, active linenoiseState pointer.
pub unsafe fn hide(ls: *mut LinenoiseState) {
    unsafe { linenoiseHide(ls); }
}

/// Show (restore) the current prompt line.
/// # Safety
/// ls must be a valid, active linenoiseState pointer.
pub unsafe fn show(ls: *mut LinenoiseState) {
    unsafe { linenoiseShow(ls); }
}

/// Free a line returned by linenoise or edit_feed_raw.
pub fn free_line(ptr: *mut c_char) {
    unsafe { linenoiseFree(ptr); }
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

/// Register the image paste callback with linenoise.
/// Called once during agent initialization after setting the image directory.
pub fn register_paste_callback() {
    unsafe {
        linenoiseSetImagePasteCallback(Some(image_paste_callback_impl));
    }
}

/// Extern "C" function called by linenoise when the user presses Ctrl+V.
/// Reads the clipboard (osascript → wl-paste → xclip), saves to image_dir/{n}.png,
/// and returns "[Image #N]" as a heap-allocated C string (freed by linenoise).
#[unsafe(no_mangle)]
pub extern "C" fn image_paste_callback_impl(
    out: *mut *mut libc::c_char,
    outlen: *mut libc::size_t,
) {
    let img_dir = match IMAGE_DIR.get() {
        Some(d) => d.clone(),
        None => return,
    };

    let _ = std::fs::create_dir_all(&img_dir);

    // Find next available image number
    let next = match std::fs::read_dir(&img_dir) {
        Ok(entries) => entries.filter_map(|e| e.ok()).count() + 1,
        Err(_) => 1,
    };

    // Try clipboard tools in order: osascript (macOS), wl-paste (Wayland), xclip (X11)
    let img_data = try_clipboard_image(next, &img_dir);

    let img_data = match img_data {
        Some(d) if !d.is_empty() => d,
        _ => return,
    };

    let img_path = img_dir.join(format!("{next}.png"));
    if std::fs::write(&img_path, &img_data).is_err() {
        return;
    }

    let placeholder = format!("[Image #{next}]");
    let c_str = match std::ffi::CString::new(placeholder) {
        Ok(s) => s,
        Err(_) => return,
    };

    unsafe {
        *out = c_str.into_raw();
        *outlen = libc::strlen(*out);
    }
}

/// Try each clipboard tool in order, returning the PNG data if successful.
fn try_clipboard_image(next: usize, img_dir: &std::path::Path) -> Option<Vec<u8>> {
    // macOS: osascript to write clipboard PNG to a temp file
    let tmp_path = img_dir.join(format!("{next}.png.tmp"));
    let tmp_str = tmp_path.to_string_lossy().to_string();
    let osa_cmd = format!(
        "set theImage to the clipboard as «class PNGf»
set theFile to open for access POSIX file \"{tmp_str}\" with write permission
write theImage to theFile
close access theFile"
    );
    if std::process::Command::new("osascript")
        .arg("-e")
        .arg(&osa_cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        if let Ok(data) = std::fs::read(&tmp_path) {
            let _ = std::fs::remove_file(&tmp_path);
            if !data.is_empty() {
                return Some(data);
            }
        }
        let _ = std::fs::remove_file(&tmp_path);
    }

    // Linux Wayland
    if let Ok(output) = std::process::Command::new("wl-paste")
        .arg("--type")
        .arg("image/png")
        .output()
    {
        if output.status.success() && !output.stdout.is_empty() {
            return Some(output.stdout);
        }
    }

    // Linux X11
    if let Ok(output) = std::process::Command::new("xclip")
        .args(["-selection", "clipboard", "-t", "image/png", "-o"])
        .output()
    {
        if output.status.success() && !output.stdout.is_empty() {
            return Some(output.stdout);
        }
    }

    None
}
