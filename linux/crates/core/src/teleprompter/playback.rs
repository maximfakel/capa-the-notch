use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PlaybackState {
    Stopped,
    Running,
    Paused,
    /// On the last line, still in view for a moment before the row goes.
    Finished,
}

/// Where the Script is, and how it moves on: the Teleprompter Module's
/// Running, Paused and Stopped (CONTEXT.md), as a value that answers for any
/// moment it is asked about.
///
/// The place is counted in lines of the Script as laid out on the row. The
/// speed is a multiplier, as the page and Settings show it: 1.00x is 130 words
/// a minute, an easy pace read aloud, and it turns a quarter at a time. The
/// words meet the lines through the Script's average line: a steady speed in
/// words is a steady speed on screen, which is what the eye can follow.
#[derive(Debug, Clone, PartialEq)]
pub struct TeleprompterPlayback {
    state: PlaybackState,
    multiplier: f64,
    word_count: usize,
    line_count: usize,
    /// The place at `anchored_at`; while running it moves on from there.
    anchor: f64,
    anchored_at: DateTime<Utc>,
    finished_at: Option<DateTime<Utc>>,
}

/// How a running Script moves on from where it was anchored.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlaybackMotion {
    pub anchor: f64,
    pub anchored_at: DateTime<Utc>,
    pub lines_per_second: f64,
    pub last_line: f64,
}

/// What a surface draws of the playback at one moment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackView {
    pub state: PlaybackState,
    pub is_showing: bool,
    pub multiplier: f64,
    pub words_per_minute: f64,
    /// In lines from the first.
    pub position: f64,
    /// 0 to 1.
    pub progress: f64,
    pub elapsed_seconds: f64,
    pub remaining_seconds: f64,
    pub duration_seconds: f64,
}

fn seconds(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_microseconds().map_or_else(|| (to - from).num_seconds() as f64, |us| us as f64 / 1e6)
}

fn after(at: DateTime<Utc>, secs: f64) -> DateTime<Utc> {
    at + Duration::microseconds((secs * 1e6).round() as i64)
}

impl TeleprompterPlayback {
    /// How long the first line holds, so the eyes can come up to it.
    pub const START_HOLD: f64 = 1.0;
    /// How long the last line stays once the Script has been read.
    pub const FINISH_LINGER: f64 = 3.0;
    /// Words a minute at 1.00x.
    pub const STANDARD_SPEED: f64 = 130.0;
    pub const MULTIPLIER_MIN: f64 = 0.5;
    pub const MULTIPLIER_MAX: f64 = 2.0;
    pub const MULTIPLIER_STEP: f64 = 0.25;

    pub fn new(word_count: usize, line_count: usize, multiplier: f64) -> Self {
        Self {
            state: PlaybackState::Stopped,
            multiplier: Self::clamped_multiplier(multiplier),
            word_count,
            line_count,
            anchor: 0.0,
            anchored_at: DateTime::<Utc>::MIN_UTC,
            finished_at: None,
        }
    }

    pub fn state(&self) -> PlaybackState {
        self.state
    }

    pub fn multiplier(&self) -> f64 {
        self.multiplier
    }

    pub fn word_count(&self) -> usize {
        self.word_count
    }

    pub fn line_count(&self) -> usize {
        self.line_count
    }

    /// The speed read at.
    pub fn words_per_minute(&self) -> f64 {
        Self::STANDARD_SPEED * self.multiplier
    }

    /// Whether the Teleprompter Row is in view.
    pub fn is_showing(&self) -> bool {
        self.state != PlaybackState::Stopped
    }

    /// The place, in lines from the first; the last line is `line_count - 1`.
    pub fn position(&self, now: DateTime<Utc>) -> f64 {
        if self.state != PlaybackState::Running {
            return self.anchor;
        }
        (self.anchor + seconds(self.anchored_at, now).max(0.0) * self.lines_per_second()).min(self.last_line())
    }

