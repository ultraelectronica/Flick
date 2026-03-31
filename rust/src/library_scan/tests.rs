use super::{FileFingerprint, HybridScanner, SharedFileDatabase, TwoPhaseScanner};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct TestDir {
    path: PathBuf,
}

impl TestDir {
    fn new(label: &str) -> Self {
        let unique_suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "flick-player-library-scan-{label}-{}-{unique_suffix}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn write_file(path: &Path, contents: &[u8]) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }

    let mut file = fs::File::create(path).unwrap();
    file.write_all(contents).unwrap();
    file.sync_all().unwrap();
}

fn fingerprint(path: &Path) -> FileFingerprint {
    let metadata = fs::metadata(path).unwrap();
    let last_modified_ms = metadata
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    FileFingerprint {
        path: path.to_string_lossy().into_owned(),
        size: metadata.len(),
        last_modified_ms,
    }
}

fn wait_for(timeout: Duration, mut predicate: impl FnMut() -> bool) {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if predicate() {
            return;
        }
        thread::sleep(Duration::from_millis(25));
    }

    panic!("timed out waiting for condition");
}

#[test]
fn two_phase_scan_classifies_all_file_states() {
    let root = TestDir::new("two-phase");
    let new_file = root.path().join("new-track.mp3");
    let modified_file = root.path().join("updated-track.flac");
    let unchanged_file = root.path().join("same-track.ogg");

    write_file(&new_file, b"brand new");
    write_file(&modified_file, b"current contents");
    write_file(&unchanged_file, b"stable contents");

    let unchanged_fingerprint = fingerprint(&unchanged_file);
    let deleted_path = root.path().join("deleted-track.m4a");

    let database = SharedFileDatabase::from_files(vec![
        FileFingerprint {
            path: modified_file.to_string_lossy().into_owned(),
            size: 1,
            last_modified_ms: 0,
        },
        unchanged_fingerprint.clone(),
        FileFingerprint {
            path: deleted_path.to_string_lossy().into_owned(),
            size: 512,
            last_modified_ms: 42,
        },
    ]);

    let diff = TwoPhaseScanner::scan(root.path(), &database).unwrap();

    assert_eq!(
        diff.new_files
            .iter()
            .map(|file| file.path.clone())
            .collect::<Vec<_>>(),
        vec![new_file.to_string_lossy().into_owned()]
    );
    assert_eq!(
        diff.modified_files
            .iter()
            .map(|file| file.path.clone())
            .collect::<Vec<_>>(),
        vec![modified_file.to_string_lossy().into_owned()]
    );
    assert_eq!(
        diff.deleted_files,
        vec![deleted_path.to_string_lossy().into_owned()]
    );
    assert_eq!(diff.unchanged_files, vec![unchanged_fingerprint]);
}

#[test]
fn two_phase_scan_async_applies_batch_updates() {
    let root = TestDir::new("async-scan");
    let track = root.path().join("async-track.wav");
    write_file(&track, b"async scan");

    let database = SharedFileDatabase::new();
    let handle = TwoPhaseScanner::scan_async(root.path().to_path_buf(), database.clone());
    let diff = handle.join().unwrap().unwrap();

    assert_eq!(diff.new_files.len(), 1);
    assert!(database.contains(track.to_string_lossy().as_ref()));
    assert_eq!(database.len(), 1);
}

#[test]
fn two_phase_scan_skips_nomedia_subtrees() {
    let root = TestDir::new("nomedia");
    let visible_track = root.path().join("visible").join("track.mp3");
    let hidden_dir = root.path().join("hidden");
    let hidden_track = hidden_dir.join("secret.flac");
    let nomedia = hidden_dir.join(".nomedia");

    write_file(&visible_track, b"visible");
    write_file(&nomedia, b"");
    write_file(&hidden_track, b"hidden");

    let database = SharedFileDatabase::new();
    let diff = TwoPhaseScanner::scan(root.path(), &database).unwrap();

    assert_eq!(
        diff.new_files
            .iter()
            .map(|file| file.path.clone())
            .collect::<Vec<_>>(),
        vec![visible_track.to_string_lossy().into_owned()]
    );
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
#[test]
fn hybrid_scanner_bootstraps_and_reacts_to_live_changes() {
    let root = TestDir::new("hybrid");
    let database = SharedFileDatabase::new();
    let (hybrid, bootstrap_diff, _live_updates) =
        HybridScanner::bootstrap(root.path(), database.clone()).unwrap();

    assert!(bootstrap_diff.is_empty());
    assert!(database.is_empty());

    let live_file = root.path().join("live-track.mp3");
    write_file(&live_file, b"v1");

    wait_for(Duration::from_secs(5), || {
        database.contains(live_file.to_string_lossy().as_ref())
    });

    let first_fingerprint = database
        .get(live_file.to_string_lossy().as_ref())
        .expect("file should have been inserted by watcher");

    thread::sleep(Duration::from_millis(50));
    write_file(&live_file, b"version-two-with-more-bytes");

    wait_for(Duration::from_secs(5), || {
        database
            .get(live_file.to_string_lossy().as_ref())
            .map(|fingerprint| fingerprint.size != first_fingerprint.size)
            .unwrap_or(false)
    });

    fs::remove_file(&live_file).unwrap();

    wait_for(Duration::from_secs(5), || {
        !database.contains(live_file.to_string_lossy().as_ref())
    });

    let manual_rescan = hybrid.manual_rescan().unwrap();
    assert!(manual_rescan.is_empty());
}
