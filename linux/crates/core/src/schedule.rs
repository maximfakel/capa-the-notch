use std::time::Duration;

/// How long to wait before reading a Provider again.
///
/// An open surface is being watched, so it is read often; a closed one is
/// glanced at, so it is read rarely. A Provider that has just failed is given
/// room: from the second consecutive failure each one doubles the wait, up to
/// a ceiling. A first failure is only a blip and is tried again soon.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RefreshSchedule {
    pub while_expanded: Duration,
    pub while_compact: Duration,
    pub failure_ceiling: Duration,
    pub first_retry: Duration,
}

impl RefreshSchedule {
    pub const STANDARD: Self = Self {
        while_expanded: Duration::from_secs(60),
        while_compact: Duration::from_secs(300),
        failure_ceiling: Duration::from_secs(900),
        first_retry: Duration::from_secs(30),
    };

    /// `consecutive_failures` counts only failures worth retrying: a Provider
    /// waiting on a person is read at the surface's own pace.
    pub fn delay(&self, expanded: bool, consecutive_failures: u32) -> Duration {
        let base = if expanded { self.while_expanded } else { self.while_compact };
        if consecutive_failures == 0 {
            return base;
        }
        if consecutive_failures == 1 {
            return self.first_retry.min(base);
        }
        // Bounded before it is computed: a large count must not overflow.
        let doublings = (consecutive_failures - 1).min(16);
        (base * 2u32.pow(doublings)).min(self.failure_ceiling)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_backs_off_and_stops_at_the_ceiling() {
        let s = RefreshSchedule::STANDARD;
        let secs = |e, n| s.delay(e, n).as_secs();
        assert_eq!(secs(true, 0), 60);
        assert_eq!(secs(false, 0), 300);
        assert_eq!(secs(false, 1), 30);
        assert_eq!(secs(true, 1), 30);
        assert_eq!(secs(true, 2), 120);
        assert_eq!(secs(true, 3), 240);
        assert_eq!(secs(false, 2), 600);
        assert_eq!(secs(false, 3), 900);
        assert_eq!(secs(false, u32::MAX), 900);
    }
}
