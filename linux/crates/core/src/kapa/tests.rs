//! Ported one-to-one from `Tests/CapacityNotchTests/KapaTests.swift`.

use super::*;
use crate::snapshot::{CapacitySnapshot, CapacityStatusReason, ConnectionState, Provider, QuotaWindow};
use chrono::{Duration, TimeZone, Utc};

fn now() -> chrono::DateTime<Utc> {
    Utc.timestamp_opt(1_000_000, 0).unwrap()
}

fn snapshot(provider: Provider, used: &[f64], state: ConnectionState) -> CapacitySnapshot {
    CapacitySnapshot {
        provider,
        captured_at: now(),
        windows: used
            .iter()
            .enumerate()
            .map(|(i, u)| QuotaWindow::new(format!("w{i}"), format!("w{i}"), None, *u, Some(now() + Duration::seconds(3600))))
            .collect(),
        connection_state: state,
        status_reason: None,
    }
}

fn fresh(provider: Provider, used: &[f64]) -> CapacitySnapshot {
    snapshot(provider, used, ConnectionState::Fresh)
}

fn codex(used: &[f64]) -> CapacitySnapshot {
    fresh(Provider::Codex, used)
}

#[test]
fn kapa_reads_capacity_off_the_window_with_the_least_left() {
    use KapaExpression::*;
    assert_eq!(KapaMood::capacity(&codex(&[0.24, 0.31])), Rest, "plenty left everywhere rests");
    assert_eq!(KapaMood::capacity(&codex(&[0.24, 0.5])), Focused, "half left in one window is attentive");
    assert_eq!(KapaMood::capacity(&codex(&[0.96, 0.31])), Worried, "four percent left worries, whichever window it is");
    assert_eq!(KapaMood::capacity(&codex(&[1.0, 0.4])), Waiting, "a window used up waits for its reset");
    assert_eq!(KapaMood::capacity(&codex(&[0.9])), Focused, "ten percent belongs to the better state, as Capacity Pace says");
    assert_eq!(KapaMood::capacity(&codex(&[])), Rest, "nothing read yet is nothing to worry about");
}

#[test]
fn kapa_judges_no_old_numbers() {
    use KapaExpression::*;
    assert_eq!(
        KapaMood::capacity(&snapshot(Provider::Codex, &[0.96], ConnectionState::Stale)),
        Stale,
        "stale four percent is stale, not worried"
    );
    assert_eq!(
        KapaMood::capacity(&snapshot(Provider::Codex, &[], ConnectionState::Connecting)),
        Stale,
        "connecting looks like stale"
    );
    let gone = CapacitySnapshot::disconnected(Provider::ClaudeCode, now(), CapacityStatusReason::ClaudeCodeNotInstalled);
    assert_eq!(KapaMood::capacity(&gone), Puzzled, "a disconnected Provider puzzles");
}

#[test]
fn one_kapa_a_page_on_the_card_that_needs_a_look() {
    use KapaExpression::*;
    let calm = fresh(Provider::Codex, &[0.2]);
    let low = fresh(Provider::ClaudeCode, &[0.97]);
    let focus = KapaMood::capacity_focus(&[calm, low]).unwrap();
    assert!(focus.provider == Provider::ClaudeCode && focus.expression == Worried, "the worried card has Kapa");

    let tie = KapaMood::capacity_focus(&[fresh(Provider::Codex, &[0.2]), fresh(Provider::ClaudeCode, &[0.1])]).unwrap();
    assert_eq!(tie.provider, Provider::Codex, "between equal cards the first keeps Kapa");

    let gone = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::CodexDisconnected);
    let worse = KapaMood::capacity_focus(&[gone, fresh(Provider::ClaudeCode, &[1.0])]).unwrap();
    assert_eq!(worse.expression, Waiting, "a window used up wants a look before a disconnected Provider");

    assert!(KapaMood::capacity_focus(&[]).is_none(), "no cards, no Kapa");
}

#[test]
fn kapa_blinks_every_two_to_five_seconds_and_sometimes_twice() {
    assert_eq!(KapaBlink::delay(0.0), 2.2, "the shortest wait");
    assert!((KapaBlink::delay(1.0) - 5.4).abs() < 1e-9, "the longest wait");
    assert_eq!(KapaBlink::delay(7.0), KapaBlink::delay(1.0), "a draw out of range is held to it");
    assert!(KapaBlink::is_double(0.1) && !KapaBlink::is_double(0.5), "about one blink in five is double");
    assert!(!KapaBlink::blinks(Eyes::Happy) && !KapaBlink::blinks(Eyes::Closed), "arcs and shut eyes have no lids to drop");
    assert!(KapaBlink::blinks(Eyes::Open), "open eyes blink");
}

