#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use lapce_app::app;

// mimalloc is faster than the Windows system heap for the editor's allocation-heavy
// work (rope edits, syntax highlighting, completion/fuzzy matching, rendering).
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

pub fn main() {
    app::launch();
}
