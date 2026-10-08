use crate::snapshot::Provider;
use std::collections::HashSet;

/// Providers sit on the surface in a fixed order, two at most.
pub const VISIBLE_LIMIT: usize = 2;

pub fn ordered(providers: impl IntoIterator<Item = Provider>) -> Vec<Provider> {
    let chosen: HashSet<_> = providers.into_iter().collect();
    Provider::ALL.into_iter().filter(|p| chosen.contains(p)).collect()
}

/// Whether this Provider may be on alongside those already on. One already
/// on may always stay on.
pub fn can_turn_on(provider: Provider, already_on: &HashSet<Provider>, limit: usize) -> bool {
    already_on.contains(&provider) || already_on.len() < limit
}

/// The Providers to connect from those chosen: the first in order, up to the
/// limit, should more have been chosen somewhere this rule was not.
pub fn to_connect(chosen: impl IntoIterator<Item = Provider>, limit: usize) -> Vec<Provider> {
    ordered(chosen).into_iter().take(limit).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use Provider::*;

    #[test]
    fn providers_keep_their_fixed_order() {
        assert_eq!(ordered([OpenCode, Codex]), [Codex, OpenCode]);
    }

    #[test]
    fn two_at_most_and_one_on_stays_on() {
        let on: HashSet<_> = [Codex, ClaudeCode].into();
        assert!(!can_turn_on(OpenCode, &on, VISIBLE_LIMIT));
        assert!(can_turn_on(Codex, &on, VISIBLE_LIMIT));
        assert!(can_turn_on(OpenCode, &[Codex].into(), VISIBLE_LIMIT));
    }

    #[test]
    fn more_than_the_limit_connects_the_first_in_order() {
        assert_eq!(to_connect([OpenCode, ClaudeCode, Codex], VISIBLE_LIMIT), [Codex, ClaudeCode]);
    }
}
