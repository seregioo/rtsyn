use rtsyn::Frontend;

fn main() {
    match rtsyn::select_frontend(std::env::args().skip(1)) {
        Frontend::Help => {
            println!("{}", rtsyn::help_text());
        }
        Frontend::Gui(args) => {
            if !args.is_empty() {
                eprintln!("error: GUI does not accept extra arguments yet");
                std::process::exit(1);
            }
            if let Err(error) = rtsyn_ui::gui::run_gui(rtsyn_ui::gui::GuiConfig::default()) {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        }
        Frontend::Cli(args) => match rtsyn_ui::rtsyn_cli::run(args) {
            Ok(output) => println!("{output}"),
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
    }
}
