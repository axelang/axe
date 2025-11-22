/** 
 * Axe Programming Language Compiler.
 * Author: Navid Momtahen (C) 2025
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
import std.string : replace, startsWith, splitLines;
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

void collectDeclaredFunctions(ASTNode node, ref bool[string] declared)
{
    if (node.nodeType == "Function")
    {
        auto funcNode = cast(FunctionNode) node;
        if (funcNode !is null)
            declared[funcNode.name] = true;
    }
    else if (node.nodeType == "Model")
    {
        auto modelNode = cast(ModelNode) node;
        if (modelNode !is null)
        {
            foreach (method; modelNode.methods)
            {
                auto methodFunc = cast(FunctionNode) method;
                if (methodFunc !is null)
                    declared[methodFunc.name] = true;
            }
        }
    }
    else if (node.nodeType == "Extern")
    {
        auto externNode = cast(ExternNode) node;
        if (externNode !is null)
            declared[externNode.functionName] = true;
    }
    else if (node.nodeType == "Macro")
    {
        auto macroNode = cast(MacroNode) node;
        if (macroNode !is null)
            declared[macroNode.name] = true;
    }
    else if (node.nodeType == "Overload")
    {
        auto overloadNode = cast(OverloadNode) node;
        if (overloadNode !is null)
            declared[overloadNode.name] = true;
    }

    foreach (child; node.children)
    {
        collectDeclaredFunctions(child, declared);
    }
}

void validateFunctionCalls(ASTNode node, bool[string] declared, string modulePrefix = "")
{
    if (node.nodeType == "Model")
    {
        auto modelNode = cast(ModelNode) node;
        if (modelNode !is null)
        {
            foreach (method; modelNode.methods)
            {
                auto methodFunc = cast(FunctionNode) method;
                if (methodFunc !is null)
                {
                    validateFunctionCalls(methodFunc, declared, modulePrefix);
                }
            }
        }
    }

    if (node.nodeType == "FunctionCall")
    {
        auto callNode = cast(FunctionCallNode) node;
        if (callNode !is null)
        {
            string name = callNode.functionName;

            // NOTE: C.<name> (and its rewritten form C__<name>) is
            // reserved for explicit C interop escapes. These are allowed to
            // bypass the Axe-level undefined function check and will be
            // handled separately by codegen/runtime.

            import std.string : startsWith;

            bool isCEscape = name.startsWith("C.") || name.startsWith("C__");

            bool isDeclared = false;
            if (auto p = name in declared)
            {
                isDeclared = *p;
            }

            if (!isDeclared && name.canFind("."))
            {
                import std.string : replace;

                string underscored = name.replace(".", "_");
                if (auto q = underscored in declared)
                {
                    isDeclared = *q;
                }

                if (!isDeclared && modulePrefix.length > 0)
                {
                    string fullyPrefixed = modulePrefix ~ "_" ~ underscored;
                    if (auto r = fullyPrefixed in declared)
                    {
                        isDeclared = *r;
                    }
                }
            }

            if (!isCEscape && !isDeclared)
            {
                throw new Exception("Undefined function: " ~ name);
            }
        }
    }

    foreach (child; node.children)
    {
        validateFunctionCalls(child, declared, modulePrefix);
    }
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

        bool[string] declaredFunctions;
        collectDeclaredFunctions(ast, declaredFunctions);

        string modulePrefix = "";
        if (moduleName.length > 0)
        {
            import std.string : replace;

            modulePrefix = moduleName.replace(".", "_");
        }

        validateFunctionCalls(ast, declaredFunctions, modulePrefix);

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
                    "clang", replace(name, ext, ".c"), "-Wno-everything", "-O0"
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

            // Include extra stuff like libraries or object files
            // Example: ./axe std/os.axec -w std/os_helpers.c
            string[] extraLinkArgs;
            for (size_t i = 2; i < args.length; i++)
            {
                if (args[i] == "-w" && i + 1 < args.length)
                {
                    extraLinkArgs ~= args[i + 1];
                    i++;
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

            clangCmd ~= extraLinkArgs;

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

                string mapped = mapCErrorsToAxe(e[1], name, ext);

                if (mapped.length > 0)
                {
                    stderr.writeln(
                        "Compilation error:\n",
                        mapped
                    );
                }
                else
                {
                    stderr.writeln(
                        "Fallthrough error, report the bug at https://github.com/axelang/axe/issues\nTrace:\n",
                        e[1]
                    );
                }
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

/**
 * Simple struct for parsed C compiler error/warning lines.
 */
