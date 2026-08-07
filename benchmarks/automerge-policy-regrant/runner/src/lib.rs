use automerge::{
    sync::{State, SyncDoc},
    transaction::Transactable,
    ActorId, AutoCommit, ReadDoc, ROOT,
};

#[cfg(getrandom_backend = "custom")]
#[no_mangle]
unsafe extern "Rust" fn __getrandom_v03_custom(
    dest: *mut u8,
    len: usize,
) -> Result<(), getrandom::Error> {
    // The benchmark replaces both actors immediately with fixed IDs.  A deterministic
    // backend keeps the standalone Wasm free of host imports while preserving the
    // production Automerge implementation used below.
    for i in 0..len {
        dest.add(i).write((i as u8).wrapping_mul(17).wrapping_add(11));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Event {
    Revoke = 0,
    Edit = 1,
    Send = 2,
    Regrant = 3,
}

struct System {
    alice: AutoCommit,
    bob: AutoCommit,
    alice_state: State,
    bob_state: State,
    allowed: bool,
    repair_sender_on_unavailable: bool,
}

impl System {
    fn new(repair_sender_on_unavailable: bool) -> Self {
        let mut alice = AutoCommit::new().with_actor(ActorId::from(vec![1]));
        let bob = AutoCommit::new().with_actor(ActorId::from(vec![2]));
        alice.put(ROOT, "value", "initial").unwrap();

        let mut system = Self {
            alice,
            bob,
            alice_state: State::new(),
            bob_state: State::new(),
            allowed: true,
            repair_sender_on_unavailable,
        };
        system.settle(32);
        debug_assert_eq!(system.alice_value(), 1);
        debug_assert_eq!(system.bob_value(), 1);
        system
    }

    fn alice_value(&self) -> i32 {
        value_code(&self.alice)
    }

    fn bob_value(&self) -> i32 {
        value_code(&self.bob)
    }

    fn deliver_alice_to_bob(&mut self) -> bool {
        let message = self
            .alice
            .sync()
            .generate_sync_message(&mut self.alice_state);
        if let Some(message) = message {
            self.bob
                .sync()
                .receive_sync_message(&mut self.bob_state, message)
                .unwrap();
            true
        } else {
            false
        }
    }

    fn deliver_bob_to_alice(&mut self) -> bool {
        let message = self
            .bob
            .sync()
            .generate_sync_message(&mut self.bob_state);
        if let Some(message) = message {
            if self.allowed {
                self.alice
                    .sync()
                    .receive_sync_message(&mut self.alice_state, message)
                    .unwrap();
            } else if self.repair_sender_on_unavailable {
                // Proposed repair for Automerge Repo's `doc-unavailable` handling:
                // start a fresh sync session while preserving shared heads.
                self.bob_state = State::decode(&self.bob_state.encode()).unwrap();
            }
            true
        } else {
            false
        }
    }

    fn settle(&mut self, rounds: usize) -> bool {
        if !self.allowed {
            return false;
        }
        for _ in 0..rounds {
            let a_to_b = self.deliver_alice_to_bob();
            let b_to_a = self.deliver_bob_to_alice();
            if !a_to_b && !b_to_a {
                return true;
            }
        }
        false
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Revoke => {
                // Stable Automerge Repo removes the peer from the active set but retains
                // the per-peer sync State for future sessions.
                self.allowed = false;
            }
            Event::Edit => {
                self.bob
                    .put(ROOT, "value", "made-while-denied")
                    .unwrap();
            }
            Event::Send => {
                // If access is denied, Automerge Repo drops this sync message and replies
                // `doc-unavailable`; the unpatched sender leaves its SyncState untouched.
                self.deliver_bob_to_alice();
            }
            Event::Regrant => {
                self.allowed = true;
                // `DocSynchronizer.beginSync` round-trips only the side that restarts
                // synchronization.  This drops transient fields on Alice, but not on Bob.
                self.alice_state = State::decode(&self.alice_state.encode()).unwrap();
                self.deliver_alice_to_bob();
            }
        }
    }
}

fn value_code(doc: &AutoCommit) -> i32 {
    match doc.get(ROOT, "value").unwrap() {
        Some((value, _)) if value.to_str() == Some("initial") => 1,
        Some((value, _)) if value.to_str() == Some("made-while-denied") => 2,
        _ => 0,
    }
}

fn decode_schedule(mut encoded: u32) -> Option<[Event; 4]> {
    let mut result = [Event::Revoke; 4];
    let mut seen = 0u8;
    for slot in &mut result {
        let digit = (encoded & 0x3) as u8;
        encoded >>= 2;
        let bit = 1u8 << digit;
        if seen & bit != 0 {
            return None;
        }
        seen |= bit;
        *slot = match digit {
            0 => Event::Revoke,
            1 => Event::Edit,
            2 => Event::Send,
            3 => Event::Regrant,
            _ => unreachable!(),
        };
    }
    (seen == 0x0f).then_some(result)
}

fn run(encoded: u32, repaired: bool) -> i32 {
    let Some(events) = decode_schedule(encoded) else {
        return 2;
    };
    let mut system = System::new(repaired);
    for event in events {
        system.event(event);
    }

    // Model a fair, reliable network after the bounded environment events.
    let quiescent = system.settle(32);
    if system.allowed
        && quiescent
        && system.alice_value() != system.bob_value()
    {
        1
    } else {
        0
    }
}

/// Encode four events in two bits each, least-significant event first:
/// 0=revoke, 1=edit, 2=send, 3=regrant.  Each event must appear once.
#[no_mangle]
pub extern "C" fn automerge_policy_schedule(encoded: u32) -> i32 {
    run(encoded, false)
}

#[no_mangle]
pub extern "C" fn automerge_policy_schedule_repaired(encoded: u32) -> i32 {
    run(encoded, true)
}

/// The production counterexample order: revoke -> edit -> send -> regrant.
#[no_mangle]
pub extern "C" fn automerge_policy_counterexample() -> i32 {
    automerge_policy_schedule(0b11_10_01_00)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(events: [Event; 4]) -> u32 {
        events
            .iter()
            .enumerate()
            .fold(0, |acc, (i, event)| acc | ((*event as u32) << (2 * i)))
    }

    fn permutations(mut data: [Event; 4]) -> Vec<[Event; 4]> {
        fn visit(k: usize, data: &mut [Event; 4], out: &mut Vec<[Event; 4]>) {
            if k == data.len() {
                out.push(*data);
                return;
            }
            for i in k..data.len() {
                data.swap(k, i);
                visit(k + 1, data, out);
                data.swap(k, i);
            }
        }
        let mut out = Vec::new();
        visit(0, &mut data, &mut out);
        out
    }

    #[test]
    fn production_order_diverges() {
        assert_eq!(automerge_policy_counterexample(), 1);
    }

    #[test]
    fn repaired_state_has_no_divergent_permutation() {
        let events = [Event::Revoke, Event::Edit, Event::Send, Event::Regrant];
        let mut current_bad = 0;
        let mut repaired_bad = 0;
        for order in permutations(events) {
            current_bad += (automerge_policy_schedule(encode(order)) == 1) as usize;
            repaired_bad +=
                (automerge_policy_schedule_repaired(encode(order)) == 1) as usize;
        }
        assert!(current_bad > 0);
        assert_eq!(repaired_bad, 0);
    }
}
