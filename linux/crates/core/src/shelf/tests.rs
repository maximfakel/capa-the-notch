//! Ported from ShelfTests.swift and ClippingTests.swift, then the controller's
//! rules, which Swift kept in an AppKit class and so never tested.
//!
//! Left to their own modules: the page order (`SurfacePageOrder`), the
//! per-language counts ("5 файлов", `Localization`), the preferences' defaults
//! (`Preferences`) and `TeleprompterSurface.excludedFromCapture`.

use super::screenshots::{self, Entry, Naming, Settings};
use super::*;
use chrono::{DateTime, Duration, FixedOffset, TimeZone, Utc};
use serde_json::{json, Map, Value};
use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

fn file(name: &str) -> PathBuf {
    PathBuf::from(format!("/tmp/shelf-tests/{name}"))
}

fn names(items: &[ShelfItem]) -> Vec<String> {
    items.iter().map(ShelfItem::name).collect()
}

fn strs(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn paths(names: impl IntoIterator<Item = String>) -> Vec<PathBuf> {
    names.into_iter().map(|n| file(&n)).collect()
}

fn t(seconds: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(1_000_000 + seconds, 0).unwrap()
}

// MARK: - The Shelf

#[test]
fn the_shelf_keeps_the_newest_first_and_at_most_twenty() {
    let mut shelf = Shelf::new();
    shelf.add(&[file("a.pdf"), file("b.png")], ShelfTab::Files);
    assert_eq!(names(shelf.items(ShelfTab::Files)), strs(&["b.png", "a.pdf"]), "The newest first");

    shelf.add(&paths((1..=25).map(|i| format!("{i}.txt"))), ShelfTab::Files);
    assert_eq!(shelf.items(ShelfTab::Files).len(), ShelfTab::Files.limit(), "Twenty at most");
    assert_eq!(shelf.items(ShelfTab::Files)[0].name(), "25.txt", "The last one dropped is in front");
    assert!(!names(shelf.items(ShelfTab::Files)).contains(&"a.pdf".to_string()), "The oldest give way");
}

#[test]
fn a_file_dropped_again_rises_instead_of_appearing_twice() {
    let mut shelf = Shelf::new();
    shelf.add(&[file("a.pdf"), file("b.png"), file("c.zip")], ShelfTab::Files);
    let before: Vec<ItemId> = shelf.items(ShelfTab::Files).iter().map(|i| i.id).collect();
    shelf.add(&[file("a.pdf")], ShelfTab::Files);
    assert_eq!(names(shelf.items(ShelfTab::Files)), strs(&["a.pdf", "c.zip", "b.png"]), "Risen to the front");
    assert_eq!(shelf.items(ShelfTab::Files)[0].id, before[2], "The same item, not a new one");
}

#[test]
fn a_path_is_standardised_so_the_same_file_by_another_spelling_is_the_same_file() {
    let mut shelf = Shelf::new();
    shelf.add(&[PathBuf::from("/tmp/x/../shelf-tests/a.pdf")], ShelfTab::Files);
    shelf.add(&[file("a.pdf")], ShelfTab::Files);
    assert_eq!(shelf.items(ShelfTab::Files).len(), 1);
    assert_eq!(shelf.items(ShelfTab::Files)[0].path(), Some(file("a.pdf").as_path()));
    assert_eq!(standardize(Path::new("/a/./b/../c/")), PathBuf::from("/a/c"));
}

#[test]
fn a_file_is_removed_alone_and_clearing_empties_its_tab() {
    let mut shelf = Shelf::new();
    shelf.add(&[file("a.pdf"), file("b.png")], ShelfTab::Files);
    let b = shelf.items(ShelfTab::Files).iter().find(|i| i.name() == "b.png").unwrap().id;
    shelf.remove(b);
    assert_eq!(names(shelf.items(ShelfTab::Files)), strs(&["a.pdf"]), "Only that one goes");
    shelf.clear(ShelfTab::Files);
    assert!(shelf.items(ShelfTab::Files).is_empty(), "Clearing empties it");
}

#[test]
fn a_file_is_drawn_by_what_kind_it_is() {
    let kind = |n: &str| ShelfFileKind::from_path(&file(n));
    assert_eq!(kind("Отчёт.PDF"), ShelfFileKind::Pdf, "PDF, whatever the case");
    assert_eq!(kind("Снимок.png"), ShelfFileKind::Image, "An image shows itself");
    assert_eq!(kind("build.zip"), ShelfFileKind::Archive);
    assert_eq!(kind("Демо.key"), ShelfFileKind::Presentation);
    assert_eq!(kind("Договор.docx"), ShelfFileKind::Document);
    assert_eq!(kind("Бюджет.xlsx"), ShelfFileKind::Spreadsheet);
    assert_eq!(kind("notes"), ShelfFileKind::Other, "No extension, no guess");
    assert_eq!(ShelfFileKind::badge("a.pdf").as_deref(), Some("PDF"), "The badge is the extension");
    assert_eq!(ShelfFileKind::badge("a.markdown").as_deref(), Some("MARK"), "Four letters at most");
    assert_eq!(ShelfFileKind::badge("notes"), None, "Nothing to show, no badge");
    assert_eq!(ShelfFileKind::badge(".bashrc"), None, "A dotfile has no extension");
    assert_eq!(ShelfFileKind::badge("Договор.docx").as_deref(), Some("DOCX"));
}

#[test]
fn the_shelf_tells_diagnostics_how_many_never_which() {
    let mut shelf = Shelf::new();
    let none = Clippings::new();
    assert_eq!(observation(false, &shelf, &none), "shelf-off", "Off");
    shelf.add(&[file("a.pdf"), file("b.zip"), file("c.key")], ShelfTab::Files);
    shelf.add_in_memory("shot.png", vec![1], ShelfTab::Screenshots);
    shelf.add_in_memory("shot 2.png", vec![2], ShelfTab::Screenshots);
    assert_eq!(observation(true, &shelf, &none), "shelf-on-3-files-2-screenshots", "On, and how many in each tab");
}

#[test]
fn an_image_without_a_file_is_held_in_memory() {
    let mut shelf = Shelf::new();
    shelf.add(&[file("a.pdf")], ShelfTab::Files);
    let png = vec![0x89, 0x50, 0x4E, 0x47];
    shelf.add_in_memory("Снимок экрана.png", png.clone(), ShelfTab::Files);
    let first = |s: &Shelf| s.items(ShelfTab::Files)[0].clone();
    assert_eq!(first(&shelf).name(), "Снимок экрана.png", "An image dropped with no file lands in front");
    assert_eq!(first(&shelf).path(), None, "With no file behind it");
    assert_eq!(first(&shelf).kind(), ShelfFileKind::Image, "Drawn as an image");
    shelf.add_in_memory("Снимок экрана 2.png", png, ShelfTab::Files);
    assert_eq!(shelf.items(ShelfTab::Files).len(), 2, "The same image again rises rather than appearing twice");
    assert_eq!(first(&shelf).name(), "Снимок экрана 2.png", "Under its newer name");
    shelf.add(&paths((1..=25).map(|i| format!("{i}.txt"))), ShelfTab::Files);
    assert_eq!(shelf.items(ShelfTab::Files).len(), ShelfTab::Files.limit(), "Images dropped count towards the twenty files");
}

#[test]
fn the_shelf_has_three_tabs_in_order() {
    assert_eq!(ShelfTab::ALL, [ShelfTab::Files, ShelfTab::Screenshots, ShelfTab::Clipboard]);
    assert_eq!(ShelfTab::Files.limit(), 20);
    assert_eq!(ShelfTab::Screenshots.limit(), 20);
}

#[test]
fn what_is_copied_lands_in_the_tab_for_its_kind() {
    let mut shelf = Shelf::new();
    let shot = "Снимок экрана 2026-10-01 в 01.02.03.png";
    shelf.add_in_memory(shot, vec![0x89, 0x50, 0x4E, 0x47], ShelfTab::for_copied(shot));
    shelf.add_in_memory("Договор.docx", vec![1, 2, 3], ShelfTab::for_copied("Договор.docx"));
    shelf.add(&[file("photo.JPG")], ShelfTab::for_copied("photo.JPG"));
    shelf.add(&[file("Отчёт.pdf")], ShelfTab::Files);

    assert_eq!(names(shelf.items(ShelfTab::Screenshots)), strs(&["photo.JPG", shot]), "Screenshots and copied images under Screenshots");
    assert_eq!(names(shelf.items(ShelfTab::Files)), strs(&["Отчёт.pdf", "Договор.docx"]), "A dropped file and a copied document under Files");
    assert!(shelf.items(ShelfTab::Clipboard).is_empty(), "Nothing under Clipboard until text intake");
    assert_eq!(shelf.count(), 4, "Four held in all");
}

#[test]
fn each_tab_keeps_its_own_limit() {
    let mut shelf = Shelf::new();
    shelf.add(&paths((1..=20).map(|i| format!("{i}.txt"))), ShelfTab::Files);
    for index in 1..=25u8 {
        shelf.add_in_memory(&format!("{index}.png"), vec![index], ShelfTab::Screenshots);
    }
    assert_eq!(shelf.items(ShelfTab::Screenshots).len(), 20, "Twenty screenshots");
    assert_eq!(shelf.items(ShelfTab::Screenshots)[0].name(), "25.png", "The newest in front");
    assert!(!names(shelf.items(ShelfTab::Screenshots)).contains(&"1.png".to_string()), "The oldest screenshot gives way");
    assert_eq!(shelf.items(ShelfTab::Files).len(), 20, "and the twenty files are all still there");
}

#[test]
fn clear_empties_only_the_tab_it_is_asked_for() {
    let mut shelf = Shelf::new();
    shelf.add(&[file("a.pdf"), file("b.zip")], ShelfTab::Files);
    shelf.add_in_memory("shot.png", vec![9], ShelfTab::Screenshots);
    shelf.clear(ShelfTab::Screenshots);
    assert!(shelf.items(ShelfTab::Screenshots).is_empty(), "Screenshots cleared");
    assert_eq!(shelf.items(ShelfTab::Files).len(), 2, "Files kept");
    let a = shelf.items(ShelfTab::Files).iter().find(|i| i.name() == "a.pdf").unwrap().id;
    shelf.remove(a);
    assert_eq!(names(shelf.items(ShelfTab::Files)), strs(&["b.zip"]), "Removing finds the item in whichever tab holds it");
    shelf.clear_all();
    assert_eq!(shelf.count(), 0, "Switching off or quitting empties every tab");
}

#[test]
fn a_tile_name_is_cut_in_the_middle_keeping_the_last_word() {
    let narrow = |text: &str| text.chars().count() <= 14;
    assert_eq!(fitted_tile_name("short.png", narrow), "short.png", "What fits is left alone");
    let cut = fitted_tile_name("Снимок экрана 2026-10-01 в 12.41.png", narrow);
    assert!(cut.ends_with("… 12.41.png"), "{cut}");
    assert!(cut.chars().count() <= 14, "{cut}");
    assert!(cut.starts_with("Сн"), "{cut}");
    let no_space = fitted_tile_name("averyveryverylongnamewithoutspaces.png", narrow);
    assert!(no_space.ends_with("…aces.png"), "With no space to cut at, the last eight characters stay: {no_space}");
}

// MARK: - From the clipboard

#[test]
fn a_screenshot_on_the_clipboard_is_one_png_and_nothing_else() {
    let items = |v: &[&[&str]]| -> Vec<Vec<String>> { v.iter().map(|i| strs(i)).collect() };
    assert!(ScreenshotClipboard::is_screenshot(&items(&[&["public.png"]])), "One item, only PNG: a screenshot");
    assert!(!ScreenshotClipboard::is_screenshot(&items(&[&["public.png", "public.tiff", "public.url"]])), "An image copied from a page brings more");
    assert!(!ScreenshotClipboard::is_screenshot(&items(&[&["public.utf8-plain-text"]])), "Text is not");
    assert!(!ScreenshotClipboard::is_screenshot(&items(&[&["public.png"], &["public.png"]])), "Two items are not one screenshot");
    assert!(!ScreenshotClipboard::is_screenshot(&[]), "Nothing is nothing");
}

#[test]
fn a_screenshot_is_named_as_macos_names_one() {
    let utc = FixedOffset::east_opt(0).unwrap();
    let date = Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 3).unwrap().with_timezone(&utc);
    assert_eq!(ScreenshotClipboard::name(&date, NameLanguage::Russian), "Снимок экрана 2026-10-01 в 01.02.03.png", "In Russian, as Finder shows them");
    assert_eq!(ScreenshotClipboard::name(&date, NameLanguage::English), "Screenshot 2026-10-01 at 01.02.03.png", "And in English");
    let moscow = FixedOffset::east_opt(3 * 3600).unwrap();
    let there = Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 3).unwrap().with_timezone(&moscow);
    assert_eq!(ScreenshotClipboard::name(&there, NameLanguage::English), "Screenshot 2026-10-01 at 04.02.03.png", "In the zone it was copied in");
}

