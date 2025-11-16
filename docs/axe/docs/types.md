
## Integer Types

| Axe Type | C Type      | Notes |
|----------|------------|-------|
| i8       | int8_t     | 8-bit signed integer |
| u8       | uint8_t    | 8-bit unsigned integer |
| i16      | int16_t    | 16-bit signed integer |
| u16      | uint16_t   | 16-bit unsigned integer |
| i32      | int32_t    | 32-bit signed integer |
| u32      | uint32_t   | 32-bit unsigned integer |
| i64      | int64_t    | 64-bit signed integer |
| u64      | uint64_t   | 64-bit unsigned integer |
| isize    | intptr_t   | Pointer-sized signed integer |
| usize    | uintptr_t  | Pointer-sized unsigned integer |

## Floating Point Types

| Axe Type | C Type   | Notes |
|----------|---------|-------|
| f32      | float   | 32-bit floating point |
| f64      | double  | 64-bit floating point |

## Boolean & Characters

| Axe Type | C Type | Notes |
|----------|-------|-------|
| bool     | bool  | C99 boolean, true/false |
| char     | char  | 8-bit character |

## Pointers & References

| Axe Type   | C Type        | Notes |
|------------|--------------|-------|
| *T / ref T | T*           | Raw pointer or reference |
| &T         | const T*     | Immutable reference |
| &mut T     | T*           | Mutable reference |

## Optional Convenience Types

| Axe Type | C Type    | Notes |
|----------|----------|-------|
| byte     | uint8_t  | For buffers/data |
| size     | usize    | Array/string sizes, capacities |
| ptrdiff  | isize    | Pointer arithmetic |