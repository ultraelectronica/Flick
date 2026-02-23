fn main() {
    println!("cargo:rustc-check-cfg=cfg(frb_expand)");
    println!("cargo:rerun-if-changed=build.rs");
    
    // Link against C++ standard library on Android for cpal/oboe
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "android" {
        println!("cargo:rustc-link-lib=c++_shared");
    }
}
