#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Frontend {
    Gui(Vec<String>),
    Cli(Vec<String>),
    Help,
}

pub fn select_frontend<I>(args: I) -> Frontend
where
    I: IntoIterator<Item = String>,
{
    let mut args = args.into_iter().collect::<Vec<_>>();
    if matches!(args.first().map(String::as_str), Some("-h" | "--help")) {
        return Frontend::Help;
    }
    if matches!(args.first().map(String::as_str), Some("--no-gui")) {
        args.remove(0);
        return Frontend::Cli(args);
    }
    Frontend::Gui(args)
}

pub fn help_text() -> &'static str {
    "usage: rtsyn [--no-gui] [ARGS...]\n\
     \n\
     Without --no-gui, ARGS are passed to the GUI frontend.\n\
     With --no-gui, ARGS are passed to the CLI frontend."
}
