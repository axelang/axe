module axe.compiler;

import axe.lexer;
import axe.parser;
import axe.renderer;
import std.file;
import std.process;
import std.array;
import std.stdio;
import std.algorithm;
import std.string : replace;

void main(string[] args)
{
    if (args.length < 2)
    {
        writeln("usage: axe input.axe");
        writeln("       [-e = emit generated code as file | -asm = emit assembly code]");
        return;
    }

    try
    {
        string name = args[1];
        if (!name.endsWith(".axe"))
        {
            name ~= ".axe";
        }

        string source = readText(name);
        auto tokens = lex(source);
        auto ast = parse(tokens);

        if (args.canFind("-asm"))
        {
            string asmCode = generateAsm(ast);
            std.file.write(replace(name, ".axe", ".asm"), asmCode);
            
            version (Windows)
            {
                execute([
                    "nasm", "-f", "win64", replace(name, ".axe", ".asm"), "-o",
                    replace(name, ".axe", ".o"), "-g"
                ]);
                execute([
                    "gcc", "-g", replace(name, ".axe", ".o"), "-o",
                    replace(name, ".axe", ".exe"), "-mconsole"
                ]);
            }
            else version (Posix)
            {
                execute([
                    "nasm", "-f", "elf64", replace(name, ".axe", ".asm"), "-o",
                    replace(name, ".axe", ".o"), "-g"
                ]);
                execute([
                    "gcc", "-g", "-m64", replace(name, ".axe", ".o"), "-o",
                    replace(name, ".axe", "")
                ]);
            }
            
            if (!args.canFind("-e"))
            {
                remove(replace(name, ".axe", ".asm"));
                remove(replace(name, ".axe", ".o"));
            }
        }
        else
        {
            string cCode = generateC(ast);
            std.file.write(replace(name, ".axe", ".c"), cCode);
            execute([
                "gcc", replace(name, ".axe", ".c"), "-o",
                replace(name, ".axe", ".exe")
            ]);
            if (!args.canFind("-e"))
            {
                remove(replace(name, ".axe", ".c"));
            }
        }
    }
    catch (Exception e)
    {
        stderr.writeln("Error: ", e.msg);
    }
}
