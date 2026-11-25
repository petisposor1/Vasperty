use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result};

use crate::Converter;

/// Identifies one conversion result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CacheKey(blake3::Hash);

impl CacheKey {
    /// Builds a key from multiple input slices without allocating a concatenated buffer.
    pub fn from_parts(converter: &dyn Converter, parts: &[&[u8]]) -> Self {
        let mut h = blake3::Hasher::new();
        h.update(converter.id().as_bytes());
        h.update(&[0]);
        h.update(&converter.version().to_le_bytes());
        for part in parts {
            h.update(part);
        }
        CacheKey(h.finalize())
    }

    pub fn new(converter: &dyn Converter, input: &[u8]) -> Self {
        Self::from_parts(converter, &[input])
    }

    pub fn to_hex(&self) -> String {
        self.0.to_hex().to_string()
    }
}

/// Content-addressed store under the user's cache directory.
#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
}

/// Aggregate statistics for the on-disk pipeline cache.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CacheStats {
    pub entries: usize,
    pub total_bytes: u64,
    pub stale_temps: usize,
    pub stale_temp_bytes: u64,
}

impl Cache {
    /// Opens (creating) a cache at `root`. Refuses locations inside the repo.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        victory_core::ensure_outside_repo(&root)?;
        std::fs::create_dir_all(&root).with_context(|| format!("creating {}", root.display()))?;
        Ok(Cache { root })
    }

    /// Root directory of this cache store.
    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path_for(&self, key: &CacheKey) -> PathBuf {
        let hex = key.to_hex();
        self.root.join(&hex[..2]).join(&hex[2..])
    }

    /// Collects file counts and byte totals across shard directories,
    /// distinguishing published entries from interrupted `.tmp-*` staging files.
    pub fn stats(&self) -> Result<CacheStats> {
        let mut stats = CacheStats::default();
        if !self.root.exists() {
            return Ok(stats);
        }
        for shard in std::fs::read_dir(&self.root)? {
            let shard = shard?;
            if !shard.file_type()?.is_dir() {
                continue;
            }
            for item in std::fs::read_dir(shard.path())? {
                let item = item?;
                if !item.file_type()?.is_file() {
                    continue;
                }
                let len = item.metadata()?.len();
                let is_tmp = item.file_name().to_string_lossy().starts_with(".tmp-");
                if is_tmp {
                    stats.stale_temps += 1;
                    stats.stale_temp_bytes += len;
                } else {
                    stats.entries += 1;
                    stats.total_bytes += len;
                }
            }
        }
        Ok(stats)
    }

    /// Removes interrupted `.tmp-*` staging files from all shard directories,
    /// returning `(removed_count, freed_bytes)`. Published cache entries are kept intact.
    pub fn prune_stale_temps(&self) -> Result<(usize, u64)> {
        let mut removed = 0usize;
        let mut freed = 0u64;
        if !self.root.exists() {
            return Ok((0, 0));
        }
        for shard in std::fs::read_dir(&self.root)? {
            let shard = shard?;
            if !shard.file_type()?.is_dir() {
                continue;
            }
            for item in std::fs::read_dir(shard.path())? {
                let item = item?;
                if !item.file_type()?.is_file() {
                    continue;
                }
                if !item.file_name().to_string_lossy().starts_with(".tmp-") {
                    continue;
                }
                let len = item.metadata().map(|m| m.len()).unwrap_or(0);
                if std::fs::remove_file(item.path()).is_ok() {
                    removed += 1;
                    freed += len;
                }
            }
        }
        Ok((removed, freed))
    }

    /// Returns `(bytes, path, cache_hit)` for the multipart key without concatenating inputs
    /// or re-reading freshly converted output from disk.
    pub fn read_or_convert_parts(
        &self,
        converter: &dyn Converter,
        parts: &[&[u8]],
        convert: impl FnOnce() -> Result<Vec<u8>>,
    ) -> Result<(Vec<u8>, PathBuf, bool)> {
        let key = CacheKey::from_parts(converter, parts);
        let path = self.path_for(&key);
        if let Ok(bytes) = std::fs::read(&path) {
            tracing::trace!(converter = converter.id(), key = %key.to_hex(), "cache hit");
            return Ok((bytes, path, true));
        }
        let output = convert()
            .with_context(|| format!("converter {} v{}", converter.id(), converter.version()))?;
        let dir = path.parent().expect("hashed path has a parent");
        std::fs::create_dir_all(dir)?;
        let (tmp, mut file) = tempfile_in(dir)?;
        let written = file.write_all(&output);
        drop(file);
        let published = written.and_then(|()| std::fs::rename(&tmp, &path));
        if published.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        published?;
        Ok((output, path, false))
    }

    /// Returns the cached output for `input`, converting it first if needed.
    pub fn get_or_convert(&self, converter: &dyn Converter, input: &[u8]) -> Result<PathBuf> {
        let (_, path, _) =
            self.read_or_convert_parts(converter, &[input], || converter.convert(input))?;
        Ok(path)
    }
}

