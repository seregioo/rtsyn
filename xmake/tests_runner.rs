fn main() {
    let mut command = std::process::Command::new("cargo");
    command.arg("test");
    if let Some(workspace) = std::env::var_os("RTSYN_WORKSPACE") {
        let dependency = std::path::PathBuf::from(workspace).join("rtsyn-ui");
        command.arg("--config").arg(format!(
            "patch.\"https://github.com/seregioo/rtsyn-ui.git\".rtsyn-ui.path=\"{}\"",
            dependency.display()
        ));
    }

    let status = command
        .status()
        .expect("failed to run cargo test");
    std::process::exit(status.code().unwrap_or(1));
}
