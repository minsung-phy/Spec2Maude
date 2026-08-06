use spacewasm::*;
use std::alloc::Layout;
use std::ptr::NonNull;

const PROVIDER: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/provider.wasm"));
const ATTACKER_INVALID: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/attacker-invalid.wasm"));

struct ByteStream {
    bytes: std::vec::Vec<u8>,
    consumed: bool,
}

impl ByteStream {
    fn new(bytes: &[u8]) -> Self {
        Self { bytes: bytes.to_vec(), consumed: false }
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
        if ptr.is_null() { Err(AllocError::OutOfMemory) } else { Ok(ptr) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { std::alloc::dealloc(ptr, layout) }
    }

    fn memory_statistics(&self) -> MemoryStatistics {
        MemoryStatistics { total_bytes: 0, pad_bytes: 0 }
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

fn run_scenario(load_rejected_attacker: bool) -> i32 {
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

    let before = engine.store.get_table(provider_ref)[0];
    let before_is_provider = matches!(
        before,
        TableElement::Func { module, index: 0 } if module == provider_ref
    );
    if !before_is_provider {
        return 2;
    }

    let mut rejected = false;
    if load_rejected_attacker {
        rejected = load(
            "attacker",
            ATTACKER_INVALID,
            &mut engine,
            &mut builder,
            alloc,
        )
        .is_err();
    }

    let module_count = engine.store.modules().len();
    let after = engine.store.get_table(provider_ref)[0];
    let dangling = matches!(
        after,
        TableElement::Func { module, index: 0 }
            if module.0 as usize >= module_count
    );

    if rejected && dangling { 1 } else { 0 }
}

/// Scenario 0 loads only the valid provider. Scenario 1 then attempts to load
/// a malformed module whose active element section has already written into
/// the provider's imported table. Returning 1 means a rejected module left a
/// dangling executable capability in a previously accepted module.
#[no_mangle]
pub extern "C" fn rejected_load_poisoned(scenario: i32) -> i32 {
    run_scenario(scenario != 0)
}

/// Invoke the provider's indirect call after the rejected attacker load. The
/// current SpaceWasm implementation indexes a nonexistent module and therefore
/// panics/traps. This export is a concrete impact witness, while
/// `rejected_load_poisoned` is the model-checking predicate.
#[no_mangle]
pub extern "C" fn invoke_after_rejected_load() -> i32 {
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
    assert!(load(
        "attacker",
        ATTACKER_INVALID,
        &mut engine,
        &mut builder,
        alloc,
    )
    .is_err());

    // Function 1 is provider.call. Its call_indirect reads the poisoned slot.
    engine.invoke(WasmRef { module: provider_ref, index: 1 }, &[]).unwrap();
    match Interpreter.run(builder.pages(), &mut engine, 1000) {
        InterpreterResult::Finished => engine.result.map(|v| v.read_i32()).unwrap_or(-1),
        _ => -2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejected_module_poison_is_observable() {
        assert_eq!(rejected_load_poisoned(0), 0);
        assert_eq!(rejected_load_poisoned(1), 1);
    }

    #[test]
    #[should_panic]
    fn rejected_module_crashes_later_indirect_call() {
        let _ = invoke_after_rejected_load();
    }
}
