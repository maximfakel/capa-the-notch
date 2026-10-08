//! Claude Code's Capacity, read through `claude /usage`.
//!
//! The report is prose, not a contract. Every failure here returns nothing
//! rather than a guess: a Provider that cannot be read must say so, not show a
//! number that has quietly stopped moving.

use crate::snapshot::QuotaWindow;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;

/// How long a reading counts as Fresh Capacity.
pub const FRESH_FOR: std::time::Duration = std::time::Duration::from_secs(5 * 60);

/// Flags: `--print` avoids the workspace-trust prompt, `--no-session-persistence`
/// leaves no transcript, `--strict-mcp-config` with no config starts no MCP server.
pub const ARGUMENTS: [&str; 4] = ["--print", "--no-session-persistence", "--strict-mcp-config", "/usage"];

#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeCapacityReading {
    pub captured_at: DateTime<Utc>,
    pub windows: Vec<QuotaWindow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageCommandError {
    ClaudeCodeNotInstalled,
    CommandFailed,
    OutputNotUnderstood,
}

/// Why a source of Claude Capacity has no reading: `/usage` failed, or the
/// status-line bridge's file could not be read (`ClaudeStatusLineBridgeError`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceError {
    Usage(UsageCommandError),
    Bridge(crate::claude_bridge::BridgeError),
}

impl From<UsageCommandError> for SourceError {
    fn from(error: UsageCommandError) -> Self {
        SourceError::Usage(error)
    }
}

impl From<crate::claude_bridge::BridgeError> for SourceError {
    fn from(error: crate::claude_bridge::BridgeError) -> Self {
        SourceError::Bridge(error)
    }
}

/// Turns the printed report into a reading, or nothing when no line is one of
/// the windows shown — or when one is worded in a way not known. That is what
/// a changed report looks like, and reading only the lines still recognised
/// would drop a window without a word.
pub fn reading(text: &str, captured_at: DateTime<Utc>) -> Option<ClaudeCapacityReading> {
    if text.lines().any(is_unknown_window) {
        return None;
    }
    let windows: Vec<_> = text.lines().filter_map(|l| window(l, captured_at)).collect();
    if windows.is_empty() {
        return None;
    }
    Some(ClaudeCapacityReading { captured_at, windows })
}

fn shape(line: &str) -> Option<(&'static str, &'static str, i64)> {
    if line.starts_with("Current session:") {
        Some(("claude-five-hour", "5 hour", 300))
    } else if line.starts_with("Current week (all models):") {
        Some(("claude-seven-day", "Weekly", 10_080))
    } else {
        None
    }
}

/// The text between the colon and `% used`, when the line has a window's form.
fn percent_text(line: &str) -> Option<&str> {
    let colon = line.find(':')?;
    let used = colon + line[colon..].find("% used")?;
    Some(line[colon + 1..used].trim())
}

fn window(line: &str, captured_at: DateTime<Utc>) -> Option<QuotaWindow> {
    let line = line.trim();
    let (id, label, minutes) = shape(line)?;
    let percent: f64 = percent_text(line)?.parse().ok()?;
    // `percent >= 0` as Swift has it, which a NaN fails too.
    if percent.is_nan() || percent < 0.0 {
        return None;
    }
    Some(QuotaWindow::new(id, label, Some(minutes), (percent / 100.0).min(1.0), reset_date(line, captured_at)))
}

/// A line with a window's form that is neither a window shown nor one
/// knowingly left out (a per-model week).
fn is_unknown_window(line: &str) -> bool {
    let line = line.trim();
    percent_text(line).is_some() && shape(line).is_none() && !line.starts_with("Current week (")
}

enum Zone {
    Named(Tz),
    Local,
}

