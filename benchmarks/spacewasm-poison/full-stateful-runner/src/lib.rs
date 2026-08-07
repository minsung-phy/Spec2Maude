#![no_std]

use core::alloc::Layout;
use core::mem::MaybeUninit;
use core::panic::PanicInfo;
use core::ptr::{addr_of_mut, copy_nonoverlapping, NonNull};
use core::sync::atomic::{AtomicUsize, Ordering};
use spacewasm::*;

const PROVIDER: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/provider.wasm"));
const ATTACKER_INVALID: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/attacker-invalid.wasm"));
const FUTURE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/future.wasm"));

const ARENA_SIZE: usize = 4 * 1024 * 1024;
static NEXT: AtomicUsize = AtomicUsize::new(0);
static mut ARENA: [u8; ARENA_SIZE] = [0; ARENA_SIZE];

fn arena_allocate(layout: Layout) -> Result<*mut u8, AllocError> {
    let align = layout.align();
    loop {
        let old = NEXT.load(Ordering::Relaxed);
        let aligned = old
            .checked_add(align - 1)
            .map(|n| n & !(align - 1))
            .ok_or(AllocError::OutOfMemory)?;
        let end = aligned
            .checked_add(layout.size())
            .ok_or(AllocError::OutOfMemory)?;
        if end > ARENA_SIZE {
            return Err(AllocError::OutOfMemory);
        }
        if NEXT
            .compare_exchange_weak(old, end, Ordering::SeqCst, Ordering::Relaxed)
            .is_ok()
        {
            return Ok(unsafe { addr_of_mut!(ARENA).cast::<u8>().add(aligned) });
        }
    }
}

struct ArenaAllocator;

unsafe impl Allocator for ArenaAllocator {
    unsafe fn alloc(&self, layout: Layout) -> Result<*mut u8, AllocError> {
        arena_allocate(layout)
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}

    fn memory_statistics(&self) -> MemoryStatistics {
        MemoryStatistics {
            total_bytes: NEXT.load(Ordering::Relaxed) as _,
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
            ptr: self.bytes.as_ptr() as *mut u8,
            capacity: self.bytes.len() as u32,
            len: self.bytes.len() as u32,
        }))
    }

    fn return_(&mut self, _chunk: InnerVec<u8>) {}
}

struct Context {
    engine: Engine,
    builder: CodeBuilder,
    allocator: Rc<dyn WasmMemoryAllocator>,
    provider: ModuleRef,
    observed: i32,
}

static mut CONTEXT: MaybeUninit<Context> = MaybeUninit::uninit();
static mut INITIALIZED: bool = false;

unsafe fn context_mut() -> &'static mut Context {
    unsafe { &mut *addr_of_mut!(CONTEXT).cast::<Context>() }
}

fn code_builder() -> Result<CodeBuilder, i32> {
    CodeBuilder::new(CompilerOptions {
        allow_memory_grow: true,
        max_backpatch_iterations: 0,
        max_code_pages: 8,
    })
    .map_err(|_| -1)
}

fn memory_allocator() -> Result<Rc<dyn WasmMemoryAllocator>, i32> {
    Rc::new(LinearAllocator)
        .map(|allocator| allocator.into_wasm_memory_allocator())
        .map_err(|_| -2)
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

fn invoke_provider(context: &mut Context) -> i32 {
    if context
        .engine
        .invoke(
            WasmRef {
                module: context.provider,
                index: 1,
            },
            &[],
        )
        .is_err()
    {
        return -1;
    }
    match Interpreter.run(&context.builder.pages(), &mut context.engine, 1000) {
        InterpreterResult::Finished => context
            .engine
            .result
            .map(|value| value.read_i32())
            .unwrap_or(-2),
        _ => -3,
    }
}

/// Prepare the exact SpaceWasm engine and load the initial provider once.
#[no_mangle]
pub extern "C" fn spacewasm_init() -> i32 {
    unsafe {
        if INITIALIZED {
            return -100;
        }
    }

    let mut engine = match Engine::new(256, 4, spacewasm::Vec::zero()) {
        Ok(engine) => engine,
        Err(_) => return -10,
    };
    let mut builder = match code_builder() {
        Ok(builder) => builder,
        Err(code) => return code,
    };
    let allocator = match memory_allocator() {
        Ok(allocator) => allocator,
        Err(code) => return code,
    };
    let provider_module = match load(
        "provider",
        PROVIDER,
        &mut engine,
        &mut builder,
        allocator.clone(),
    ) {
        Ok(module) => module,
        Err(_) => return -11,
    };
    let provider = match engine.push_module(provider_module) {
        Ok(reference) => reference,
        Err(_) => return -12,
    };

    unsafe {
        addr_of_mut!(CONTEXT).write(MaybeUninit::new(Context {
            engine,
            builder,
            allocator,
            provider,
            observed: 0,
        }));
        INITIALIZED = true;
    }
    0
}

/// Apply one environment event to the persistent exact SpaceWasm state.
/// 0 = rejected attacker load, 1 = valid future load, 2 = provider call.
#[no_mangle]
pub extern "C" fn spacewasm_event(event: i32) -> i32 {
    unsafe {
        if !INITIALIZED {
            return -101;
        }
        let context = context_mut();
        match event {
            0 => {
                if load(
                    "attacker",
                    ATTACKER_INVALID,
                    &mut context.engine,
                    &mut context.builder,
                    context.allocator.clone(),
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
                    &mut context.engine,
                    &mut context.builder,
                    context.allocator.clone(),
                ) {
                    Ok(module) => module,
                    Err(_) => return -21,
                };
                if context.engine.push_module(future).is_err() {
                    return -22;
                }
            }
            2 => context.observed = invoke_provider(context),
            _ => return -30,
        }
    }
    0
}

#[no_mangle]
pub extern "C" fn spacewasm_bad() -> i32 {
    unsafe {
        if !INITIALIZED {
            return 0;
        }
        if context_mut().observed == 31337 { 1 } else { 0 }
    }
}

#[no_mangle]
pub extern "C" fn spacewasm_observed() -> i32 {
    unsafe {
        if !INITIALIZED {
            return 0;
        }
        context_mut().observed
    }
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    core::arch::wasm32::unreachable()
}
