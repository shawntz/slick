//! Regenerates `include/slick_core.h` from the crate's source when the `header` feature is on.
//!
//! The header is committed. cbindgen rewrites it only when its content changes, so a no-op Rust
//! build keeps the file's modification time and does not trigger a Swift rebuild.

use std::error::Error;

fn main() -> Result<(), Box<dyn Error>> {
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    #[cfg(feature = "header")]
    generate()?;
    Ok(())
}

#[cfg(feature = "header")]
fn generate() -> Result<(), Box<dyn Error>> {
    use std::path::PathBuf;

    let crate_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?);
    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen.toml"))?;
    let header = crate_dir.join("include").join("slick_core.h");
    let bindings = cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()?;
    // Writes only when the content differs. scripts/build-rust.sh reports the change.
    bindings.write_to_file(&header);
    Ok(())
}
