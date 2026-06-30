use lapce_proxy::mainloop;

// mimalloc is faster than the Windows system heap for the proxy's allocation-heavy
// work (file search, reading buffers, plugin/LSP message churn).
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() {
    mainloop();
}