#[test]
fn an_image_that_is_not_a_screenshot_is_named_for_its_moment() {
    let utc = FixedOffset::east_opt(0).unwrap();
    let date = Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 3).unwrap().with_timezone(&utc);
    assert_eq!(ScreenshotClipboard::image_name(&date, NameLanguage::English, "jpeg"), "Image 2026-10-01 at 01.02.03.jpeg");
    assert_eq!(ScreenshotClipboard::image_name(&date, NameLanguage::Russian, "png"), "Изображение 2026-10-01 в 01.02.03.png");
}

fn take(
    items: &[&[&str]],
    path: Option<&str>,
    size: Option<u64>,
    folder: bool,
    manager: bool,
) -> Choice {
    let items: Vec<Vec<String>> = items.iter().map(|i| strs(i)).collect();
    ClipboardTake::choose(&items, path.map(Path::new), size, folder, manager, &ClipboardRules::macos())
}

#[test]
fn what_is_copied_lands_on_the_shelf_except_from_finder() {
    const MB: u64 = 1024 * 1024;
    let plain = |items: &[&[&str]]| take(items, None, None, false, false);
    assert_eq!(plain(&[&["public.png"]]), Choice::Screenshot, "A lone PNG is a screenshot");
    assert_eq!(plain(&[&["public.html", "public.tiff", "public.png", "public.url"]]), Choice::Data("public.png".into()), "An image from a page: its PNG, over the TIFF");
    assert_eq!(plain(&[&["org.webmproject.webp", "public.url"]]), Choice::Data("org.webmproject.webp".into()), "WebP too");
    assert_eq!(plain(&[&["public.tiff"]]), Choice::Data("public.tiff".into()), "TIFF when nothing else");
    let photo = Some("/tmp/cache/photo.JPG");
    let contract = Some("/tmp/cache/Договор.docx");
    let url: &[&[&str]] = &[&["public.file-url"]];
    assert_eq!(take(url, photo, Some(2 * MB), false, false), Choice::FileIntoMemory, "An image file copied as Telegram copies media");
    assert_eq!(take(url, contract, Some(3 * MB), false, false), Choice::FileIntoMemory, "A document from a messenger, held in memory");
    assert_eq!(take(url, contract, Some(50 * MB), false, false), Choice::FileIntoMemory, "Fifty megabytes exactly is still memory");
    assert_eq!(take(url, contract, Some(200 * MB), false, false), Choice::FileReference, "Past fifty megabytes, a reference");
    assert_eq!(take(url, contract, Some(3 * MB), false, true), Choice::Nothing, "Copying in Finder is a file operation, left alone");
    assert_eq!(take(url, photo, Some(2 * MB), false, true), Choice::Nothing, "Images included");
    assert_eq!(take(url, Some("/tmp/Папка"), None, true, false), Choice::Nothing, "Not a folder");
    assert_eq!(take(url, None, None, false, false), Choice::Nothing, "A file the clipboard names but cannot be found");
    assert_eq!(plain(&[&["public.utf8-plain-text"]]), Choice::Nothing, "Text never");
    assert_eq!(plain(&[&["public.png", "org.nspasteboard.ConcealedType"]]), Choice::Nothing, "Nothing a password manager marks as secret");
    assert_eq!(plain(&[&["public.png", "org.nspasteboard.TransientType"]]), Choice::Nothing, "Nor anything marked as passing through");
    assert_eq!(plain(&[]), Choice::Nothing, "Nothing on it");
    let rules = ClipboardRules::macos();
    assert!(rules.is_excluded_application(Some("com.apple.Passwords")), "Passwords is never read from");
    assert!(rules.is_excluded_application(Some("com.apple.keychainaccess")), "Nor Keychain Access");
    assert!(!rules.is_excluded_application(Some("ru.keepcoder.Telegram")), "Telegram is");
    assert!(!rules.is_excluded_application(None));
}

