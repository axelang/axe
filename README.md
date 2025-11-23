# Axe

Axe is a compiled programming language with a focus on type safety, ease of concurrency, and performance. 

It provides a clean syntax for systems programming with modern and parallel language features.

```axe
use std.string;

model Person {
    name: string;
    age: i32;
}

def main() {
    parallel for mut i = 0 to 10 {
        mut person = new Person(name: "Alice", age: i);
        println person.age;
    }
}
```

Documentation on the language can be found [here](https://axe-docs.pages.dev)

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
use std/string;

def greet(name: string): void {
    println "Hello, ", name.data, ".";
}

def main() {
    greet(string.create("Axe"));
}
```

### Game of Life

```
/// Convert 2D coordinate (x, y) into 1D index
def idx(x: i32, y: i32, width: i32): i32 {
    return y * width + x;
}

/// Print the grid (1-D array)
def print_grid(grid: ref i32[], width: i32, height: i32) {
    for mut y = 0; y < height; y++ {
        for mut x = 0; x < width; x++ {
            if grid[idx(x, y, width)] == 1 {
                print "■";
            } else {
                print "□";
            }
        }
        println "";
    }
}

/// Count live neighbors around (x, y)
def count_neighbors(grid: ref i32[], x: i32, y: i32, width: i32, height: i32): i32 {
    mut count: i32 = 0;

    for mut dy = -1; dy <= 1; dy++ {
        for mut dx = -1; dx <= 1; dx++ {
            if dx == 0 and dy == 0 {
                continue;
            }

            val nx = x + dx;
            val ny = y + dy;

            if nx >= 0 and nx < width and ny >= 0 and ny < height {
                if grid[idx(nx, ny, width)] == 1 {
                    count = count + 1;
                }
            }
        }
    }

    return count;
}

/// Compute next generation
def next_generation(grid: ref i32[], new_grid: ref i32[], width: i32, height: i32) {
    for mut y = 0; y < height; y++ {
        for mut x = 0; x < width; x++ {

            val i = idx(x, y, width);
            val neighbors = count_neighbors(grid, x, y, width, height);

            if grid[i] == 1 {
                if neighbors == 2 or neighbors == 3 {
                    new_grid[i] = 1;
                } else {
                    new_grid[i] = 0;
                }
            } else {
                if neighbors == 3 {
                    new_grid[i] = 1;
                } else {
                    new_grid[i] = 0;
                }
            }
        }
    }
}

/// Copy new_grid back into grid
def copy_grid(src: ref i32[], dst: ref i32[], size: i32) {
    for mut i = 0; i < size; i++ {
        dst[i] = src[i];
    }
}

def main() {
    val width: i32 = 20;
    val height: i32 = 20;
    val size: i32 = width * height;

    mut grid: i32[size];
    mut new_grid: i32[size];

    for mut i = 0; i < size; i++ {
        grid[i] = 0;
        new_grid[i] = 0;
    }

    grid[idx(2,1,width)] = 1;
    grid[idx(3,2,width)] = 1;
    grid[idx(1,3,width)] = 1;
    grid[idx(2,3,width)] = 1;
    grid[idx(3,3,width)] = 1;

    println "Conway's Game of Life\n";

    for mut gen = 0; gen < 20; gen++ {
        print "Generation ";
        println gen;
        println "";

        print_grid(grid, width, height);

        next_generation(grid, new_grid, width, height);
        copy_grid(new_grid, grid, size);

        println "\n---\n";
    }
}
```

## Roadmap

- [x] Control flow constructs, functions, variables, fundamentals...
- [x] Immutability by default
- [x] Parallel for
- [x] Union types
- [x] Pure `parallel { ... }` blocks
- [x] Syntax (`single { ... }`) for isolating single threaded behaviours in parallel contexts
- [x] Map and reduce clauses
- [x] Smart type inference based on RHS of exprs.
- [ ] Further memory models beyond arena allocation.