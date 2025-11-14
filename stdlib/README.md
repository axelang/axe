# STDLIB Documentation

## Memory Management

### Arena Allocator (`arena.axe`)

Fast, bulk memory allocation with single-call cleanup. Perfect for:
- Temporary computations
- Request/response handling
- Per-frame game allocations
- Compiler passes

**Usage:**
```axe
def process_data() {
    mut val arena = arena_create(1048576);  // 1MB arena
    
    // Fast allocations
    val buffer = arena_alloc(ref_of(arena), 4096);
    val array = arena_alloc_array(ref_of(arena), 4, 1000);
    
    // ... do work ...
    
    // Free everything at once
    arena_destroy(ref_of(arena));
}
```

**API:**
- `arena_create(size: int): Arena` - Create arena with given size
- `arena_destroy(arena: ref Arena)` - Free all memory
- `arena_alloc(arena: ref Arena, size: int): long` - Allocate bytes
- `arena_alloc_array(arena: ref Arena, element_size: int, count: int): long` - Allocate array
- `arena_reset(arena: ref Arena)` - Reset arena without freeing (reuse memory)
- `arena_get_used(arena: ref Arena): int` - Get bytes used
- `arena_get_remaining(arena: ref Arena): int` - Get bytes remaining
