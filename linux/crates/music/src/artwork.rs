//! Covers. A player gives a cover as a URL (a file, or an address) to an
//! image of any size and kind; the page wants a small square it can draw.
//! Covers are decoded once, kept (a few) as PNG under an id, and the state
//! carries only the id: a cover is hundreds of kilobytes and the state goes out
//! every time anything changes.

use image::imageops::FilterType;
use image::{DynamicImage, GenericImageView, ImageFormat};
use std::collections::VecDeque;
use std::io::Cursor;
use std::path::Path;
use std::sync::Mutex;

/// The page's artwork is 146 points; this is for a 2× display.
pub const SIZE: u32 = 292;
const KEEP: usize = 8;
const LARGEST_DOWNLOAD: u64 = 8 * 1024 * 1024;
/// An SVG icon is drawn this many pixels on a side, then kept as a PNG.
pub const ICON_SVG_SIZE: u32 = 256;
const LARGEST_ICON: u64 = 4 * 1024 * 1024;

#[derive(Default)]
pub struct ArtworkStore {
    entries: Mutex<VecDeque<(String, Vec<u8>)>>,
    /// Players' icons, kept apart so a run of covers does not push them out.
    icons: Mutex<VecDeque<(String, Vec<u8>)>>,
}

fn keep(entries: &Mutex<VecDeque<(String, Vec<u8>)>>, id: &str, png: Vec<u8>) {
    let mut entries = entries.lock().unwrap();
    entries.retain(|(known, _)| known != id);
    entries.push_back((id.to_owned(), png));
    while entries.len() > KEEP {
        entries.pop_front();
    }
}

fn find(entries: &Mutex<VecDeque<(String, Vec<u8>)>>, id: &str) -> Option<Vec<u8>> {
    entries.lock().unwrap().iter().find(|(known, _)| known == id).map(|(_, png)| png.clone())
}

impl ArtworkStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Decodes `raw` (any image the `image` crate reads), crops it to the
    /// middle square, scales it, keeps it as PNG and returns its id. `None`
    /// for something that is not an image.
    pub fn put(&self, raw: &[u8]) -> Option<String> {
        let id = id_of(raw);
        if self.get(&id).is_some() {
            return Some(id);
        }
        let png = square_png(raw)?;
        keep(&self.entries, &id, png);
        Some(id)
    }

    /// A player's icon, kept as a cover is but apart from the covers.
    pub fn put_icon(&self, raw: &[u8]) -> Option<String> {
        let id = id_of(raw);
        if find(&self.icons, &id).is_some() {
            return Some(id);
        }
        let png = square_png(raw)?;
        keep(&self.icons, &id, png);
        Some(id)
    }

    pub fn get(&self, id: &str) -> Option<Vec<u8>> {
        find(&self.entries, id).or_else(|| find(&self.icons, id))
    }
}

