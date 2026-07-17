#![no_main]
use inferno::collapse::guess::Folder as Guess;
use inferno::collapse::sample::Folder as Sample;
use inferno::collapse::vsprof::Folder as Vsprof;
use inferno::collapse::vtune::Folder as Vtune;
use inferno::collapse::Collapse;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    // is_applicable expects at least one input line; vsprof's panics (.expect) on
    // fully-empty input, so skip the trivial empty case (nothing to collapse anyway).
    if data.is_empty() {
        return;
    }
    // Guess::is_applicable is unreachable!() by design (the guesser probes the
    // other folders itself), so only run its collapse path — it dispatches to
    // every concrete folder (perf, dtrace, sample, vtune, vsprof, ghcprof, xctrace).
    collapse_only(data, Guess::default());
    fuzz_folder(data, Sample::default());
    fuzz_folder(data, Vsprof::default());
    fuzz_folder(data, Vtune::default());
});

fn fuzz_folder(data: &str, mut folder: impl Collapse) {
    let _ = folder.is_applicable(data);
    collapse_only(data, folder);
}

fn collapse_only(data: &str, mut folder: impl Collapse) {
    let sink = std::io::sink();
    let cursor = std::io::Cursor::new(data);
    let _ = folder.collapse(cursor, sink);
}
