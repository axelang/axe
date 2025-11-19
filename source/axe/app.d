/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * The entry point for the Axe compiler.
 */

module axe.app;

import axe.builds;
import axe.meta;
import axe.gstate;
import std.stdio;
import std.algorithm;

void main(string[] args)
{
    Logger.quietMode = !args.canFind("--loud") && !args.canFind("-l");
    if (args.canFind("--version") || args.canFind("-v") || args.canFind("--about"))
    {
        writeln(ver ~ "\n" ~ about);
        return;
    }
    if (args.length < 2 || args.canFind("-h") || args.canFind("--help"))
    {
        writeln("usage: axe <input.axe|axec> [options]");
        writeln;
        writeln("Options:");
        writeln("  -asm          emit assembly and assemble/link/run it (requires nasm)");
        writeln("  -e            keep the emitted file");
        writeln("  -r            run the built executable after compilation");
        writeln("  -tokens       print lexer tokens and exit");
        writeln("  -ast          print the parsed AST and exit");
        writeln("  -dll          build shared instead of standalone executable");
        writeln("  --release     build in release mode");
        writeln("  -q, --quiet   suppress debug output");
        writeln("  -I<path>      pass a C include directory");
        writeln("  --version, -v show axe version and exit");
        writeln("");
        return;
    }
    if (handleMachineArgs(args) && !args.canFind("-r")) {
        writeln("Compiled.");
    } else if (!args.canFind("-r")){
        writeln("Compilation failed.");
    }
}
