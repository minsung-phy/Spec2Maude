use std::{env, fs, path::PathBuf};

fn read_uleb(bytes: &[u8], mut at: usize) -> (usize, usize) {
    let start = at;
    loop {
        let b = bytes[at];
        at += 1;
        if b & 0x80 == 0 {
            return (at - start, at);
        }
    }
}

fn corrupt_code_vector_count(mut wasm: Vec<u8>) -> Vec<u8> {
    assert_eq!(&wasm[..4], b"\0asm");
    let mut at = 8;
    while at < wasm.len() {
        let section_id = wasm[at];
        at += 1;
        let (_, after_len) = read_uleb(&wasm, at);
        let mut p = at;
        let mut size = 0usize;
        let mut shift = 0;
        loop {
            let b = wasm[p];
            p += 1;
            size |= ((b & 0x7f) as usize) << shift;
            if b & 0x80 == 0 {
                break;
            }
            shift += 7;
        }
        let payload = after_len;
        if section_id == 10 {
            // The active element segment has already been decoded when the
            // code section claims zero bodies although the function section
            // declared one. SpaceWasm rejects with
            // InvalidCodeSectionFunctionCount after the table write.
            assert_eq!(wasm[payload], 1);
            wasm[payload] = 0;
            return wasm;
        }
        at = payload + size;
    }
    panic!("code section not found");
}

fn main() {
    println!("cargo:rerun-if-changed=../provider.wat");
    println!("cargo:rerun-if-changed=../attacker.wat");
    println!("cargo:rerun-if-changed=../future.wat");

    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let provider = wat::parse_file("../provider.wat").unwrap();
    let attacker_valid = wat::parse_file("../attacker.wat").unwrap();
    let attacker_invalid = corrupt_code_vector_count(attacker_valid);
    let future = wat::parse_file("../future.wat").unwrap();

    fs::write(out.join("provider.wasm"), provider).unwrap();
    fs::write(out.join("attacker-invalid.wasm"), attacker_invalid).unwrap();
    fs::write(out.join("future.wasm"), future).unwrap();
}
