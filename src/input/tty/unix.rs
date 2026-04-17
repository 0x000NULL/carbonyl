use std::fs::File;
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::RawFd;
use std::os::unix::prelude::AsRawFd;

enum TTY {
    Raw(RawFd),
    File(File),
}

impl TTY {
    fn stdin() -> TTY {
        let isatty = unsafe { libc::isatty(libc::STDIN_FILENO) };

        if isatty != 1 {
            if let Ok(file) = File::open("/dev/tty") {
                return TTY::File(file);
            }
        }

        TTY::Raw(libc::STDIN_FILENO)
    }

    fn as_raw_fd(self) -> RawFd {
        match self {
            TTY::Raw(fd) => fd,
            TTY::File(file) => file.as_raw_fd(),
        }
    }
}

trait ToErr {
    fn to_err(self) -> io::Result<()>;
}
impl ToErr for libc::c_int {
    fn to_err(self) -> io::Result<()> {
        if self == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

/// Safe wrapper around libc::termios
#[derive(Clone)]
pub(super) struct TerminalSettings {
    data: libc::termios,
}

impl TerminalSettings {
    /// Fetch the current TTY settings, apply raw mode, and return the
    /// pre-raw snapshot so the caller can restore it later.
    pub fn open_raw() -> io::Result<TerminalSettings> {
        let mut raw = Self::open()?;
        let settings = raw.clone();

        raw.make_raw();
        raw.apply()?;

        Ok(settings)
    }

    /// Apply the settings to the current TTY
    pub fn apply(&self) -> io::Result<()> {
        let tty = TTY::stdin();

        unsafe { libc::tcsetattr(tty.as_raw_fd(), libc::TCSANOW, &self.data).to_err() }
    }

    /// Fetch settings from the current TTY
    fn open() -> io::Result<Self> {
        let tty = TTY::stdin();
        let mut term = MaybeUninit::uninit();
        let data = unsafe {
            libc::tcgetattr(tty.as_raw_fd(), term.as_mut_ptr()).to_err()?;

            term.assume_init()
        };

        Ok(Self { data })
    }

    /// Enable raw input
    fn make_raw(&mut self) {
        let c_oflag = self.data.c_oflag;

        // Set the terminal to raw mode
        unsafe { libc::cfmakeraw(&mut self.data) }

        // Restore output flags, ensures carriage returns are consistent
        self.data.c_oflag = c_oflag;
    }
}
