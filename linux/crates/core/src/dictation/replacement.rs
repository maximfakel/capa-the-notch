//! Words the recogniser hears, and what to write for them instead.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictationReplacement {
    /// Told apart in a list. The caller hands them out; `next_id` suggests one.
    pub id: u64,
    pub heard: String,
    pub replacement: String,
    pub enabled: bool,
}

impl DictationReplacement {
    pub fn new(id: u64, heard: impl Into<String>, replacement: impl Into<String>) -> Self {
        Self { id, heard: heard.into(), replacement: replacement.into(), enabled: true }
    }

    pub fn disabled(mut self) -> Self {
        self.enabled = false;
        self
    }

    /// An id no rule in the list has.
    pub fn next_id(rules: &[Self]) -> u64 {
        rules.iter().map(|r| r.id).max().map_or(1, |m| m + 1)
    }

    /// The rules a person starts with (Russian words for English terms). The
    /// last two are also ordinary words or names, so off until turned on.
    pub fn defaults() -> Vec<Self> {
        let rules = [
            ("пул реквест", "pull request", true),
            ("коммит", "commit", true),
            ("диплой", "deploy", true),
            ("гитхаб", "GitHub", true),
            ("тайпскрипт", "TypeScript", true),
            ("докер", "Docker", true),
            ("кубернетес", "Kubernetes", true),
            ("фронтенд", "frontend", true),
            ("бэкенд", "backend", true),
            ("джейсон", "JSON", false),
            ("реакт", "React", false),
        ];
        rules
            .into_iter()
            .enumerate()
            .map(|(i, (heard, replacement, enabled))| Self {
                id: i as u64 + 1,
                heard: heard.into(),
                replacement: replacement.into(),
                enabled,
            })
            .collect()
    }

    /// Match the original once, choosing the longest phrase at a position.
    /// Replacements are literal, never regex templates or input to another
    /// rule: a replacement is not read again.
    ///
    /// A phrase matches whole words only (not inside a longer word), in any
    /// letter case, with any run of white space between its words.
    pub fn apply(rules: &[Self], text: &str) -> String {
        let text: Vec<char> = text.chars().collect();

        // Longest phrase first (by characters, as the original counts them).
        // Stable, so equal lengths keep the person's order.
        let mut ordered: Vec<(usize, &Self)> = rules
            .iter()
            .filter(|r| r.enabled && !r.heard.trim().is_empty())
            .map(|r| (r.heard.chars().count(), r))
            .collect();
        ordered.sort_by_key(|(length, _)| std::cmp::Reverse(*length));

        let mut matches: Vec<(usize, usize, &str)> = Vec::new();
        for (_, rule) in ordered {
            let words: Vec<Vec<char>> = rule.heard.split_whitespace().map(|w| w.chars().collect()).collect();
            let mut at = 0;
            while at < text.len() {
                if let Some(end) = match_phrase(&text, at, &words) {
                    // A match another rule already has any part of is theirs.
                    if !matches.iter().any(|(s, e, _)| *s < end && at < *e) {
                        matches.push((at, end, rule.replacement.as_str()));
                    }
                    at = end;
                } else {
                    at += 1;
                }
            }
        }

        matches.sort_by_key(|(start, _, _)| std::cmp::Reverse(*start));
        let mut output = text;
        for (start, end, replacement) in matches {
            output.splice(start..end, replacement.chars());
        }
        output.into_iter().collect()
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn same_letter(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

/// Where a phrase matched at `at` ends, if it does match there: not preceded
/// or followed by a letter, digit or underscore.
fn match_phrase(text: &[char], at: usize, words: &[Vec<char>]) -> Option<usize> {
    if at > 0 && is_word_char(text[at - 1]) {
        return None;
    }
    let mut i = at;
    for (n, word) in words.iter().enumerate() {
        if n > 0 {
            // One or more white space between words.
            let start = i;
            while i < text.len() && text[i].is_whitespace() {
                i += 1;
            }
            if i == start {
                return None;
            }
        }
        for &letter in word {
            if i >= text.len() || !same_letter(text[i], letter) {
                return None;
            }
            i += 1;
        }
    }
    if i < text.len() && is_word_char(text[i]) {
        return None;
    }
    Some(i)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(id: u64, heard: &str, replacement: &str) -> DictationReplacement {
        DictationReplacement::new(id, heard, replacement)
    }

    #[test]
    fn dictation_replaces_phrases_without_substrings_or_cascades() {
        let rules = [rule(1, "пул реквест", "pull request"), rule(2, "коммит", "commit"), rule(3, "commit", "WRONG")];
        assert_eq!(
            DictationReplacement::apply(&rules, "ПУЛ РЕКВЕСТ, коммит. Коммиты!"),
            "pull request, commit. Коммиты!",
            "Whole phrases, preserved spelling, no cascading"
        );
        assert_eq!(
            DictationReplacement::apply(&DictationReplacement::defaults(), "Джейсон читает реакт, докеров и фронтендеров."),
            "Джейсон читает реакт, докеров и фронтендеров.",
            "Ambiguous and substring matches stay untouched"
        );
    }

    #[test]
    fn the_longest_phrase_wins_a_position_and_a_replacement_is_not_read_again() {
        let rules = [rule(1, "пул", "X"), rule(2, "пул реквест", "pull request"), rule(3, "request", "Y")];
        assert_eq!(DictationReplacement::apply(&rules, "пул реквест"), "pull request", "'request' in the replacement is not matched");
        assert_eq!(DictationReplacement::apply(&rules, "пул"), "X");
    }

    #[test]
    fn a_phrase_matches_across_any_run_of_white_space_and_in_any_case() {
        let rules = [rule(1, "пул реквест", "pull request")];
        assert_eq!(DictationReplacement::apply(&rules, "Пул \n  Реквест"), "pull request");
        assert_eq!(DictationReplacement::apply(&rules, "пулреквест"), "пулреквест", "no space, no match");
    }

    #[test]
    fn disabled_and_blank_rules_do_nothing_and_a_replacement_is_literal() {
        let rules = [rule(1, "коммит", "commit").disabled(), rule(2, "  ", "nothing"), rule(3, "докер", "$1 \\0 (.*)")];
        assert_eq!(DictationReplacement::apply(&rules, "коммит докер"), "коммит $1 \\0 (.*)");
    }

    #[test]
    fn digits_underscores_and_punctuation_are_the_edges_of_a_word() {
        let rules = [rule(1, "гитхаб", "GitHub")];
        assert_eq!(DictationReplacement::apply(&rules, "гитхаб2 гитхаб_ гитхаб-ссылка (гитхаб)"), "гитхаб2 гитхаб_ GitHub-ссылка (GitHub)");
    }

    #[test]
    fn the_same_phrase_twice_is_replaced_twice() {
        let rules = [rule(1, "коммит", "commit")];
        assert_eq!(DictationReplacement::apply(&rules, "коммит и коммит"), "commit и commit");
    }

    #[test]
    fn the_defaults_are_the_eleven_and_the_ordinary_words_start_off() {
        let defaults = DictationReplacement::defaults();
        assert_eq!(defaults.len(), 11);
        assert_eq!(defaults.iter().filter(|r| r.enabled).count(), 9);
        let off: Vec<_> = defaults.iter().filter(|r| !r.enabled).map(|r| r.replacement.as_str()).collect();
        assert_eq!(off, ["JSON", "React"]);
        assert_eq!(DictationReplacement::next_id(&defaults), 12);
        assert_eq!(DictationReplacement::next_id(&[]), 1);
    }
}
