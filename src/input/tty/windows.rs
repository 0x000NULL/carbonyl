use std::io;

use windows_sys::Win32::Foundation::{BOOL, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Console::{
    GetConsoleMode, GetStdHandle, SetConsoleMode, CONSOLE_MODE, DISABLE_NEWLINE_AUTO_RETURN,
    ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_MOUSE_INPUT, ENABLE_PROCESSED_INPUT,
    ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING, ENABLE_WINDOW_INPUT,
    STD_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
};

#[derive(Clone, Copy)]
pub(super) struct TerminalSettings {
    stdin_mode: CONSOLE_MODE,
    stdout_mode: CONSOLE_MODE,
}

impl TerminalSettings {
    /// Read the current console modes for stdin/stdout, enable raw input with
    /// VT sequences on stdout, and return the pre-raw snapshot so the caller
    /// can restore it later.
    pub fn open_raw() -> io::Result<TerminalSettings> {
        let original = Self::open()?;
        let raw = TerminalSettings {
            stdin_mode: (original.stdin_mode
                & !(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT))
                | ENABLE_WINDOW_INPUT
                | ENABLE_MOUSE_INPUT
                | ENABLE_VIRTUAL_TERMINAL_INPUT,
            stdout_mode: original.stdout_mode
                | ENABLE_VIRTUAL_TERMINAL_PROCESSING
                | DISABLE_NEWLINE_AUTO_RETURN,
        };

        raw.apply()?;

        Ok(original)
    }

    /// Apply these console modes to stdin and stdout.
    pub fn apply(&self) -> io::Result<()> {
        unsafe {
            let stdin = std_handle(STD_INPUT_HANDLE)?;
            let stdout = std_handle(STD_OUTPUT_HANDLE)?;

            SetConsoleMode(stdin, self.stdin_mode).to_err()?;
            SetConsoleMode(stdout, self.stdout_mode).to_err()?;
        }

        Ok(())
    }

    /// Read the current console modes.
    fn open() -> io::Result<Self> {
        unsafe {
            let stdin = std_handle(STD_INPUT_HANDLE)?;
            let stdout = std_handle(STD_OUTPUT_HANDLE)?;

            let mut stdin_mode: CONSOLE_MODE = 0;
            let mut stdout_mode: CONSOLE_MODE = 0;

            GetConsoleMode(stdin, &mut stdin_mode).to_err()?;
            GetConsoleMode(stdout, &mut stdout_mode).to_err()?;

            Ok(Self {
                stdin_mode,
                stdout_mode,
            })
        }
    }
}

unsafe fn std_handle(kind: STD_HANDLE) -> io::Result<HANDLE> {
    let handle = GetStdHandle(kind);

    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        Err(io::Error::last_os_error())
    } else {
        Ok(handle)
    }
}

trait ToErr {
    fn to_err(self) -> io::Result<()>;
}
impl ToErr for BOOL {
    fn to_err(self) -> io::Result<()> {
        if self != 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}