#[test]
fn kapas_eyes_sit_as_drawn_and_turn_with_the_head() {
    let left = KapaGaze::eye(-1.0, KapaLook::AHEAD);
    let right = KapaGaze::eye(1.0, KapaLook::AHEAD);
    assert!((left.x - 41.0).abs() < 0.1 && (right.x - 63.0).abs() < 0.1, "looking ahead, the eyes are where the sheet draws them");
    assert!((left.scale_x - 1.0).abs() < 1e-9 && left.scale_y == 1.0, "and at the size it draws them");

    let turned = KapaLook::new(0.4, 0.0);
    assert!(KapaGaze::eye(-1.0, turned).x > left.x, "turning right moves the eyes right");
    assert!(
        KapaGaze::eye(1.0, turned).scale_x < KapaGaze::eye(-1.0, turned).scale_x,
        "the eye turning away narrows"
    );
    assert!(KapaGaze::eye(1.0, KapaLook::new(1.5, 0.0)).is_hidden, "an eye gone round the head is not drawn");
    assert!(KapaGaze::eye(-1.0, KapaLook::new(0.0, 0.2)).y < 60.0, "looking up raises the eyes");
}

#[test]
fn every_kapa_pose_says_it_with_more_than_colour() {
    // ADR 0006: the body never changes colour, so each pose a person must
    // tell apart differs in its face or its sign.
    let faces: Vec<_> = KapaExpression::ALL.iter().map(|e| KapaFace::of(*e)).collect();
    for (index, face) in faces.iter().enumerate() {
        for other in &faces[index + 1..] {
            assert_ne!(face, other, "two poses draw the same face: {face:?}");
        }
    }
    assert_ne!(KapaFace::of(KapaExpression::Copied).badge, KapaFace::of(KapaExpression::Inserted).badge, "copied is not drawn as inserted");
    assert!(
        KapaFace::of(KapaExpression::Music).headphones && KapaFace::of(KapaExpression::Paused).headphones,
        "headphones say music, playing or paused"
    );
    const { assert!(KapaPreference::DEFAULT_VALUE, "Kapa is on until a person turns it off") };
}

#[test]
fn kapa_follows_a_target_the_same_at_any_frame_rate() {
    let mut thirty = 0.0;
    for _ in 0..30 {
        thirty = KapaMotion::approach(thirty, 1.0, 0.0025, 1.0 / 30.0);
    }
    let mut sixty = 0.0;
    for _ in 0..60 {
        sixty = KapaMotion::approach(sixty, 1.0, 0.0025, 1.0 / 60.0);
    }
    assert!((thirty - sixty).abs() < 1e-9, "a second at 30 frames ends where a second at 60 does");
    assert!((thirty - 0.9975).abs() < 1e-9, "after a second, the base of the gap is left");
}

#[test]
fn kapa_nods_on_every_beat_of_the_music() {
    let beat = 60.0 / KapaMotion::MUSIC_TEMPO;
    assert!(KapaMotion::bob(0.0).0 > 3.0, "the dip falls on the beat");
    assert!(KapaMotion::bob(beat * 0.7).0 < 0.1, "and has eased back up before the next");
    assert!((KapaMotion::bob(beat).0 - KapaMotion::bob(0.0).0).abs() < 1e-9, "every beat alike");
    assert!(KapaMotion::bob(beat / 2.0).1 > 0.0 && KapaMotion::bob(beat * 1.5).1 < 0.0, "swaying one way, then the other");
}

#[test]
fn kapa_blinks_shut_and_open_in_a_fifth_of_a_second() {
    assert!(KapaMotion::lid(-1.0) == 1.0 && KapaMotion::lid(1.0) == 1.0, "open outside a blink");
    assert!((KapaMotion::lid(KapaBlink::CLOSING) - 0.08).abs() < 0.01, "shut at 70 ms");
    assert_eq!(KapaMotion::lid(KapaBlink::CLOSING + KapaBlink::OPENING), 1.0, "open again by 200 ms");
}

#[test]
fn kapa_opens_wider_the_nearer_a_file_is_held() {
    let far = KapaMotion::appetite(1000.0, 150.0);
    let middle = KapaMotion::appetite(75.0, 150.0);
    let over = KapaMotion::appetite(0.0, 150.0);
    assert!(far > 0.0, "a file held anywhere opens the mouth a little");
    assert!(far < middle && middle < over, "wider as it comes closer");
    assert_eq!(over, 1.0, "wide open over the mouth");
}