    /// What a surface needs to carry the place on between the moments it is told:
    /// the place at `anchored_at`, from when the Script moves, and how fast. While
    /// running, the place at any later moment is `min(anchor + max(0, t - anchored_at) × lines_per_second, last_line)`.
    pub fn motion(&self) -> PlaybackMotion {
        PlaybackMotion {
            anchor: self.anchor,
            anchored_at: self.anchored_at,
            lines_per_second: self.lines_per_second(),
            last_line: self.last_line(),
        }
    }

    /// How far through the Script, from 0 to 1.
    pub fn progress(&self, now: DateTime<Utc>) -> f64 {
        if self.last_line() > 0.0 { self.position(now) / self.last_line() } else { 0.0 }
    }

    pub fn elapsed_seconds(&self, now: DateTime<Utc>) -> f64 {
        let lps = self.lines_per_second();
        if lps > 0.0 { self.position(now) / lps } else { 0.0 }
    }

    pub fn remaining_seconds(&self, now: DateTime<Utc>) -> f64 {
        let lps = self.lines_per_second();
        if lps > 0.0 { (self.last_line() - self.position(now)) / lps } else { 0.0 }
    }

    /// The whole Script, first line to last, at the speed it is read at.
    pub fn duration_seconds(&self) -> f64 {
        let lps = self.lines_per_second();
        if lps > 0.0 { self.last_line() / lps } else { 0.0 }
    }

    /// When a running Script reaches its last line.
    pub fn ends_at(&self) -> Option<DateTime<Utc>> {
        let lps = self.lines_per_second();
        (self.state == PlaybackState::Running && lps > 0.0).then(|| after(self.anchored_at, (self.last_line() - self.anchor) / lps))
    }

    /// When a finished Script's row goes.
    pub fn leaves_at(&self) -> Option<DateTime<Utc>> {
        self.finished_at.map(|at| after(at, Self::FINISH_LINGER))
    }

    /// The next moment something changes by itself: the last line reached, or
    /// the row leaving. A surface sets one timer for this and nothing else.
    pub fn next_wake(&self) -> Option<DateTime<Utc>> {
        self.ends_at().or_else(|| self.leaves_at())
    }

    pub fn view(&self, now: DateTime<Utc>) -> PlaybackView {
        PlaybackView {
            state: self.state,
            is_showing: self.is_showing(),
            multiplier: self.multiplier,
            words_per_minute: self.words_per_minute(),
            position: self.position(now),
            progress: self.progress(now),
            elapsed_seconds: self.elapsed_seconds(now),
            remaining_seconds: self.remaining_seconds(now),
            duration_seconds: self.duration_seconds(),
        }
    }

    // MARK: - What a person does

    pub fn start(&mut self, now: DateTime<Utc>) {
        if self.word_count == 0 || self.line_count == 0 {
            return;
        }
        self.state = PlaybackState::Running;
        self.anchor = 0.0;
        self.anchored_at = after(now, Self::START_HOLD);
        self.finished_at = None;
    }

    /// The one control for start, pause and resume: the click on the row and
    /// the first shortcut.
    pub fn toggle(&mut self, now: DateTime<Utc>) {
        match self.state {
            PlaybackState::Stopped | PlaybackState::Finished => self.start(now),
            PlaybackState::Running => self.pause(now),
            PlaybackState::Paused => self.resume(now),
        }
    }

    pub fn pause(&mut self, now: DateTime<Utc>) {
        if self.state != PlaybackState::Running {
            return;
        }
        self.anchor = self.position(now);
        self.state = PlaybackState::Paused;
    }

    pub fn resume(&mut self, now: DateTime<Utc>) {
        if self.state != PlaybackState::Paused {
            return;
        }
        self.anchored_at = now;
        self.state = PlaybackState::Running;
    }

    pub fn stop(&mut self) {
        self.state = PlaybackState::Stopped;
        self.anchor = 0.0;
        self.finished_at = None;
    }

    pub fn faster(&mut self, now: DateTime<Utc>) {
        self.set_multiplier(self.multiplier + Self::MULTIPLIER_STEP, now);
    }

