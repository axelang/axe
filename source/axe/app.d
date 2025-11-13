module axe.app;

import axe.lexer;
import axe.parser;
import axe.renderer;
import axe.structs;
import std.file;
import std.process;
import std.array;
import std.stdio;
import std.algorithm;
import std.string : replace;
import std.path : dirName, buildPath;

/**
 * Process use statements and merge imported ASTs
 */
ASTNode processImports(ASTNode ast, string baseDir, bool isAxec)
{
    auto programNode = cast(ProgramNode) ast;
    if (programNode is null)
        return ast;
    
    ASTNode[] newChildren;
    string[string] importedFunctions; // Maps original name -> prefixed name
    
    foreach (child; programNode.children)
    {
        if (child.nodeType == "Use")
        {
            auto useNode = cast(UseNode) child;
            string modulePath = buildPath(baseDir, useNode.moduleName ~ ".axe");
            
            if (!exists(modulePath))
            {
                throw new Exception("Module not found: " ~ modulePath);
            }
            
            // Parse the imported module
            string importSource = readText(modulePath);
            auto importTokens = lex(importSource);
            auto importAst = parse(importTokens, isAxec);
            auto importProgram = cast(ProgramNode) importAst;
            
            // Extract requested functions and add them with prefixed names
            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    if (useNode.imports.canFind(funcNode.name))
                    {
                        // Prefix function name to avoid collisions
                        string prefixedName = useNode.moduleName ~ "_" ~ funcNode.name;
                        importedFunctions[funcNode.name] = prefixedName;
                        
                        // Create a new function node with prefixed name
                        auto newFunc = new FunctionNode(prefixedName, funcNode.params);
                        newFunc.returnType = funcNode.returnType;
                        newFunc.children = funcNode.children;
                        newChildren ~= newFunc;
                    }
                }
            }
        }
        else
        {
            // Rename function calls to use prefixed names
            renameFunctionCalls(child, importedFunctions);
            newChildren ~= child;
        }
    }
    
    programNode.children = newChildren;
    return programNode;
}

/**
 * Recursively rename function calls to use prefixed names
 */
void renameFunctionCalls(ASTNode node, string[string] nameMap)
{
    if (node.nodeType == "FunctionCall")
    {
        auto callNode = cast(FunctionCallNode) node;
        if (callNode.functionName in nameMap)
        {
            callNode.functionName = nameMap[callNode.functionName];
        }
    }
    
    foreach (child; node.children)
    {
        renameFunctionCalls(child, nameMap);
    }
}

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
        bool isAxec = name.endsWith(".axec");

        if (!name.endsWith(".axe") && !isAxec)
            name ~= ".axe";

        string source = readText(name);
        auto tokens = lex(source);

        if (args.canFind("-tokens"))
            writeln(tokens);

        auto ast = parse(tokens, isAxec);
        
        // Process imports
        ast = processImports(ast, dirName(name), isAxec);

        if (args.canFind("-ast"))
            writeln(ast);

        if (args.canFind("-asm"))
        {
            string asmCode = generateAsm(ast);
            string result = compileAndRunAsm(asmCode);

            if (result.canFind("Error:"))
            {
                stderr.writeln(result);
                return;
            }

            stdout.writeln(result);
        }
        else
        {
            string cCode = generateC(ast);
            string ext = isAxec ? ".axec" : ".axe";
            std.file.write(replace(name, ext, ".c"), cCode);
            auto e = execute([
                "clang", replace(name, ext, ".c"), "-Wno-everything", "-Os", "-o",
                replace(name, ext, ".exe")
            ]);
            if (e[0] != 0)
            {
                stderr.writeln(
                    "Fallthrough error, report the bug at https://github.com/navid-m/axe/issues:\nTrace:\n",
                    e[1]
                );
                return;
            }
            if (!args.canFind("-e"))
            {
                remove(replace(name, ext, ".c"));
            }
        }
    }
    catch (Exception e)
    {
        if (e.message.canFind("Failed to spawn process"))
        {
            stderr.writeln(
                "You do not have the clang toolchain installed. Install it from https://clang.llvm.org/"
            );
        }
        else
        {
            stderr.writeln("Compilation error: ", e.msg);
        }
    }
}