struct CErrorInfo
{
    string cFile;
    int line;
    int column;
    string kind;
    string message;
}

/**
 * Parse clang/gcc style C errors of the form: path/to/file.c:123:45: error: message
 */
CErrorInfo[] parseCErrorLines(string stderrOutput)
{
    import std.regex : regex, matchAll;
    import std.string : strip;
    import std.conv : to;

    CErrorInfo[] result;

    auto re = regex(`^([^:]+):(\d+):(\d+):\s+(error|warning):\s+(.*)$`, "m");
    foreach (m; matchAll(stderrOutput, re))
    {
        CErrorInfo info;
        info.cFile = m[1].idup.strip();
        info.line = m[2].to!int;
        info.column = m[3].to!int;
        info.kind = m[4].idup.strip();
        info.message = m[5].idup.strip();
        result ~= info;
    }

    return result;
}

/**
 * Heuristically map a single C error to an Axe source location.
 *
 * Strategy:
 *   - Compute the Axe source path from the original input name/ext.
 *   - Load both the generated .c file and the Axe source.
 *   - For each C error, grab the C line, try to extract the expression
 *     after the last '=' (or before the first ';'), and search for that
 *     snippet inside the Axe source. If found, report that Axe file/line.
 */
string mapSingleCErrorToAxe(CErrorInfo err, string inputName, string ext)
{
    import std.file : exists, readText;
    import std.algorithm : min;
    import std.string : strip, lastIndexOf, indexOf;
    import std.conv : to;

    string cPath = replace(inputName, ext, ".c");
    if (!exists(cPath))
        return "";

    string axeSourcePath = inputName;
    if (!exists(axeSourcePath))
        return "";

    string cText = readText(cPath);
    string axeText = readText(axeSourcePath);

    string[] cLines = cText.splitLines();
    if (err.line <= 0 || err.line > cast(int) cLines.length)
        return "";

    string cLine = cLines[err.line - 1].strip();
    if (cLine.length == 0)
        return "";

    string snippet = cLine;
    ptrdiff_t eqPos = snippet.lastIndexOf('=');
    if (eqPos >= 0 && eqPos + 1 < cast(ptrdiff_t) snippet.length)
        snippet = snippet[eqPos + 1 .. $].strip();

    ptrdiff_t semiPos = snippet.indexOf(';');
    if (semiPos > 0)
        snippet = snippet[0 .. semiPos].strip();

    if (snippet.length < 3)
        return "";

    enum maxSnippet = 80;
    if (snippet.length > maxSnippet)
        snippet = snippet[0 .. maxSnippet];

    ptrdiff_t axePos = axeText.indexOf(snippet);
    if (axePos < 0)
        return "";

    int axeLine = 1;
    foreach (idx, ch; axeText)
    {
        if (cast(ptrdiff_t) idx >= axePos)
            break;
        if (ch == '\n')
            axeLine++;
    }

    string[] axeLines = axeText.splitLines();
    string axeLineText = (axeLine > 0 && axeLine <= cast(int) axeLines.length)
        ? axeLines[axeLine - 1].strip() : "";

    import std.format : format;

    return format("%s:%d:%d: %s: %s\n  -> Axe %s:%d: %s\n",
        err.cFile, err.line, err.column, err.kind, err.message,
        axeSourcePath, axeLine, axeLineText);
}

/**
 * Map all C errors in stderr output back to Axe source, where possible.
 */
string mapCErrorsToAxe(string stderrOutput, string inputName, string ext)
{
    auto infos = parseCErrorLines(stderrOutput);
    if (infos.length == 0)
        return stderrOutput;

    string result;
    foreach (err; infos)
    {
        string mapped = mapSingleCErrorToAxe(err, inputName, ext);
        if (mapped.length > 0)
            result ~= mapped;
        else
            result ~= stderrOutput;
    }

    return result;
}