    pub fn slower(&mut self, now: DateTime<Utc>) {
        self.set_multiplier(self.multiplier - Self::MULTIPLIER_STEP, now);
    }

    pub fn set_multiplier(&mut self, value: f64, now: DateTime<Utc>) {
        self.rebase(now);
        self.multiplier = Self::clamped_multiplier(value);
    }

    /// Two fingers on the row: the Script moves under them, and stays put when
    /// they lift.
    pub fn move_by_lines(&mut self, lines: f64, now: DateTime<Utc>) {
        if !self.is_showing() {
            return;
        }
        self.anchor = (self.position(now) + lines).clamp(0.0, self.last_line());
        if self.state != PlaybackState::Paused {
            self.state = PlaybackState::Paused;
        }
        self.finished_at = None;
    }

    /// The progress dragged on the page. A Script not running is left paused
    /// there, so the next start begins where it was put.
    pub fn seek_to_fraction(&mut self, fraction: f64, now: DateTime<Utc>) {
        if self.word_count == 0 || self.line_count == 0 {
            return;
        }
        self.anchor = fraction.clamp(0.0, 1.0) * self.last_line();
        self.finished_at = None;
        if self.state == PlaybackState::Running {
            self.anchored_at = now.max(self.anchored_at);
        } else {
            self.state = PlaybackState::Paused;
        }
    }

    /// The Script laid out again — another text size, another Script — keeps
    /// its place as a share of the whole.
    pub fn relayout(&mut self, word_count: usize, line_count: usize, now: DateTime<Utc>) {
        let fraction = self.progress(now);
        self.rebase(now);
        self.word_count = word_count;
        self.line_count = line_count;
        self.anchor = fraction * self.last_line();
        if self.word_count == 0 || self.line_count == 0 {
            self.stop();
        }
    }

    /// Moves the states that change by themselves on to `now`: the last line
    /// reached, and the row leaving three seconds after.
    pub fn advance(&mut self, now: DateTime<Utc>) {
        if self.state == PlaybackState::Running {
            if let Some(ends) = self.ends_at() {
                if now >= ends {
                    self.anchor = self.last_line();
                    self.state = PlaybackState::Finished;
                    self.finished_at = Some(ends);
                }
            }
        }
        if self.state == PlaybackState::Finished {
            if let Some(leaves) = self.leaves_at() {
                if now >= leaves {
                    self.stop();
                }
            }
        }
    }

    // MARK: -

    fn last_line(&self) -> f64 {
        self.line_count.saturating_sub(1) as f64
    }

    fn lines_per_second(&self) -> f64 {
        if self.word_count == 0 || self.line_count == 0 {
            return 0.0;
        }
        let words_per_line = self.word_count as f64 / self.line_count as f64;
        self.words_per_minute() / 60.0 / words_per_line
    }

    /// Fixes the place reached so far as the new starting point, keeping a
    /// hold that has not run out yet.
    fn rebase(&mut self, now: DateTime<Utc>) {
        if self.state != PlaybackState::Running {
            return;
        }
        self.anchor = self.position(now);
        self.anchored_at = now.max(self.anchored_at);
    }

    /// Kept to the hundredth, so a step lands on 1.25 and never drifts to
    /// 1.2499.
    pub fn clamped_multiplier(value: f64) -> f64 {
        (value.clamp(Self::MULTIPLIER_MIN, Self::MULTIPLIER_MAX) * 100.0).round() / 100.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn start() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn at(secs: f64) -> DateTime<Utc> {
        after(start(), secs)
    }

    /// 130 words in 13 lines: ten words a line, so at 130 words a minute the
    /// Script moves on 13 lines a minute — one every 60/13 seconds.
    fn playback() -> TeleprompterPlayback {
        TeleprompterPlayback::new(130, 13, 1.0)
    }

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 0.0001
    }

    const LINE: f64 = 60.0 / 13.0;