fn tempfile_in(dir: &Path) -> io::Result<(PathBuf, File)> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    create_tempfile_in(dir, &COUNTER)
}

fn create_tempfile_in(dir: &Path, counter: &AtomicU64) -> io::Result<(PathBuf, File)> {
    // An interrupted writer can leave a file behind, and process IDs are
    // reused. Keep it intact and try a new name rather than failing a miss.
    for _ in 0..128 {
        let n = counter.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!(".tmp-{}-{n}", std::process::id()));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not create a unique cache staging file after 128 attempts",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Upper {
        version: u32,
        runs: AtomicUsize,
    }

    impl Converter for Upper {
        fn id(&self) -> &'static str {
            "test.upper"
        }
        fn version(&self) -> u32 {
            self.version
        }
        fn convert(&self, input: &[u8]) -> Result<Vec<u8>> {
            self.runs.fetch_add(1, Ordering::Relaxed);
            Ok(input.to_ascii_uppercase())
        }
    }

    #[test]
    fn converts_once_then_hits() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().join("cache")).unwrap();
        let conv = Upper {
            version: 1,
            runs: AtomicUsize::new(0),
        };
        let a = cache.get_or_convert(&conv, b"abc").unwrap();
        let b = cache.get_or_convert(&conv, b"abc").unwrap();
        assert_eq!(a, b);
        assert_eq!(std::fs::read(&a).unwrap(), b"ABC");
        assert_eq!(conv.runs.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn failed_publication_removes_the_staging_file() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().join("cache")).unwrap();
        let conv = Upper {
            version: 1,
            runs: AtomicUsize::new(0),
        };
        let path = cache.path_for(&CacheKey::new(&conv, b"abc"));
        std::fs::create_dir_all(&path).unwrap();

        assert!(cache.get_or_convert(&conv, b"abc").is_err());
        assert!(path.is_dir());
        assert_eq!(
            std::fs::read_dir(path.parent().unwrap()).unwrap().count(),
            1
        );
    }

    #[test]
    fn staging_retries_collisions_without_changing_existing_files() {
        let dir = tempfile::tempdir().unwrap();
        let counter = AtomicU64::new(0);
        for n in 0..2 {
            std::fs::write(
                dir.path().join(format!(".tmp-{}-{n}", std::process::id())),
                b"stale",
            )
            .unwrap();
        }

        let (path, mut file) = create_tempfile_in(dir.path(), &counter).unwrap();
        file.write_all(b"fresh").unwrap();
        drop(file);
        assert_eq!(
            path.file_name().unwrap(),
            format!(".tmp-{}-2", std::process::id()).as_str()
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"fresh");
        for n in 0..2 {
            assert_eq!(
                std::fs::read(dir.path().join(format!(".tmp-{}-{n}", std::process::id()))).unwrap(),
                b"stale"
            );
        }
        assert_eq!(counter.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn staging_collision_retries_are_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let counter = AtomicU64::new(0);
        for n in 0..128 {
            std::fs::write(
                dir.path().join(format!(".tmp-{}-{n}", std::process::id())),
                b"stale",
            )
            .unwrap();
        }

        let error = create_tempfile_in(dir.path(), &counter).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(counter.load(Ordering::Relaxed), 128);
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 128);
    }

    #[test]
    fn staging_does_not_retry_other_io_errors() {
        let dir = tempfile::tempdir().unwrap();
        let counter = AtomicU64::new(0);
        let missing = dir.path().join("missing");

        let error = create_tempfile_in(&missing, &counter).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(counter.load(Ordering::Relaxed), 1);
        assert!(!missing.exists());
    }

    #[test]
    fn version_bump_invalidates() {
        let v1 = Upper {
            version: 1,
            runs: AtomicUsize::new(0),
        };
        let v2 = Upper {
            version: 2,
            runs: AtomicUsize::new(0),
        };
        assert_ne!(CacheKey::new(&v1, b"x"), CacheKey::new(&v2, b"x"));
    }

    #[test]
    fn refuses_cache_inside_repo() {
        let inside = Path::new(env!("CARGO_MANIFEST_DIR")).join("cache");
        assert!(Cache::open(inside).is_err());
    }

    #[test]
    fn stats_and_prune_stale_temps_preserve_entries() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().join("cache")).unwrap();
        let conv = Upper {
            version: 1,
            runs: AtomicUsize::new(0),
        };
        let entry = cache.get_or_convert(&conv, b"abc").unwrap();
        let shard = entry.parent().unwrap();
        std::fs::write(shard.join(".tmp-999-0"), b"partial").unwrap();
        std::fs::write(shard.join(".tmp-999-1"), b"junk-data").unwrap();

        let before = cache.stats().unwrap();
        assert_eq!(before.entries, 1);
        assert_eq!(before.total_bytes, 3);
        assert_eq!(before.stale_temps, 2);
        assert_eq!(before.stale_temp_bytes, 16);

        let (removed, freed) = cache.prune_stale_temps().unwrap();
        assert_eq!(removed, 2);
        assert_eq!(freed, 16);

        let after = cache.stats().unwrap();
        assert_eq!(after.entries, 1);
        assert_eq!(after.total_bytes, 3);
        assert_eq!(after.stale_temps, 0);
        assert_eq!(after.stale_temp_bytes, 0);
        assert_eq!(std::fs::read(entry).unwrap(), b"ABC");
    }

    #[test]
    fn read_or_convert_parts_matches_key_and_avoids_concat() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().join("cache")).unwrap();
        let conv = Upper {
            version: 1,
            runs: AtomicUsize::new(0),
        };
        assert_eq!(
            CacheKey::from_parts(&conv, &[b"hello ", b"world"]),
            CacheKey::new(&conv, b"hello world")
        );

        let calls = AtomicUsize::new(0);
        let (first, path1, hit1) = cache
            .read_or_convert_parts(&conv, &[b"hello ", b"world"], || {
                calls.fetch_add(1, Ordering::Relaxed);
                Ok(b"HELLO WORLD".to_vec())
            })
            .unwrap();
        assert!(!hit1);
        assert_eq!(first, b"HELLO WORLD");
        assert_eq!(calls.load(Ordering::Relaxed), 1);

        let (second, path2, hit2) = cache
            .read_or_convert_parts(&conv, &[b"hello ", b"world"], || {
                calls.fetch_add(1, Ordering::Relaxed);
                Ok(b"UNUSED".to_vec())
            })
            .unwrap();
        assert!(hit2);
        assert_eq!(path1, path2);
        assert_eq!(second, b"HELLO WORLD");
        assert_eq!(calls.load(Ordering::Relaxed), 1);
    }
}
