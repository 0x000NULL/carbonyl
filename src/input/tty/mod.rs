use std::io::{self, Write};

use crate::utils::log;

#[cfg(unix)]
mod unix;
#[cfg(unix)]
use unix::TerminalSettings;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
use windows::TerminalSettings;

pub struct Terminal {
    settings: Option<TerminalSettings>,
    alt_screen: bool,
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.teardown()
    }
}

impl Terminal {
    /// Setup the input stream to operate in raw mode.
    /// Returns an object that'll revert terminal settings.
    pub fn setup() -> Self {
        Self {
            settings: match TerminalSettings::open_raw() {
                Ok(settings) => Some(settings),
                Err(error) => {
                    log::error!("Failed to setup terminal: {error}");

                    None
                }
            },
            alt_screen: if let Err(error) = enter_alt_screen() {
                log::error!("Failed to enter alternative screen: {error}");

                false
            } else {
                true
            },
        }
    }

    pub fn teardown(&mut self) {
        if let Some(ref settings) = self.settings {
            if let Err(error) = settings.apply() {
                log::error!("Failed to revert terminal settings: {error}");
            }

            self.settings = None;
        }

        if self.alt_screen {
            if let Err(error) = quit_alt_screen() {
                log::error!("Failed to quit alternative screen: {error}");
            }

            self.alt_screen = false;
        }
    }
}

const SEQUENCES: [(u32, bool); 4] = [(1049, true), (1003, true), (1006, true), (25, false)];

fn enter_alt_screen() -> io::Result<()> {
    let mut out = io::stdout();

    for (sequence, enable) in SEQUENCES {
        write!(out, "\x1b[?{}{}", sequence, if enable { "h" } else { "l" })?;
    }

    // Set the current foreground color to black
    write!(out, "\x1b[48;2;0;0;0m")?;
    // Query current foreground color to for true-color support detection
    write!(out, "\x1bP$qm\x1b\\")?;
    // Query current terminal name
    write!(out, "\x1bP+q544e\x1b\\")?;

    out.flush()
}

fn quit_alt_screen() -> io::Result<()> {
    let mut out = io::stdout();

    for (sequence, enable) in SEQUENCES {
        write!(out, "\x1b[?{}{}", sequence, if enable { "l" } else { "h" })?;
    }

    out.flush()
}