#[test]
fn kapa_eats_a_dropped_file_and_settles() {
    let start = KapaMotion::gulp(0.0).unwrap();
    assert!(start.file == Some(0.0) && !start.pleased, "the file starts where it was let go");
    let sinking = KapaMotion::gulp(0.2).unwrap();
    assert!(sinking.file.unwrap() > 0.2 && sinking.mouth > 0.8, "it is drawn into a wide mouth");
    let swallowed = KapaMotion::gulp(0.33).unwrap();
    assert!(swallowed.file.is_none() && swallowed.kick.sy < 1.0, "then gone, with a squash");
    let chewing: Vec<_> = (0..30).filter_map(|i| KapaMotion::gulp(0.38 + i as f64 * 0.02)).collect();
    assert!(chewing.iter().all(|g| g.pleased) && chewing.iter().any(|g| g.mouth > 0.2), "chewed, pleased");
    assert!(KapaMotion::gulp(KapaMotion::GULP_LENGTH).is_none(), "and over");
}

#[test]
fn kapas_movements_end_where_they_began() {
    for reaction in [Reaction::Nod, Reaction::Gulp, Reaction::Hop] {
        assert!(KapaMotion::kick(reaction, KapaMotion::duration(reaction)).is_none(), "{reaction:?} ends");
        let near = KapaMotion::kick(reaction, KapaMotion::duration(reaction) - 0.001).unwrap();
        assert!(
            (near.sx - 1.0).abs() < 0.02 && (near.sy - 1.0).abs() < 0.02 && near.dy.abs() < 0.1,
            "{reaction:?} lands at rest"
        );
    }
    assert!(KapaMotion::boop(KapaMotion::BOOP_LENGTH).is_none(), "a boop ends");
    assert!(KapaMotion::shake(KapaMotion::SHAKE_LENGTH).is_none(), "a shake ends");
}

// Not in the Swift tests: the JSON a surface reads.

#[test]
fn a_face_and_a_pose_are_camel_case_json() {
    assert_eq!(serde_json::to_string(&KapaExpression::DropReady).unwrap(), "\"dropReady\"");
    let json = serde_json::to_value(KapaFace::of(KapaExpression::Puzzled)).unwrap();
    assert_eq!(json["eyes"], "uneven");
    assert_eq!(json["badge"], "unplugged");
    assert_eq!(json["brows"], "puzzled");
    assert_eq!(json["tilt"], -4.0);
    assert_eq!(json["look"]["yaw"], 0.0);
    let eye = serde_json::to_value(KapaGaze::eye(-1.0, KapaLook::AHEAD)).unwrap();
    assert!(eye.get("scaleX").is_some() && eye.get("isHidden").is_some());
}

#[test]
fn the_motion_that_the_swift_tests_do_not_pin_is_pinned_here() {
    // The mouth spring settles on its target without running away.
    let (mut value, mut velocity) = (0.0, 0.0);
    for _ in 0..120 {
        (value, velocity) = KapaMotion::mouth_spring(value, velocity, 1.0, 1.0 / 60.0);
    }
    assert!((value - 1.0).abs() < 0.01 && velocity.abs() < 0.05);
    // A long frame is held to 50 ms, so a stall cannot throw it.
    let (v, _) = KapaMotion::mouth_spring(0.0, 0.0, 1.0, 10.0);
    let (w, _) = KapaMotion::mouth_spring(0.0, 0.0, 1.0, 0.05);
    assert_eq!(v, w);
    // Breathing is small and centred on 1.
    let (sx, sy) = KapaMotion::breath(0.0);
    assert_eq!((sx, sy), (1.0, 1.0));
    let (_, sy) = KapaMotion::breath(std::f64::consts::FRAC_PI_2 / 1.8);
    assert!((sy - 1.022).abs() < 1e-9);
    // Only the urgent poses outrank the rest.
    assert!(KapaMood::urgency(KapaExpression::Worried) < KapaMood::urgency(KapaExpression::Waiting));
    assert_eq!(KapaMood::urgency(KapaExpression::Rest), 5);
    assert_eq!(KapaMood::music(true), KapaExpression::Music);
    assert_eq!(KapaMood::music(false), KapaExpression::Paused);
    // Features move less than the eyes.
    let f = KapaGaze::features(KapaLook::new(0.4, 0.0));
    assert!(f.dx > 0.0 && f.dx < KapaGaze::eye(1.0, KapaLook::new(0.4, 0.0)).x - KapaGaze::FACE_X);
}

// MARK: - The fixture the JS side checks itself against

mod fixture {
    use super::*;
    use crate::view::ProviderView;
    use serde_json::{json, Value};

