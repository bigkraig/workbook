//! Documents converted from PDFs into the structured form the Porsche
//! documents have (tools/ferrari_extract.py, tools/r8_extract.py). Each is a
//! JSON file beside its figures; only documents whose conversion passed its
//! checks against the PDF are loaded this way, and the PDF is kept as the
//! original.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use pcss::workshop_literature::{Children, Toc};
use serde_derive::Deserialize;

#[derive(Deserialize)]
pub struct StructuredDocument {
    passed: bool,
    pub content: Children,
    /// Headings, for the contents menu.
    #[serde(default)]
    pub toc: Vec<Toc>,
    /// Workshop image id -> file, relative to the structured directory.
    images: HashMap<String, String>,
    /// Search text.
    pub text: String,
    /// Date printed on the document (YYYY-MM-DD), when it has one.
    #[serde(default)]
    pub updated: Option<String>,
}

/// A structured document with its figures, as (workshop image id, bytes).
pub struct Structured {
    pub document: StructuredDocument,
    pub images: Vec<(i32, Vec<u8>)>,
}

/// `<dir>/<name>.json`, if it exists and passed its checks. Anything wrong with
/// it (unreadable, a shape the document types reject, a missing figure) means
/// the caller loads the PDF instead, with a warning.
pub fn read(dir: &Path, name: &str) -> Option<Structured> {
    let path = dir.join(format!("{}.json", name));
    let raw = fs::read(&path).ok()?;
    let document: StructuredDocument = match serde_json::from_slice(&raw) {
        Ok(document) => document,
        Err(e) => {
            eprintln!("Warning: {} is not a valid structured document ({}); loading the PDF", path.display(), e);
            return None;
        }
    };
    if !document.passed {
        return None;
    }
    let mut images = Vec::with_capacity(document.images.len());
    for (key, file) in &document.images {
        match key.parse::<i32>().ok().zip(fs::read(dir.join(file)).ok()) {
            Some((id, bytes)) => images.push((id, bytes)),
            None => {
                eprintln!("Warning: {} is missing figure {}; loading the PDF", path.display(), file);
                return None;
            }
        }
    }
    Some(Structured { document, images })
}
