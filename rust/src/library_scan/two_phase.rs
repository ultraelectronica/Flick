use super::database::SharedFileDatabase;
use super::types::{FileFingerprint, ScanDiff};
use anyhow::{anyhow, Result};
use jwalk::WalkDir;
use rayon::prelude::*;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Error, ErrorKind};
use std::path::{Path, PathBuf};
use std::thread::{self, JoinHandle};
use std::time::UNIX_EPOCH;

pub struct TwoPhaseScanner;

impl TwoPhaseScanner {
    pub fn scan<P: AsRef<Path>>(root_path: P, database: &SharedFileDatabase) -> Result<ScanDiff> {
        let root_path = normalize_root(root_path)?;
        let snapshot = database.snapshot();
        Self::scan_with_snapshot(&root_path, &snapshot)
    }

    pub fn scan_with_snapshot<P: AsRef<Path>>(
        root_path: P,
        snapshot: &HashMap<String, FileFingerprint>,
    ) -> Result<ScanDiff> {
        let root_path = normalize_root(root_path)?;
        let candidates = collect_candidate_paths(&root_path);
        let scanned_files = candidates
            .into_par_iter()
            .filter_map(|path| read_fingerprint(&path).ok())
            .collect::<Vec<_>>();

        Ok(classify_diff(scanned_files, snapshot))
    }

    pub fn scan_and_apply<P: AsRef<Path>>(
        root_path: P,
        database: &SharedFileDatabase,
    ) -> Result<ScanDiff> {
        let diff = Self::scan(root_path, database)?;
        database.apply_scan_diff(&diff);
        Ok(diff)
    }

    pub fn scan_async<P: Into<PathBuf> + Send + 'static>(
        root_path: P,
        database: SharedFileDatabase,
    ) -> JoinHandle<Result<ScanDiff>> {
        let root_path = root_path.into();
        thread::spawn(move || Self::scan_and_apply(root_path, &database))
    }
}

fn normalize_root<P: AsRef<Path>>(root_path: P) -> Result<PathBuf> {
    let root_path = root_path.as_ref();

    if !root_path.exists() {
        return Err(anyhow!("scan root does not exist: {}", root_path.display()));
    }

    if !root_path.is_dir() {
        return Err(anyhow!(
            "scan root is not a directory: {}",
            root_path.display()
        ));
    }

    Ok(root_path.canonicalize()?)
}

fn collect_candidate_paths(root_path: &Path) -> Vec<PathBuf> {
    let mut nomedia_cache = HashMap::new();

    WalkDir::new(root_path)
        .follow_links(false)
        .process_read_dir(|_, _, _, children| {
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
        })
        .into_iter()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_file())
        .map(|entry| entry.path())
        .filter(|path| !is_in_nomedia_subtree(path, &mut nomedia_cache))
        .filter(|path| is_supported_audio_path(path))
        .collect()
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

fn classify_diff(
    scanned_files: Vec<FileFingerprint>,
    known_files: &HashMap<String, FileFingerprint>,
) -> ScanDiff {
    let mut diff = ScanDiff::default();
    let mut seen_paths = HashSet::with_capacity(scanned_files.len());

    for file in scanned_files {
        seen_paths.insert(file.path.clone());

        match known_files.get(&file.path) {
            None => diff.new_files.push(file),
            Some(existing) if file.changed_from(existing) => diff.modified_files.push(file),
            Some(_) => diff.unchanged_files.push(file),
        }
    }

    diff.deleted_files = known_files
        .keys()
        .filter(|path| !seen_paths.contains(*path))
        .cloned()
        .collect();

    diff.new_files
        .sort_by(|left, right| left.path.cmp(&right.path));
    diff.modified_files
        .sort_by(|left, right| left.path.cmp(&right.path));
    diff.deleted_files.sort();
    diff.unchanged_files
        .sort_by(|left, right| left.path.cmp(&right.path));

    diff
}

pub(crate) fn read_fingerprint(path: &Path) -> std::io::Result<FileFingerprint> {
    let metadata = fs::metadata(path)?;

    if !metadata.is_file() {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("path is not a file: {}", path.display()),
        ));
    }

    let last_modified_ms = metadata
        .modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    Ok(FileFingerprint {
        path: path.to_string_lossy().into_owned(),
        size: metadata.len(),
        last_modified_ms,
    })
}

pub(crate) fn is_supported_audio_path(path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    matches!(
        extension.as_str(),
        "mp3" | "flac" | "ogg" | "oga" | "ogx" | "opus" | "m4a" | "wav" | "aif" | "aiff" | "alac"
    )
}
