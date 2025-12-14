# Axe

Axe is a compiled programming language with a focus on type safety, ease of concurrency, and performance.

It provides a clean syntax for systems programming with modern and parallel language features.

```axe
use std.io;
use std.string;

model Person {
    name: string;
    age:  i32;
}

def main() {
    parallel for mut i = 0 to 10 {
        val person = Person{name: "Alice", age: i};
        println person.age;
    }
}
```

## Getting Started

- [Latest release of the Axe compiler](https://github.com/axelang/axe/releases)
- [Documentation on the language](https://axe-docs.pages.dev)
- [The Visual Studio Code extension for Axe](https://marketplace.visualstudio.com/items?itemName=NavidM.axe-programming-language)
- [The LSP, namely Axels](https://github.com/axelang/axels/releases/), installation involves just downloading it and adding it to PATH.
- [Saw, a build tool and package manager for Axe](https://github.com/axelang/saw/releases)

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

### Prerequisite

[Clang compiler](https://clang.llvm.org/)

### Building from Source

There are two ways to build from source without already having an `axe` binary, one involves cloning tag v0.0.0, and building with `dub build`, though you can also clone <https://github.com/axelang/axe-bootstrap.git> to get axe latest on POSIX systems.

#### Bootstrapping process

Use the install script to get axe running on your POSIX system.

The install script will:

- download and install clang
- download the axe bootstrap repo
- generate axe binary from bootstrap repo
- copy the axe binary and its dependencies to /urs/local/bin
- clean up and delete the downloaded bootstrap repo

```bash
chmod +x ./bootstrap/install.sh
./bootstrap/install.sh
```

If you already have an axe binary (recommended - download from release v0.0.5), the build process is simply:

```bash
git clone https://github.com/axelang/axe.git
cd axe/source/compiler
axe axc -o axe --release
```

Or use `saw build --release` with the saw build tool.

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
./axe mylib.axe -dll
```

## Language Syntax

### Hello World

```
use std.string;

def greet(name: string): void {
    println $"Hello, {name}";
}

def main() {
    greet(str("Axe"));
}
```

### Tagged Unions

Axe supports tagged unions, allowing a value to take one of several typed forms.
Each variant has its own fields, and the active variant is determined by the tag:

```axe
model Expr {
    tag: string;

    data: union {
        literal: model { value: i32 };
        variable: model { name: string };
        binary: model { op: string; left: Expr; right: Expr };
    };
}

def main() {
    val x = Expr{
        tag: "literal",
        data: literal{ value: 42 }
    };

    println x.data.literal.value;  // 42
}
```

Tagged unions provide a safe and expressive way to model AST nodes, protocol messages, and other variant-based structures.

### Generics (new in v0.0.6)

Generics in Axe allow writing of functions and models that operate on different types while maintaining type safety. You can specify type parameters using square brackets `[T]`, and use type-specific logic with `when` clauses.

```
use std.io;
use std.string;

model SomeModel {
    pub def some_function[T](arg: T): T {
        when T is i32 {
            return arg + 1;
        }
        when T is f32 {
            return arg * 2.0;
        }
        when T is string {
            return concat_c(arg, "!\n");
        }
    }
}

def main() {
    println(SomeModel.some_function[i32](5));
    println(SomeModel.some_function[f32](5.0));
    println(SomeModel.some_function[string](str("Hello")));
    println(SomeModel.some_function(3.0));
}
```

### Game of Life

```
use std.io;

/// Convert 2D coordinate (x, y) into 1D index
def idx(x: i32, y: i32, width: i32): i32 {
    return y * width + x;
}

/// Print the grid (1-D list)
def print_grid(grid: ref list(i32), width: i32, height: i32) {
    for mut y = 0; y < height; y++ {
        for mut x = 0; x < width; x++ {
            if grid.data[idx(x, y, width)] == 1 {
                print "■";
            } else {
                print "□";
            }
        }
        println "";
    }
}

/// Count live neighbors around (x, y)
def count_neighbors(grid: ref list(i32), x: i32, y: i32, width: i32, height: i32): i32 {
    mut count: i32 = 0;

    for mut dy = -1; dy <= 1; dy++ {
        for mut dx = -1; dx <= 1; dx++ {
            if dx == 0 and dy == 0 {
                continue;
            }

            val nx = x + dx;
            val ny = y + dy;

            if nx >= 0 and nx < width and ny >= 0 and ny < height {
                if grid.data[idx(nx, ny, width)] == 1 {
                    count++;
                }
            }
        }
    }

    return count;
}

/// Compute next generation
def next_generation(grid: ref list(i32), new_grid: ref list(i32), width: i32, height: i32) {
    for mut y = 0; y < height; y++ {
        for mut x = 0; x < width; x++ {

            val i = idx(x, y, width);
            val neighbors = count_neighbors(grid, x, y, width, height);

            if grid.data[i] == 1 {
                if neighbors == 2 or neighbors == 3 {
                    new_grid.data[i] = 1;
                } else {
                    new_grid.data[i] = 0;
                }
            } else {
                if neighbors == 3 {
                    new_grid.data[i] = 1;
                } else {
                    new_grid.data[i] = 0;
                }
            }
        }
    }
}

/// Copy new_grid back into grid
def copy_grid(src: ref list(i32), dst: ref list(i32), size: i32) {
    for mut i = 0; i < size; i++ {
        dst.data[i] = src.data[i];
    }
}

def main() {
    val width: i32 = 20;
    val height: i32 = 20;
    val size: i32 = width * height;

    mut grid: list(i32);
    mut new_grid: list(i32);

    for mut i = 0; i < size; i++ {
        append(grid, 0);
        append(new_grid, 0);
    }

    grid.data[idx(2,1,width)] = 1;
    grid.data[idx(3,2,width)] = 1;
    grid.data[idx(1,3,width)] = 1;
    grid.data[idx(2,3,width)] = 1;
    grid.data[idx(3,3,width)] = 1;

    println "Conway's Game of Life\n";

    for mut gen = 0; gen < 20; gen++ {
        print "Generation ";
        println gen;
        println "";

        print_grid(addr(grid), width, height);

        next_generation(addr(grid), addr(new_grid), width, height);
        copy_grid(addr(new_grid), addr(grid), size);

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
