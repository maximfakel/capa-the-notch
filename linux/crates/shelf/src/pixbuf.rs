//! gdk-pixbuf, opened the first time it is wanted rather than linked: where it
//! is installed it reads what the `image` crate does not (HEIC and HEIF,
//! through glycin's or libheif's loader), and where it is not, nothing fails —
//! the tile shows no picture, as before.

use libloading::Library;
use std::ffi::{c_char, c_int, c_void, CString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::OnceLock;

type Object = *mut c_void;
type Error = *mut c_void;
type Int = unsafe extern "C" fn(Object) -> c_int;
type Errored = unsafe extern "C" fn(Object, *mut Error) -> c_int;

struct Api {
    new_from_file: unsafe extern "C" fn(*const c_char, *mut Error) -> Object,
    loader_new: unsafe extern "C" fn() -> Object,
    loader_write: unsafe extern "C" fn(Object, *const u8, usize, *mut Error) -> c_int,
    loader_close: Errored,
    loader_get_pixbuf: unsafe extern "C" fn(Object) -> Object,
    apply_embedded_orientation: unsafe extern "C" fn(Object) -> Object,
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
    let new_from_file = symbol!(b"gdk_pixbuf_new_from_file\0");
    let loader_new = symbol!(b"gdk_pixbuf_loader_new\0");
    let loader_write = symbol!(b"gdk_pixbuf_loader_write\0");
    let loader_close = symbol!(b"gdk_pixbuf_loader_close\0");
    let loader_get_pixbuf = symbol!(b"gdk_pixbuf_loader_get_pixbuf\0");
    let apply_embedded_orientation = symbol!(b"gdk_pixbuf_apply_embedded_orientation\0");
    let width = symbol!(b"gdk_pixbuf_get_width\0");
    let height = symbol!(b"gdk_pixbuf_get_height\0");
    let rowstride = symbol!(b"gdk_pixbuf_get_rowstride\0");
    let n_channels = symbol!(b"gdk_pixbuf_get_n_channels\0");
    let bits_per_sample = symbol!(b"gdk_pixbuf_get_bits_per_sample\0");
    let read_pixels = symbol!(b"gdk_pixbuf_read_pixels\0");
    let unref = symbol!(b"g_object_unref\0");
    let error_free = symbol!(b"g_error_free\0");
    Some(Api {
        new_from_file,
        loader_new,
        loader_write,
        loader_close,
        loader_get_pixbuf,
        apply_embedded_orientation,
        width,
        height,
        rowstride,
        n_channels,
        bits_per_sample,
        read_pixels,
        unref,
        error_free,
        _library: library,
    })
}

/// Frees an error a call set, if it set one.
fn clear(api: &Api, error: &mut Error) {
    if !error.is_null() {
        // SAFETY: the error was set for us to free.
        unsafe { (api.error_free)(*error) };
        *error = std::ptr::null_mut();
    }
}

/// The picture in the file at `path`, turned upright.
pub fn load_file(path: &Path) -> Option<image::DynamicImage> {
    let api = api()?;
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut error: Error = std::ptr::null_mut();
    // SAFETY: a valid C string and an empty error slot; the pixbuf returned is ours.
    let pixbuf = unsafe { (api.new_from_file)(path.as_ptr(), &mut error) };
    clear(api, &mut error);
    // SAFETY: ours, or null.
    unsafe { upright(api, pixbuf) }
}

/// The picture in `data`, turned upright.
pub fn load_data(data: &[u8]) -> Option<image::DynamicImage> {
    let api = api()?;
    let mut error: Error = std::ptr::null_mut();
    // SAFETY: a new loader, fed `data` and closed; the pixbuf it holds is
    // borrowed, so read before the loader is released.
    unsafe {
        let loader = (api.loader_new)();
        if loader.is_null() {
            return None;
        }
        let written = (api.loader_write)(loader, data.as_ptr(), data.len(), &mut error) != 0;
        clear(api, &mut error);
        let closed = (api.loader_close)(loader, &mut error) != 0;
        clear(api, &mut error);
        let pixbuf = if written && closed { (api.loader_get_pixbuf)(loader) } else { std::ptr::null_mut() };
        let image = if pixbuf.is_null() { None } else { rgba(api, (api.apply_embedded_orientation)(pixbuf)) };
        (api.unref)(loader);
        image
    }
}

/// # Safety
/// `pixbuf` is null or a pixbuf the caller owns; it is released.
unsafe fn upright(api: &Api, pixbuf: Object) -> Option<image::DynamicImage> {
    if pixbuf.is_null() {
        return None;
    }
    let turned = (api.apply_embedded_orientation)(pixbuf);
    (api.unref)(pixbuf);
    rgba(api, turned)
}

/// A pixbuf's pixels as straight RGBA; the pixbuf is released.
///
/// # Safety
/// `pixbuf` is null or a `GdkPixbuf` the caller owns.
unsafe fn rgba(api: &Api, pixbuf: Object) -> Option<image::DynamicImage> {
    if pixbuf.is_null() {
        return None;
    }
    let image = pixels(api, pixbuf);
    (api.unref)(pixbuf);
    image.map(image::DynamicImage::ImageRgba8)
}

/// # Safety
/// `pixbuf` is a live `GdkPixbuf`.
unsafe fn pixels(api: &Api, pixbuf: Object) -> Option<image::RgbaImage> {
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

#[cfg(test)]
pub fn available() -> bool {
    api().is_some()
}
