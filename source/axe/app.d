module axe.app;

import axe.builds;
import axe.meta;
import std.stdio;
import std.algorithm;

void main(string[] args)
{
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
        writeln("  -I<path>      pass an include directory to the C compiler");
        writeln("  --version, -v show axe version and exit");
        writeln("");
        return;
    }
    if (handleMachineArgs(args)) {
        writeln("Compiled.");
    } else {
        writeln("Compilation failed.");
    }
}
