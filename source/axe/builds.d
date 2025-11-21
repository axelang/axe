/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * Handles the actual compilation process.
 */

module axe.builds;

import axe.lexer;
import axe.parser;
import axe.renderer;
import axe.renderer_asm;
import axe.imports;
import axe.structs;
import axe.gstate;
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
    if (node.nodeType == "ParallelFor" || node.nodeType == "Parallel")
        return true;

    foreach (child; node.children)
    {
        if (hasParallelBlocks(child))
            return true;
    }

    return false;
}

void collectExternalHeaders(ASTNode node, ref string[] headers, string currentPlatform = null)
{
    import std.algorithm : canFind;

    if (node.nodeType == "ExternalImport")
    {
        auto ext = cast(ExternalImportNode) node;
        if (ext !is null && currentPlatform is null && !headers.canFind(ext.headerFile))
        {
            headers ~= ext.headerFile;
        }
    }

    if (node.nodeType == "Platform")
    {
        return;
    }

    foreach (child; node.children)
    {
        collectExternalHeaders(child, headers, currentPlatform);
    }
}

/**
 * Detects whether the AST uses a specific external header (e.g., "pcre.h").
 */
bool hasExternalHeader(ASTNode node, string headerFile)
{
    if (node.nodeType == "ExternalImport")
    {
        auto ext = cast(ExternalImportNode) node;
        if (ext !is null && ext.headerFile == headerFile)
            return true;
    }

    foreach (child; node.children)
    {
        if (hasExternalHeader(child, headerFile))
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

        // Derive module name from file path (e.g., std/string.axec -> std.string)
        string moduleName = "";
        if (name.canFind("std/") || name.canFind("std\\"))
        {
            import std.path : baseName, stripExtension;
            import std.string : replace;
            string fileName = baseName(name);
            string moduleBase = stripExtension(fileName);
            moduleName = "std." ~ moduleBase;
        }

        auto ast = parse(tokens, isAxec, true, moduleName);

        resetProcessedModules();
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
            string cCode = "";
            if (args.canFind("--release"))
            {
                RendererConfiguration.releaseBuild = true;
                cCode = generateC(ast);
            }
            else
            {
                cCode = generateC(ast);
            }
            string ext = isAxec ? ".axec" : ".axe";
            std.file.write(replace(name, ext, ".c"), cCode);
            bool needsOpenMP = hasParallelBlocks(ast);
            bool makeDll = args.canFind("-dll");
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
                    "clang", replace(name, ext, ".c"), "-Wno-everything"
                ];
                version (Windows)
                {
                    clangCmd ~= "-ldbghelp";
                }
            }

            if (needsOpenMP)
            {
                clangCmd ~= ["-fopenmp"];
            }

            foreach (arg; args)
            {
                if (arg.startsWith("-I"))
                {
                    clangCmd ~= arg;
                }
            }

            if (hasExternalHeader(ast, "pcre.h"))
            {
                import std.file : thisExePath;

                string exePath = thisExePath();
                string toolchainRoot = dirName(exePath);
                string pcreInclude = buildPath(toolchainRoot, "external", "pcre", "include");

                clangCmd ~= ["-DPCRE_STATIC"];

                version (Windows)
                {
                    string pcreLib = buildPath(toolchainRoot, "external", "x64-windows", "pcre.lib").replace("\\", "/");
                    clangCmd ~= ["-I" ~ pcreInclude, pcreLib];
                }
                version (Linux)
                {
                    string pcreLib = buildPath(toolchainRoot, "external", "x64-linux", "libpcre.a");
                    clangCmd ~= ["-I" ~ pcreInclude, pcreLib];
                }
                version (OSX)
                {
                    string pcreLib = buildPath(toolchainRoot, "external", "x64-macos", "libpcre.a");
                    clangCmd ~= ["-I" ~ pcreInclude, pcreLib];
                }
            }

            if (hasImportedModule("std/net") || hasImportedModule("net.axec"))
            {
                import std.file : thisExePath;

                string exePath = thisExePath();
                string toolchainRoot = dirName(exePath);
                string curlInclude = buildPath(toolchainRoot, "external", "curl", "include");

                clangCmd ~= ["-DCURL_STATICLIB", "-I" ~ curlInclude];

                version (Windows)
                {
                    string curlLib = buildPath(toolchainRoot, "external", "x64-windows", "libcurl.lib")
                        .replace("\\", "/");
                    string zlibLib = buildPath(toolchainRoot, "external", "x64-windows", "zlib.lib").replace("\\", "/");
                    clangCmd ~= [curlLib, zlibLib];
                    clangCmd ~= [
                        "-lws2_32", "-lwldap32", "-ladvapi32", "-lcrypt32"
                    ];
                    clangCmd ~= [
                        "-lnormaliz", "-liphlpapi", "-lsecur32", "-lbcrypt"
                    ];
                }
                version (Linux)
                {
                    string curlLib = buildPath(toolchainRoot, "external", "x64-linux", "libcurl.a");
                    clangCmd ~= [curlLib, "-lssl", "-lcrypto", "-lz"];
                }
                version (OSX)
                {
                    string curlLib = buildPath(toolchainRoot, "external", "x64-macos", "libcurl.a");
                    clangCmd ~= [curlLib, "-lssl", "-lcrypto", "-lz"];
                }
            }

            if (hasImportedModule("std/json") || hasImportedModule("json.axec"))
            {
                import std.file : thisExePath;

                string exePath = thisExePath();
                string toolchainRoot = dirName(exePath);
                string yyjsonInclude = buildPath(toolchainRoot, "external", "yyjson", "include");

                clangCmd ~= ["-I" ~ yyjsonInclude];

                version (Windows)
                {
                    string yyjsonLib = buildPath(toolchainRoot, "external", "x64-windows", "yyjson.lib")
                        .replace("\\", "/");
                    clangCmd ~= [yyjsonLib];
                }
                version (Linux)
                {
                    string yyjsonLib = buildPath(toolchainRoot, "external", "x64-linux", "libyyjson.a");
                    clangCmd ~= [yyjsonLib];
                }
                version (OSX)
                {
                    string yyjsonLib = buildPath(toolchainRoot, "external", "x64-macos", "libyyjson.a");
                    clangCmd ~= [yyjsonLib];
                }
            }

            string[] externalHeaders;
            collectExternalHeaders(ast, externalHeaders);
            foreach (header; externalHeaders)
            {
                clangCmd ~= ["-include", header];
            }

            if (makeDll)
            {
                clangCmd ~= ["-shared"];
                auto extension = ".so";
                version (Windows)
                {
                    extension = ".dll";
                }
                version (OSX)
                {
                    extension = ".dylib";
                }
                clangCmd ~= ["-o", replace(name, ext, extension)];
            }
            else
            {
                clangCmd ~= ["-o", replace(name, ext, ".exe")];
            }

            auto e = execute(clangCmd);
            if (e[0] != 0)
            {
                debugWriteln("CLANGCMD: ", clangCmd);

                stderr.writeln(
                    "Fallthrough error, report the bug at https://github.com/axelang/axe/issues\nTrace:\n",
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
                if (makeDll)
                {
                    stderr.writeln("Note: -r (run) is ignored when building a DLL.");
                }
                else
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
            stderr.writeln("\033[31mCompilation error: ", e.msg, "\033[0m");
        }
        return false;
    }
}