    #[test]
    fn starting_holds_the_first_line_then_moves_at_the_chosen_speed() {
        let mut p = playback();
        assert!(p.state() == PlaybackState::Stopped && !p.is_showing(), "stopped shows no row");

        p.start(start());
        assert!(p.state() == PlaybackState::Running && p.is_showing(), "started, it runs");
        assert_eq!(p.position(at(0.9)), 0.0, "the first line holds for about a second");
        assert!(near(p.position(at(1.0 + LINE)), 1.0), "then one line every 60/13 s: {}", p.position(at(1.0 + LINE)));
    }

    #[test]
    fn an_empty_script_does_not_start() {
        let mut p = TeleprompterPlayback::new(0, 0, 1.0);
        p.start(start());
        assert_eq!(p.state(), PlaybackState::Stopped, "nothing to read, nothing runs");
    }

    #[test]
    fn pause_holds_the_place_and_resume_goes_on_from_it() {
        let mut p = playback();
        p.start(start());
        let later = at(1.0 + 2.0 * LINE);
        p.toggle(later);
        assert_eq!(p.state(), PlaybackState::Paused, "toggling a running Script pauses it");
        assert!(near(p.position(after(later, 30.0)), 2.0), "paused, it stays where it was");

        let resumed = after(later, 30.0);
        p.toggle(resumed);
        assert_eq!(p.state(), PlaybackState::Running, "toggling again resumes");
        assert!(near(p.position(after(resumed, LINE)), 3.0), "from where it was, without a second hold");
    }

    #[test]
    fn stop_clears_the_row_and_starts_over() {
        let mut p = playback();
        p.start(start());
        p.stop();
        assert!(p.state() == PlaybackState::Stopped && !p.is_showing(), "stopped, no row");
        p.start(at(100.0));
        assert_eq!(p.position(at(100.5)), 0.0, "the next start is from the top");
    }

    #[test]
    fn faster_and_slower_change_the_speed_in_quarters() {
        let mut p = playback();
        assert!(near(p.multiplier(), 1.0) && near(p.words_per_minute(), 130.0), "1.00x is 130 words a minute");
        p.start(start());
        let later = at(1.0 + LINE);
        p.faster(later);
        assert!(near(p.multiplier(), 1.25), "faster is a quarter more: {}", p.multiplier());
        assert!(near(p.words_per_minute(), 162.5), "of 130: {}", p.words_per_minute());
        assert!(near(p.position(later), 1.0), "the place does not jump");
        assert!(near(p.position(after(later, 60.0 / (13.0 * 1.25))), 2.0), "and it goes on at the new speed");

        let mut slow = playback();
        for _ in 0..100 {
            slow.slower(start());
        }
        assert!(near(slow.multiplier(), TeleprompterPlayback::MULTIPLIER_MIN), "never slower than half");
        let mut quick = playback();
        for _ in 0..100 {
            quick.faster(start());
        }
        assert!(near(quick.multiplier(), TeleprompterPlayback::MULTIPLIER_MAX), "never faster than twice");
        for _ in 0..3 {
            quick.slower(start());
        }
        assert!(near(quick.multiplier(), 1.25), "three quarters back from twice: {}", quick.multiplier());
    }

    #[test]
    fn fingers_move_the_script_and_pause_it() {
        let mut p = playback();
        p.start(start());
        let later = at(1.0 + 4.0 * LINE);
        p.move_by_lines(-1.5, later);
        assert_eq!(p.state(), PlaybackState::Paused, "moving it by hand pauses it");
        assert!(near(p.position(later), 2.5), "back a line and a half");
        p.move_by_lines(-10.0, later);
        assert_eq!(p.position(later), 0.0, "never before the first line");
        p.move_by_lines(100.0, later);
        assert!(near(p.position(later), 12.0), "nor past the last");
    }

    #[test]
    fn fingers_do_nothing_to_a_script_that_is_not_showing() {
        let mut p = playback();
        p.move_by_lines(3.0, start());
        assert_eq!((p.state(), p.position(start())), (PlaybackState::Stopped, 0.0));
    }

