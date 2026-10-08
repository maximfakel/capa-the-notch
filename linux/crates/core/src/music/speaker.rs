use serde::{Deserialize, Serialize};

/// Which glyph the speaker button wears: struck through when nothing is
/// heard, one wave low, two otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeakerIcon {
    Slash,
    Wave1,
    Wave2,
}

/// The output volume as the music page shows it: a level and whether it is
/// muted, read from the output device and written back to it.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Speaker {
    /// From 0 to 1. Muting leaves it where it was.
    pub level: f64,
    pub is_muted: bool,
}

impl Speaker {
    pub fn new(level: f64, is_muted: bool) -> Self {
        Self { level: level.clamp(0.0, 1.0), is_muted }
    }

    /// Muted reads as silent, as Control Center shows it: the bar empties and
    /// the level comes back with the sound.
    pub fn shown_level(&self) -> f64 {
        if self.is_muted { 0.0 } else { self.level }
    }

    pub fn icon(&self) -> SpeakerIcon {
        let shown = self.shown_level();
        if shown <= 0.0 {
            SpeakerIcon::Slash
        } else if shown < 1.0 / 3.0 {
            SpeakerIcon::Wave1
        } else {
            SpeakerIcon::Wave2
        }
    }

    /// The SF Symbol the macOS page uses for the same thing.
    pub fn symbol(&self) -> &'static str {
        match self.icon() {
            SpeakerIcon::Slash => "speaker.slash.fill",
            SpeakerIcon::Wave1 => "speaker.wave.1.fill",
            SpeakerIcon::Wave2 => "speaker.wave.2.fill",
        }
    }
}

/// The platform side of the volume bar: the default output device's level and
/// mute. Core Audio on macOS, PipeWire / PulseAudio on Linux.
pub trait AudioOutput {
    /// Whether the output device's level can be set; false for some displays
    /// over HDMI, some USB converters. Such a device has no speaker, and the
    /// page shows no bar.
    fn level_settable(&self) -> bool;
    /// The level, 0 to 1.
    fn read_level(&self) -> f64;
    /// Whether the device has a mute of its own that can be set.
    fn mute_settable(&self) -> bool;
    /// Whether the device's own mute is on; false for a device with none.
    fn read_muted(&self) -> bool;
    fn write_level(&mut self, level: f64);
    fn write_muted(&mut self, muted: bool);
    /// Begin telling the model when the device, its level or its mute change
    /// (it then calls `SystemVolume::follow` or `read`). Called when the first
    /// bar appears.
    fn start_listening(&mut self);
    /// The last bar went: stop listening altogether (ADR 0003).
    fn stop_listening(&mut self);
    /// Whether the default output device changed since this was last asked:
    /// the model then `follow`s it rather than only reading the level again.
    fn take_device_changed(&mut self) -> bool {
        false
    }
}

/// The model behind the volume bar: which speaker to show, and what muting
/// means on a device that has no mute of its own.
///
/// It follows the device, and listens only while a bar is on screen: with the
/// music page closed or the Music Module off, nothing is asked of the audio
/// system.
pub struct SystemVolume<A: AudioOutput> {
    output: A,
    speaker: Option<Speaker>,
    watchers: usize,
    /// Where the level was when it was muted, on a device with no mute of its
    /// own: muting there is setting the level to zero.
    level_before_mute: Option<f64>,
}

impl<A: AudioOutput> SystemVolume<A> {
    pub fn new(output: A) -> Self {
        Self { output, speaker: None, watchers: 0, level_before_mute: None }
    }

    /// Nil when the output device's level cannot be set.
    pub fn speaker(&self) -> Option<Speaker> {
        self.speaker
    }

    pub fn output(&mut self) -> &mut A {
        &mut self.output
    }

    /// A bar appeared: follow the output device and its level.
    pub fn start_watching(&mut self) {
        self.watchers += 1;
        if self.watchers == 1 {
            self.output.start_listening();
            self.follow();
        }
    }

    /// A bar went; the last one stops the listening.
    pub fn stop_watching(&mut self) {
        if self.watchers == 0 {
            return;
        }
        self.watchers -= 1;
        if self.watchers == 0 {
            self.output.stop_listening();
        }
    }

    pub fn is_watching(&self) -> bool {
        self.watchers > 0
    }

    /// Dragging the bar up from silence brings the sound back, as the system's
    /// own slider does.
    pub fn set_level(&mut self, level: f64) {
        if self.speaker.is_some_and(|s| s.is_muted) && level > 0.0 {
            self.level_before_mute = None;
            self.set_muted(false);
        }
        self.write_level(level);
        self.read();
    }

    pub fn toggle_mute(&mut self) {
        let Some(speaker) = self.speaker else { return };
        self.set_muted(!speaker.is_muted);
        self.read();
    }

    fn write_level(&mut self, level: f64) {
        self.output.write_level(level.clamp(0.0, 1.0));
    }

    fn set_muted(&mut self, muted: bool) {
        if self.output.mute_settable() {
            self.output.write_muted(muted);
        } else if muted {
            self.level_before_mute = self.speaker.map(|s| s.level);
            self.write_level(0.0);
        } else if let Some(level) = self.level_before_mute.take() {
            self.write_level(level);
        }
    }

    /// The default output device changed (or listening began): forget a mute
    /// that was a zero, and read the new device.
    pub fn follow(&mut self) {
        self.level_before_mute = None;
        self.read();
    }

