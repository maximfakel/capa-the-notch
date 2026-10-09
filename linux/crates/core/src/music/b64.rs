//! Standard base64, because the adapter sends artwork inside its JSON lines
//! and surfaces want it back as text. Small and local: no dependency for it.

const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

/// Lenient the way Foundation is not: whitespace is skipped, padding is
/// optional. Anything else outside the alphabet is not base64 at all.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let mut bits = 0u32;
    let mut have = 0;
    let mut padding = 0;
    for c in text.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                padding += 1;
                continue;
            }
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => return None,
        };
        if padding > 0 {
            return None; // data after padding
        }
        bits = (bits << 6) | u32::from(value);
        have += 6;
        if have >= 8 {
            have -= 8;
            out.push((bits >> have) as u8);
            bits &= (1 << have) - 1;
        }
    }
    // A lone leftover sextet cannot be a byte.
    (have < 6).then_some(out)
}

/// `Option<Vec<u8>>` as an optional base64 string, for surfaces.
pub mod serde_artwork {
    use super::{decode, encode};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => s.serialize_some(&encode(bytes)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        Ok(Option::<String>::deserialize(d)?.and_then(|t| decode(&t)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_round_trips_every_padding() {
        for s in ["", "f", "fo", "foo", "foob", "fooba", "foobar"] {
            assert_eq!(decode(&encode(s.as_bytes())).unwrap(), s.as_bytes());
        }
        assert_eq!(encode(b"artwork"), "YXJ0d29yaw==");
        assert_eq!(decode("YXJ0d29yaw").unwrap(), b"artwork", "padding is optional");
        assert_eq!(decode("YXJ0\nd29y aw==").unwrap(), b"artwork", "whitespace is skipped");
    }

    #[test]
    fn it_refuses_what_is_not_base64() {
        assert_eq!(decode("not*base64"), None);
        assert_eq!(decode("YQ==YQ"), None, "data after padding");
        assert_eq!(decode("Y"), None, "a lone sextet");
    }
}