    const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../js/test/fixtures/kapa.json");

    fn looks() -> Vec<KapaLook> {
        vec![
            KapaLook::AHEAD,
            KapaLook::TOWARD_THE_ORB,
            KapaLook::new(0.4, 0.0),
            KapaLook::new(-0.4, 0.2),
            KapaLook::new(1.5, 0.0),
            KapaLook::new(0.0, 0.2),
            KapaLook::new(0.5, 0.4),
        ]
    }

    fn times() -> Vec<f64> {
        vec![-0.5, 0.0, 0.01, 0.07, 0.1, 0.2, 0.28, 0.33, 0.38, 0.45, 0.6, 0.9, 1.0, 1.2, 1.29, 1.3, 2.0]
    }

    fn views(snapshots: &[CapacitySnapshot]) -> Vec<Value> {
        snapshots.iter().map(|s| serde_json::to_value(ProviderView::new(s, now())).unwrap()).collect()
    }

    pub fn build() -> Value {
        let faces: serde_json::Map<String, Value> = KapaExpression::ALL
            .iter()
            .map(|e| (serde_json::to_value(e).unwrap().as_str().unwrap().to_owned(), serde_json::to_value(KapaFace::of(*e)).unwrap()))
            .collect();

        let gaze: Vec<Value> = looks()
            .into_iter()
            .flat_map(|look| {
                [-1.0, 1.0].map(|side| json!({"side": side, "look": look, "eye": KapaGaze::eye(side, look)}))
            })
            .collect();
        let features: Vec<Value> = looks().into_iter().map(|look| json!({"look": look, "features": KapaGaze::features(look)})).collect();

        let reactions = [("nod", Reaction::Nod), ("gulp", Reaction::Gulp), ("hop", Reaction::Hop)];
        let kicks: Vec<Value> = reactions
            .iter()
            .flat_map(|(name, r)| {
                times().into_iter().map(move |t| json!({"reaction": name, "elapsed": t, "kick": KapaMotion::kick(*r, t)}))
            })
            .collect();

        let bob: Vec<Value> = times()
            .iter()
            .map(|t| {
                let (dy, tilt, sy) = KapaMotion::bob(*t);
                json!({"time": t, "dy": dy, "tilt": tilt, "sy": sy})
            })
            .collect();
        let breath: Vec<Value> = times()
            .iter()
            .map(|t| {
                let (sx, sy) = KapaMotion::breath(*t);
                json!({"time": t, "sx": sx, "sy": sy})
            })
            .collect();
        let spring: Vec<Value> = [(0.0, 0.0, 1.0, 1.0 / 60.0), (0.5, 3.0, 1.0, 0.016), (0.2, -1.0, 0.0, 10.0), (0.0, 0.0, 0.35, 0.05)]
            .iter()
            .map(|(v, vel, target, dt)| {
                let (value, velocity) = KapaMotion::mouth_spring(*v, *vel, *target, *dt);
                json!({"value": v, "velocity": vel, "target": target, "dt": dt, "next": {"value": value, "velocity": velocity}})
            })
            .collect();
        let approach: Vec<Value> = [(0.0, 1.0, 0.0025, 1.0 / 30.0), (0.3, -2.0, 0.0008, 0.05), (1.0, 0.0, 0.0025, -1.0)]
            .iter()
            .map(|(v, t, b, dt)| json!({"value": v, "target": t, "base": b, "dt": dt, "next": KapaMotion::approach(*v, *t, *b, *dt)}))
            .collect();
        let appetite: Vec<Value> = [(1000.0, 150.0), (75.0, 150.0), (0.0, 150.0), (10.0, 0.0)]
            .iter()
            .map(|(d, r)| json!({"distance": d, "reach": r, "value": KapaMotion::appetite(*d, *r)}))
            .collect();

        let provider_cases: Vec<(CapacitySnapshot, KapaExpression)> = vec![
            (codex(&[0.24, 0.31]), KapaMood::capacity(&codex(&[0.24, 0.31]))),
            (codex(&[0.24, 0.5]), KapaMood::capacity(&codex(&[0.24, 0.5]))),
            (codex(&[0.96, 0.31]), KapaMood::capacity(&codex(&[0.96, 0.31]))),
            (codex(&[1.0, 0.4]), KapaMood::capacity(&codex(&[1.0, 0.4]))),
            (codex(&[0.9]), KapaMood::capacity(&codex(&[0.9]))),
            (codex(&[]), KapaMood::capacity(&codex(&[]))),
            (snapshot(Provider::Codex, &[0.96], ConnectionState::Stale), KapaExpression::Stale),
            (snapshot(Provider::Codex, &[], ConnectionState::Connecting), KapaExpression::Stale),
            (
                CapacitySnapshot::disconnected(Provider::ClaudeCode, now(), CapacityStatusReason::ClaudeCodeNotInstalled),
                KapaExpression::Puzzled,
            ),
        ];
        let moods: Vec<Value> = provider_cases
            .iter()
            .map(|(s, expected)| {
                assert_eq!(KapaMood::capacity(s), *expected);
                json!({"view": serde_json::to_value(ProviderView::new(s, now())).unwrap(), "expression": expected})
            })
            .collect();

        let gone = CapacitySnapshot::disconnected(Provider::Codex, now(), CapacityStatusReason::CodexDisconnected);
        let focus_cases: Vec<Vec<CapacitySnapshot>> = vec![
            vec![fresh(Provider::Codex, &[0.2]), fresh(Provider::ClaudeCode, &[0.97])],
            vec![fresh(Provider::Codex, &[0.2]), fresh(Provider::ClaudeCode, &[0.1])],
            vec![gone, fresh(Provider::ClaudeCode, &[1.0])],
            vec![],
        ];
        let focus: Vec<Value> = focus_cases
            .iter()
            .map(|c| json!({"views": views(c), "focus": KapaMood::capacity_focus(c)}))
            .collect();

        let blink: Vec<Value> = [0.0, 0.1, 0.22, 0.5, 1.0, 7.0, -3.0]
            .iter()
            .map(|d| json!({"draw": d, "delay": KapaBlink::delay(*d), "isDouble": KapaBlink::is_double(*d)}))
            .collect();
        let lid: Vec<Value> = times().iter().map(|t| json!({"elapsed": t, "value": KapaMotion::lid(*t)})).collect();
        let boop: Vec<Value> = times().iter().map(|t| json!({"elapsed": t, "kick": KapaMotion::boop(*t)})).collect();
        let shake: Vec<Value> = times().iter().map(|t| json!({"elapsed": t, "kick": KapaMotion::shake(*t)})).collect();
        let gulp: Vec<Value> = times().iter().map(|t| json!({"elapsed": t, "gulp": KapaMotion::gulp(*t)})).collect();

        json!({
            "faces": faces,
            "gaze": gaze,
            "features": features,
            "kicks": kicks,
            "bob": bob,
            "breath": breath,
            "spring": spring,
            "approach": approach,
            "appetite": appetite,
            "lid": lid,
            "boop": boop,
            "shake": shake,
            "gulp": gulp,
            "blink": blink,
            "moods": moods,
            "focus": focus,
        })
    }

