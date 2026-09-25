extern crate cc;

fn main() {
    let vendor = std::path::Path::new("vendor/quickjs");
    if !vendor.join("quickjs.h").exists() {
        eprintln!(
            "build.rs: vendor/quickjs not found.\n  Run: scripts/fetch-quickjs.sh\n  or:  mkdir -p vendor && cd vendor && curl ..."
        );
        // 不阻断 build check（仅骨架）；正式编译时 vendor 必须存在
        return;
    }
    let mut build = cc::Build::new();
    for f in &[
        "quickjs.c", "libregexp.c", "libunicode.c", "cutils.c", "libbf.c",
    ] {
        let p = vendor.join(f);
        if p.exists() {
            build.file(p);
        }
    }
    build
        .include(vendor)
        .define("CONFIG_VERSION", "\"ezvjs\"")
        .define("CONFIG_BIGNUM", "1")
        .flag_if_supported("-std=c11")
        .compile("quickjs");
    println!("cargo:rerun-if-changed=vendor/quickjs");
}