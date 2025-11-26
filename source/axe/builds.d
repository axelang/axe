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
import std.algorithm : canFind, endsWith;
import std.string : replace, startsWith, splitLines, lastIndexOf;
import std.path : dirName, buildPath;
import std.regex : regex, matchAll, matchFirst;

/**
 * Recursively check if AST contains parallel blocks
 */
bool hasParallelBlocks(ASTNode node)
{
    if (node.nodeType == "ParallelFor" || node.nodeType == "Parallel" || node.nodeType == "ParallelLocal")
        return true;

    foreach (child; node.children)
    {
        if (hasParallelBlocks(child))
            return true;
    }

    return false;
}

/**
 * Check if parallelism module is imported
 */
bool hasParallelismImport()
{
    import axe.parser : g_importedModules;

    return ("std.parallelism" in g_importedModules) !is null;
}

void collectModelNames(ASTNode node, ref string[string] modelNames)
{
    if (node.nodeType == "Model")
    {
        auto modelNode = cast(ModelNode) node;
        if (modelNode !is null)
        {
            // Store the model name mapping
            // Extract base name from prefixed name (e.g., "std_arena_Arena" -> "Arena")
            string baseName = modelNode.name;
            if (modelNode.name.canFind("_") && modelNode.name.startsWith("std_"))
            {
                auto lastUnderscore = modelNode.name.lastIndexOf('_');
                if (lastUnderscore >= 0)
                {
                    baseName = modelNode.name[lastUnderscore + 1 .. $];
                    modelNames[baseName] = modelNode.name;
                }
            }
            else
            {
                // Not prefixed, so base name is the same as the model name
                // For std files, prefix with module name
                if (modelNode.name == "error")
                    modelNames[modelNode.name] = "std_errors_" ~ modelNode.name;
                else
                    modelNames[modelNode.name] = modelNode.name;
            }
        }
    }

    foreach (child; node.children)
    {
        collectModelNames(child, modelNames);
    }
}