#[test]
fn the_rules_are_data_each_platform_feeds() {
    let linux = ClipboardRules::linux();
    assert!(linux.secret_markers.contains("x-kde-passwordManagerHint"));
    assert!(linux.is_excluded_application(Some("org.keepassxc.KeePassXC")));
    assert!(linux.is_file_manager(Some("org.gnome.Nautilus")));
    assert!(linux.secret_markers.contains("org.nspasteboard.ConcealedType"), "The reference markers stay");
    assert_eq!(ClipboardRules::default(), ClipboardRules::macos());
    // A KDE-marked secret is not taken, with the marker named as the platform names it.
    let items = vec![strs(&["public.utf8-plain-text", "x-kde-passwordManagerHint"])];
    assert!(!ClipboardText::is_kept(&items, None, &BTreeSet::new(), None, &linux));
    assert!(ClipboardText::is_kept(&items, None, &BTreeSet::new(), None, &ClipboardRules::macos()), "A marker the rules do not list is not one");
}

#[test]
fn a_platforms_formats_are_mapped_onto_the_identifiers_the_rules_read() {
    assert_eq!(canonical::linux("text/plain;charset=utf-8"), "public.utf8-plain-text");
    assert_eq!(canonical::linux("UTF8_STRING"), "public.utf8-plain-text");
    assert_eq!(canonical::linux("image/png"), "public.png");
    assert_eq!(canonical::linux("text/uri-list"), "public.file-url");
    assert_eq!(canonical::linux("x-kde-passwordManagerHint"), "x-kde-passwordManagerHint", "What is not known passes through, to be found as a marker");
    assert_eq!(canonical::linux("application/x-capacitynotch-own"), ClipboardText::OWN_MARKER);
}

// MARK: - The screenshot folder

