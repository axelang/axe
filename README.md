# Axe

<p style="text-align: center;"><img src="docs/axe/docs/assets/axe.png" width="256"></p>

Axe is a compiled programming language with a focus on type safety, ease of concurrency, and performance. 

It began as a re-engineering of Scar, though evolved into its own entity later on. Axe provides a clean syntax for systems programming with modern language features.

## Features

- **Type Safety**: Safe by default
- **Parallelism at the core of the language** Supports parallelism at the language level, making it easy to write programs that can take advantage of multiple CPU cores.
- **Clean Syntax**: Intuitive syntax inspired by modern languages
- **Standard Library**: Built-in support for numerous data structures and utilities
- **Cross-platform**: Works on Windows, macOS, and Linux
- **Fast Compilation**: Optimized build system for quick iteration

### Language Features

- Functions and variables, immutability by default
- Control flow (if/else, for loops, `loop` construct)
- Pointers and memory management with high level abstractions
- Parallel processing support at the core of the language
- Built-in println for debugging

## Installation

### Prerequisites

- [Clang compiler](https://clang.llvm.org/)

### Building from Source

```bash
git clone https://github.com/navid-m/axe.git
cd axe
dub build
```

This will create the `axe` executable.

## Usage

### Compiling Axe Programs

```bash
# Compile and run a program
./axe hello.axe -r

# Compile to executable
./axe hello.axe

# Compile for release (optimized)
./axe hello.axe --release -r

# Compile to shared library
./axe mylib.axec -dll
```

## Language Syntax

### Hello World

```
def greet(name: string): void {
    println "Hello, ", name, ".";
}

main {
    greet("Axe");
}
```

### Variables and Types

```
main {
    val x: i32 = 42;
    mut val y: i32 = 10;

    y = y + x;
    println y;
}
```

### Control Flow

```
main {
    val x = 5;

    if x > 3 {
        println "x is greater than 3";
    } else {
        println "x is not greater than 3";
    }

    for val i = 0; i < 5; i++ {
        println i;
    }
}
```

### Arrays

```
main {
    val arr: i32[5] = {1, 2, 3, 4, 5};

    for val i = 0; i < 5; i++ {
        println arr[i];
    }
}
```

### Structs

```
model Person {
    name: string;
    age: i32;
}

main {
    val person = new Person(name: "Alice", age: 30);
    println person.name;
}
```

## Standard Library

Axe includes a standard library with common utilities:

- **arena**: Memory arena allocation
- **string**: String manipulation functions
- **lists**: Dynamic arrays and lists

(WIP)
