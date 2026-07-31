use std::{
    io::{self, Read},
    process::{Command, ExitStatus, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

const STDERR_LIMIT: usize = 1024 * 1024;

pub(crate) struct CapturedOutput {
    pub(crate) status: ExitStatus,
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) stdout_exceeded: bool,
    pub(crate) timed_out: bool,
    pub(crate) cancelled: bool,
}

pub(crate) fn capture(
    command: &mut Command,
    timeout: Duration,
    max_stdout: usize,
) -> io::Result<CapturedOutput> {
    capture_cancellable(command, timeout, max_stdout, None)
}

pub(crate) fn capture_cancellable(
    command: &mut Command,
    timeout: Duration,
    max_stdout: usize,
    cancellation: Option<&AtomicBool>,
) -> io::Result<CapturedOutput> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let stdout = child.stdout.take().expect("stdout configured as piped");
    let stderr = child.stderr.take().expect("stderr configured as piped");
    let stdout_reader = thread::spawn(move || read_capped(stdout, max_stdout));
    let stderr_reader = thread::spawn(move || read_capped(stderr, STDERR_LIMIT));
    let started = Instant::now();
    let (status, timed_out, cancelled) = loop {
        match child.try_wait()? {
            Some(status) => break (status, false, false),
            None if cancellation.is_some_and(|cancelled| cancelled.load(Ordering::Acquire)) => {
                let _ = child.kill();
                break (child.wait()?, false, true);
            }
            None if started.elapsed() < timeout => thread::sleep(Duration::from_millis(10)),
            None => {
                let _ = child.kill();
                break (child.wait()?, true, false);
            }
        }
    };
    let (stdout, stdout_exceeded) = stdout_reader
        .join()
        .map_err(|_| io::Error::other("stdout reader thread panicked"))??;
    let (stderr, _) = stderr_reader
        .join()
        .map_err(|_| io::Error::other("stderr reader thread panicked"))??;
    Ok(CapturedOutput {
        status,
        stdout,
        stderr,
        stdout_exceeded,
        timed_out,
        cancelled,
    })
}

fn read_capped(mut reader: impl Read, limit: usize) -> io::Result<(Vec<u8>, bool)> {
    let mut kept = Vec::new();
    let mut buffer = [0_u8; 8192];
    let mut exceeded = false;
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        let remaining = limit.saturating_sub(kept.len());
        let retain = count.min(remaining);
        kept.extend_from_slice(&buffer[..retain]);
        exceeded |= retain < count;
    }
    Ok((kept, exceeded))
}
