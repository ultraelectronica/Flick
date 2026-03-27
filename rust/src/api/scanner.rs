use lofty::prelude::*;
use lofty::probe::Probe;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use walkdir::WalkDir;

#[derive(Debug, Clone)]
pub struct AudioFileMetadata {
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: Option<u64>,
    pub format: String,
    pub last_modified: i64,
    pub bit_depth: Option<u8>,
    pub sample_rate: Option<u32>,
    pub bitrate: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct ScanResult {
    pub new_or_modified: Vec<AudioFileMetadata>,
    pub deleted_paths: Vec<String>,
}

#[derive(Debug, Clone)]
struct FileScanEntry {
    path: String,
    last_modified: i64,
}

fn is_supported_audio_path(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    matches!(
        ext.as_str(),
        "mp3" | "flac" | "ogg" | "m4a" | "wav" | "aif" | "aiff" | "alac"
    )
}

pub fn scan_root_dir(root_path: String, known_files: HashMap<String, i64>) -> ScanResult {
    let files_on_disk: Vec<FileScanEntry> = WalkDir::new(&root_path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|entry| {
            let path = entry.into_path();
            if !is_supported_audio_path(&path) {
                return None;
            }

            let last_modified = std::fs::metadata(&path)
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);

            Some(FileScanEntry {
                path: path.to_string_lossy().to_string(),
                last_modified,
            })
        })
        .collect();

    let mut found_paths_vec = Vec::with_capacity(files_on_disk.len());
    let mut to_process = Vec::new();

    for file in files_on_disk {
        let needs_processing = match known_files.get(&file.path) {
            Some(&known_timestamp) => file.last_modified > known_timestamp,
            None => true,
        };

        found_paths_vec.push(file.path.clone());
        if needs_processing {
            to_process.push(file);
        }
    }

    let new_or_modified: Vec<AudioFileMetadata> = to_process
        .par_iter()
        .filter_map(|entry| {
            let path = Path::new(&entry.path);

            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();

            let tagged_file = Probe::open(path).ok()?.read().ok()?;
            let tag = tagged_file.primary_tag();
            let properties = tagged_file.properties();

            let title = tag.and_then(|t: &lofty::tag::Tag| t.title().map(|s| s.to_string()));
            let artist = tag.and_then(|t: &lofty::tag::Tag| t.artist().map(|s| s.to_string()));
            let album = tag.and_then(|t: &lofty::tag::Tag| t.album().map(|s| s.to_string()));
            let duration_secs = Some(properties.duration().as_secs());

            let bit_depth = properties.bit_depth();
            let sample_rate = properties.sample_rate();
            let bitrate = properties.audio_bitrate();

            Some(AudioFileMetadata {
                path: entry.path.clone(),
                title,
                artist,
                album,
                duration_secs,
                format: ext,
                last_modified: entry.last_modified,
                bit_depth,
                sample_rate,
                bitrate,
            })
        })
        .collect();

    let found_paths_set: HashSet<String> = found_paths_vec.into_iter().collect();
    let deleted_paths: Vec<String> = known_files
        .keys()
        .filter(|k| !found_paths_set.contains(*k))
        .cloned()
        .collect();

    ScanResult {
        new_or_modified,
        deleted_paths,
    }
}
