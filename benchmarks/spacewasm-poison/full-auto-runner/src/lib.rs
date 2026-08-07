#![no_std]

use core::alloc::Layout;
use core::panic::PanicInfo;
use core::ptr::{addr_of_mut, copy_nonoverlapping, NonNull};
use core::sync::atomic::{AtomicUsize, Ordering};
use spacewasm::*;

const PROVIDER: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/provider.wasm"));
const ATTACKER_INVALID: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/attacker-invalid.wasm"));
const FUTURE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/future.wasm"));

// A bounded monotonic arena is enough for this one-shot three-module scenario.
// It avoids linking Rust's general-purpose allocator into the Wasm program,
// while the exact SpaceWasm parser/compiler/interpreter code remains unchanged.
const ARENA_SIZE: usize = 4 * 1024 * 1024;
static NEXT: AtomicUsize = AtomicUsize::new(0);
static mut ARENA: [u8; ARENA_SIZE] = [0; ARENA_SIZE];

fn arena_allocate(layout: Layout) -> Result<*mut u8, AllocError> {
    let align = layout.align();
    let size = layout.size();
    loop {
        let old = NEXT.load(Ordering::Relaxed);
        let aligned = old
            .checked_add(align - 1)
            .map(|n| n & !(align - 1))
            .ok_or(AllocError::OutOfMemory)?;
        let end = aligned
            .checked_add(size)
            .ok_or(AllocError::OutOfMemory)?;
        if end > ARENA_SIZE {
            return Err(AllocError::OutOfMemory);
        }
        if NEXT
            .compare_exchange_weak(old, end, Ordering::SeqCst, Ordering::Relaxed)
            .is_ok()
        {
            let base = addr_of_mut!(ARENA).cast::<u8>();
            return Ok(unsafe { base.add(aligned) });
        }
    }
}

struct ArenaAllocator;

unsafe impl Allocator for ArenaAllocator {
    unsafe fn alloc(&self, layout: Layout) -> Result<*mut u8, AllocError> {
        arena_allocate(layout)
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // Monotonic by design: all memory dies with the one-shot execution.
    }

    fn memory_statistics(&self) -> MemoryStatistics {
        MemoryStatistics {
            total_bytes: NEXT.load(Ordering::Relaxed),
            pad_bytes: 0,
        }
    }
}

spacewasm::global_allocator!(ArenaAllocator, ArenaAllocator);

struct LinearAllocator;

impl WasmMemoryAllocator for LinearAllocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<u8>, AllocError> {
        NonNull::new(arena_allocate(layout)?).ok_or(AllocError::AllocationFailed)
    }

    fn reallocate(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        layout: Layout,
    ) -> Result<NonNull<u8>, AllocError> {
        let new_ptr = NonNull::new(arena_allocate(layout)?)
            .ok_or(AllocError::AllocationFailed)?;
        unsafe {
            copy_nonoverlapping(
                ptr.as_ptr(),
                new_ptr.as_ptr(),
                core::cmp::min(old_layout.size(), layout.size()),
            );
        }
        Ok(new_ptr)
    }

    fn deallocate(&self, _ptr: NonNull<u8>, _layout: Layout) {}
}

struct StaticStream {
    bytes: &'static [u8],
    consumed: bool,
}

impl StaticStream {
    const fn new(bytes: &'static [u8]) -> Self {
        Self {
            bytes,
            consumed: false,
        }
    }
}

impl WasmStream for StaticStream {
    fn read(&mut self) -> Result<Option<InnerVec<u8>>, u8> {
        if self.consumed {
            return Ok(None);
        }
        self.consumed = true;
        Ok(Some(InnerVec {
            // SpaceWasm only reads the input chunk.  Avoiding a defensive copy
            // substantially reduces the number of modeled Wasm instructions.
            ptr: self.bytes.as_ptr() as *mut u8,
            capacity: self.bytes.len() as u32,
            len: self.bytes.len() as u32,
        }))
    }

    fn return_(&mut self, _chunk: InnerVec<u8>) {}
}

fn code_builder() -> CodeBuilder {
    CodeBuilder::new(CompilerOptions {
        allow_memory_grow: true,
        max_backpatch_iterations: 0,
        max_code_pages: 8,
    })
    .unwrap()
}

fn memory_allocator() -> Rc<dyn WasmMemoryAllocator> {
    Rc::new(LinearAllocator)
        .unwrap()
        .into_wasm_memory_allocator()
}

fn load(
    name: &str,
    bytes: &'static [u8],
    engine: &mut Engine,
    builder: &mut CodeBuilder,
    allocator: Rc<dyn WasmMemoryAllocator>,
) -> Result<Module, ParseError> {
    let mut stream = StaticStream::new(bytes);
    Module::new::<32, 64>(
        name,
        &mut stream,
        &mut engine.store,
        builder,
        allocator,
    )
}

fn invoke_provider(
    engine: &mut Engine,
    builder: &CodeBuilder,
    provider_ref: ModuleRef,
) -> i32 {
    // Function 1 is provider.call and performs call_indirect through slot 0.
    if engine
        .invoke(
            WasmRef {
                module: provider_ref,
                index: 1,
            },
            &[],
        )
        .is_err()
    {
        return -1;
    }
    match Interpreter.run(builder.pages(), engine, 1000) {
        InterpreterResult::Finished => engine.result.map(|v| v.read_i32()).unwrap_or(-2),
        _ => -3,
    }
}

fn run_schedule(events: [i32; 3]) -> i32 {
    let mut engine = match Engine::new(256, 4, spacewasm::Vec::zero()) {
        Ok(engine) => engine,
        Err(_) => return -10,
    };
    let mut builder = code_builder();
    let allocator = memory_allocator();

    let provider = match load(
        "provider",
        PROVIDER,
        &mut engine,
        &mut builder,
        allocator.clone(),
    ) {
        Ok(module) => module,
        Err(_) => return -11,
    };
    let provider_ref = match engine.push_module(provider) {
        Ok(reference) => reference,
        Err(_) => return -12,
    };

    let mut observed = 0;
    for event in events {
        match event {
            0 => {
                // The malformed module mutates provider.table while processing
                // its active element section, then fails in the later code section.
                if load(
                    "attacker",
                    ATTACKER_INVALID,
                    &mut engine,
                    &mut builder,
                    allocator.clone(),
                )
                .is_ok()
                {
                    return -20;
                }
            }
            1 => {
                let future = match load(
                    "future",
                    FUTURE,
                    &mut engine,
                    &mut builder,
                    allocator.clone(),
                ) {
                    Ok(module) => module,
                    Err(_) => return -21,
                };
                if engine.push_module(future).is_err() {
                    return -22;
                }
            }
            2 => observed = invoke_provider(&mut engine, &builder, provider_ref),
            _ => return -30,
        }
    }

    if observed == 31337 { 1 } else { 0 }
}

/// 0 = rejected attacker load, 1 = later valid future load,
/// 2 = provider call_indirect.  The return value 1 denotes a private-function
/// hijack.  The full NASA SpaceWasm implementation computes the result.
#[no_mangle]
pub extern "C" fn spacewasm_run3(event0: i32, event1: i32, event2: i32) -> i32 {
    run_schedule([event0, event1, event2])
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    core::arch::wasm32::unreachable()
}