/// The reset moment from `resets Sep 20 at 7pm (Europe/Moscow)`.
///
/// The year is not printed, so it comes from the reading's own moment. A date
/// far enough in the past to be implausible is read as next year's.
fn reset_date(line: &str, captured_at: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let tail = &line[line.find("resets ")? + "resets ".len()..];
    let (stamp, zone) = match tail.find('(') {
        Some(open) => {
            let named: String = tail[open + 1..].chars().take_while(|c| *c != ')').collect();
            let zone = named.parse::<Tz>().map(Zone::Named).unwrap_or(Zone::Local);
            (tail[..open].trim(), zone)
        }
        None => (tail.trim(), Zone::Local),
    };
    let (month, day, time) = parse_stamp(stamp)?;

    let year_in_zone = |year: i32| -> Option<DateTime<Utc>> {
        let naive = NaiveDateTime::new(NaiveDate::from_ymd_opt(year, month, day)?, time);
        match &zone {
            Zone::Named(tz) => tz.from_local_datetime(&naive).earliest().map(|d| d.with_timezone(&Utc)),
            Zone::Local => Local.from_local_datetime(&naive).earliest().map(|d| d.with_timezone(&Utc)),
        }
    };
    let this_year = match &zone {
        Zone::Named(tz) => captured_at.with_timezone(tz).year(),
        Zone::Local => captured_at.with_timezone(&Local).year(),
    };

    let candidate = year_in_zone(this_year)?;
    // Past by more than a week is next year's, seen across the turn of the
    // year; a few days of slack keeps a clock skew from triggering it.
    if candidate - captured_at < -Duration::days(7) {
        return year_in_zone(this_year + 1);
    }
    Some(candidate)
}

