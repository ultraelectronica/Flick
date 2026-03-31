use crate::frb_generated::StreamSink;
use jwalk::WalkDir;
use lofty::config::ParseOptions;
use lofty::picture::PictureType;
use lofty::prelude::*;
use lofty::probe::Probe;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

const SCAN_BATCH_SIZE: usize = 500;

#[derive(Debug, Clone)]
pub struct ScanOptions {
    pub filter_non_music_files_and_folders: bool,
}

#[derive(Debug, Clone)]
pub struct AudioFileMetadata {
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<u64>,
    pub format: String,
    pub last_modified: i64,
    pub bit_depth: Option<u8>,
    pub sample_rate: Option<u32>,
    pub bitrate: Option<u32>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub file_size: u64,
}

#[derive(Debug, Clone)]
pub struct ScanResult {
    pub new_or_modified: Vec<AudioFileMetadata>,
    pub deleted_paths: Vec<String>,
    pub total_files: u32,
}

#[derive(Debug, Clone)]
pub struct ScanChunk {
    pub new_or_modified: Vec<AudioFileMetadata>,
    pub deleted_paths: Vec<String>,
    pub total_files: u32,
    pub is_complete: bool,
}

#[derive(Debug, Clone)]
struct FileScanEntry {
    path: String,
    last_modified: i64,
    file_size: u64,
}

fn is_supported_audio_path(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    matches!(
        ext.as_str(),
        "mp3" | "flac" | "ogg" | "oga" | "ogx" | "opus" | "m4a" | "wav" | "aif" | "aiff" | "alac"
    )
}

pub fn scan_root_dir(
    root_path: String,
    known_files: HashMap<String, i64>,
    scan_options: ScanOptions,
) -> ScanResult {
    let files_on_disk = collect_scan_file_entries(&root_path, &scan_options);
    let total_files = files_on_disk.len() as u32;
    let (to_process, deleted_paths, _) = classify_scan_work(files_on_disk, &known_files);

    let new_or_modified = to_process
        .par_iter()
        .filter_map(extract_text_metadata_only)
        .collect();

    ScanResult {
        new_or_modified,
        deleted_paths,
        total_files,
    }
}

pub async fn scan_music_library(
    root_path: String,
    known_files: HashMap<String, i64>,
    scan_options: ScanOptions,
    sink: StreamSink<ScanChunk>,
) -> anyhow::Result<()> {
    let files_on_disk = collect_scan_file_entries(&root_path, &scan_options);
    let total_files = files_on_disk.len() as u32;
    let (to_process, deleted_paths, _) = classify_scan_work(files_on_disk, &known_files);

    sink.add(ScanChunk {
        new_or_modified: Vec::new(),
        deleted_paths,
        total_files,
        is_complete: false,
    })
    .map_err(|err| anyhow::anyhow!(err.to_string()))?;

    for chunk in to_process.chunks(SCAN_BATCH_SIZE) {
        let new_or_modified = chunk
            .par_iter()
            .filter_map(extract_text_metadata_only)
            .collect::<Vec<_>>();

        if new_or_modified.is_empty() {
            continue;
        }

        sink.add(ScanChunk {
            new_or_modified,
            deleted_paths: Vec::new(),
            total_files,
            is_complete: false,
        })
        .map_err(|err| anyhow::anyhow!(err.to_string()))?;
    }

    sink.add(ScanChunk {
        new_or_modified: Vec::new(),
        deleted_paths: Vec::new(),
        total_files,
        is_complete: true,
    })
    .map_err(|err| anyhow::anyhow!(err.to_string()))?;

    Ok(())
}

pub fn discover_playlist_files(root_path: String, scan_options: ScanOptions) -> Vec<String> {
    collect_playlist_file_entries(&root_path, &scan_options)
        .into_iter()
        .map(|entry| entry.path)
        .collect()
}

pub fn extract_embedded_artwork(path: String) -> Option<Vec<u8>> {
    let parse_options = ParseOptions::new().read_properties(false);
    let tagged_file = Probe::open(path).ok()?.options(parse_options).read().ok()?;
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())?;
    let picture = tag
        .get_picture_type(PictureType::CoverFront)
        .or_else(|| tag.pictures().first())?;

    Some(picture.data().to_vec())
}

fn collect_scan_file_entries(root_path: &str, scan_options: &ScanOptions) -> Vec<FileScanEntry> {
    collect_file_entries(root_path, scan_options, |path| {
        if scan_options.filter_non_music_files_and_folders {
            is_supported_audio_path(path)
        } else {
            true
        }
    })
}

