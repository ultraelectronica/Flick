use flutter_rust_bridge::frb;
use lofty::prelude::*;
use lofty::probe::Probe;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
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
}

#[derive(Debug, Clone)]
pub struct ScanResult {
    pub new_or_modified: Vec<AudioFileMetadata>,
    pub deleted_paths: Vec<String>,
}

#[frb(sync)]
pub fn scan_root_dir(root_path: String, known_files: HashMap<String, i64>) -> ScanResult {
    let files_on_disk: Vec<walkdir::DirEntry> = WalkDir::new(&root_path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .collect();

    let (to_process, found_paths_vec): (Vec<walkdir::DirEntry>, Vec<String>) = files_on_disk
        .into_par_iter()
        .fold(
            || (Vec::new(), Vec::new()),
            |(mut to_process, mut found_paths), entry| {
                let path_str = entry.path().to_string_lossy().to_string();
                let metadata = entry.metadata().ok();
                let modified = metadata
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);

                let needs_processing = match known_files.get(&path_str) {
                    Some(&known_timestamp) => modified > known_timestamp,
                    None => true,
                };

                if needs_processing {
                    to_process.push(entry);
                }
                found_paths.push(path_str);
                (to_process, found_paths)
            },
        )
        .reduce(
            || (Vec::new(), Vec::new()),
            |(mut a_proc, mut a_paths), (b_proc, b_paths)| {
                a_proc.extend(b_proc);
                a_paths.extend(b_paths);
                (a_proc, a_paths)
            },
        );

    let new_or_modified: Vec<AudioFileMetadata> = to_process
        .par_iter()
        .filter_map(|entry: &walkdir::DirEntry| {
            let path = entry.path();
            let path_str = path.to_string_lossy().to_string();

            let ext = path
                .extension()
                .and_then(|s: &std::ffi::OsStr| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            if !["mp3", "flac", "ogg", "m4a", "wav"].contains(&ext.as_str()) {
                return None;
            }

            let tagged_file = Probe::open(path).ok()?.read().ok()?;
            let tag = tagged_file.primary_tag();
            let properties = tagged_file.properties();

            let title = tag.and_then(|t: &lofty::tag::Tag| t.title().map(|s| s.to_string()));
            let artist = tag.and_then(|t: &lofty::tag::Tag| t.artist().map(|s| s.to_string()));
            let album = tag.and_then(|t: &lofty::tag::Tag| t.album().map(|s| s.to_string()));
            let duration_secs = Some(properties.duration().as_secs());

            let modified = entry
                .metadata()
                .ok()
                .and_then(|m: std::fs::Metadata| m.modified().ok())
                .and_then(|t: std::time::SystemTime| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d: std::time::Duration| d.as_secs() as i64)
                .unwrap_or(0);

            Some(AudioFileMetadata {
                path: path_str,
                title,
                artist,
                album,
                duration_secs,
                format: ext,
                last_modified: modified,
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
