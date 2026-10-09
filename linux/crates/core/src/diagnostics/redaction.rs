//! The second line: anything that got in from outside is rubbed out by shape.
//!
//! This is not what makes the report safe — the closed vocabulary is. This
//! catches what a version string or a path can carry, and what a future
//! careless addition might. Written without a regular-expression engine: each
//! rule is the Swift one, matched left to right, longest run first.

/// The rules, in the order they run; each sees what the one before left.
pub struct Redaction;

impl Redaction {
    pub fn scrub(text: &str) -> String {
        let mut chars: Vec<char> = text.chars().collect();
        chars = prefixed(&chars, "eyJ", false, token_body, 8, false, "[redacted-token]"); // a JSON Web Token
        chars = prefixed(&chars, "sk-", false, key_body, 8, false, "[redacted-token]"); // provider key shapes
        chars = prefixed(&chars, "bearer", true, bearer_body, 8, true, "[redacted-token]");
        chars = addresses(&chars);
        chars = identifiers(&chars);
        chars = homes(&chars);
        chars = opaque_runs(&chars);
        chars.into_iter().collect()
    }
}

/// `[A-Za-z0-9_.+/=-]`
fn token_body(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '+' | '/' | '=' | '-')
}

/// `[A-Za-z0-9_-]`
fn key_body(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-')
}

/// `[A-Za-z0-9._~+/=-]`
fn bearer_body(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '~' | '+' | '/' | '=' | '-')
}

/// `[A-Za-z0-9._%+-]`
fn local_part(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '%' | '+' | '-')
}

/// `[A-Za-z0-9.-]`
fn domain_part(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '-')
}

fn starts_with_at(chars: &[char], at: usize, prefix: &str, ignore_case: bool) -> Option<usize> {
    let mut i = at;
    for p in prefix.chars() {
        let c = *chars.get(i)?;
        let same = if ignore_case { c.to_lowercase().eq(p.to_lowercase()) } else { c == p };
        if !same {
            return None;
        }
        i += 1;
    }
    Some(i)
}

fn run_length(chars: &[char], from: usize, class: impl Fn(char) -> bool) -> usize {
    chars[from.min(chars.len())..].iter().take_while(|c| class(**c)).count()
}

