use serde::{Deserialize, Serialize};

/// The Script (CONTEXT.md): the one text the Teleprompter Module reads out.
/// Plain text — line breaks and blank lines are kept, nothing is parsed.
pub struct TeleprompterScript;

impl TeleprompterScript {
    /// Words as a person reading aloud counts them: runs of text holding at
    /// least one letter or digit. A dash standing alone is not a word.
    pub fn word_count(text: &str) -> usize {
        text.split_whitespace().filter(|w| w.chars().any(|c| c.is_alphanumeric())).count()
    }

    /// How long reading it takes at a speed, to the nearest minute, and a
    /// minute at least for anything at all.
    pub fn minutes(words: usize, words_per_minute: f64) -> usize {
        if words == 0 || words_per_minute <= 0.0 {
            return 0;
        }
        ((words as f64 / words_per_minute).round() as usize).max(1)
    }

    /// The Script as the row's lines: its own line breaks kept, a blank line
    /// kept as a gap, each paragraph wrapped by `wrap` — the type decides where
    /// — and nothing blank before the first line or after the last.
    pub fn lines(text: &str, mut wrap: impl FnMut(&str) -> Vec<String>) -> Vec<String> {
        let mut lines: Vec<String> = vec![];
        for paragraph in split_newlines(text) {
            // `.whitespaces`: spaces and tabs, not the line breaks.
            let trimmed = paragraph.trim_matches(|c: char| c.is_whitespace() && !is_line_break(c));
            if trimmed.is_empty() {
                lines.push(String::new());
            } else {
                lines.extend(wrap(trimmed));
            }
        }
        while lines.first().is_some_and(String::is_empty) {
            lines.remove(0);
        }
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines
    }
}

/// Foundation's `components(separatedBy: .newlines)`: LF, CR, CRLF (as two
/// separators, hence an empty component between), NEL, line and paragraph
/// separators, vertical tab and form feed.
fn split_newlines(text: &str) -> Vec<&str> {
    text.split(is_line_break).collect()
}

fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}')
}

/// What the Teleprompter Module says about itself in Copy Diagnostics: that it
/// is on, and how long the Script is. Never a word of the Script itself — the
/// report is built from closed vocabularies, and a count is one.
pub struct TeleprompterModule;

impl TeleprompterModule {
    pub fn observation(enabled: bool, script: &str) -> String {
        if enabled {
            format!("teleprompter-on-{}-words", TeleprompterScript::word_count(script))
        } else {
            "teleprompter-off".into()
        }
    }
}

/// The text sizes Settings offers; medium is the mockup's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeleprompterTextSize {
    Small,
    #[default]
    Medium,
    Large,
}

impl TeleprompterTextSize {
    pub const ALL: [Self; 3] = [Self::Small, Self::Medium, Self::Large];

    pub fn points(self) -> f64 {
        match self {
            Self::Small => 15.0,
            Self::Medium => 17.0,
            Self::Large => 20.0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Small => "Small",
            Self::Medium => "Medium",
            Self::Large => "Large",
        }
    }
}

/// The Script on this machine, and the one before it: one step back, no more.
/// Typing in Settings changes the Script itself; only Paste keeps the one
/// before. (The Swift keeps both in `Preferences`.)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptStore {
    pub script: String,
    pub previous_script: Option<String>,
}

impl ScriptStore {
    /// Paste from Clipboard: the new Script replaces the current one, which is
    /// kept; pasting the same Script again forgets nothing, and blank text is
    /// not a Script (`pasteFromClipboard` asks the same before it replaces).
    pub fn replace_script(&mut self, text: &str) {
        if text == self.script || text.trim().is_empty() {
            return;
        }
        if !self.script.is_empty() {
            self.previous_script = Some(std::mem::take(&mut self.script));
        }
        self.script = text.to_owned();
    }

    /// Restore Previous Script: the two trade places, so a second restore
    /// undoes the first.
    pub fn restore_previous_script(&mut self) {
        let Some(previous) = self.previous_script.take() else { return };
        self.previous_script = (!self.script.is_empty()).then(|| std::mem::take(&mut self.script));
        self.script = previous;
    }