fn collect_playlist_file_entries(
    root_path: &str,
    scan_options: &ScanOptions,
) -> Vec<FileScanEntry> {
    collect_file_entries(root_path, scan_options, is_supported_playlist_path)
}

fn collect_file_entries<F>(
    root_path: &str,
    scan_options: &ScanOptions,
    should_include: F,
) -> Vec<FileScanEntry>
where
    F: Fn(&Path) -> bool,
{
    let mut nomedia_cache = HashMap::new();
    let respect_nomedia = scan_options.filter_non_music_files_and_folders;

    WalkDir::new(root_path)
        .follow_links(false)
        .process_read_dir(move |_, _, _, children| {
            if respect_nomedia {
                let has_nomedia = children.iter().any(|child| {
                    child
                        .as_ref()
                        .ok()
                        .and_then(|entry| entry.file_name.to_str())
                        == Some(".nomedia")
                });

                if has_nomedia {
                    children.clear();
                }
            }
        })
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file())
        .filter_map(|entry| {
            let path = entry.path();
            if !should_include(&path)
                || (respect_nomedia && is_in_nomedia_subtree(&path, &mut nomedia_cache))
            {
                return None;
            }

            let metadata = std::fs::metadata(&path).ok()?;
            let last_modified = metadata
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);

            Some(FileScanEntry {
                path: path.to_string_lossy().to_string(),
                last_modified,
                file_size: metadata.len(),
            })
        })
        .collect()
}

fn is_supported_playlist_path(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    matches!(ext.as_str(), "m3u" | "m3u8")
}

fn is_in_nomedia_subtree(path: &Path, cache: &mut HashMap<PathBuf, bool>) -> bool {
    path.parent()
        .map(|parent| directory_is_nomedia_blocked(parent, cache))
        .unwrap_or(false)
}

fn directory_is_nomedia_blocked(dir: &Path, cache: &mut HashMap<PathBuf, bool>) -> bool {
    if let Some(cached) = cache.get(dir) {
        return *cached;
    }

    let blocked = dir.join(".nomedia").is_file()
        || dir
            .parent()
            .map(|parent| directory_is_nomedia_blocked(parent, cache))
            .unwrap_or(false);

    cache.insert(dir.to_path_buf(), blocked);
    blocked
}

fn classify_scan_work(
    files_on_disk: Vec<FileScanEntry>,
    known_files: &HashMap<String, i64>,
) -> (Vec<FileScanEntry>, Vec<String>, HashSet<String>) {
    let mut found_paths = HashSet::with_capacity(files_on_disk.len());
    let mut to_process = Vec::new();

    for file in files_on_disk {
        let path = file.path.clone();
        let needs_processing = known_files.get(&path).map_or(true, |known_timestamp| {
            *known_timestamp != file.last_modified
        });

        found_paths.insert(path);

        if needs_processing {
            to_process.push(file);
        }
    }

    let deleted_paths = known_files
        .keys()
        .filter(|path| !found_paths.contains(*path))
        .cloned()
        .collect::<Vec<_>>();

    (to_process, deleted_paths, found_paths)
}

fn extract_text_metadata_only(entry: &FileScanEntry) -> Option<AudioFileMetadata> {
    let path = PathBuf::from(&entry.path);
    let format = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let parse_options = ParseOptions::new().read_cover_art(false);
    let tagged_file = Probe::open(&path)
        .ok()?
        .options(parse_options)
        .read()
        .ok()?;
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag());
    let properties = tagged_file.properties();
    let duration_ms = properties.duration().as_millis().min(u128::from(u64::MAX)) as u64;

    Some(AudioFileMetadata {
        path: entry.path.clone(),
        title: tag.and_then(|t| t.title().map(|s| s.to_string())),
        artist: tag.and_then(|t| t.artist().map(|s| s.to_string())),
        album: tag.and_then(|t| t.album().map(|s| s.to_string())),
        duration_ms: Some(duration_ms),
        format,
        last_modified: entry.last_modified,
        bit_depth: properties.bit_depth(),
        sample_rate: properties.sample_rate(),
        bitrate: properties.audio_bitrate(),
        track_number: tag.and_then(|t| t.track()),
        disc_number: tag.and_then(|t| t.disk()),
        file_size: entry.file_size,
    })
}
