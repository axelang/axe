module axe.builds;

import axe.lexer;
import axe.parser;
import axe.renderer;
import axe.renderer_asm;
import axe.imports;
import axe.structs;
import std.file;
import std.process;
import std.array;
import std.stdio;
import std.algorithm;
import std.string : replace, startsWith;
import std.path : dirName, buildPath;

/**
 * Recursively check if AST contains parallel blocks
 */
bool hasParallelBlocks(ASTNode node)
{
    if (node.nodeType == "ParallelFor")
        return true;
    
    foreach (child; node.children)
    {
        if (hasParallelBlocks(child))
            return true;
    }
    
    return false;
}

/**
 * Compiles and runs the generated assembly code.
 *
 * Returns NASM errors if any.
 */
string compileAndRunAsm(string asmCode)
{
    string asmFile = buildPath(tempDir(), "temp.asm");
    string objFile = buildPath(tempDir(), "temp.o");
    string exeFile = buildPath(tempDir(), "temp.exe");

    std.file.write(asmFile, asmCode);

    auto nasmResult = execute(["nasm", "-f", "win64", "-o", objFile, asmFile]);

    if (nasmResult.status != 0)
        return "NASM Error: " ~ nasmResult.output;

    auto linkResult = execute(["clang", "-o", exeFile, objFile, "-lmsvcrt"]);

    if (linkResult.status != 0)
        return "Linker Error: " ~ linkResult.output;

    auto runResult = execute([exeFile]);
    return runResult.output;
}

/** 
 * Handles compile arguments.
 *
 * Params:
 *   args = Command line arguments
 * Returns: 
 *   True if successful, false otherwise
 */
bool handleMachineArgs(string[] args)
{
    try
    {
        string name = args[1];
        bool isAxec = name.endsWith(".axec");

        if (!name.endsWith(".axe") && !isAxec)
            name ~= ".axe";

        string source = readText(name);
        auto tokens = lex(source);

        if (args.canFind("-tokens"))
            writeln(tokens);

        auto ast = parse(tokens, isAxec);

        ast = processImports(ast, dirName(name), isAxec, name);

        if (args.canFind("-ast"))
            writeln(ast);

        if (args.canFind("-asm"))
        {
            string asmCode = generateAsm(ast);
            string result = compileAndRunAsm(asmCode);

            if (result.canFind("Error:"))
            {
                stderr.writeln(result);
                return false;
            }

            stdout.writeln(result);
        }
        else
        {
            writeln("Generating C...");
            string cCode = generateC(ast);
            string ext = isAxec ? ".axec" : ".axe";
            std.file.write(replace(name, ext, ".c"), cCode);
            
            // Check if we need to link OpenMP
            bool needsOpenMP = hasParallelBlocks(ast);
            
            string[] clangCmd;

            if (args.canFind("--release"))
            {
                clangCmd = [
                    "clang", replace(name, ext, ".c"), "-Wno-everything", "-Os"
                ];
            }
            else
            {
                clangCmd = [
                    "clang", replace(name, ext, ".c"), "-Wno-everything", "-Os"
                ];
                version(Windows)
                {
                    clangCmd ~= "-ldbghelp";
                }
            }
            
            // Add OpenMP flags if needed
            if (needsOpenMP)
            {
                writeln("Detected parallel blocks, adding OpenMP support (-fopenmp)");
                clangCmd ~= ["-fopenmp"];
            }

            foreach (arg; args)
            {
                if (arg.startsWith("-I"))
                {
                    clangCmd ~= arg;
                }
            }

            clangCmd ~= ["-o", replace(name, ext, ".exe")];

            auto e = execute(clangCmd);
            if (e[0] != 0)
            {
                stderr.writeln(
                    "Fallthrough error, report the bug at https://github.com/navid-m/axe/issues:\nTrace:\n",
                    e[1]
                );
                return false;
            }
            if (!args.canFind("-e"))
            {
                remove(replace(name, ext, ".c"));
            }
            if (args.canFind("-r"))
            {
                string exePath = replace(name, ext, ".exe");
                auto runResult = execute([exePath]);

                if (runResult.status != 0)
                {
                    stderr.writeln("Program exited with code ", runResult.status);
                    return false;
                }

                if (runResult.output.length > 0)
                {
                    stdout.write(runResult.output);
                }
            }
        }
        return true;
    }
    catch (Exception e)
    {
        if (e.message.canFind("Failed to spawn process"))
        {
            stderr.writeln(
                "You do not have the clang toolchain installed. Install it. (https://clang.llvm.org/)."
            );
        }
        else
        {
            stderr.writeln("Compilation error: ", e.msg);
        }
        return false;
    }
}
