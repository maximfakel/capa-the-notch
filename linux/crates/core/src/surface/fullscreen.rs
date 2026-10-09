use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A rectangle in global display coordinates, origin at the top left of the
/// main display, y running down.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn min_x(&self) -> f64 { self.x }
    pub fn min_y(&self) -> f64 { self.y }
    pub fn max_x(&self) -> f64 { self.x + self.width }
    pub fn max_y(&self) -> f64 { self.y + self.height }

    pub fn offset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width, self.height)
    }

    /// Whether the two overlap by more than an edge, as `CGRect.intersects`.
    pub fn intersects(&self, other: &Rect) -> bool {
        self.min_x() < other.max_x() && other.min_x() < self.max_x() && self.min_y() < other.max_y() && other.min_y() < self.max_y()
    }
}

/// One on-screen window as a window list describes it without screen-capture
/// permission: its level, its owner, and its bounds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScreenWindow {
    pub level: i64,
    pub owner: String,
    pub bounds: Rect,
}

impl ScreenWindow {
    pub fn new(level: i64, owner: impl Into<String>, bounds: Rect) -> Self {
        Self { level, owner: owner.into(), bounds }
    }
}

/// What a platform supplies: the windows it can see, and the level its
/// desktop icons stand at. Nothing else about the screen is asked of it.
pub trait FullscreenQuery {
    fn windows(&self) -> Vec<ScreenWindow>;
    fn desktop_icon_level(&self) -> i64;
}

/// Whether the display the surface sits on is showing a fullscreen
/// application.
///
/// Measured on macOS 26.6, not assumed. A fullscreen window spans the
/// display's width and reaches its bottom edge, starting at the top or just
/// under the camera housing — alone, or stacked with its application's other
/// windows — which a zoomed window can also do. What a zoomed window cannot do
/// is take the desktop away: a fullscreen Space has no wallpaper and no
/// desktop icons, while every ordinary Space has at least one of them. The
/// Dock and the Window Server keep windows at desktop levels in both, so they
/// do not count; on macOS 27 WindowManager holds what the Dock held.
pub struct FullscreenDetection;

const KEEPERS_OF_DESKTOP_LEVELS: [&str; 3] = ["Dock", "WindowManager", "Window Server"];

impl FullscreenDetection {
    pub fn is_fullscreen(windows: &[ScreenWindow], screen: Rect, menu_bar_height: f64, desktop_icon_level: i64) -> bool {
        let on_screen: Vec<&ScreenWindow> = windows.iter().filter(|w| w.bounds.intersects(&screen)).collect();

        // One application's full-width windows, stacked, reaching from the
        // top to the bottom. Chrome is not one window when fullscreen: its
        // tab strip, its toolbar and the page are separate windows one under
        // another, and none of them spans the display on its own. Only the
        // width is asked, not where the window stands: changing Space slides
        // every window sideways, easing the last few points over half a
        // second (measured on macOS 27.0), and a fullscreen window mid-slide
        // is still fullscreen.
        let mut spanning: BTreeMap<&str, Vec<&ScreenWindow>> = BTreeMap::new();
        for window in on_screen.iter().filter(|w| w.level == 0 && w.bounds.width >= screen.width) {
            spanning.entry(window.owner.as_str()).or_default().push(window);
        }
        let covered = spanning.values().any(|windows| {
            let mut reached = screen.min_y() + menu_bar_height + 1.0;
            let mut stacked = windows.clone();
            stacked.sort_by(|a, b| a.bounds.min_y().total_cmp(&b.bounds.min_y()));
            for window in stacked {
                if window.bounds.min_y() > reached {
                    break;
                }
                reached = reached.max(window.bounds.max_y());
            }
            reached >= screen.max_y()
        });
        if !covered {
            return false;
        }

        // The wallpaper and the icons slide with their Space too, and stand at
        // the display's origin only once it has settled; one sliding away is a
        // desktop being left, not one showing.
        let desktop_shows = on_screen.iter().any(|w| {
            w.level <= desktop_icon_level
                && !KEEPERS_OF_DESKTOP_LEVELS.contains(&w.owner.as_str())
                && w.bounds.x == screen.x
                && w.bounds.y == screen.y
        });
        !desktop_shows
    }