string canonicalModelCName(string name, string[string] modelNames)
{
    if (name in modelNames)
        return modelNames[name];

    foreach (baseName, cName; modelNames)
    {
        if (cName == name)
            return cName;
    }

    return "";
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
            import std.stdio : writeln;

            foreach (method; modelNode.methods)
            {
                auto methodFunc = cast(FunctionNode) method;
                if (methodFunc !is null)
                {
                    declared[methodFunc.name] = true;
                }
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

void validateFunctionCalls(ASTNode node, bool[string] declared, string[string] modelNames, string modulePrefix = "")
{
    // Add built-in functions that are always available
    declared["append"] = true;

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
                    validateFunctionCalls(methodFunc, declared, modelNames, modulePrefix);
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

            // For simple function names without dots, check if there's ANY prefixed version
            // from imported modules (e.g., "panic" might be "std_errors_panic")
            if (!isDeclared && !name.canFind("."))
            {
                foreach (declaredName; declared.keys)
                {
                    if (declaredName.canFind("_" ~ name))
                    {
                        if (declaredName.endsWith("_" ~ name))
                        {
                            isDeclared = true;
                            break;
                        }
                    }
                }
            }

            if (!isDeclared && name.canFind("."))
            {
                import std.string : replace, split, strip;

                auto parts = name.split(".");
                if (parts.length == 2)
                {
                    string modelName = parts[0].strip();
                    string methodName = parts[1].strip();

                    // Look up the canonical model name (e.g., "error" -> "std_errors_error")
                    if (modelName in modelNames)
                    {
                        string modelCName = canonicalModelCName(modelName, modelNames);
                        if (modelCName.length == 0)
                            modelCName = modelName;

                        // Construct the full method name (e.g., "std_errors_error_print_self")
                        string fullMethodName = modelCName ~ "_" ~ methodName;
                        if (auto q = fullMethodName in declared)
                        {
                            isDeclared = *q;
                        }
                    }
                }

                // Fall back to simple underscore replacement
                if (!isDeclared)
                {
                    string underscored = name.replace(".", "_");
                    if (auto q = underscored in declared)
                    {
                        isDeclared = *q;
                    }

                    if (!isDeclared && modulePrefix.length > 0)
                    {
                        string fullyPrefixed = modulePrefix ~ "__" ~ underscored;
                        if (auto r = fullyPrefixed in declared)
                        {
                            isDeclared = *r;
                        }
                    }
                }
            }

            if (!isCEscape && !isDeclared)
            {
                import std.stdio : writeln;

                writeln("Failed validation for: ", name);
                writeln("Module prefix: ", modulePrefix);
                writeln("Declared keys: ", declared.keys);
                throw new Exception("Undefined function: " ~ name);
            }
        }
    }

    foreach (child; node.children)
    {
        validateFunctionCalls(child, declared, modelNames, modulePrefix);
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

        writeln("1 | IO");
        string source = readText(name);

        writeln("2 | Lex");
        auto tokens = lex(source);

        if (args.canFind("-tokens"))
            writeln(tokens);

        string moduleName = "";
        {
            import std.path : baseName, stripExtension, dirName;
            import std.string : replace;

            string fileName = baseName(name);
            string moduleBase = stripExtension(fileName);
            string directory = dirName(name);

            if (directory.canFind("std/") || directory.canFind("std\\"))
            {
                moduleName = "std." ~ moduleBase;
            }
            else if (directory != "." && directory.length > 0)
            {
                string dirBase = baseName(directory).replace("-", "_");
                moduleName = dirBase ~ "." ~ moduleBase;
            }
            else
            {
                moduleName = moduleBase;
            }

            debugWriteln("DEBUG: Derived module name '", moduleName, "' from file '", name, "'");
        }

        writeln("3 | Parse");
        auto ast = parse(tokens, isAxec, true, moduleName);

        writeln("4 | Parse");
        resetProcessedModules();

        writeln("5 | Imports");
        ast = processImports(ast, dirName(name), isAxec, name, true, moduleName); // SLOW.

        bool[string] declaredFunctions;
        writeln("6 | Collect Decls");
        collectDeclaredFunctions(ast, declaredFunctions);

        string[string] modelNames;
        writeln("7 | Collect Models");
        collectModelNames(ast, modelNames);

        string modulePrefix = "";
        if (moduleName.length > 0)
        {
            import std.string : replace;

            modulePrefix = moduleName.replace(".", "_");
        }

        writeln("8 | Validate Calls");
        validateFunctionCalls(ast, declaredFunctions, modelNames, modulePrefix);

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
            setCurrentModuleName(moduleName);

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
            bool needsOpenMP = hasParallelBlocks(ast) || hasParallelismImport() || name.canFind(
                "parallelism.axec");
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
                version (Windows)
                {
                    // -gcodeview       -> emit CodeView debug info
                    // -fuse-ld=lld     -> required for PDB
                    // -Xlinker /debug  -> linker should write a PDB
                    clangCmd = [
                        "clang",
                        replace(name, ext, ".c"),
                        "-Wno-everything",
                        "-O0",
                        "-gcodeview",
                        "-fuse-ld=lld",
                        "-Xlinker", "/debug",
                    ];
                }
                else
                {
                    clangCmd = [
                        "clang",
                        replace(name, ext, ".c"),
                        "-Wno-everything",
                        "-O0"
                    ];
                }

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

            writeln("9 | Lowering to LLVM/ASM");
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
 * Extract meaningful code snippets from a C line for mapping to Axe source.
 * Returns multiple candidate snippets in order of preference.
 */
string[] extractSnippetsFromCLine(string cLine)
{
    import std.string : strip, lastIndexOf, indexOf, split;
    import std.algorithm : filter, map;
    import std.array : array;

    string[] candidates;
    string line = cLine.strip();

    // Skip comments and very generic lines
    if (line.startsWith("//") || line.startsWith("/*") || line.length < 5)
        return candidates;

    // Skip lines that look like includes or preprocessor directives
    if (line.startsWith("#") || line.startsWith("typedef") || line.startsWith("struct"))
        return candidates;

    // Pattern 1: Function calls to Axe-generated functions (most reliable)
    auto funcCallMatch = line.matchFirst(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^;]+)\);");
    if (!funcCallMatch.empty)
    {
        string funcName = funcCallMatch[1];
        // Only add if it looks like an Axe-generated function (contains underscores or specific patterns)
        if (funcName.canFind("_") || funcName.length >= 6)
        {
            // Filter out common C library functions
            string[] commonCFuncs = [
                "printf", "malloc", "free", "strcpy", "strlen",
                "memcpy", "memset", "exit", "fprintf", "scanf",
                "strcmp", "strcat", "atoi", "atol", "atof"
            ];
            if (!commonCFuncs.canFind(funcName))
                candidates ~= funcName;
        }
    }

    // Pattern 2: Variable assignments with function calls
    ptrdiff_t eqPos = line.lastIndexOf('=');
    if (eqPos >= 0 && eqPos + 1 < cast(ptrdiff_t) line.length)
    {
        string rhs = line[eqPos + 1 .. $].strip();
        ptrdiff_t semiPos = rhs.indexOf(';');
        if (semiPos > 0)
            rhs = rhs[0 .. semiPos].strip();

        if (rhs.canFind("(") && rhs.canFind(")"))
        {
            auto funcMatch = rhs.matchFirst(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\(");
            if (!funcMatch.empty)
            {
                string funcName = funcMatch[1];
                if (funcName.canFind("_") || funcName.length >= 6)
                    candidates ~= funcName;
            }
        }
    }

    // Pattern 3: Variable declarations that look like Axe types
    auto varDeclMatch = line.matchFirst(r"\w+\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^;]+);");
    if (!varDeclMatch.empty)
    {
        string varName = varDeclMatch[1];
        string initExpr = varDeclMatch[2].strip();

        // Only use variables that look like Axe identifiers (not temp vars)
        if (varName.length >= 5 && !varName.startsWith("temp") && !varName.startsWith("tmp") &&
            !varName.startsWith("_"))
        {
            // Extract function calls from initialization
            if (initExpr.canFind("("))
            {
                auto initFuncMatch = initExpr.matchFirst(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\(");
                if (!initFuncMatch.empty)
                {
                    string funcName = initFuncMatch[1];
                    if (funcName.canFind("_") || funcName.length >= 6)
                        candidates ~= funcName;
                }
            }
            // Also add the variable name if it looks meaningful
            candidates ~= varName;
        }
    }

    // Pattern 4: Return statements with function calls
    if (line.startsWith("return"))
    {
        string expr = line[6 .. $].strip();
        ptrdiff_t semiPos = expr.indexOf(';');
        if (semiPos > 0)
            expr = expr[0 .. semiPos].strip();

        if (expr.canFind("(") && expr.canFind(")"))
        {
            auto retFuncMatch = expr.matchFirst(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\(");
            if (!retFuncMatch.empty)
            {
                string funcName = retFuncMatch[1];
                if (funcName.canFind("_") || funcName.length >= 6)
                    candidates ~= funcName;
            }
        }
    }

    // Filter and deduplicate - prefer longer, more specific snippets
    import std.algorithm : canFind, sort;

    string[] result;
    foreach (candidate; candidates)
    {
        if (candidate.length >= 5 && candidate.length <= 50 && !result.canFind(candidate))
            result ~= candidate;
    }

    // Sort by length (longer first) as they're likely more specific
    result.sort!((a, b) => a.length > b.length);

    return result;
}

/**
 * Try to find a snippet in Axe source using multiple search strategies.
 * Returns -1 if not found or if the match is in a comment line.
 */
int findAxeLineForSnippet(string axeText, string snippet)
{
    import std.string : indexOf, splitLines, strip;
    import std.regex : regex, matchAll;

    // Strategy 1: Exact match
    ptrdiff_t pos = axeText.indexOf(snippet);
    if (pos >= 0)
    {
        int line = 1;
        foreach (i, ch; axeText[0 .. pos])
        {
            if (ch == '\n')
                line++;
        }

        // Check if this line is a comment - if so, reject it
        string[] lines = axeText.splitLines();
        if (line > 0 && line <= cast(int) lines.length)
        {
            string lineText = lines[line - 1].strip();
            if (lineText.startsWith("//") || lineText.startsWith("/*"))
                return -1;
        }

        return line;
    }

    // Strategy 2: Case-insensitive match
    auto caseInsensitiveMatch = axeText.matchFirst(snippet, "i");
    if (!caseInsensitiveMatch.empty)
    {
        ptrdiff_t posb = caseInsensitiveMatch.pre.length;
        int line = 1;
        foreach (i, ch; axeText[0 .. posb])
        {
            if (ch == '\n')
                line++;
        }

        // Check if this line is a comment - if so, reject it
        string[] lines = axeText.splitLines();
        if (line > 0 && line <= cast(int) lines.length)
        {
            string lineText = lines[line - 1].strip();
            if (lineText.startsWith("//") || lineText.startsWith("/*"))
                return -1;
        }

        return line;
    }

    // Strategy 3: Word boundary match
    string pattern = r"\b" ~ snippet.replace(" ", r"\s+") ~ r"\b";
    auto wordMatch = axeText.matchFirst(pattern);
    if (!wordMatch.empty)
    {
        ptrdiff_t posa = wordMatch.pre.length;
        int line = 1;
        foreach (i, ch; axeText[0 .. posa])
        {
            if (ch == '\n')
                line++;
        }

        // Check if this line is a comment - if so, reject it
        string[] lines = axeText.splitLines();
        if (line > 0 && line <= cast(int) lines.length)
        {
            string lineText = lines[line - 1].strip();
            if (lineText.startsWith("//") || lineText.startsWith("/*"))
                return -1;
        }

        return line;
    }

    return -1;
}

/**
 * Heuristically map a single C error to an Axe source location.
 *
 * Strategy:
 *   - Extract multiple candidate snippets from the C line
 *   - Try different search strategies to find matching Axe code
 *   - Return clean, focused Axe error message
 */
string mapSingleCErrorToAxe(CErrorInfo err, string inputName, string ext)
{
    import std.file : exists, readText;
    import std.string : strip;
    import std.format : format;

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

    string[] snippets = extractSnippetsFromCLine(cLine);
    if (snippets.length == 0)
        return "";

    foreach (snippet; snippets)
    {
        int axeLine = findAxeLineForSnippet(axeText, snippet);
        if (axeLine > 0)
        {
            string[] axeLines = axeText.splitLines();
            string axeLineText = (axeLine > 0 && axeLine <= cast(int) axeLines.length)
                ? axeLines[axeLine - 1].strip() : "";

            return format("%s:%d: %s: %s\n    -> %s\n    (C line %d: %s)",
                axeSourcePath, axeLine, err.kind, err.message, axeLineText,
                err.line, cLine);
        }
    }

    return "";
}

/**
 * Map all C errors in stderr output back to Axe source, where possible.
 * Returns clean output with only Axe mappings when successful, or simplified
 * fallback when mapping fails.
 */
string mapCErrorsToAxe(string stderrOutput, string inputName, string ext)
{
    import std.string;
    import std.format;

    auto infos = parseCErrorLines(stderrOutput);
    if (infos.length == 0)
        return "";

    string result;
    int mappedCount = 0;

    foreach (err; infos)
    {
        string mapped = mapSingleCErrorToAxe(err, inputName, ext);
        if (mapped.length > 0)
        {
            result ~= mapped ~ "\n";
            mappedCount++;
        }
    }

    if (mappedCount > 0)
    {
        return result.stripRight();
    }
    else
    {
        return format("Fallthrough error, report at https://github.com/axelang/axe/issues. %d error(s) occurred:\n%s",
            infos.length, stderrOutput);
    }
}