    /// Equal where they are numbers within a rounding error, and exactly elsewhere.
    fn same(a: &Value, b: &Value, at: &str) {
        match (a, b) {
            (Value::Number(x), Value::Number(y)) => {
                let (x, y) = (x.as_f64().unwrap(), y.as_f64().unwrap());
                assert!((x - y).abs() <= 1e-9 * x.abs().max(1.0), "{at}: {x} != {y}");
            }
            (Value::Array(x), Value::Array(y)) => {
                assert_eq!(x.len(), y.len(), "{at}: lengths");
                for (i, (p, q)) in x.iter().zip(y).enumerate() {
                    same(p, q, &format!("{at}[{i}]"));
                }
            }
            (Value::Object(x), Value::Object(y)) => {
                assert_eq!(x.keys().collect::<Vec<_>>(), y.keys().collect::<Vec<_>>(), "{at}: keys");
                for (k, p) in x {
                    same(p, &y[k], &format!("{at}.{k}"));
                }
            }
            _ => assert_eq!(a, b, "{at}"),
        }
    }

    /// The JS side reads `linux/js/test/fixtures/kapa.json`. It is written
    /// from here (`KAPA_WRITE_FIXTURE=1 cargo test -p capa-core kapa`) and this
    /// test keeps it from drifting: change the Rust, and it fails until the
    /// fixture is written again and the JS port follows.
    #[test]
    fn the_shared_fixture_is_what_the_rust_says() {
        let built = build();
        if std::env::var_os("KAPA_WRITE_FIXTURE").is_some() {
            std::fs::create_dir_all(std::path::Path::new(PATH).parent().unwrap()).unwrap();
            std::fs::write(PATH, serde_json::to_string_pretty(&built).unwrap() + "\n").unwrap();
            return;
        }
        let on_disk: Value = serde_json::from_str(&std::fs::read_to_string(PATH).expect("fixture present")).unwrap();
        same(&built, &on_disk, "fixture");
    }
}