/// FNV-1a over the bytes: an id, not a secret.
pub fn id_of(raw: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in raw {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn square_png(raw: &[u8]) -> Option<Vec<u8>> {
    let image = image::load_from_memory(raw).ok()?;
    let (w, h) = image.dimensions();
    if w == 0 || h == 0 {
        return None;
    }
    let side = w.min(h);
    let cropped = image.crop_imm((w - side) / 2, (h - side) / 2, side, side);
    let scaled = DynamicImage::ImageRgba8(cropped.to_rgba8()).resize_exact(SIZE.min(side.max(1)), SIZE.min(side.max(1)), FilterType::Triangle);
    let mut out = Cursor::new(Vec::new());
    scaled.write_to(&mut out, ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// An application's icon as bytes `put_icon` takes: a PNG as it is, an SVG
/// drawn `ICON_SVG_SIZE` pixels on a side (by gdk-pixbuf; `None` where it is
/// not installed). Blocking: call it off the async threads.
pub fn icon_png(path: &Path) -> Option<Vec<u8>> {
    if std::fs::metadata(path).ok()?.len() > LARGEST_ICON {
        return None;
    }
    if !path.extension().is_some_and(|e| e.eq_ignore_ascii_case("svg")) {
        return std::fs::read(path).ok();
    }
    let image = pixbuf::load_at_size(path, ICON_SVG_SIZE)?;
    let mut out = Cursor::new(Vec::new());
    image.write_to(&mut out, ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// gdk-pixbuf, opened the first time it is wanted rather than linked: it
/// draws SVG (with librsvg or glycin) where it is installed, and nothing
/// fails where it is not.
mod pixbuf {
    use libloading::Library;
    use std::ffi::{c_char, c_int, c_void, CString};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;
    use std::sync::OnceLock;

    type Object = *mut c_void;
    type Error = *mut c_void;
    type Int = unsafe extern "C" fn(Object) -> c_int;

    struct Api {
        new_from_file_at_size: unsafe extern "C" fn(*const c_char, c_int, c_int, *mut Error) -> Object,
        width: Int,
        height: Int,
        rowstride: Int,
        n_channels: Int,
        bits_per_sample: Int,
        read_pixels: unsafe extern "C" fn(Object) -> *const u8,
        unref: unsafe extern "C" fn(Object),
        error_free: unsafe extern "C" fn(Error),
        _library: Library,
    }

    fn api() -> Option<&'static Api> {
        static API: OnceLock<Option<Api>> = OnceLock::new();
        API.get_or_init(open).as_ref()
    }

    fn open() -> Option<Api> {
        // SAFETY: loading the system's gdk-pixbuf runs only its (and GLib's) initialisers.
        let library = unsafe { Library::new("libgdk_pixbuf-2.0.so.0") }.ok()?;
        macro_rules! symbol {
            ($name:literal) => {
                // SAFETY: the signature is the header's for this symbol; GObject's and
                // GLib's are found through gdk-pixbuf's own dependencies.
                *unsafe { library.get($name) }.ok()?
            };
        }
        let new_from_file_at_size = symbol!(b"gdk_pixbuf_new_from_file_at_size\0");
        let width = symbol!(b"gdk_pixbuf_get_width\0");
        let height = symbol!(b"gdk_pixbuf_get_height\0");
        let rowstride = symbol!(b"gdk_pixbuf_get_rowstride\0");
        let n_channels = symbol!(b"gdk_pixbuf_get_n_channels\0");
        let bits_per_sample = symbol!(b"gdk_pixbuf_get_bits_per_sample\0");
        let read_pixels = symbol!(b"gdk_pixbuf_read_pixels\0");
        let unref = symbol!(b"g_object_unref\0");
        let error_free = symbol!(b"g_error_free\0");
        Some(Api { new_from_file_at_size, width, height, rowstride, n_channels, bits_per_sample, read_pixels, unref, error_free, _library: library })
    }

    /// The picture at `path`, scaled to fit `size` × `size` pixels.
    pub fn load_at_size(path: &Path, size: u32) -> Option<image::RgbaImage> {
        let api = api()?;
        let path = CString::new(path.as_os_str().as_bytes()).ok()?;
        let side = c_int::try_from(size).ok()?;
        let mut error: Error = std::ptr::null_mut();
        // SAFETY: a valid C string and an empty error slot; the pixbuf returned is ours to unref.
        let pixbuf = unsafe { (api.new_from_file_at_size)(path.as_ptr(), side, side, &mut error) };
        if !error.is_null() {
            // SAFETY: the error was set for us to free.
            unsafe { (api.error_free)(error) };
        }
        if pixbuf.is_null() {
            return None;
        }
        // SAFETY: a live pixbuf, released once read.
        let image = unsafe { rgba(api, pixbuf) };
        unsafe { (api.unref)(pixbuf) };
        image
    }

    /// A pixbuf's pixels as straight RGBA.
    ///
    /// # Safety
    /// `pixbuf` is a live `GdkPixbuf`.
    unsafe fn rgba(api: &Api, pixbuf: Object) -> Option<image::RgbaImage> {
        let (width, height) = (usize::try_from((api.width)(pixbuf)).ok()?, usize::try_from((api.height)(pixbuf)).ok()?);
        let (stride, channels) = (usize::try_from((api.rowstride)(pixbuf)).ok()?, usize::try_from((api.n_channels)(pixbuf)).ok()?);
        let pixels = (api.read_pixels)(pixbuf);
        if width == 0 || height == 0 || pixels.is_null() || (api.bits_per_sample)(pixbuf) != 8 || !(channels == 3 || channels == 4) {
            return None;
        }
        let mut out = Vec::with_capacity(width * height * 4);
        for y in 0..height {
            // The last row may stop short of the stride; never short of its pixels.
            let row = std::slice::from_raw_parts(pixels.add(y * stride), width * channels);
            for px in row.chunks_exact(channels) {
                out.extend_from_slice(&[px[0], px[1], px[2], if channels == 4 { px[3] } else { 255 }]);
            }
        }
        image::RgbaImage::from_raw(width as u32, height as u32, out)
    }
}

/// What `mpris:artUrl` points at: a `file://` path, or an `http(s)` address.
/// Blocking: call it off the async threads.
pub fn fetch(url: &str) -> Option<Vec<u8>> {
    if let Some(path) = url.strip_prefix("file://") {
        let path = percent_decode(path);
        let meta = std::fs::metadata(&path).ok()?;
        if meta.len() > LARGEST_DOWNLOAD {
            return None;
        }
        return std::fs::read(path).ok();
    }
    if url.starts_with("http://") || url.starts_with("https://") {
        use std::io::Read;
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(std::time::Duration::from_secs(8)))
            .build()
            .into();
        let mut response = agent.get(url).call().ok()?;
        let mut body = Vec::new();
        response.body_mut().as_reader().take(LARGEST_DOWNLOAD).read_to_end(&mut body).ok()?;
        return Some(body);
    }
    None
}

pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Base64, for a surface that has no other way to take bytes.
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let image = image::RgbaImage::from_fn(w, h, |x, _| image::Rgba([(x % 256) as u8, 40, 90, 255]));
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(image).write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn a_cover_becomes_a_small_square_png_kept_under_an_id() {
        let store = ArtworkStore::new();
        let id = store.put(&png(600, 400)).expect("an image");
        let kept = store.get(&id).unwrap();
        let back = image::load_from_memory(&kept).unwrap();
        assert_eq!(back.dimensions(), (SIZE, SIZE), "cropped to the middle square, scaled");
        assert_eq!(store.put(&png(600, 400)).unwrap(), id, "the same cover is the same id");
    }

    #[test]
    fn a_small_cover_is_not_blown_up() {
        let store = ArtworkStore::new();
        let id = store.put(&png(64, 64)).unwrap();
        assert_eq!(image::load_from_memory(&store.get(&id).unwrap()).unwrap().dimensions(), (64, 64));
    }

    #[test]
    fn something_that_is_not_an_image_is_not_kept() {
        assert_eq!(ArtworkStore::new().put(b"not an image"), None);
    }

    #[test]
    fn only_a_few_covers_are_kept() {
        let store = ArtworkStore::new();
        let ids: Vec<_> = (0..12).map(|i| store.put(&png(32 + i, 32 + i)).unwrap()).collect();
        assert!(store.get(&ids[0]).is_none() && store.get(&ids[11]).is_some());
    }

    #[test]
    fn icons_are_not_pushed_out_by_covers() {
        let store = ArtworkStore::new();
        let icon = store.put_icon(&png(16, 16)).unwrap();
        for i in 0..12 {
            store.put(&png(32 + i, 32 + i)).unwrap();
        }
        assert!(store.get(&icon).is_some());
    }

    #[test]
    fn file_urls_are_read_and_percent_decoded() {
        let dir = std::env::temp_dir().join(format!("capa-art-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a cover.png");
        std::fs::write(&path, png(8, 8)).unwrap();
        let url = format!("file://{}", path.to_string_lossy().replace(' ', "%20"));
        assert_eq!(fetch(&url).unwrap(), png(8, 8));
        assert_eq!(fetch("file:///nonexistent/x.png"), None);
        assert_eq!(fetch("data:image/png;base64,AAAA"), None, "only files and addresses");
    }

    #[test]
    fn an_svg_icon_is_drawn_at_256_pixels_and_a_png_is_kept_as_it_is() {
        let dir = std::env::temp_dir().join(format!("capa-icon-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let png_path = dir.join("player.png");
        std::fs::write(&png_path, png(8, 8)).unwrap();
        assert_eq!(icon_png(&png_path).unwrap(), png(8, 8));
        assert_eq!(icon_png(&dir.join("absent.svg")), None);

        let svg_path = dir.join("player.svg");
        std::fs::write(&svg_path, r##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#ff0000"/></svg>"##).unwrap();
        // Nothing draws SVG here (no gdk-pixbuf, or one without an SVG loader): the icon is
        // left out, as before.
        let Some(drawn) = icon_png(&svg_path) else {
            return;
        };
        let image = image::load_from_memory(&drawn).unwrap().to_rgba8();
        assert_eq!(image.dimensions(), (ICON_SVG_SIZE, ICON_SVG_SIZE));
        assert_eq!(image.get_pixel(128, 128).0, [255, 0, 0, 255]);
        let store = ArtworkStore::new();
        let id = store.put_icon(&drawn).unwrap();
        assert_eq!(image::load_from_memory(&store.get(&id).unwrap()).unwrap().dimensions(), (ICON_SVG_SIZE, ICON_SVG_SIZE));
        std::fs::write(&svg_path, b"not an svg").unwrap();
        assert_eq!(icon_png(&svg_path), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn base64_is_standard() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
    }
}