    /// The same, asking a platform for the windows.
    pub fn query(source: &dyn FullscreenQuery, screen: Rect, menu_bar_height: f64) -> bool {
        Self::is_fullscreen(&source.windows(), screen, menu_bar_height, source.desktop_icon_level())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The windows below were read off a 2056 × 1329 display with a 38-point
    // camera housing: a test window taken fullscreen, then back.
    const ICON_LEVEL: i64 = -2_147_483_603;

    fn display() -> Rect {
        Rect::new(0.0, 0.0, 2056.0, 1329.0)
    }

    fn w(level: i64, owner: &str, x: f64, y: f64, width: f64, height: f64) -> ScreenWindow {
        ScreenWindow::new(level, owner, Rect::new(x, y, width, height))
    }

    fn menu_bar() -> Vec<ScreenWindow> {
        vec![
            w(24, "Window Server", 0.0, 0.0, 2056.0, 39.0),
            ScreenWindow::new(-2_147_483_624, "Dock", display()),
            ScreenWindow::new(-2_147_483_626, "Window Server", display()),
        ]
    }

    fn desktop() -> Vec<ScreenWindow> {
        vec![
            ScreenWindow::new(-2_147_483_603, "Finder", display()),
            ScreenWindow::new(-2_147_483_625, "Обои", display()),
        ]
    }

    fn cat(parts: &[&[ScreenWindow]]) -> Vec<ScreenWindow> {
        parts.iter().flat_map(|p| p.iter().cloned()).collect()
    }

    fn verdict(windows: &[ScreenWindow]) -> bool {
        FullscreenDetection::is_fullscreen(windows, display(), 38.0, ICON_LEVEL)
    }

    #[test]
    fn a_fullscreen_application_is_told_apart_from_a_zoomed_window() {
        let fullscreen = cat(&[&menu_bar(), &[w(0, "Safari", 0.0, 39.0, 2056.0, 1290.0), ScreenWindow::new(-2_147_483_622, "Dock", display())]]);
        assert!(verdict(&fullscreen), "A window spanning the display under the camera, with no desktop behind it, is fullscreen");

        let zoomed = cat(&[&menu_bar(), &desktop(), &[w(0, "Safari", 0.0, 39.0, 2056.0, 1290.0)]]);
        assert!(!verdict(&zoomed), "The same window over the wallpaper is only zoomed");

        let ordinary = cat(&[&menu_bar(), &desktop(), &[w(0, "Telegram", 1427.0, 70.0, 509.0, 1053.0)]]);
        assert!(!verdict(&ordinary), "An ordinary Space is not fullscreen");

        // Chrome, fullscreen: the tab strip, the toolbar and the page are
        // separate windows, moved to the display's origin. None of them spans
        // the display alone.
        let chrome = cat(&[&menu_bar(), &[
            w(0, "Google Chrome", 0.0, 39.0, 2056.0, 41.0),
            w(0, "Google Chrome", 0.0, 80.0, 2056.0, 81.0),
            w(0, "Google Chrome", 0.0, 39.0, 2056.0, 158.0),
            w(0, "Google Chrome", 0.0, 161.0, 2056.0, 1168.0),
            ScreenWindow::new(-2_147_483_622, "Dock", display()),
        ]]);
        assert!(verdict(&chrome), "Chrome's stacked windows together span the display, so Chrome is fullscreen");

        let apart = cat(&[&menu_bar(), &[w(0, "Google Chrome", 0.0, 39.0, 2056.0, 41.0), w(0, "Google Chrome", 0.0, 400.0, 2056.0, 929.0)]]);
        assert!(!verdict(&apart), "Windows with a gap between them do not span the display");

        let elsewhere = Rect::new(2056.0, 0.0, 1920.0, 1080.0);
        assert!(!FullscreenDetection::is_fullscreen(&fullscreen, elsewhere, 24.0, ICON_LEVEL), "A fullscreen application on another display leaves this one alone");
    }

    // Read off a Mac on macOS 27.0: the desktop-level windows the Dock held on
    // 26.6 now belong to WindowManager, in fullscreen Spaces and ordinary ones.
    #[test]
    fn on_macos_27_window_manager_holds_what_the_dock_held() {
        let base = vec![
            w(24, "Window Server", 0.0, 0.0, 2056.0, 39.0),
            ScreenWindow::new(-2_147_483_624, "WindowManager", display()),
            ScreenWindow::new(-2_147_483_626, "Window Server", display()),
        ];
        let chrome = cat(&[&base, &[
            w(0, "Google Chrome", 0.0, 39.0, 2056.0, 41.0),
            w(0, "Google Chrome", 0.0, 80.0, 2056.0, 81.0),
            w(0, "Google Chrome", 0.0, 39.0, 2056.0, 158.0),
            w(0, "Google Chrome", 0.0, 161.0, 2056.0, 1168.0),
            ScreenWindow::new(-2_147_483_622, "WindowManager", display()),
        ]]);
        assert!(verdict(&chrome), "Fullscreen Chrome on macOS 27 is fullscreen");

        let figma = cat(&[&base, &[w(0, "Figma Beta", 0.0, 39.0, 2056.0, 32.0), w(0, "Figma Beta", 0.0, 39.0, 2056.0, 1290.0), ScreenWindow::new(-2_147_483_622, "WindowManager", display())]]);
        assert!(verdict(&figma), "Fullscreen Figma on macOS 27 is fullscreen");

        let zoomed = cat(&[&base, &desktop(), &[w(0, "Figma Beta", 0.0, 39.0, 2056.0, 1290.0)]]);
        assert!(!verdict(&zoomed), "A spanning window over the wallpaper on macOS 27 is only zoomed");
    }

    // Read off a Mac on macOS 27.0 at 20 Hz: changing Space slides the windows
    // sideways, and the slide eases out over half a second, a point or two at a
    // time. The desktop leaves the window list partway through.
    fn figma_at(x: f64) -> Vec<ScreenWindow> {
        vec![w(0, "Figma Beta", x, 39.0, 2056.0, 32.0), w(0, "Figma Beta", x, 39.0, 2056.0, 1290.0)]
    }

    fn chrome_at(x: f64) -> Vec<ScreenWindow> {
        vec![
            w(0, "Google Chrome", x, 39.0, 2056.0, 41.0),
            w(0, "Google Chrome", x, 80.0, 2056.0, 81.0),
            w(0, "Google Chrome", x, 39.0, 2056.0, 158.0),
            w(0, "Google Chrome", x, 161.0, 2056.0, 1168.0),
        ]
    }

    fn fullscreen_space() -> Vec<ScreenWindow> {
        vec![
            w(24, "Window Server", 0.0, 0.0, 2056.0, 39.0),
            ScreenWindow::new(-2_147_483_624, "WindowManager", display()),
            ScreenWindow::new(-2_147_483_622, "WindowManager", display()),
            ScreenWindow::new(-2_147_483_626, "Window Server", display()),
        ]
    }

    fn verdicts(frames: &[Vec<ScreenWindow>]) -> Vec<bool> {
        frames.iter().map(|f| verdict(f)).collect()
    }

    #[test]
    fn a_slide_between_fullscreen_spaces_stays_fullscreen() {
        let mut frames: Vec<_> = [2033.0, 1442.0, 989.0, 623.0, 390.0, 163.0, 102.0]
            .iter()
            .map(|x| cat(&[&fullscreen_space(), &chrome_at(x - 2120.0), &figma_at(*x)]))
            .collect();
        frames.extend([64.0, 43.0, 27.0, 17.0, 10.0, 7.0, 4.0, 3.0, 2.0, 1.0, 0.0].iter().map(|x| cat(&[&fullscreen_space(), &figma_at(*x)])));
        let seen = verdicts(&frames);
        assert!(!seen.contains(&false), "From fullscreen Chrome to fullscreen Figma, every frame is fullscreen: {seen:?}");
    }

    // The desktop slides too: the wallpaper and the icons leave with the Space
    // they belong to, and stand at the display's origin only once it has settled.
    fn desktop_at(x: f64) -> Vec<ScreenWindow> {
        vec![
            ScreenWindow::new(-2_147_483_603, "Finder", display().offset_by(x, 0.0)),
            ScreenWindow::new(-2_147_483_625, "Обои", display().offset_by(x, 0.0)),
        ]
    }

    fn finder_window(x: f64) -> ScreenWindow {
        w(0, "Finder", x, 270.0, 1099.0, 711.0)
    }

    #[test]
    fn entering_fullscreen_is_told_from_the_first_frame() {
        // Desktop to fullscreen Chrome, frame by frame.
        let mut frames: Vec<_> = [(1898.0, -222.0, 589.0), (1339.0, -781.0, 30.0), (856.0, -1264.0, -453.0), (538.0, -1582.0, -771.0), (210.0, -1910.0, -1300.0), (82.0, -2038.0, -1300.0)]
            .iter()
            .map(|(chrome_x, desktop_x, finder_x)| cat(&[&fullscreen_space(), &desktop_at(*desktop_x), &chrome_at(*chrome_x), &[finder_window(*finder_x)]]))
            .collect();
        frames.extend([55.0, 13.0, 2.0, 0.0].iter().map(|x| cat(&[&fullscreen_space(), &chrome_at(*x)])));
        let seen = verdicts(&frames);
        assert!(!seen.contains(&false), "From the first frame of the slide, Chrome arriving is fullscreen: {seen:?}");
    }

    #[test]
    fn leaving_fullscreen_is_told_once_the_application_has_gone() {
        // Fullscreen Chrome back to the desktop.
        let while_chrome_shows = verdicts(
            &[(278.0, -1842.0), (1261.0, -859.0), (1979.0, -141.0)]
                .iter()
                .map(|(chrome_x, desktop_x)| cat(&[&fullscreen_space(), &desktop_at(*desktop_x), &chrome_at(*chrome_x), &[finder_window(desktop_x + 811.0)]]))
                .collect::<Vec<_>>(),
        );
        assert!(!while_chrome_shows.contains(&false), "While Chrome is still sliding out, it is still fullscreen: {while_chrome_shows:?}");

        let once = verdicts(&[-55.0, -13.0, -1.0, 0.0].iter().map(|x| cat(&[&fullscreen_space(), &desktop_at(*x), &[finder_window(x + 811.0)]])).collect::<Vec<_>>());
        assert!(!once.contains(&true), "Once Chrome has gone, it is not fullscreen: {once:?}");
    }

    #[test]
    fn a_zoomed_window_over_a_settled_desktop_is_not_fullscreen() {
        let zoomed = cat(&[&fullscreen_space(), &desktop_at(0.0), &chrome_at(0.0)]);
        assert!(!verdict(&zoomed), "Chrome's windows over a desktop at rest are only zoomed");
    }

    #[test]
    fn rectangles_that_only_touch_do_not_intersect() {
        let a = Rect::new(0.0, 0.0, 10.0, 10.0);
        assert!(a.intersects(&Rect::new(5.0, 5.0, 10.0, 10.0)));
        assert!(!a.intersects(&Rect::new(10.0, 0.0, 10.0, 10.0)), "sharing an edge is not overlapping");
        assert!(!a.intersects(&Rect::new(0.0, 11.0, 10.0, 10.0)));
    }

    struct Fixed(Vec<ScreenWindow>);

    impl FullscreenQuery for Fixed {
        fn windows(&self) -> Vec<ScreenWindow> { self.0.clone() }
        fn desktop_icon_level(&self) -> i64 { ICON_LEVEL }
    }

    #[test]
    fn a_platform_answers_through_the_trait() {
        let fullscreen = Fixed(cat(&[&menu_bar(), &[w(0, "Safari", 0.0, 39.0, 2056.0, 1290.0)]]));
        assert!(FullscreenDetection::query(&fullscreen, display(), 38.0));
        let zoomed = Fixed(cat(&[&menu_bar(), &desktop(), &[w(0, "Safari", 0.0, 39.0, 2056.0, 1290.0)]]));
        assert!(!FullscreenDetection::query(&zoomed, display(), 38.0));
    }
}