    /// The device's level or mute changed.
    pub fn read(&mut self) {
        if !self.output.level_settable() {
            self.speaker = None;
            return;
        }
        let level = self.output.read_level();
        let muted = self.output.read_muted();
        // A level raised from the keyboard ends a mute that was a zero.
        if level > 0.0 {
            self.level_before_mute = None;
        }
        self.speaker = Some(Speaker::new(level, muted || self.level_before_mute.is_some()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_speaker_is_struck_through_when_nothing_is_heard() {
        assert_eq!(Speaker::new(0.6, false).symbol(), "speaker.wave.2.fill", "two waves at an ordinary level");
        assert_eq!(Speaker::new(0.2, false).symbol(), "speaker.wave.1.fill", "one wave when it is low");
        assert_eq!(Speaker::new(0.0, false).symbol(), "speaker.slash.fill", "struck through at zero");
        assert_eq!(Speaker::new(0.6, true).symbol(), "speaker.slash.fill", "and when muted, at any level");
        assert_eq!(Speaker::new(0.2, false).icon(), SpeakerIcon::Wave1);
    }

    #[test]
    fn muting_empties_the_bar_and_keeps_the_level() {
        let muted = Speaker::new(0.6, true);
        assert_eq!(muted.shown_level(), 0.0, "the bar is empty while muted");
        assert_eq!(muted.level, 0.6, "the level waits for the sound to come back");
        assert!(Speaker::new(1.4, false).level == 1.0 && Speaker::new(-1.0, false).level == 0.0, "never outside 0 to 1");
    }

    #[derive(Default)]
    struct Fake {
        settable: bool,
        has_mute: bool,
        level: f64,
        muted: bool,
        listening: u32,
        stopped: u32,
    }

    impl AudioOutput for Fake {
        fn level_settable(&self) -> bool { self.settable }
        fn read_level(&self) -> f64 { self.level }
        fn mute_settable(&self) -> bool { self.has_mute }
        fn read_muted(&self) -> bool { self.muted }
        fn write_level(&mut self, level: f64) { self.level = level; }
        fn write_muted(&mut self, muted: bool) { self.muted = muted; }
        fn start_listening(&mut self) { self.listening += 1; }
        fn stop_listening(&mut self) { self.stopped += 1; }
    }

    fn volume(has_mute: bool, level: f64) -> SystemVolume<Fake> {
        let mut v = SystemVolume::new(Fake { settable: true, has_mute, level, ..Fake::default() });
        v.start_watching();
        v
    }

    #[test]
    fn it_listens_only_while_a_bar_is_on_screen() {
        let mut v = SystemVolume::new(Fake { settable: true, level: 0.5, ..Fake::default() });
        assert!(v.speaker().is_none() && !v.is_watching(), "nothing is asked before a bar appears");
        v.start_watching();
        v.start_watching();
        assert_eq!(v.output().listening, 1, "two bars, one listener");
        assert_eq!(v.speaker(), Some(Speaker::new(0.5, false)));
        v.stop_watching();
        assert_eq!(v.output().stopped, 0, "one bar is still there");
        v.stop_watching();
        v.stop_watching();
        assert_eq!(v.output().stopped, 1, "the last bar stops it, once");
    }

    #[test]
    fn a_device_whose_level_cannot_be_set_has_no_speaker() {
        let mut v = SystemVolume::new(Fake { settable: false, ..Fake::default() });
        v.start_watching();
        assert_eq!(v.speaker(), None);
        v.toggle_mute();
        assert_eq!(v.speaker(), None, "nothing to mute");
    }

    #[test]
    fn muting_a_device_with_a_mute_uses_it_and_keeps_the_level() {
        let mut v = volume(true, 0.6);
        v.toggle_mute();
        assert_eq!(v.speaker(), Some(Speaker::new(0.6, true)));
        assert_eq!(v.output().level, 0.6);
        v.toggle_mute();
        assert_eq!(v.speaker(), Some(Speaker::new(0.6, false)));
    }

    #[test]
    fn muting_a_device_without_one_is_a_zero_that_comes_back() {
        let mut v = volume(false, 0.6);
        v.toggle_mute();
        assert_eq!(v.output().level, 0.0, "muting there is setting the level to zero");
        assert_eq!(v.speaker(), Some(Speaker::new(0.0, true)), "and it reads as muted");
        v.toggle_mute();
        assert_eq!(v.output().level, 0.6, "unmuting puts the level back");
        assert_eq!(v.speaker(), Some(Speaker::new(0.6, false)));
    }

    #[test]
    fn dragging_up_from_silence_brings_the_sound_back() {
        let mut v = volume(true, 0.6);
        v.toggle_mute();
        v.set_level(0.3);
        assert_eq!(v.speaker(), Some(Speaker::new(0.3, false)), "unmuted at the new level");

        let mut z = volume(false, 0.6);
        z.toggle_mute();
        z.set_level(0.4);
        assert_eq!(z.speaker(), Some(Speaker::new(0.4, false)), "a zero-mute ends too, and does not restore the old level over it");
        assert_eq!(z.output().level, 0.4);
    }

    #[test]
    fn a_level_raised_from_the_keyboard_ends_a_mute_that_was_a_zero() {
        let mut v = volume(false, 0.6);
        v.toggle_mute();
        v.output().level = 0.5; // the keyboard
        v.read();
        assert_eq!(v.speaker(), Some(Speaker::new(0.5, false)));
    }

    #[test]
    fn a_new_output_device_forgets_a_zero_mute() {
        let mut v = volume(false, 0.6);
        v.toggle_mute();
        v.output().level = 0.0;
        v.follow();
        assert_eq!(v.speaker(), Some(Speaker::new(0.0, false)), "silent, not muted: the old level means nothing here");
    }

    #[test]
    fn levels_written_stay_between_zero_and_one() {
        let mut v = volume(true, 0.5);
        v.set_level(1.7);
        assert_eq!(v.output().level, 1.0);
        v.set_level(-2.0);
        assert_eq!(v.output().level, 0.0);
    }
}
