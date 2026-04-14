fn main() {
    std::panic::set_hook(Box::new(|info| {
        let _ = crossterm::terminal::disable_raw_mode();
        eprintln!("{info}");
    }));
    if let Err(err) = rustagent::app::run(std::env::args().skip(1).collect()) {
        eprintln!("Error: {err}");
        std::process::exit(1);
    }
}
