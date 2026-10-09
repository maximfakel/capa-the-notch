//! Thumbnails of what the Shelf holds, drawn with the `image` crate: the size
//! the tile shows (the drawing's 56 × 38, at twice that for a sharp screen).
//! A photo is turned upright by its EXIF orientation, as Quick Look turns it;
//! HEIC and HEIF, which the `image` crate does not read, go to gdk-pixbuf
//! where the system has it.

use capa_core::shelf::{FileThumbnailer, ImageCodec, Thumbnail};
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader};
use std::io::{BufRead, Cursor, Read, Seek};
use std::path::Path;

pub struct ImageThumbnailer;

fn fit(image: DynamicImage, max_width: u32, max_height: u32) -> Thumbnail {
    // Cover the box, as the tile does (`aspectRatio(contentMode: .fill)`), then cut to it.
    let scaled = image.resize_to_fill(max_width, max_height, FilterType::Triangle);
    let rgba = scaled.to_rgba8();
    Thumbnail { width: rgba.width(), height: rgba.height(), rgba: rgba.into_raw() }
}

/// Decodes what `reader` holds (its kind sniffed from the bytes, else the
/// file's extension) and turns it by its EXIF orientation.
fn upright<R: BufRead + Seek>(reader: ImageReader<R>) -> Option<DynamicImage> {
    let mut decoder = reader.with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let mut image = DynamicImage::from_decoder(decoder).ok()?;
    image.apply_orientation(orientation);
    Some(image)
}

/// HEIF's brands (`ftyp`), HEIC and AVIF among them: what is sent on to
/// gdk-pixbuf, and nothing else, so a PDF or an archive set down does not
/// start an image loader.
fn is_heif(head: &[u8]) -> bool {
    const BRANDS: [&[u8; 4]; 12] = [b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"hevm", b"hevs", b"mif1", b"msf1", b"avif", b"avis"];
    head.len() >= 12 && &head[4..8] == b"ftyp" && BRANDS.iter().any(|b| &head[8..12] == *b)
}

fn file_head(path: &Path) -> Option<[u8; 12]> {
    let mut head = [0; 12];
    std::fs::File::open(path).ok()?.read_exact(&mut head).ok()?;
    Some(head)
}

impl FileThumbnailer for ImageThumbnailer {
    fn thumbnail_file(&self, path: &Path, max_width: u32, max_height: u32) -> Option<Thumbnail> {
        // A file too large to be a picture someone set down is not decoded.
        if std::fs::metadata(path).ok()?.len() > 80 * 1024 * 1024 {
            return None;
        }
        let image = match ImageReader::open(path).ok().and_then(upright) {
            Some(image) => image,
            None if file_head(path).is_some_and(|h| is_heif(&h)) => crate::pixbuf::load_file(path)?,
            None => return None,
        };
        Some(fit(image, max_width, max_height))
    }

    fn thumbnail_data(&self, data: &[u8], max_width: u32, max_height: u32) -> Option<Thumbnail> {
        let image = match upright(ImageReader::new(Cursor::new(data))) {
            Some(image) => image,
            None if is_heif(data) => crate::pixbuf::load_data(data)?,
            None => return None,
        };
        Some(fit(image, max_width, max_height))
    }
}

