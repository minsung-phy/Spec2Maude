#![cfg_attr(target_arch = "wasm32", no_std)]

use core::alloc::Layout;
use core::ptr::NonNull;
use spacewasm::*;

const PROVIDER: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/provider.wasm"));
const ATTACKER_INVALID: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/attacker-invalid.wasm"));
const FUTURE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/future.wasm"));

/// Read the embedded production fixtures without copying them through Rust's
/// standard-library heap. SpaceWasm only reads the returned chunk and gives it
/// back through `return_`; ownership remains with this static byte slice.
struct ByteStream {
    bytes: &'static [u8],
    consumed: bool,
}

impl ByteStream {
    fn new(bytes: &'static [u8]) -> Self {
        Self {
            bytes,
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
            // The parser treats the chunk as input. `return_` does not free it.
            ptr: self.bytes.as_ptr() as *mut u8,
            capacity: self.bytes.len() as u32,
            len: self.bytes.len() as u32,
        }))
    }

    fn return_(&mut self, _chunk: InnerVec<u8>) {}
}

// -------------------------------------------------------------------------
// Allocation
// -------------------------------------------------------------------------

#[cfg(not(target_arch = "wasm32"))]
struct SystemAllocator;

#[cfg(not(target_arch = "wasm32"))]
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

#[cfg(not(target_arch = "wasm32"))]
struct LinearAllocator;

#[cfg(not(target_arch = "wasm32"))]
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

/// A tiny single-threaded bump allocator for the `wasm32` analysis build.
///
/// The previous exact harness linked Rust's full `std` allocator and produced a
/// 143 KiB module whose deterministic initialization dominated Maude's state
/// space. SpaceWasm itself is `no_std`, so the analysis build can allocate
/// directly above `__heap_base` and grow linear memory only when required.
/// This changes allocation strategy, not any SpaceWasm loader/interpreter code.
#[cfg(target_arch = "wasm32")]
struct WasmBump {
    cursor: core::cell::UnsafeCell<usize>,
}

#[cfg(target_arch = "wasm32")]
unsafe impl Sync for WasmBump {}

#[cfg(target_arch = "wasm32")]
impl WasmBump {
    const fn new() -> Self {
        Self {
            cursor: core::cell::UnsafeCell::new(0),
        }
    }

    fn heap_base() -> usize {
        unsafe extern "C" {
            static __heap_base: u8;
        }
        core::ptr::addr_of!(__heap_base) as usize
    }

    unsafe fn reset(&self) {
        unsafe { *self.cursor.get() = Self::heap_base() };
    }

    unsafe fn allocate(&self, layout: Layout) -> Result<*mut u8, AllocError> {
        let cursor = unsafe { *self.cursor.get() };
        let cursor = if cursor == 0 { Self::heap_base() } else { cursor };
        let mask = layout.align() - 1;
        let aligned = cursor
            .checked_add(mask)
            .map(|x| x & !mask)
            .ok_or(AllocError::OutOfMemory)?;
        let end = aligned
            .checked_add(layout.size())
            .ok_or(AllocError::OutOfMemory)?;

        const PAGE: usize = 65_536;
        let current_bytes = core::arch::wasm32::memory_size::<0>() * PAGE;
        if end > current_bytes {
            let missing = end - current_bytes;
            let pages = missing.div_ceil(PAGE);
            if core::arch::wasm32::memory_grow::<0>(pages) == usize::MAX {
                return Err(AllocError::OutOfMemory);
            }
        }

        unsafe { *self.cursor.get() = end };
        Ok(aligned as *mut u8)
    }
}

#[cfg(target_arch = "wasm32")]
static WASM_BUMP: WasmBump = WasmBump::new();

#[cfg(target_arch = "wasm32")]
struct SystemAllocator;

#[cfg(target_arch = "wasm32")]
unsafe impl Allocator for SystemAllocator {
    unsafe fn alloc(&self, layout: Layout) -> Result<*mut u8, AllocError> {
        unsafe { WASM_BUMP.allocate(layout) }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // All allocations made by one exported schedule run are reclaimed by
        // resetting the bump pointer at the next entry. Model-checking paths
        // invoke the export once from an identical initial Wasm state.
    }

    fn memory_statistics(&self) -> MemoryStatistics {
        MemoryStatistics {
            total_bytes: 0,
            pad_bytes: 0,
        }
    }
}

#[cfg(target_arch = "wasm32")]
struct LinearAllocator;

#[cfg(target_arch = "wasm32")]
impl WasmMemoryAllocator for LinearAllocator {
    fn allocate(&self, layout: Layout) -> Result<NonNull<u8>, AllocError> {
        unsafe { NonNull::new(WASM_BUMP.allocate(layout)?).ok_or(AllocError::AllocationFailed) }
    }

    fn reallocate(
        &self,
        ptr: NonNull<u8>,
        old_layout: Layout,
        layout: Layout,
    ) -> Result<NonNull<u8>, AllocError> {
        unsafe {
            let new_ptr = NonNull::new(WASM_BUMP.allocate(layout)?)
                .ok_or(AllocError::AllocationFailed)?;
            core::ptr::copy_nonoverlapping(
                ptr.as_ptr(),
                new_ptr.as_ptr(),
                core::cmp::min(old_layout.size(), layout.size()),
            );
            Ok(new_ptr)
        }
    }

    fn deallocate(&self, _ptr: NonNull<u8>, _layout: Layout) {}
}

spacewasm::global_allocator!(SystemAllocator, SystemAllocator);

#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo<'_>) -> ! {
    core::arch::wasm32::unreachable()
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
    bytes: &'static [u8],
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
    #[cfg(target_arch = "wasm32")]
    unsafe {
        WASM_BUMP.reset();
    }

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

    observed
}

/// Event identifiers are: 0 = rejected attacker load, 1 = valid future load,
/// 2 = provider call_indirect. The return value is the provider's observed
/// result, so the model property is simply `result == 7`; no bug-specific
/// `31337` oracle is embedded in the production driver.
#[unsafe(no_mangle)]
pub extern "C" fn spacewasm_run3(event0: i32, event1: i32, event2: i32) -> i32 {
    run_schedule([event0, event1, event2])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attack_then_future_then_call_hijacks_private_function() {
        assert_eq!(run_schedule([0, 1, 2]), 31337);
    }

    #[test]
    fn call_before_rejected_load_is_not_retroactively_hijacked() {
        assert_eq!(run_schedule([2, 0, 1]), 7);
    }
}
