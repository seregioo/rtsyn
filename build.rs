use std::env;
use std::path::PathBuf;

fn split_env_paths(name: &str) -> Vec<PathBuf> {
    env::var_os(name)
        .map(|value| env::split_paths(&value).collect())
        .unwrap_or_default()
}

fn main() {
    println!("cargo:rerun-if-changed=native/daemon_embedded.cpp");
    println!("cargo:rerun-if-env-changed=RTSYN_NATIVE_INCLUDE_DIRS");
    println!("cargo:rerun-if-env-changed=RTSYN_NATIVE_LIB_DIRS");
    println!("cargo:rerun-if-env-changed=RTSYN_NATIVE_LIBS");
    println!("cargo:rerun-if-env-changed=RTSYN_THREAD_CORE");

    let include_dirs = split_env_paths("RTSYN_NATIVE_INCLUDE_DIRS");
    if include_dirs.is_empty() {
        panic!("RTSYN_NATIVE_INCLUDE_DIRS is unset; build rtsyn through xmake");
    }

    let mut build = cc::Build::new();
    build.cpp(true).std("c++23").file("native/daemon_embedded.cpp");
    for include_dir in include_dirs {
        build.include(include_dir);
    }
    build.compile("rtsyn_embedded_daemon");

    let lib_dirs = split_env_paths("RTSYN_NATIVE_LIB_DIRS");
    for lib_dir in &lib_dirs {
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
    }

    let libs = env::var("RTSYN_NATIVE_LIBS").unwrap_or_default();
    for lib in libs.split(',').filter(|lib| !lib.is_empty()) {
        if let Some(archive) = find_static_archive(&lib_dirs, lib) {
            println!("cargo:rerun-if-changed={}", archive.display());
            println!("cargo:rustc-link-lib=static:+whole-archive={lib}");
        } else {
            println!("cargo:rustc-link-lib=static={lib}");
        }
    }

    println!("cargo:rustc-link-lib=dylib=stdc++");
    println!("cargo:rustc-link-lib=dylib=pthread");
    println!("cargo:rustc-link-lib=dylib=dl");
    println!("cargo:rustc-link-lib=dylib=rt");
}

fn find_static_archive(lib_dirs: &[PathBuf], lib: &str) -> Option<PathBuf> {
    let file_name = format!("lib{lib}.a");
    lib_dirs
        .iter()
        .map(|dir| dir.join(&file_name))
        .find(|candidate| candidate.is_file())
}
