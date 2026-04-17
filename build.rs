#[cfg(target_os = "linux")]
use std::path::PathBuf;

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn link_sysroot() {
    let sysroot_path = PathBuf::from("./chromium/src/build/linux/debian_bullseye_amd64-sysroot");

    if sysroot_path.is_dir() {
        println!("cargo:rustc-link-search=chromium/src/build/linux/debian_bullseye_amd64-sysroot/lib/x86_64-linux-gnu");
        println!("cargo:rustc-link-search=chromium/src/build/linux/debian_bullseye_amd64-sysroot/usr/lib/x86_64-linux-gnu");

        println!(
            "cargo:rustc-link-arg=--sysroot=./chromium/src/build/linux/debian_bullseye_amd64-sysroot"
        );
    } else {
        println!("cargo:warning={}", "x86_64 debian sysroot provided by chromium was not found!");
        println!("cargo:warning={}", "carbonyl may fail to link against a proper libc!");
    }
}

#[cfg(all(target_os = "linux", target_arch = "x86"))]
fn link_sysroot() {
    let sysroot_path = PathBuf::from("./chromium/src/build/linux/debian_bullseye_i386-sysroot");

    if sysroot_path.is_dir() {
        println!("cargo:rustc-link-search=chromium/src/build/linux/debian_bullseye_i386-sysroot/lib/i386-linux-gnu");
        println!("cargo:rustc-link-search=chromium/src/build/linux/debian_bullseye_i386-sysroot/usr/lib/i386-linux-gnu");

        println!(
            "cargo:rustc-link-arg=--sysroot=./chromium/src/build/linux/debian_bullseye_i386-sysroot"
        );
    } else {
        println!("cargo:warning={}", "x86 debian sysroot provided by chromium was not found!");
        println!("cargo:warning={}", "carbonyl may fail to link against a proper libc!");
    }
}

#[cfg(not(all(target_os = "linux", any(target_arch = "x86_64", target_arch = "x86"))))]
fn link_sysroot() {
    // Intentionally left blank. Sysroot linking is a Linux-only concern tied to
    // the Debian sysroot shipped under chromium/src/build/linux/.
}

fn main() {
    link_sysroot();
}
