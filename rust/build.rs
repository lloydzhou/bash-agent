fn main() {
    cc::Build::new()
        .file("vendor/linenoise/linenoise.c")
        .include("vendor/linenoise")
        .flag("-Wall")
        .flag("-O2")
        .compile("linenoise");
}
