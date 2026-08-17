use std::{
    cell::Cell,
    time::{Duration, Instant},
};

thread_local! {
    static ACTIVE: Cell<Option<Instant>> = const { Cell::new(None) };
}

pub(crate) struct Guard(Option<Instant>);

pub(crate) fn enter(timeout: Option<Duration>) -> Guard {
    let deadline = timeout.map(|timeout| Instant::now() + timeout);
    Guard(ACTIVE.replace(deadline))
}

/// Capture the caller's absolute deadline so work moved to another thread
/// retains the same budget rather than receiving a fresh one.
pub(crate) fn snapshot() -> Option<Instant> {
    ACTIVE.with(Cell::get)
}

/// Enter a deadline captured by [`snapshot`].
pub(crate) fn enter_snapshot(deadline: Option<Instant>) -> Guard {
    Guard(ACTIVE.replace(deadline))
}

pub(crate) fn effective(requested: Duration) -> Option<Duration> {
    ACTIVE.with(|active| match active.get() {
        Some(deadline) => deadline
            .checked_duration_since(Instant::now())
            .map(|remaining| remaining.min(requested)),
        None => Some(requested),
    })
}

/// Whether the deadline inherited by this synchronous callback has elapsed.
pub(crate) fn expired() -> bool {
    ACTIVE.with(|active| {
        active
            .get()
            .is_some_and(|deadline| Instant::now() >= deadline)
    })
}

impl Drop for Guard {
    fn drop(&mut self) {
        ACTIVE.set(self.0);
    }
}