/// `prefix` then (optionally whitespace, one or more) then at least `min`
/// characters of `class`, greedy.
fn prefixed(
    chars: &[char],
    prefix: &str,
    ignore_case: bool,
    class: fn(char) -> bool,
    min: usize,
    whitespace_between: bool,
    replacement: &str,
) -> Vec<char> {
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        if let Some(mut j) = starts_with_at(chars, i, prefix, ignore_case) {
            let mut ok = true;
            if whitespace_between {
                let spaces = run_length(chars, j, char::is_whitespace);
                ok = spaces > 0;
                j += spaces;
            }
            let run = run_length(chars, j, class);
            if ok && run >= min {
                out.extend(replacement.chars());
                i = j + run;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`
fn addresses(chars: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        if let Some(end) = address_at(chars, i) {
            out.extend("[redacted-address]".chars());
            i = end;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

fn address_at(chars: &[char], start: usize) -> Option<usize> {
    let local = run_length(chars, start, local_part);
    let at = start + local;
    if local == 0 || chars.get(at) != Some(&'@') {
        return None;
    }
    let domain_start = at + 1;
    let run = run_length(chars, domain_start, domain_part);
    // The group before the last dot takes as much as it can, then gives back
    // until a dot is followed by two or more letters.
    for group in (1..run).rev() {
        let dot = domain_start + group;
        if chars[dot] != '.' {
            continue;
        }
        let letters = run_length(chars, dot + 1, |c| c.is_ascii_alphabetic());
        if letters >= 2 {
            return Some(dot + 1 + letters);
        }
    }
    None
}

/// `[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`
fn identifiers(chars: &[char]) -> Vec<char> {
    const SHAPE: [usize; 5] = [8, 4, 4, 4, 12];
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    'scan: while i < chars.len() {
        let mut j = i;
        for (n, width) in SHAPE.iter().enumerate() {
            if n > 0 {
                if chars.get(j) != Some(&'-') {
                    out.push(chars[i]);
                    i += 1;
                    continue 'scan;
                }
                j += 1;
            }
            if run_length(chars, j, |c| c.is_ascii_hexdigit()).min(*width) < *width {
                out.push(chars[i]);
                i += 1;
                continue 'scan;
            }
            j += width;
        }
        out.extend("[redacted-id]".chars());
        i = j;
    }
    out
}

/// `/Users/[^/\s]+` — and on Linux `/home/[^/\s]+` — becomes `~`: somebody's
/// home, and therefore their name.
fn homes(chars: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    'next: while i < chars.len() {
        // A Mac's home, and a Linux one.
        for home in ["/Users/", "/home/"] {
            if let Some(j) = starts_with_at(chars, i, home, false) {
                let name = run_length(chars, j, |c| c != '/' && !c.is_whitespace());
                if name > 0 {
                    out.push('~');
                    i = j + name;
                    continue 'next;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// `[A-Za-z0-9_-]{32,}`: a long opaque run, which is what a secret looks like
/// when it is not one of the shapes above.
fn opaque_runs(chars: &[char]) -> Vec<char> {
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        let run = run_length(chars, i, key_body);
        if run >= 32 {
            out.extend("[redacted-opaque]".chars());
            i += run;
        } else if run > 0 {
            out.extend(&chars[i..i + run]);
            i += run;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrubbing_catches_what_gets_in_from_outside() {
        let cases = [
            ("Bearer eyJhbGciOiJIUzI1NiJ9.eyJhIjoxfQ.sig", "eyJ"),
            ("key sk-ant-oat01-7Qv3mK9xR2wL5nB8tY4cE6uH1sJ0aD", "sk-ant"),
            ("/Users/jordanlee/Library", "jordanlee"),
            ("jordan.lee@example.com", "@example.com"),
            ("3f9d1bdc-5671-44be-bc29-0825e2fb372e", "3f9d1bdc"),
            ("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", "AbCdEfGh"),
        ];
        for (input, forbidden) in cases {
            let scrubbed = Redaction::scrub(input);
            assert!(!scrubbed.contains(forbidden), "\"{forbidden}\" survived scrubbing: {scrubbed}");
        }
        assert_eq!(Redaction::scrub("/Users/someone/Library"), "~/Library", "a home directory becomes a tilde rather than a name");
    }

    #[test]
    fn each_rule_leaves_its_marker_and_the_words_around_it() {
        assert_eq!(Redaction::scrub("a eyJhbGciOiJIUzI1NiJ9.x b"), "a [redacted-token] b");
        assert_eq!(Redaction::scrub("use sk-abcdefgh12 now"), "use [redacted-token] now");
        assert_eq!(Redaction::scrub("Authorization: BEARER abc.def-ghi_jkl ok"), "Authorization: [redacted-token] ok");
        assert_eq!(Redaction::scrub("mail jordan.lee@example.com please"), "mail [redacted-address] please");
        assert_eq!(Redaction::scrub("id 3f9d1bdc-5671-44be-bc29-0825e2fb372e."), "id [redacted-id].");
        assert_eq!(Redaction::scrub("at /Users/jo/x and /Users/ka/y"), "at ~/x and ~/y");
        assert_eq!(Redaction::scrub("at /home/jo/.local/bin/codex"), "at ~/.local/bin/codex", "a Linux home too");
        assert_eq!(Redaction::scrub(&format!("run {} end", "a".repeat(32))), "run [redacted-opaque] end");
    }

    #[test]
    fn short_things_are_left_alone() {
        for plain in ["provider-unavailable", "sk-short", "eyJshort", "bearer abc", "a@b", "/Users/", "123e4567-e89b-12d3-a456", "launched 0.1.0 macOS 26.6.2", "NSURLErrorDomain -1001"] {
            assert_eq!(Redaction::scrub(plain), plain, "{plain}");
        }
        // Thirty-one characters is under the line a secret is drawn at.
        let thirty_one = "a".repeat(31);
        assert_eq!(Redaction::scrub(&thirty_one), thirty_one);
    }

    #[test]
    fn an_address_is_taken_whole_back_to_its_last_dot() {
        assert_eq!(Redaction::scrub("x a.b@mail.example.co.uk y"), "x [redacted-address] y");
        assert_eq!(Redaction::scrub("a@b.c"), "a@b.c", "a one-letter top level is not an address");
    }
}
