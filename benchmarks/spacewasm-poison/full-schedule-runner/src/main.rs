use std::process::ExitCode;

fn parse_event(arg: Option<String>, name: &str) -> Result<i32, String> {
    let text = arg.ok_or_else(|| format!("missing {name}"))?;
    let event = text
        .parse::<i32>()
        .map_err(|_| format!("invalid {name}: {text}"))?;
    if !(0..=2).contains(&event) {
        return Err(format!("{name} must be 0, 1, or 2"));
    }
    Ok(event)
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let event0 = match parse_event(args.next(), "event0") {
        Ok(value) => value,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(2);
        }
    };
    let event1 = match parse_event(args.next(), "event1") {
        Ok(value) => value,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(2);
        }
    };
    let event2 = match parse_event(args.next(), "event2") {
        Ok(value) => value,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::from(2);
        }
    };
    if args.next().is_some() {
        eprintln!("expected exactly three events");
        return ExitCode::from(2);
    }

    let result = spacewasm_full_schedule_runner::spacewasm_run3(event0, event1, event2);
    println!("result={result}");
    ExitCode::SUCCESS
}
