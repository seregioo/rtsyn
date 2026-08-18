use rtsyn::Frontend;

#[test]
fn selects_gui_by_default() {
    assert_eq!(
        rtsyn::select_frontend(["--workspace".to_string(), "plant.toml".to_string()]),
        Frontend::Gui(vec!["--workspace".to_string(), "plant.toml".to_string()])
    );
}

#[test]
fn selects_cli_when_no_gui_flag_is_present() {
    assert_eq!(
        rtsyn::select_frontend(["--no-gui".to_string(), "health".to_string()]),
        Frontend::Cli(vec!["health".to_string()])
    );
}

#[test]
fn selects_help() {
    assert_eq!(
        rtsyn::select_frontend(["--help".to_string()]),
        Frontend::Help
    );
}