/// `Sep 20 at 7pm`, `Sep 20 at 7:30pm` or `Oct 6, 1:39am`.
fn parse_stamp(stamp: &str) -> Option<(u32, u32, NaiveTime)> {
    let mut words = stamp.split_whitespace();
    let month = match words.next()? {
        "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
        "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
        _ => return None,
    };
    // `Sep 20 at 7pm`, and the newer `Oct 6, 1:39am`.
    let day: u32 = words.next()?.trim_end_matches(',').parse().ok()?;
    let mut clock = words.next()?;
    if clock == "at" {
        clock = words.next()?;
    }
    if words.next().is_some() {
        return None;
    }
    let (digits, pm) = if let Some(d) = clock.strip_suffix("pm") {
        (d, true)
    } else {
        (clock.strip_suffix("am")?, false)
    };
    let (hour, minute) = match digits.split_once(':') {
        Some((h, m)) => (h.parse::<u32>().ok()?, m.parse::<u32>().ok()?),
        None => (digits.parse::<u32>().ok()?, 0),
    };
    if !(1..=12).contains(&hour) {
        return None;
    }
    let hour = hour % 12 + if pm { 12 } else { 0 };
    Some((month, day, NaiveTime::from_hms_opt(hour, minute, 0)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_at() -> DateTime<Utc> {
        Utc.timestamp_opt(1_789_909_000, 0).unwrap()
    }

    const REAL: &str = "You are currently using your subscription to power your Claude Code usage

Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)
Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine.

Last 24h · 825 requests · 3 sessions
  97% of your usage was at >150k context
";

    #[test]
    fn the_usage_report_becomes_quota_windows() {
        let r = reading(REAL, read_at()).expect("a real report reads");
        let ids: Vec<_> = r.windows.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, ["claude-five-hour", "claude-seven-day"]);
        assert_eq!(r.windows[0].remaining_percentage(), 76.0);
        assert_eq!(r.windows[1].remaining_percentage(), 11.0);
        assert_eq!(r.captured_at, read_at());
        // 2026-09-20 19:00 in Moscow (UTC+3) is 16:00 UTC.
        assert_eq!(r.windows[0].resets_at, Utc.with_ymd_and_hms(2026, 9, 20, 16, 0, 0).single());
        assert_eq!(r.windows[1].resets_at, Utc.with_ymd_and_hms(2026, 9, 20, 15, 0, 0).single());
    }

    #[test]
    fn prose_that_no_longer_parses_is_not_a_reading() {
        assert!(reading("Session usage: 24 percent\n", read_at()).is_none());
        assert!(reading("", read_at()).is_none());
        let no_reset = reading("Current session: 24% used\n", read_at()).unwrap();
        assert_eq!(no_reset.windows[0].resets_at, None);
    }

    #[test]
    fn a_window_in_wording_not_known_refuses_the_whole_report() {
        let reworded = REAL.replace("Current week (all models):", "This week (all models):");
        assert!(reading(&reworded, read_at()).is_none());
    }

    #[test]
    fn windows_left_out_on_purpose_are_not_a_changed_report() {
        let with_model = REAL.replace(
            "Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)",
            "Current week (all models): 89% used · resets Sep 20 at 6pm (Europe/Moscow)\nCurrent week (Fable): 41% used · resets Sep 20 at 6pm (Europe/Moscow)",
        );
        let ids: Vec<_> = reading(&with_model, read_at()).unwrap().windows.into_iter().map(|w| w.id).collect();
        assert_eq!(ids, ["claude-five-hour", "claude-seven-day"]);

        let one = reading("Current session: 24% used · resets Sep 20 at 7pm (Europe/Moscow)\n", read_at()).unwrap();
        assert_eq!(one.windows.len(), 1);
    }

    #[test]
    fn a_window_without_a_year_reads_as_the_one_ahead() {
        // Read on 28 December 2026, a window that resets on 2 January.
        let december = Utc.timestamp_opt(1_798_500_000, 0).unwrap();
        let r = reading("Current session: 5% used · resets Jan 2 at 3am (UTC)\n", december).unwrap();
        assert_eq!(r.windows[0].resets_at, Utc.with_ymd_and_hms(2027, 1, 2, 3, 0, 0).single());
    }

    #[test]
    fn minutes_and_twelve_oclock_read_right() {
        assert_eq!(parse_stamp("Sep 20 at 7:30pm").unwrap().2, NaiveTime::from_hms_opt(19, 30, 0).unwrap());
        assert_eq!(parse_stamp("Sep 20 at 12am").unwrap().2, NaiveTime::from_hms_opt(0, 0, 0).unwrap());
        assert_eq!(parse_stamp("Sep 20 at 12pm").unwrap().2, NaiveTime::from_hms_opt(12, 0, 0).unwrap());
        assert!(parse_stamp("Sep 20 at 13pm").is_none());
        assert!(parse_stamp("Smarch 20 at 7pm").is_none());
    }

    #[test]
    fn the_newer_wording_with_a_comma_reads_too() {
        // What `claude /usage` printed on 5 October 2026.
        let report = "Current session: 0% used · resets Oct 6, 1:39am (Europe/Moscow)\nCurrent week (all models): 8% used · resets Oct 11, 5:59pm (Europe/Moscow)\nCurrent week (Fable): 0% used · resets Oct 11, 6pm (Europe/Moscow)\n";
        let now = Utc.with_ymd_and_hms(2026, 10, 5, 12, 0, 0).unwrap();
        let r = reading(report, now).expect("the newer wording reads");
        // 01:39 in Moscow (UTC+3) is 22:39 UTC the day before.
        assert_eq!(r.windows[0].resets_at, Utc.with_ymd_and_hms(2026, 10, 5, 22, 39, 0).single());
        assert_eq!(r.windows[1].resets_at, Utc.with_ymd_and_hms(2026, 10, 11, 14, 59, 0).single());
    }

    #[test]
    fn a_percentage_that_is_not_a_number_is_not_a_reading() {
        assert!(reading("Current session: NaN% used\n", read_at()).is_none());
        assert!(reading("Current session: -3% used\n", read_at()).is_none());
    }

    #[test]
    fn usage_over_a_hundred_is_clamped() {
        let r = reading("Current session: 130% used\n", read_at()).unwrap();
        assert_eq!(r.windows[0].used_fraction, 1.0);
    }
}