    pub fn has_previous(&self) -> bool {
        self.previous_script.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_script_counts_its_words_across_lines_and_spaces() {
        assert_eq!(TeleprompterScript::word_count(""), 0, "nothing is no words");
        assert_eq!(TeleprompterScript::word_count("  \n\n "), 0, "blank lines are no words");
        assert_eq!(TeleprompterScript::word_count("Добрый день.\nСегодня  я покажу"), 5, "words, however they are spaced");
        assert_eq!(TeleprompterScript::word_count("Claude — и Codex"), 3, "a dash standing alone is not a word");
    }

    #[test]
    fn a_script_takes_a_minute_at_least_and_rounds_to_the_nearest() {
        assert_eq!(TeleprompterScript::minutes(0, 130.0), 0, "nothing takes no time");
        assert_eq!(TeleprompterScript::minutes(39, 130.0), 1, "a short Script is a minute");
        assert_eq!(TeleprompterScript::minutes(412, 130.0), 3, "412 words at 130 is about 3 minutes");
        assert_eq!(TeleprompterScript::minutes(412, 260.0), 2, "and about 2 at twice the speed");
    }

    #[test]
    fn a_script_keeps_its_line_breaks_and_blank_lines_and_wraps_the_rest() {
        let wrapped = TeleprompterScript::lines("\n\n  First paragraph  \n\nSecond one\n\n", |p| {
            let n = p.chars().count();
            if n > 6 {
                vec![p.chars().take(6).collect(), p.chars().skip(6).collect()]
            } else {
                vec![p.to_owned()]
            }
        });
        assert_eq!(wrapped, ["First ", "paragraph", "", "Second", " one"]);
        assert!(TeleprompterScript::lines(" \n \n", |p| vec![p.to_owned()]).is_empty(), "blank is no lines");
    }

    #[test]
    fn windows_line_endings_keep_a_gap_only_where_the_text_has_one() {
        // CRLF is two separators for Foundation, as it is here: a blank line
        // between every line, which the Script's own blank lines cannot be told
        // from. The surface sees the same lines the Mac does.
        let lines = TeleprompterScript::lines("a\r\nb", |p| vec![p.to_owned()]);
        assert_eq!(lines, ["a", "", "b"]);
        assert_eq!(TeleprompterScript::lines("a\nb", |p| vec![p.to_owned()]), ["a", "b"]);
    }

    #[test]
    fn pasting_replaces_the_script_and_only_the_one_before_comes_back() {
        let mut store = ScriptStore::default();
        assert!(store.script.is_empty() && store.previous_script.is_none(), "no Script until one is given");

        store.replace_script("first");
        store.replace_script("second");
        assert!(store.script == "second" && store.previous_script.as_deref() == Some("first"), "a new Script keeps the one before");

        store.restore_previous_script();
        assert_eq!(store.script, "first", "restore brings the one before back");
        assert_eq!(store.previous_script.as_deref(), Some("second"), "and keeps the one it replaced, so restoring twice undoes itself");

        store.replace_script("third");
        assert_eq!(store.previous_script.as_deref(), Some("first"), "only one step is kept");

        store.replace_script("third");
        assert_eq!(store.previous_script.as_deref(), Some("first"), "pasting the same Script again forgets nothing");

        store.replace_script(" \n\t ");
        assert_eq!(store.script, "third", "a blank clipboard is not a Script");
        assert_eq!(store.previous_script.as_deref(), Some("first"));
    }

    #[test]
    fn restoring_with_nothing_before_does_nothing_and_an_empty_script_is_not_kept() {
        let mut store = ScriptStore::default();
        store.restore_previous_script();
        assert_eq!(store, ScriptStore::default());
        store.replace_script("first"); // the empty Script is not kept as "previous"
        assert!(!store.has_previous());
    }

    #[test]
    fn the_text_sizes_are_the_mockups() {
        assert_eq!(TeleprompterTextSize::default(), TeleprompterTextSize::Medium);
        assert_eq!(TeleprompterTextSize::ALL.map(|s| s.points()), [15.0, 17.0, 20.0]);
        assert_eq!(serde_json::to_string(&TeleprompterTextSize::Large).unwrap(), "\"large\"");
    }

    #[test]
    fn diagnostics_say_how_long_the_script_is_and_never_what_it_says() {
        let script = "Добрый день. Сегодня я покажу секретный план";
        assert_eq!(TeleprompterModule::observation(false, script), "teleprompter-off");
        let said = TeleprompterModule::observation(true, script);
        assert_eq!(said, "teleprompter-on-7-words");
        for word in script.split(' ').filter(|w| w.chars().count() > 2) {
            assert!(!said.contains(word), "the observation carries none of the Script's words, found {word}");
        }
        // Under 32 characters, so the report's scrubbing leaves it.
        assert!(said.len() < 32);
    }
}