/// PNG bytes of a thumbnail.
pub fn png(thumbnail: &Thumbnail) -> Option<Vec<u8>> {
    let buffer = image::RgbaImage::from_raw(thumbnail.width, thumbnail.height, thumbnail.rgba.clone())?;
    let mut out = Cursor::new(Vec::new());
    buffer.write_to(&mut out, ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// Converts what the clipboard holds as TIFF — its converted copy, and large — to PNG.
pub struct PngCodec;

impl ImageCodec for PngCodec {
    fn to_png(&self, data: &[u8], _from_type: &str) -> Option<Vec<u8>> {
        let image = image::load_from_memory(data).ok()?;
        let mut out = Cursor::new(Vec::new());
        image.write_to(&mut out, ImageFormat::Png).ok()?;
        Some(out.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use capa_core::shelf::THUMBNAIL_SIZE;

    const WIDTH: u32 = THUMBNAIL_SIZE.0;
    const HEIGHT: u32 = THUMBNAIL_SIZE.1;

    fn png_of(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(width, height, image::Rgba([10, 200, 30, 255]));
        let mut out = Cursor::new(Vec::new());
        image.write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn a_picture_is_cut_to_the_tile() {
        let t = ImageThumbnailer.thumbnail_data(&png_of(400, 100), WIDTH, HEIGHT).unwrap();
        assert_eq!((t.width, t.height), (WIDTH, HEIGHT));
        assert_eq!(t.rgba.len(), (WIDTH * HEIGHT * 4) as usize);
        assert_eq!(&t.rgba[..4], &[10, 200, 30, 255]);
    }

    #[test]
    fn what_is_not_a_picture_has_none() {
        assert!(ImageThumbnailer.thumbnail_data(b"not an image", WIDTH, HEIGHT).is_none());
        assert!(ImageThumbnailer.thumbnail_file(Path::new("/nonexistent.png"), WIDTH, HEIGHT).is_none());
    }

    /// A JPEG, `width` × `height` as stored, left half red and right half
    /// blue, with an EXIF orientation of `orientation`.
    fn jpeg_turned(width: u32, height: u32, orientation: u16) -> Vec<u8> {
        use image::ImageEncoder;
        let image = image::RgbImage::from_fn(width, height, |x, _| if x < width / 2 { image::Rgb([255, 0, 0]) } else { image::Rgb([0, 0, 255]) });
        // A big-endian TIFF header and one IFD entry: Orientation (0x0112), SHORT, 1.
        let mut exif = b"MM\0\x2a\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01".to_vec();
        exif.extend_from_slice(&orientation.to_be_bytes());
        exif.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
        let mut out = Vec::new();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 95);
        encoder.set_exif_metadata(exif).unwrap();
        encoder.write_image(image.as_raw(), width, height, image::ExtendedColorType::Rgb8).unwrap();
        out
    }

    fn is_red(px: &[u8]) -> bool {
        px[0] > 200 && px[2] < 60
    }

    fn is_blue(px: &[u8]) -> bool {
        px[2] > 200 && px[0] < 60
    }

    #[test]
    fn a_photo_is_turned_upright_by_its_exif_orientation() {
        // Stored 80 × 40, red on the left; orientation 6 is "turn 90° clockwise to show",
        // so it shows 40 × 80, red on top.
        let data = jpeg_turned(80, 40, 6);
        let t = ImageThumbnailer.thumbnail_data(&data, 40, 80).unwrap();
        assert_eq!((t.width, t.height), (40, 80));
        let at = |x: u32, y: u32| &t.rgba[((y * t.width + x) * 4) as usize..][..4];
        assert!(is_red(at(20, 10)) && is_blue(at(20, 70)), "top {:?} bottom {:?}", at(20, 10), at(20, 70));

        let path = std::env::temp_dir().join(format!("capa-thumb-{}.jpg", std::process::id()));
        std::fs::write(&path, &data).unwrap();
        let f = ImageThumbnailer.thumbnail_file(&path, 40, 80).unwrap();
        assert_eq!(f.rgba, t.rgba, "a file is turned as the bytes are");
        let _ = std::fs::remove_file(&path);

        // Without the orientation it stays as stored: red on the left.
        let plain = ImageThumbnailer.thumbnail_data(&jpeg_turned(80, 40, 1), 80, 40).unwrap();
        let at = |x: u32, y: u32| &plain.rgba[((y * plain.width + x) * 4) as usize..][..4];
        assert!(is_red(at(10, 20)) && is_blue(at(70, 20)));
    }

    #[test]
    fn heif_is_told_by_its_brand() {
        assert!(is_heif(b"\0\0\0\x18ftypheic\0\0\0\0"));
        assert!(is_heif(b"\0\0\0\x18ftypmif1\0\0\0\0"));
        assert!(!is_heif(b"\0\0\0\x18ftypisom\0\0\0\0"), "an MP4 is not a picture");
        assert!(!is_heif(b"%PDF-1.7"));
        // Something HEIF-shaped that is not a picture has none, and does not fail.
        assert!(ImageThumbnailer.thumbnail_data(b"\0\0\0\x18ftypheic\0\0\0\0garbage", WIDTH, HEIGHT).is_none());
    }

    #[test]
    fn a_heic_photo_is_read_by_gdk_pixbuf_where_there_is_one() {
        let dir = std::env::temp_dir().join(format!("capa-heic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (source, heic) = (dir.join("photo.png"), dir.join("photo.heic"));
        image::RgbImage::from_pixel(64, 48, image::Rgb([200, 30, 30])).save(&source).unwrap();
        let encoded = std::process::Command::new("heif-enc")
            .arg("-o")
            .arg(&heic)
            .arg(&source)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !encoded || !crate::pixbuf::available() {
            let _ = std::fs::remove_dir_all(&dir);
            return; // No encoder, or no gdk-pixbuf: nothing to read it with, nothing to show.
        }
        let Some(t) = ImageThumbnailer.thumbnail_file(&heic, WIDTH, HEIGHT) else {
            // gdk-pixbuf without a HEIF loader: no picture, and no failure.
            let _ = std::fs::remove_dir_all(&dir);
            return;
        };
        assert_eq!((t.width, t.height), (WIDTH, HEIGHT));
        assert!(t.rgba[0] > 150 && t.rgba[1] < 80, "{:?}", &t.rgba[..4]);
        let d = ImageThumbnailer.thumbnail_data(&std::fs::read(&heic).unwrap(), WIDTH, HEIGHT).expect("the same bytes in memory");
        assert_eq!((d.width, d.height), (WIDTH, HEIGHT));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_thumbnail_encodes_to_png_and_back() {
        let t = ImageThumbnailer.thumbnail_data(&png_of(50, 50), 20, 20).unwrap();
        let bytes = png(&t).unwrap();
        assert_eq!(&bytes[1..4], b"PNG");
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 20);
    }
}