fn domain(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn the_screenshot_folder_is_where_macos_saves_screenshots() {
    let home = Path::new("/Users/someone");
    assert_eq!(screenshots::location(None, home), PathBuf::from("/Users/someone/Desktop"), "The Desktop unless another place was chosen");
    assert_eq!(screenshots::location(Some("~/Pictures/Снимки"), home), PathBuf::from("/Users/someone/Pictures/Снимки"), "A folder of one's own, with ~ for home");
    assert_eq!(screenshots::location(Some("/Volumes/Work/Shots/"), home), PathBuf::from("/Volumes/Work/Shots"), "Or anywhere at all");
    assert_eq!(screenshots::location(Some("  "), home), PathBuf::from("/Users/someone/Desktop"), "A blank setting is no setting");
}

fn entry(folder: &str, name: &str, after: i64, regular: bool) -> Entry {
    Entry { path: PathBuf::from(folder).join(name), created: t(after), is_regular_file: regular }
}

#[test]
fn only_screenshots_saved_after_the_switch_was_turned_on_are_taken() {
    let f = "/Users/someone/Desktop";
    let on = t(0);
    let entries = vec![
        entry(f, "Снимок экрана 2026-10-02 в 10.00.02.png", 2, true),
        entry(f, "Screenshot 2026-10-02 at 10.00.01.png", 1, true),
        entry(f, "Снимок экрана 2026-10-02 в 09.59.00.png", -60, true),
        entry(f, ".Снимок экрана 2026-10-02 в 10.00.03.png", 3, true),
        entry(f, "kcl.png", 4, true),
        entry(f, "Отчёт.pdf", 5, true),
        entry(f, "Bildschirmfoto 2026-10-02 um 10.00.06.png", 6, true),
        entry(f, "Screenshot 2026-10-02 at 1.00.07 PM.png", 7, true),
        entry(f, "Screenshot 2026-10-02 at 10.00.08.png", 8, false),
    ];
    let naming = Naming::MacOs(Settings::default());
    let taken = screenshots::new_screenshots(&entries, on, &BTreeSet::new(), &naming);
    let last: Vec<String> = taken.iter().map(|p| file_name(p)).collect();
    assert_eq!(
        last,
        strs(&[
            "Screenshot 2026-10-02 at 10.00.01.png",
            "Снимок экрана 2026-10-02 в 10.00.02.png",
            "Bildschirmfoto 2026-10-02 um 10.00.06.png",
            "Screenshot 2026-10-02 at 1.00.07 PM.png",
        ]),
        "New screenshots, oldest first so the newest lands in front — whatever language names them — never one from before, one still being written, another image, a document or a folder"
    );
    let again = screenshots::new_screenshots(&entries, on, &taken.iter().cloned().collect(), &naming);
    assert!(again.is_empty(), "A screenshot already taken is not taken again");
}

#[test]
fn a_screenshot_is_known_by_the_name_and_type_macos_was_told_to_use() {
    let taken = |name: &str, settings: Settings| screenshots::is_screenshot(name, &settings);
    let none = Settings::default;
    assert!(taken("Screenshot.png", none()), "Without the date, by its name");
    assert!(taken("Снимок экрана 2.png", none()), "or a numbered one");
    assert!(!taken("Screenshot 2026-10-02 at 10.00.01.jpg", none()), "PNG unless told otherwise");
    assert!(taken("Screenshot 2026-10-02 at 10.00.01.jpg", Settings::new(None, Some("jpg".into()))), "JPEG when macOS was told JPEG");
    assert!(taken("Screenshot 2026-10-02 at 10.00.01.jpeg", Settings::new(None, Some("jpg".into()))), "jpeg is jpg");
    let own = || Settings::new(Some("Экран".into()), None);
    assert!(taken("Экран.png", own()), "A name of one's own");
    assert!(taken("Экран 2026-10-02 в 10.00.01.png", own()), "with the date after it");
    assert!(!taken("Экраны и окна.png", own()), "but not any word that starts with it");
    assert!(!taken("Screenshot of the bug.png", none()), "nor a name that only begins like a screenshot's");
    assert!(taken("Screenshot 2026-10-02 at 10.00.01 (2).png", none()), "Two in one second");
    assert!(taken("Снимок экрана — 2026-10-02 в 18.03.21.png", none()), "macOS 27 puts a dash between the name and the day");
    assert!(taken("Снимок экрана\u{00A0}— 2026-10-02 в\u{00A0}18.03.21.png", none()), "with no-break spaces where macOS 27 puts them, as on this Mac");
    assert!(taken("Screenshot 2026-10-02 at 1.00.07\u{202F}PM.png", none()), "and the narrow one before PM");
    assert!(taken("Screenshot — 2026-10-02 at 18.03.21.png", none()), "in English too");
    assert!(taken("Экран — 2026-10-02 в 18.03.21.png", own()), "and after a name of one's own");
    assert!(!taken("Bildschirmfoto 2026-10-02 um 10.00.06.png", own()), "With a name of one's own, only that name");
    assert!(taken("Bildschirmfoto 2026-10-02 um 10.00.06.png", none()), "Any name before the date, without one");
    assert!(!taken(".Screenshot.png", none()), "A hidden file is one still being written");
    assert!(!taken("Screenshot 2026-10-02 at 10.00.01 extra words.png", none()), "A date followed by more is not one");
    assert!(!taken("Screenshot 20261002 at 10.00.01.png", none()), "A day is yyyy-mm-dd");
}

#[test]
fn the_screenshot_settings_are_read_from_macoss_own_keys() {
    let home = Path::new("/Users/someone");
    let chosen = domain(json!({"location": "~/Pictures", "name": "Экран", "type": "JPG", "location-last": "~/Elsewhere"}));
    assert_eq!(screenshots::location_from_domain(&chosen, home), PathBuf::from("/Users/someone/Pictures"), "`location`, not the last one offered");
    assert_eq!(Settings::from_domain(&chosen), Settings::new(Some("Экран".into()), Some("jpg".into())), "`name` and `type`, the type in lower case");
    assert_eq!(screenshots::location_from_domain(&Map::new(), home), PathBuf::from("/Users/someone/Desktop"), "Nothing said, the Desktop");
    assert_eq!(Settings::from_domain(&domain(json!({"name": "", "type": 3}))), Settings::default(), "Nothing usable, nothing set");
}

#[test]
fn the_folder_is_looked_at_only_while_macos_saves_screenshots_to_one() {
    assert!(screenshots::saves_to_folder(&Map::new()), "To a file, unless told otherwise");
    assert!(screenshots::saves_to_folder(&domain(json!({"target": "file"}))), "To a file");
    assert!(!screenshots::saves_to_folder(&domain(json!({"target": "clipboard"}))), "Not while screenshots go to the clipboard");
    assert!(!screenshots::saves_to_folder(&domain(json!({"target": "preview"}))), "nor to Preview");
    assert!(
        screenshots::saves_to_folder(&domain(json!({"target": "clipboard", "target-screenshot": "file"}))),
        "The screenshots' own target over the shared one"
    );
}

#[test]
fn other_systems_name_their_screenshots_in_their_own_way() {
    let gnome = Naming::Gnome;
    assert!(gnome.is_screenshot("Screenshot from 2026-10-02 10-00-01.png"));
    assert!(gnome.is_screenshot("Снимок экрана от 2026-10-02 10-00-01.png"));
    assert!(gnome.is_screenshot("Screenshot from 2026-10-02 10-00-01 (2).png"));
    assert!(!gnome.is_screenshot("Screenshot from 2026-10-02 10-00-01.jpg"));
    assert!(!gnome.is_screenshot("holiday.png"));
    assert!(!gnome.is_screenshot(".Screenshot from 2026-10-02 10-00-01.png"));
    let kde = Naming::Spectacle;
    assert!(kde.is_screenshot("Screenshot_20261002_100001.png"));
    assert!(kde.is_screenshot("Screenshot_20261002_100001_1.png"));
    assert!(!kde.is_screenshot("Screenshot_2026.png"));
    assert_eq!(Naming::for_platform(Platform::Linux, Some("KDE")), Naming::Spectacle);
    assert_eq!(Naming::for_platform(Platform::Linux, Some("GNOME")), Naming::Gnome);
}

// MARK: - Clippings

fn keep(clippings: &mut Clippings, text: &str, at: i64) -> bool {
    clippings.keep(text, t(at), ClippingLimit::default())
}

fn texts(clippings: &Clippings) -> Vec<String> {
    clippings.items().iter().map(|c| c.text.clone()).collect()
}

#[test]
fn clippings_are_newest_first_and_a_repeat_rises() {
    let mut c = Clippings::new();
    keep(&mut c, "один", 0);
    keep(&mut c, "два", 1);
    keep(&mut c, "один", 2);
    assert_eq!(texts(&c), strs(&["один", "два"]), "A repeat rises rather than appearing twice");
    assert_eq!(c.items()[0].copied_at, t(2), "with the time it was copied again");
}

#[test]
fn clippings_keep_twenty_or_fifty_or_a_hundred() {
    assert_eq!(ClippingLimit::ALL.map(ClippingLimit::raw), [20, 50, 100], "20, 50 or 100");
    assert_eq!(ClippingLimit::DEFAULT, ClippingLimit::Twenty, "20 unless chosen");
    let mut c = Clippings::new();
    for index in 1..=60 {
        c.keep(&index.to_string(), t(index), ClippingLimit::Fifty);
    }
    assert_eq!(c.items().len(), 50, "Fifty when chosen");
    assert_eq!(c.items()[0].text, "60");
    assert_eq!(c.items().last().unwrap().text, "11", "The oldest give way");
    c.keep("61", t(61), ClippingLimit::Twenty);
    assert_eq!(c.items().len(), 20, "Down to twenty when that is chosen again");
}

#[test]
fn a_clipping_goes_after_a_day_unless_that_is_switched_off() {
    let mut c = Clippings::new();
    keep(&mut c, "старый", 0);
    keep(&mut c, "новый", 3600);
    let day = 24 * 3600;
    let mut kept = c.clone();
    kept.forget_old(t(day + 1), false);
    assert_eq!(kept.items().len(), 2, "Expiry switched off keeps both");
    c.forget_old(t(day - 1), true);
    assert_eq!(c.items().len(), 2, "Not before the day is out");
    c.forget_old(t(day), true);
    assert_eq!(texts(&c), strs(&["новый"]), "At 24 hours it goes");
}

#[test]
fn a_text_too_long_or_empty_is_not_kept_at_all() {
    let mut c = Clippings::new();
    assert!(!keep(&mut c, &"a".repeat(100_001), 0), "Over 100,000 characters, not kept");
    assert!(keep(&mut c, &"a".repeat(100_000), 0), "100,000 exactly is kept");
    assert!(!keep(&mut c, "  \n ", 0), "Nothing but spaces is nothing");
    assert_eq!(c.items().len(), 1, "Only the one that fits");
}

#[test]
fn a_clipping_is_removed_alone_and_clearing_empties_them() {
    let mut c = Clippings::new();
    keep(&mut c, "a", 0);
    keep(&mut c, "b", 0);
    let b = c.items().iter().find(|x| x.text == "b").unwrap().id;
    c.remove(b);
    assert_eq!(texts(&c), strs(&["a"]), "Only that one goes");
    c.clear();
    assert!(c.items().is_empty(), "Clearing empties them");
}

#[test]
fn only_plain_text_copied_elsewhere_and_unmarked_is_kept() {
    let own = Some("app.capacitynotch.CapacityNotch");
    let rules = ClipboardRules::macos();
    let keeps = |types: &[&str], front: Option<&str>, excluded: &[&str]| {
        let excluded: BTreeSet<String> = excluded.iter().map(|s| s.to_string()).collect();
        ClipboardText::is_kept(&[strs(types)], front, &excluded, own, &rules)
    };
    let safari = Some("com.apple.Safari");
    assert!(keeps(&["public.utf8-plain-text"], safari, &[]), "Plain text");
    assert!(keeps(&["public.html", "public.utf8-plain-text", "public.rtf"], safari, &[]), "Text copied from a page");
    assert!(!keeps(&["public.png"], safari, &[]), "An image is not text");
    assert!(!keeps(&["public.file-url", "public.utf8-plain-text"], safari, &[]), "A copied file's name is not a Clipping");
    assert!(!keeps(&["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], safari, &[]), "Concealed");
    assert!(!keeps(&["public.utf8-plain-text", "org.nspasteboard.TransientType"], safari, &[]), "Transient");
    assert!(!keeps(&["public.utf8-plain-text", "org.nspasteboard.AutoGeneratedType"], safari, &[]), "Auto-generated");
    assert!(!keeps(&["public.utf8-plain-text", "com.agilebits.onepassword"], safari, &[]), "An older marker");
    assert!(!keeps(&["public.utf8-plain-text"], Some("com.apple.Passwords"), &[]), "Copied while Passwords is in front");
    assert!(!keeps(&["public.utf8-plain-text"], Some("com.apple.keychainaccess"), &[]), "or Keychain Access");
    assert!(!keeps(&["public.utf8-plain-text"], Some("ru.bank.app"), &["ru.bank.app"]), "or an application chosen in Settings");
    assert!(!keeps(&["public.utf8-plain-text", ClipboardText::OWN_MARKER], safari, &[]), "Never what CapaTheNotch put there itself");
    assert!(
        !keeps(&["public.utf8-plain-text"], own, &[]),
        "Nor what is copied with ⌘C in its own windows — Dictation's history, the report"
    );
    assert!(!ClipboardText::is_kept(&[], None, &BTreeSet::new(), None, &rules), "Nothing is nothing");
    assert!(keeps(&["public.utf8-plain-text"], None, &[]), "No application known: kept");
}

#[test]
fn the_shelf_tells_diagnostics_how_many_clippings_never_which() {
    let mut c = Clippings::new();
    keep(&mut c, "секрет", 0);
    let said = observation(true, &Shelf::new(), &c);
    assert_eq!(said, "shelf-on-0-files-0-screenshots-1-clippings", "Counts only");
    assert!(!said.contains("секрет"), "Never what was copied");
}

#[test]
fn fewer_chosen_the_oldest_go_at_once_and_the_rest_stay_as_they_were() {
    let mut c = Clippings::new();
    for index in 1..=30 {
        c.keep(&index.to_string(), t(index), ClippingLimit::Fifty);
    }
    let newest = c.items()[0].clone();
    c.trim(ClippingLimit::Twenty);
    assert_eq!(c.items().len(), 20);
    assert_eq!(c.items()[0], newest, "The newest unchanged, the same Clipping as before");
    assert_eq!(c.items().last().unwrap().text, "11", "The oldest gone");
}

#[test]
fn a_limit_is_a_number_in_json_and_nothing_else_is_a_limit() {
    assert_eq!(serde_json::to_string(&ClippingLimit::Fifty).unwrap(), "50");
    assert_eq!(serde_json::from_str::<ClippingLimit>("100").unwrap(), ClippingLimit::Hundred);
    assert!(serde_json::from_str::<ClippingLimit>("30").is_err());
    assert_eq!(ClippingLimit::from_raw(0), None, "An unset preference reads as the default, not as a limit");
}

// MARK: - The controller

#[derive(Default)]
struct FakeFiles {
    present: RefCell<BTreeSet<PathBuf>>,
    metas: RefCell<HashMap<PathBuf, FileMeta>>,
    contents: RefCell<HashMap<PathBuf, Vec<u8>>>,
}

impl FakeFiles {
    fn has(&self, path: &str, size: u64, content: &[u8]) {
        let p = PathBuf::from(path);
        self.present.borrow_mut().insert(p.clone());
        self.metas.borrow_mut().insert(p.clone(), FileMeta { size, is_directory: false });
        self.contents.borrow_mut().insert(p, content.to_vec());
    }
}

impl ShelfFiles for FakeFiles {
    fn exists(&self, path: &Path) -> bool {
        self.present.borrow().contains(path)
    }
    fn meta(&self, path: &Path) -> Option<FileMeta> {
        self.metas.borrow().get(path).copied()
    }
    fn read(&self, path: &Path) -> Option<Vec<u8>> {
        self.contents.borrow().get(path).cloned()
    }
}

#[derive(Default)]
struct FakeBoard {
    count: RefCell<u64>,
    front: RefCell<Option<String>>,
    types: RefCell<Vec<Vec<String>>>,
    text: RefCell<Option<String>>,
    file: RefCell<Option<PathBuf>>,
    data: RefCell<HashMap<String, Vec<u8>>>,
    refused: RefCell<bool>,
}

impl FakeBoard {
    fn copy(&self, front: &str, types: &[&[&str]]) {
        *self.count.borrow_mut() += 1;
        *self.front.borrow_mut() = Some(front.to_owned());
        *self.types.borrow_mut() = types.iter().map(|i| strs(i)).collect();
    }
}

impl ClipboardSource for FakeBoard {
    fn change_count(&self) -> u64 {
        *self.count.borrow()
    }
    fn frontmost_application(&self) -> Option<String> {
        self.front.borrow().clone()
    }
    fn item_types(&self) -> Vec<Vec<String>> {
        self.types.borrow().clone()
    }
    fn text(&self) -> Option<String> {
        self.text.borrow().clone()
    }
    fn file_path(&self) -> Option<PathBuf> {
        self.file.borrow().clone()
    }
    fn data(&self, kind: &str) -> Option<Vec<u8>> {
        self.data.borrow().get(kind).cloned()
    }
    fn access_refused(&self) -> bool {
        *self.refused.borrow()
    }
}

struct Png;

impl ImageCodec for Png {
    fn to_png(&self, data: &[u8], from_type: &str) -> Option<Vec<u8>> {
        assert_eq!(from_type, "public.tiff");
        Some([b"PNG:".as_slice(), data].concat())
    }
}

fn names_in() -> NameContext {
    NameContext { language: NameLanguage::English, offset: FixedOffset::east_opt(0).unwrap() }
}

fn controller(settings: ShelfSettings) -> ShelfController {
    ShelfController::new(settings, ClipboardRules::macos()).with_own_application("app.capacitynotch.CapacityNotch")
}

fn on() -> ShelfSettings {
    ShelfSettings { enabled: true, takes_clipboard_images: true, keeps_text: true, ..Default::default() }
}

/// Starts watching, as the first poll does, and returns the controller ready.
fn watching(settings: ShelfSettings, board: &FakeBoard, files: &FakeFiles) -> ShelfController {
    let mut c = controller(settings);
    assert!(c.poll_clipboard(t(0), board, files, None, &names_in()).is_empty());
    c
}

#[test]
fn everything_is_off_until_asked_for() {
    let s = ShelfSettings::default();
    assert!(!s.enabled && !s.takes_clipboard_images && !s.keeps_text, "Nothing on anyone's behalf");
    assert_eq!(s.clipping_limit, ClippingLimit::Twenty, "Twenty Clippings");
    assert!(s.clippings_expire, "Each gone after a day");
    assert!(s.excluded_applications.is_empty(), "No application chosen");
    let c = controller(s);
    assert!(!c.wants_clipboard() && !c.wants_folder());
    assert_eq!(serde_json::to_value(ShelfSettings::default()).unwrap()["clippingLimit"], 20);
    // A settings file from an older run, with a key missing, still reads.
    assert_eq!(serde_json::from_str::<ShelfSettings>(r#"{"enabled":true}"#).unwrap().clipping_limit, ClippingLimit::Twenty);
}

#[test]
fn an_off_shelf_holds_nothing_and_switching_it_off_empties_it() {
    let files = FakeFiles::default();
    let mut c = controller(ShelfSettings::default());
    c.add(&[file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("x.png", vec![1], ShelfTab::Screenshots);
    assert_eq!(c.shelf().count(), 0, "Off, it holds nothing");

    c.set_enabled(true);
    c.set_keeps_text(true);
    c.add(&[file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("x.png", vec![1], ShelfTab::Screenshots);
    c.keep_clipping("hello", t(0));
    assert_eq!((c.shelf().count(), c.clippings().items().len()), (2, 1));
    c.set_enabled(false);
    assert_eq!((c.shelf().count(), c.clippings().items().len()), (0, 0), "Switching it off empties it, Clippings too");
    assert_eq!(c.diagnostics(), vec!["shelf-off"]);
}

#[test]
fn text_is_kept_only_on_its_own_switch_and_off_the_clippings_go_at_once() {
    let mut c = controller(ShelfSettings { enabled: true, ..Default::default() });
    c.keep_clipping("a", t(0));
    assert!(c.clippings().items().is_empty(), "Text intake is off until turned on");
    c.set_keeps_text(true);
    c.keep_clipping("a", t(0));
    assert_eq!(c.clippings().items().len(), 1);
    c.set_keeps_text(false);
    assert!(c.clippings().items().is_empty(), "Off, the Clippings go at once");
}

#[test]
fn changing_the_limit_or_the_expiry_acts_at_once() {
    let mut c = controller(ShelfSettings { enabled: true, keeps_text: true, clipping_limit: ClippingLimit::Fifty, ..Default::default() });
    for i in 0..30 {
        c.keep_clipping(&i.to_string(), t(i));
    }
    c.set_clipping_limit(ClippingLimit::Twenty);
    assert_eq!(c.clippings().items().len(), 20);
    assert_eq!(c.settings().clipping_limit, ClippingLimit::Twenty);
    c.set_clippings_expire(false, t(0));
    c.tick(t(10 * 24 * 3600));
    assert_eq!(c.clippings().items().len(), 20, "Expiry off: kept");
    c.set_clippings_expire(true, t(10 * 24 * 3600));
    assert!(c.clippings().items().is_empty(), "Expiry on: the old go at once");
}

#[test]
fn clear_empties_only_the_tab_shown() {
    let files = FakeFiles::default();
    let mut c = controller(on());
    c.add(&[file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("s.png", vec![5], ShelfTab::Screenshots);
    c.keep_clipping("t", t(0));
    c.tab = ShelfTab::Screenshots;
    c.clear();
    assert_eq!((c.items(ShelfTab::Screenshots).len(), c.items(ShelfTab::Files).len(), c.clippings().items().len()), (0, 1, 1));
    c.tab = ShelfTab::Clipboard;
    c.clear();
    assert_eq!((c.items(ShelfTab::Files).len(), c.clippings().items().len()), (1, 0), "Clipboard clears the Clippings and no files");
}

#[test]
fn a_file_moved_since_is_shown_as_moved() {
    let files = FakeFiles::default();
    files.present.borrow_mut().insert(file("a.pdf"));
    files.present.borrow_mut().insert(file("b.pdf"));
    let mut c = controller(on());
    c.add(&[file("a.pdf"), file("b.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("s.png", vec![1], ShelfTab::Screenshots);
    assert!(c.missing().is_empty());
    files.present.borrow_mut().remove(&file("a.pdf"));
    c.refresh_availability(&files);
    let a = c.items(ShelfTab::Files).iter().find(|i| i.name() == "a.pdf").unwrap().id;
    assert_eq!(c.missing().iter().copied().collect::<Vec<_>>(), vec![a], "Only the file; an image in memory cannot go missing");
    c.remove(a);
    assert!(c.missing().is_empty(), "Gone from the Shelf, gone from the missing");
}

#[test]
fn thumbnails_are_asked_for_once_and_kept_only_while_the_item_is_held() {
    let files = FakeFiles::default();
    let mut c = controller(on());
    // Only images are drawn: the PDF is not, wherever it lies.
    c.add(&[file("photo.png"), file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("s.png", vec![1], ShelfTab::Files);
    let jobs = c.pending_thumbnails();
    assert_eq!(jobs.len(), 2);
    assert!(jobs.iter().any(|j| matches!(j, ThumbnailJob::File { path, .. } if path.ends_with("photo.png"))));
    let data_id = jobs.iter().find_map(|j| if let ThumbnailJob::Data { id } = j { Some(*id) } else { None }).unwrap();
    assert!(c.pending_thumbnails().is_empty(), "Each asked for once");
    c.set_thumbnail(data_id, Thumbnail { width: 1, height: 1, rgba: vec![0; 4] });
    assert!(c.thumbnail(data_id).is_some());
    assert_eq!(c.bytes(data_id), Some([1u8].as_slice()));
    c.remove(data_id);
    assert!(c.thumbnail(data_id).is_none(), "Gone with the item");
    c.set_thumbnail(data_id, Thumbnail { width: 1, height: 1, rgba: vec![0; 4] });
    assert!(c.thumbnail(data_id).is_none(), "A late thumbnail for an item that left is dropped");
}

#[test]
fn choosing_a_clipping_says_copied_for_a_moment() {
    let mut c = controller(on());
    c.keep_clipping("hello", t(0));
    let id = c.clippings().items()[0].id;
    let (text, event) = c.copy(id, t(5)).unwrap();
    assert_eq!((text.as_str(), event), ("hello", ShelfEvent::ClippingCopied));
    assert_eq!(c.just_copied(), Some(id));
    c.tick(t(5) + Duration::milliseconds(1199));
    assert_eq!(c.just_copied(), Some(id), "Still Copied");
    c.tick(t(5) + Duration::milliseconds(1200));
    assert_eq!(c.just_copied(), None, "1.2 seconds");
    assert!(c.copy(ClippingId(999), t(9)).is_none());
}

#[test]
fn the_drop_area_stays_while_kapa_eats_and_only_where_kapa_is_shown() {
    let mut c = controller(on());
    c.swallow(t(0), 1.3, false, false);
    assert!(!c.is_swallowing(t(0)), "Without Kapa there is nothing to watch");
    c.swallow(t(0), 1.3, true, true);
    assert!(!c.is_swallowing(t(0)), "Nor with reduced motion");
    c.swallow(t(0), 1.3, true, false);
    assert!(c.is_swallowing(t(1)) && c.shows_drop_area(t(1)));
    assert!(c.is_swallowing(t(0) + Duration::milliseconds(1449)), "The gulp and a little more");
    assert!(!c.is_swallowing(t(0) + Duration::milliseconds(1450)));
    c.tick(t(2));
    assert_eq!(c.swallowed_at(), None, "Over, and forgotten");
    c.is_drop_targeted = true;
    assert!(c.shows_drop_area(t(3)), "A file carried over it shows it");
}

#[test]
fn the_clipboard_is_watched_only_while_wanted_and_only_what_is_copied_after() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    *board.text.borrow_mut() = Some("was there before".into());
    let mut c = controller(on());
    assert!(c.wants_clipboard());
    assert!(c.poll_clipboard(t(0), &board, &files, None, &names_in()).is_empty(), "The first look only notes the clipboard");
    assert!(c.clippings().items().is_empty(), "What was on it already is left alone");
    assert!(c.poll_clipboard(t(1), &board, &files, None, &names_in()).is_empty(), "Unchanged: nothing");

    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    *board.text.borrow_mut() = Some("copied after".into());
    c.poll_clipboard(t(2), &board, &files, None, &names_in());
    assert_eq!(texts(c.clippings()), strs(&["copied after"]));

    c.set_keeps_text(false);
    c.set_takes_clipboard_images(false);
    assert!(!c.wants_clipboard());
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    c.poll_clipboard(t(3), &board, &files, None, &names_in());
    c.set_keeps_text(true);
    assert!(c.wants_clipboard());
    assert!(c.poll_clipboard(t(4), &board, &files, None, &names_in()).is_empty(), "Switched on again: it begins by noting the clipboard once more");
}

#[test]
fn text_from_a_password_app_or_marked_secret_is_never_read() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let mut c = watching(on(), &board, &files);
    *board.text.borrow_mut() = Some("hunter2".into());
    board.copy("com.apple.Passwords", &[&["public.utf8-plain-text"]]);
    c.poll_clipboard(t(1), &board, &files, None, &names_in());
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]]);
    c.poll_clipboard(t(2), &board, &files, None, &names_in());
    c.set_excluded_applications(vec!["ru.bank.app".into()]);
    board.copy("ru.bank.app", &[&["public.utf8-plain-text"]]);
    c.poll_clipboard(t(3), &board, &files, None, &names_in());
    board.copy("app.capacitynotch.CapacityNotch", &[&["public.utf8-plain-text"]]);
    c.poll_clipboard(t(4), &board, &files, None, &names_in());
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text", ClipboardText::OWN_MARKER]]);
    c.poll_clipboard(t(5), &board, &files, None, &names_in());
    assert!(c.clippings().items().is_empty(), "None of it kept");
    assert_eq!(c.shelf().count(), 0);
}

#[test]
fn a_screenshot_on_the_clipboard_lands_under_screenshots_named_as_macos_names_it() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let mut c = watching(on(), &board, &files);
    board.data.borrow_mut().insert("public.png".into(), vec![0x89, 0x50]);
    board.copy("com.apple.screencaptureui", &[&["public.png"]]);
    let events = c.poll_clipboard(Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 3).unwrap(), &board, &files, None, &names_in());
    assert_eq!(events, vec![ShelfEvent::Took(ShelfTab::Screenshots)]);
    let held = c.items(ShelfTab::Screenshots);
    assert_eq!(held[0].name(), "Screenshot 2026-10-01 at 01.02.03.png");
    assert_eq!(held[0].path(), None, "Held in memory");
}

#[test]
fn an_image_copied_from_a_page_is_kept_as_png_and_a_tiff_is_converted() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let mut c = watching(on(), &board, &files);
    board.data.borrow_mut().insert("public.png".into(), vec![1]);
    board.copy("com.apple.Safari", &[&["public.html", "public.tiff", "public.png"]]);
    c.poll_clipboard(Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 3).unwrap(), &board, &files, Some(&Png), &names_in());
    assert_eq!(c.items(ShelfTab::Screenshots)[0].name(), "Image 2026-10-01 at 01.02.03.png");

    board.data.borrow_mut().insert("public.tiff".into(), vec![9, 9]);
    board.copy("com.apple.Preview", &[&["public.tiff"]]);
    c.poll_clipboard(Utc.with_ymd_and_hms(2026, 10, 1, 1, 2, 4).unwrap(), &board, &files, Some(&Png), &names_in());
    let first = &c.items(ShelfTab::Screenshots)[0];
    assert_eq!(first.name(), "Image 2026-10-01 at 01.02.04.png", "Kept as PNG");
    assert_eq!(c.bytes(first.id), Some(b"PNG:\x09\x09".as_slice()), "Converted");
}

#[test]
fn a_file_copied_in_another_application_is_read_into_memory_or_kept_as_a_reference() {
    const MB: u64 = 1024 * 1024;
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    files.has("/tmp/cache/Договор.docx", 3 * MB, b"docx");
    files.has("/tmp/cache/big.zip", 200 * MB, b"zip");
    files.has("/tmp/cache/photo.JPG", 2 * MB, b"jpg");
    let mut c = watching(on(), &board, &files);

    *board.file.borrow_mut() = Some(PathBuf::from("/tmp/cache/Договор.docx"));
    board.copy("ru.keepcoder.Telegram", &[&["public.file-url"]]);
    assert_eq!(c.poll_clipboard(t(1), &board, &files, None, &names_in()), vec![ShelfEvent::Took(ShelfTab::Files)]);
    assert_eq!(c.items(ShelfTab::Files)[0].path(), None, "Read into memory: the cache may be emptied");
    assert_eq!(c.items(ShelfTab::Files)[0].name(), "Договор.docx");

    *board.file.borrow_mut() = Some(PathBuf::from("/tmp/cache/big.zip"));
    board.copy("ru.keepcoder.Telegram", &[&["public.file-url"]]);
    c.poll_clipboard(t(2), &board, &files, None, &names_in());
    assert_eq!(c.items(ShelfTab::Files)[0].path(), Some(Path::new("/tmp/cache/big.zip")), "Past fifty megabytes, a reference");

    *board.file.borrow_mut() = Some(PathBuf::from("/tmp/cache/photo.JPG"));
    board.copy("ru.keepcoder.Telegram", &[&["public.file-url"]]);
    c.poll_clipboard(t(3), &board, &files, None, &names_in());
    assert_eq!(c.items(ShelfTab::Screenshots)[0].name(), "photo.JPG", "An image file goes under Screenshots");

    let before = c.shelf().count();
    board.copy("com.apple.finder", &[&["public.file-url"]]);
    c.poll_clipboard(t(4), &board, &files, None, &names_in());
    assert_eq!(c.shelf().count(), before, "Copying in Finder is left alone");

    *board.file.borrow_mut() = Some(PathBuf::from("/tmp/cache/gone.pdf"));
    board.copy("ru.keepcoder.Telegram", &[&["public.file-url"]]);
    assert_eq!(
        c.poll_clipboard(t(5), &board, &files, None, &names_in()),
        vec![ShelfEvent::ReadFailed("copied-file-unreadable")],
        "A file named and not there: reported, by reason only"
    );
}

#[test]
fn a_copied_file_that_cannot_be_read_is_reported_by_reason_only() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    files.metas.borrow_mut().insert(PathBuf::from("/tmp/x.pdf"), FileMeta { size: 1, is_directory: false });
    let mut c = watching(on(), &board, &files);
    *board.file.borrow_mut() = Some(PathBuf::from("/tmp/x.pdf"));
    board.copy("ru.keepcoder.Telegram", &[&["public.file-url"]]);
    assert_eq!(c.poll_clipboard(t(1), &board, &files, None, &names_in()), vec![ShelfEvent::ReadFailed("copied-file-unreadable")]);
}

#[test]
fn a_clipboard_the_system_will_not_let_be_read_is_said_in_settings_and_in_diagnostics() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let mut c = watching(on(), &board, &files);
    *board.refused.borrow_mut() = true;
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    assert_eq!(c.poll_clipboard(t(1), &board, &files, None, &names_in()), vec![ShelfEvent::ClipboardRefused]);
    assert!(c.clipboard_refused());
    assert_eq!(c.diagnostics(), vec!["shelf-on-0-files-0-screenshots".to_string(), "shelf-clipboard-refused".to_string()]);
    c.set_takes_clipboard_images(true);
    assert!(!c.clipboard_refused(), "Asking again clears it");

    // Nothing worth taking: not even asked.
    *board.refused.borrow_mut() = true;
    board.copy("com.apple.Safari", &[&["public.rtf"]]);
    assert!(c.poll_clipboard(t(2), &board, &files, None, &names_in()).is_empty());
    assert!(!c.clipboard_refused());

    // Text that was announced but cannot be read.
    *board.refused.borrow_mut() = false;
    *board.text.borrow_mut() = None;
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    assert_eq!(c.poll_clipboard(t(3), &board, &files, None, &names_in()), vec![ShelfEvent::ReadFailed("clipboard-text-unreadable")]);
    assert!(c.clipboard_refused());
}

#[test]
fn images_alone_or_text_alone_each_have_their_own_switch() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let mut only_text = watching(ShelfSettings { enabled: true, keeps_text: true, ..Default::default() }, &board, &files);
    board.data.borrow_mut().insert("public.png".into(), vec![1]);
    board.copy("com.apple.screencaptureui", &[&["public.png"]]);
    only_text.poll_clipboard(t(1), &board, &files, None, &names_in());
    assert_eq!(only_text.shelf().count(), 0, "Text intake on, image intake off: no image");

    let mut only_images = watching(ShelfSettings { enabled: true, takes_clipboard_images: true, ..Default::default() }, &board, &files);
    *board.text.borrow_mut() = Some("t".into());
    board.copy("com.apple.Safari", &[&["public.utf8-plain-text"]]);
    only_images.poll_clipboard(t(1), &board, &files, None, &names_in());
    assert!(only_images.clippings().items().is_empty(), "Image intake on, text off: no text");
}

#[derive(Default)]
struct FakeFolder {
    saves: bool,
    entries: RefCell<Vec<Entry>>,
    refused: RefCell<bool>,
    listed: RefCell<u32>,
}

impl ScreenshotFolderWatcher for FakeFolder {
    fn saves_to_folder(&self) -> bool {
        self.saves
    }
    fn folder(&self) -> PathBuf {
        PathBuf::from("/Users/someone/Desktop")
    }
    fn list(&self, _: &Path) -> FolderListing {
        *self.listed.borrow_mut() += 1;
        if *self.refused.borrow() {
            FolderListing::Refused
        } else {
            FolderListing::Entries(self.entries.borrow().clone())
        }
    }
}

fn mac() -> Naming {
    Naming::MacOs(Settings::default())
}

#[test]
fn the_folder_is_taken_from_only_once_each_and_only_after_the_switch() {
    let files = FakeFiles::default();
    let folder = FakeFolder { saves: true, ..Default::default() };
    folder.entries.borrow_mut().push(entry("/Users/someone/Desktop", "Screenshot 2026-10-02 at 09.00.00.png", -100, true));
    let mut c = controller(on());
    assert!(c.poll_folder(t(0), &folder, mac(), &files).is_empty(), "The first look: what was there before is not taken");
    assert_eq!(*folder.listed.borrow(), 1, "…but the folder was listed, which is what has macOS ask for it");

    folder.entries.borrow_mut().push(entry("/Users/someone/Desktop", "Screenshot 2026-10-02 at 10.00.01.png", 5, true));
    assert_eq!(c.poll_folder(t(6), &folder, mac(), &files), vec![ShelfEvent::Took(ShelfTab::Screenshots)]);
    assert_eq!(names(c.items(ShelfTab::Screenshots)), strs(&["Screenshot 2026-10-02 at 10.00.01.png"]));
    assert!(c.items(ShelfTab::Screenshots)[0].path().is_some(), "A reference to its file, never a copy");
    assert!(c.poll_folder(t(8), &folder, mac(), &files).is_empty(), "Not taken again");
    assert_eq!(c.items(ShelfTab::Screenshots).len(), 1);

    c.set_takes_clipboard_images(false);
    assert!(c.poll_folder(t(10), &folder, mac(), &files).is_empty());
    assert!(!c.wants_folder());
}

#[test]
fn the_folder_is_not_looked_at_while_screenshots_go_elsewhere() {
    let files = FakeFiles::default();
    let folder = FakeFolder { saves: false, ..Default::default() };
    let mut c = controller(on());
    assert!(c.poll_folder(t(0), &folder, mac(), &files).is_empty());
    assert_eq!(*folder.listed.borrow(), 0, "The system is not asked for a folder it would get nothing from");
}

#[test]
fn a_folder_the_system_refuses_is_said_once_and_cleared_when_it_opens() {
    let files = FakeFiles::default();
    let folder = FakeFolder { saves: true, ..Default::default() };
    *folder.refused.borrow_mut() = true;
    let mut c = controller(on());
    assert_eq!(c.poll_folder(t(0), &folder, mac(), &files), vec![ShelfEvent::ScreenshotFolderRefused]);
    assert!(c.poll_folder(t(2), &folder, mac(), &files).is_empty(), "Said once");
    assert!(c.screenshot_folder_refused());
    assert!(c.diagnostics().contains(&"shelf-screenshot-folder-refused".to_string()));
    *folder.refused.borrow_mut() = false;
    c.poll_folder(t(4), &folder, mac(), &files);
    assert!(!c.screenshot_folder_refused());
}

#[test]
fn a_look_begun_before_the_switch_went_off_is_not_taken_as_this_watchs() {
    let files = FakeFiles::default();
    let folder = FakeFolder { saves: true, ..Default::default() };
    let mut c = controller(on());
    let scan = c.begin_folder_scan(t(0), &folder, mac()).expect("a scan");
    assert!(c.begin_folder_scan(t(1), &folder, mac()).is_none(), "One look at a time");
    // Off, and on again, while the listing is being read.
    c.set_takes_clipboard_images(false);
    assert!(c.begin_folder_scan(t(2), &folder, mac()).is_none());
    c.set_takes_clipboard_images(true);
    let fresh = c.begin_folder_scan(t(3), &folder, mac()).expect("a new watch begins");
    let stale = vec![entry("/Users/someone/Desktop", "Screenshot 2026-10-02 at 10.00.01.png", 5, true)];
    assert!(c.finish_folder_scan(scan, FolderListing::Entries(stale.clone()), &files).is_empty(), "The old look is dropped");
    assert_eq!(c.shelf().count(), 0);
    assert_eq!(c.finish_folder_scan(fresh, FolderListing::Entries(stale), &files), vec![ShelfEvent::Took(ShelfTab::Screenshots)]);
}

#[test]
fn the_empty_tab_says_what_lands_in_it_or_how_to_turn_its_intake_on() {
    let off = controller(ShelfSettings { enabled: true, ..Default::default() });
    assert_eq!(off.empty_title(ShelfTab::Files), EmptyTitle::DragFiles);
    assert_eq!(off.empty_detail(ShelfTab::Files), EmptyDetail::FilesLimit);
    assert_eq!(off.empty_detail(ShelfTab::Screenshots), EmptyDetail::TurnOnImages);
    assert_eq!(off.empty_detail(ShelfTab::Clipboard), EmptyDetail::TurnOnText);
    let all = controller(on());
    assert_eq!(all.empty_detail(ShelfTab::Screenshots), EmptyDetail::ScreenshotsLimit);
    assert_eq!(all.empty_detail(ShelfTab::Clipboard), EmptyDetail::ClippingsExpire { limit: 20 });
    let stay = controller(ShelfSettings { clippings_expire: false, clipping_limit: ClippingLimit::Hundred, ..on() });
    assert_eq!(stay.empty_detail(ShelfTab::Clipboard), EmptyDetail::ClippingsStay { limit: 100 });
    assert_eq!(serde_json::to_value(EmptyDetail::ClippingsStay { limit: 100 }).unwrap(), json!({"hint": "clippingsStay", "limit": 100}));
}

#[test]
fn the_view_carries_what_a_surface_draws_and_never_an_images_bytes() {
    let files = FakeFiles::default();
    files.present.borrow_mut().insert(file("a.pdf"));
    let mut c = controller(on());
    c.add(&[file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("Снимок.png", vec![1, 2, 3], ShelfTab::Screenshots);
    c.keep_clipping("secret-ish", t(0));
    c.tab = ShelfTab::Screenshots;
    let view = c.view(t(1));
    let json = serde_json::to_value(&view).unwrap();
    assert_eq!(json["tab"], "screenshots");
    assert_eq!(json["files"][0]["name"], "a.pdf");
    assert_eq!(json["files"][0]["badge"], "PDF");
    assert_eq!(json["files"][0]["kind"], "pdf");
    assert_eq!(json["files"][0]["inMemory"], false);
    assert_eq!(json["screenshots"][0]["inMemory"], true);
    assert_eq!(json["screenshots"][0]["path"], Value::Null);
    assert_eq!(json["tabs"][0]["held"], 1);
    assert_eq!(json["tabs"][2]["held"], 1);
    assert_eq!(json["tabs"][2]["limit"], 20);
    assert_eq!(json["clippings"][0]["text"], "secret-ish");
    assert_eq!(json["clippingLimit"], 20);
    assert!(!json.to_string().contains("[1,2,3]"), "No bytes in the view");
}

#[test]
fn a_dragged_images_file_is_written_when_the_drag_starts_and_goes_with_the_item() {
    let dir = std::env::temp_dir().join(format!("capa-shelf-drag-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let store = std::sync::Arc::new(TempDragFiles::at(dir.clone()));
    let files = FakeFiles::default();
    let mut c = controller(on()).with_drag_files(store.clone());
    c.add(&[file("a.pdf")], ShelfTab::Files, &files);
    c.add_in_memory("shot.png", vec![7, 7, 7], ShelfTab::Screenshots);
    assert!(!dir.exists(), "Nothing is written for an image that is never dragged");
    let id = c.items(ShelfTab::Screenshots)[0].id;
    let written = c.file_to_drag(id).expect("a file");
    assert_eq!(std::fs::read(&written).unwrap(), vec![7, 7, 7]);
    assert!(written.starts_with(&dir) && written.ends_with("shot.png"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700, "Readable by this user alone");
    }
    assert_eq!(c.file_to_drag(id), Some(written.clone()), "The same file again");
    let referred = c.items(ShelfTab::Files)[0].id;
    assert_eq!(c.file_to_drag(referred), Some(file("a.pdf")), "A file the Shelf refers to is dragged as it is");

    c.remove(id);
    assert!(!written.exists(), "It goes when the item leaves the Shelf");
    c.add_in_memory("again.png", vec![8], ShelfTab::Screenshots);
    let again = c.file_to_drag(c.items(ShelfTab::Screenshots)[0].id).unwrap();
    c.set_enabled(false);
    assert!(!again.exists(), "and when the Shelf is switched off");
    store.remove_all();
    assert!(!dir.exists(), "and at quit");
    assert!(store.file_for(ItemId(1), "../escape.png", b"x").is_some_and(|p| p.starts_with(&dir)), "A name is a name, not a path");
    store.remove_all();
}

#[test]
fn a_screenshot_put_on_the_clipboard_and_saved_to_the_folder_lands_once_as_its_file() {
    let board = FakeBoard::default();
    let files = FakeFiles::default();
    let folder = FakeFolder { saves: true, ..Default::default() };
    let mut c = watching(on(), &board, &files);
    assert!(c.poll_folder(t(0), &folder, mac(), &files).is_empty());
    // An older one, also from the clipboard, stays as it is.
    board.data.borrow_mut().insert("public.png".into(), vec![1, 2, 3]);
    board.copy("com.apple.screencaptureui", &[&["public.png"]]);
    c.poll_clipboard(t(1), &board, &files, None, &names_in());
    board.data.borrow_mut().insert("public.png".into(), vec![0x89, 0x50, 0x4E]);
    board.copy("com.apple.screencaptureui", &[&["public.png"]]);
    c.poll_clipboard(t(5), &board, &files, None, &names_in());
    let id = c.items(ShelfTab::Screenshots)[0].id;
    assert_eq!(c.items(ShelfTab::Screenshots).len(), 2);

    let path = "/Users/someone/Desktop/Screenshot 2026-10-02 at 10.00.01.png";
    files.has(path, 3, &[0x89, 0x50, 0x4E]);
    folder.entries.borrow_mut().push(entry("/Users/someone/Desktop", "Screenshot 2026-10-02 at 10.00.01.png", 5, true));
    assert!(c.poll_folder(t(6), &folder, mac(), &files).is_empty(), "Nothing new landed");
    let held = c.items(ShelfTab::Screenshots);
    assert_eq!(held.len(), 2, "Once, not twice");
    assert_eq!(held[0].id, id, "Where it stood, as itself");
    assert_eq!(held[0].path(), Some(Path::new(path)), "Its file behind it now");
    assert_eq!(held[1].path(), None);

    // Long after, the same bytes saved again are a screenshot of their own.
    board.data.borrow_mut().insert("public.png".into(), vec![7, 7]);
    board.copy("com.apple.screencaptureui", &[&["public.png"]]);
    c.poll_clipboard(t(10), &board, &files, None, &names_in());
    let later = "/Users/someone/Desktop/Screenshot 2026-10-02 at 10.01.00.png";
    files.has(later, 2, &[7, 7]);
    folder.entries.borrow_mut().push(entry("/Users/someone/Desktop", "Screenshot 2026-10-02 at 10.01.00.png", 60, true));
    assert_eq!(c.poll_folder(t(60), &folder, mac(), &files), vec![ShelfEvent::Took(ShelfTab::Screenshots)]);
    assert_eq!(c.items(ShelfTab::Screenshots).len(), 4);
}

#[test]
fn copies_made_in_capathenotchs_own_windows_are_never_kept() {
    let excluded = BTreeSet::new();
    let rules = ClipboardRules::linux();
    let types = vec![strs(&["public.utf8-plain-text"])];
    assert!(!ClipboardText::is_kept(&types, Some("tech.capathenotch.Settings"), &excluded, Some("tech.capathenotch."), &rules));
    assert!(!ClipboardText::is_kept(&types, Some("tech.capathenotch.Settings"), &excluded, Some("tech.capathenotch.Settings"), &rules));
    assert!(ClipboardText::is_kept(&types, Some("tech.capathenotcher"), &excluded, Some("tech.capathenotch."), &rules));
    assert!(ClipboardText::is_kept(&types, Some("org.gnome.Terminal"), &excluded, Some("tech.capathenotch."), &rules));
}
