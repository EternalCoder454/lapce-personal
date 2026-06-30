use std::{path::PathBuf, sync::atomic::AtomicU64};

use criterion::{Criterion, black_box, criterion_group, criterion_main};
use lapce_proxy::dispatch::search_in_path;
use walkdir::WalkDir;

/// Collect the editor's own `.rs` sources as a realistic multi-hundred-file
/// search workload.
fn rs_files() -> Vec<PathBuf> {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../lapce-app/src");
    WalkDir::new(root)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "rs").unwrap_or(false))
        .map(|e| e.path().to_path_buf())
        .collect()
}

fn bench_search(c: &mut Criterion) {
    let files = rs_files();
    assert!(!files.is_empty(), "no source files found to search");
    let current_id = AtomicU64::new(1);

    c.bench_function("global_search lapce-app/src \"fn \"", |b| {
        b.iter(|| {
            let r = search_in_path(
                1,
                &current_id,
                black_box(files.clone()).into_iter(),
                black_box("fn "),
                false, // case_sensitive
                false, // whole_word
                false, // is_regex
            );
            black_box(r.is_ok())
        })
    });
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
