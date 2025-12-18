fn main() {
    println!("cargo:rustc-check-cfg=cfg(frb_expand)");
    println!("cargo:rerun-if-changed=build.rs");
}
