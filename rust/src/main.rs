fn main() {
    if let Err(err) = rustagent::app::run(std::env::args().skip(1).collect()) {
        eprintln!("Error: {err}");
        std::process::exit(1);
    }
}