    #[test]
    fn dragging_the_progress_goes_anywhere_in_the_script() {
        let mut p = playback();
        p.start(start());
        p.seek_to_fraction(0.5, at(3.0));
        assert!(near(p.position(at(3.0)), 6.0), "half way is line six of twelve moves");
        assert_eq!(p.state(), PlaybackState::Running, "a running Script keeps running from there");
        assert!(near(p.progress(at(3.0)), 0.5), "and says so");
    }

    #[test]
    fn dragging_the_progress_of_a_stopped_script_chooses_where_it_starts() {
        let mut p = playback();
        p.seek_to_fraction(0.5, start());
        assert!(p.state() == PlaybackState::Paused && p.is_showing(), "dragged, the row shows the place, paused");
        p.toggle(at(1.0));
        assert_eq!(p.state(), PlaybackState::Running, "then it runs");
        assert!(near(p.position(at(1.0 + LINE)), 7.0), "from there, not from the top");
    }

    #[test]
    fn at_the_end_it_stops_on_the_last_line_and_the_row_leaves_after_three_seconds() {
        let mut p = playback();
        p.start(start());
        let end = p.ends_at().expect("a running Script knows when it ends");
        assert!(near(seconds(start(), end), 1.0 + 12.0 * LINE), "twelve moves after the hold");
        assert_eq!(p.next_wake(), Some(end), "that is what a surface waits for");

        p.advance(after(end, 1.0));
        assert!(p.state() == PlaybackState::Finished && p.is_showing(), "it stops on the last line and stays in view");
        assert!(near(p.position(after(end, 1.0)), 12.0), "on the last line");
        assert_eq!(p.next_wake(), p.leaves_at(), "then it waits for the row to leave");

        p.advance(after(end, 2.9));
        assert_eq!(p.state(), PlaybackState::Finished, "still there before three seconds");
        p.advance(after(end, 3.0));
        assert!(p.state() == PlaybackState::Stopped && !p.is_showing(), "gone after three seconds");
        assert_eq!(p.next_wake(), None, "and nothing ticks");

        p.toggle(after(end, 10.0));
        assert!(p.state() == PlaybackState::Running && p.position(after(end, 10.5)) == 0.0, "the next start is from the top");
    }

    #[test]
    fn time_spent_and_left_follow_the_place() {
        let mut p = playback();
        p.start(start());
        let later = at(1.0 + 3.0 * LINE);
        assert!(near(p.elapsed_seconds(later), 3.0 * LINE), "time read so far");
        assert!(near(p.remaining_seconds(later), 9.0 * LINE), "time still to read");
        assert!(near(p.duration_seconds(), 12.0 * LINE), "and the whole, as the page shows it");
        p.faster(later);
        assert!(near(p.duration_seconds(), 12.0 * 60.0 / (13.0 * 1.25)), "at the speed it is read at");
    }

    #[test]
    fn a_new_layout_keeps_the_place_in_the_script() {
        let mut p = playback();
        p.start(start());
        let later = at(1.0 + 6.0 * LINE);
        p.relayout(130, 25, later);
        assert!(near(p.progress(later), 0.5), "half way stays half way when the text grows: {}", p.progress(later));
    }

    #[test]
    fn a_script_emptied_while_running_stops() {
        let mut p = playback();
        p.start(start());
        p.relayout(0, 0, at(5.0));
        assert_eq!(p.state(), PlaybackState::Stopped);
    }

    #[test]
    fn changing_the_speed_during_the_start_hold_keeps_the_hold() {
        let mut p = playback();
        p.start(start());
        p.faster(at(0.5));
        assert_eq!(p.position(at(1.0)), 0.0, "the first line still holds until its second is over");
        assert!(p.position(at(1.0 + LINE)) > 1.0, "and the new speed takes over after it");
    }

    #[test]
    fn the_view_is_json_for_surfaces() {
        let mut p = playback();
        p.start(start());
        let json = serde_json::to_value(p.view(at(1.0 + LINE))).unwrap();
        assert_eq!(json["state"], "running");
        assert_eq!(json["isShowing"], true);
        assert_eq!(json["wordsPerMinute"], 130.0);
        assert!((json["position"].as_f64().unwrap() - 1.0).abs() < 1e-3);
    }
}
