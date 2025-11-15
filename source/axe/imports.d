module axe.imports;

import axe.structs;
import axe.lexer;
import axe.parser;
import std.file;
import std.path;
import std.stdio;
import std.algorithm;
import std.string;
import std.array;
import std.exception;

/**
 * Process use statements and merge imported ASTs
 */
ASTNode processImports(ASTNode ast, string baseDir, bool isAxec)
{
    auto programNode = cast(ProgramNode) ast;
    if (programNode is null)
        return ast;

    ASTNode[] newChildren;
    string[string] importedFunctions;
    string[string] importedModels;

    foreach (child; programNode.children)
    {
        if (child.nodeType == "Use")
        {
            auto useNode = cast(UseNode) child;
            string modulePath;

            if (useNode.moduleName.startsWith("stdlib/"))
            {
                string homeDir = getUserHomeDir();
                if (homeDir.length == 0)
                {
                    throw new Exception("Could not determine user home directory");
                }

                string moduleName = useNode.moduleName[7 .. $];
                modulePath = buildPath(homeDir, ".axe", "stdlib", moduleName ~ ".axec");

                if (!exists(modulePath))
                {
                    throw new Exception(
                        "Stdlib module not found: " ~ modulePath ~
                            "\nMake sure the module is installed in ~/.axe/stdlib/");
                }
            }
            else
            {
                modulePath = buildPath(baseDir, useNode.moduleName ~ ".axe");

                if (!exists(modulePath))
                {
                    throw new Exception("Module not found: " ~ modulePath);
                }
            }

            string importSource = readText(modulePath);
            auto importTokens = lex(importSource);
            auto importAst = parse(importTokens, true);
            auto importProgram = cast(ProgramNode) importAst;
            string sanitizedModuleName = useNode.moduleName.replace("/", "_");

            string[string] moduleFunctionMap;
            string[string] moduleModelMap;
            string[string] moduleMacroMap;

            import std.stdio : writeln;

            writeln("DEBUG imports: Building function map for module: ", useNode.moduleName);

            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    string prefixedName = sanitizedModuleName ~ "_" ~ funcNode.name;
                    moduleFunctionMap[funcNode.name] = prefixedName;
                    writeln("  DEBUG: Mapped function '", funcNode.name, "' -> '", prefixedName, "'");
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    string prefixedName = sanitizedModuleName ~ "_" ~ modelNode.name;
                    moduleModelMap[modelNode.name] = prefixedName;
                    writeln("  DEBUG: Mapped model '", modelNode.name, "' -> '", prefixedName, "'");
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;
                    // Macros don't get prefixed - they expand inline
                    moduleMacroMap[macroNode.name] = macroNode.name;
                    writeln("  DEBUG: Mapped macro '", macroNode.name, "'");
                }
            }

            writeln("DEBUG imports: Processing imported items");
            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    if (useNode.imports.canFind(funcNode.name))
                    {
                        string prefixedName = moduleFunctionMap[funcNode.name];
                        importedFunctions[funcNode.name] = prefixedName;
                        auto newFunc = new FunctionNode(prefixedName, funcNode.params);
                        newFunc.returnType = funcNode.returnType;
                        newFunc.children = funcNode.children;

                        writeln("  DEBUG: Renaming calls in function '", prefixedName, "'");
                        
                        // Rename internal calls within this function
                        renameFunctionCalls(newFunc, moduleFunctionMap);
                        renameTypeReferences(newFunc, moduleModelMap);

                        newChildren ~= newFunc;
                    }
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    if (useNode.imports.canFind(modelNode.name))
                    {
                        string prefixedName = moduleModelMap[modelNode.name];
                        importedModels[modelNode.name] = prefixedName;
                        auto newModel = new ModelNode(prefixedName, null);
                        newModel.fields = modelNode.fields;
                        newChildren ~= newModel;
                    }
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;
                    if (useNode.imports.canFind(macroNode.name))
                    {
                        // Macros are added directly without prefixing - they expand inline
                        writeln("  DEBUG: Adding macro '", macroNode.name, "'");
                        newChildren ~= macroNode;
                    }
                }
            }
        }
        else
        {
            // This is user code - rename function calls and type references
            renameFunctionCalls(child, importedFunctions);
            renameTypeReferences(child, importedModels);
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
    import std.stdio : writeln;

    if (node.nodeType == "FunctionCall")
    {
        auto callNode = cast(FunctionCallNode) node;
        if (callNode.functionName in nameMap)
        {
            string oldName = callNode.functionName;
            callNode.functionName = nameMap[callNode.functionName];
            writeln("    DEBUG renameFunctionCalls: Renamed call '", oldName, "' -> '", callNode.functionName, "'");
        }
        else
        {
            writeln("    DEBUG renameFunctionCalls: Call '", callNode.functionName, "' not in map");
        }
    }
    else if (node.nodeType == "Print")
    {
        auto printNode = cast(PrintNode) node;
        if (printNode.isExpression)
        {
            foreach (oldName, newName; nameMap)
            {
                printNode.message = printNode.message.replace(oldName ~ "(", newName ~ "(");
            }
        }
    }
    else if (node.nodeType == "Println")
    {
        auto printlnNode = cast(PrintlnNode) node;
        if (printlnNode.isExpression)
        {
            foreach (oldName, newName; nameMap)
            {
                printlnNode.message = printlnNode.message.replace(oldName ~ "(", newName ~ "(");
            }
        }
    }
    else if (node.nodeType == "Return")
    {
        auto returnNode = cast(ReturnNode) node;
        foreach (oldName, newName; nameMap)
        {
            string oldCall = oldName ~ "(";
            if (returnNode.expression.canFind(oldCall))
            {
                returnNode.expression = returnNode.expression.replace(oldCall, newName ~ "(");
                writeln("    DEBUG renameFunctionCalls: Renamed call in return: '", oldName, "' -> '", newName, "'");
            }
        }
    }
    else if (node.nodeType == "Declaration")
    {
        auto declNode = cast(DeclarationNode) node;
        foreach (oldName, newName; nameMap)
        {
            string oldCall = oldName ~ "(";
            if (declNode.initializer.canFind(oldCall))
            {
                declNode.initializer = declNode.initializer.replace(oldCall, newName ~ "(");
                writeln("    DEBUG renameFunctionCalls: Renamed call in declaration: '", oldName, "' -> '", newName, "'");
            }
        }
    }
    else if (node.nodeType == "Assignment")
    {
        auto assignNode = cast(AssignmentNode) node;
        foreach (oldName, newName; nameMap)
        {
            string oldCall = oldName ~ "(";
            if (assignNode.expression.canFind(oldCall))
            {
                assignNode.expression = assignNode.expression.replace(oldCall, newName ~ "(");
                writeln("    DEBUG renameFunctionCalls: Renamed call in assignment: '", oldName, "' -> '", newName, "'");
            }
        }
    }

    foreach (child; node.children)
    {
        renameFunctionCalls(child, nameMap);
    }
}

/**
 * Recursively rename type references to use prefixed model names
 */
void renameTypeReferences(ASTNode node, string[string] typeMap)
{
    import std.algorithm : startsWith;
    import std.array : split, join;

    if (node.nodeType == "Function")
    {
        auto funcNode = cast(FunctionNode) node;

        // Update return type
        if (funcNode.returnType in typeMap)
        {
            funcNode.returnType = typeMap[funcNode.returnType];
        }

        // Update parameter types
        for (size_t i = 0; i < funcNode.params.length; i++)
        {
            string param = funcNode.params[i];
            auto parts = param.split(" ");
            if (parts.length >= 2)
            {
                // Handle "Type name" or "Type[] name" or "ref Type name"
                foreach (oldType, newType; typeMap)
                {
                    // Replace standalone type names
                    if (parts[0] == oldType)
                    {
                        parts[0] = newType;
                    }
                    // Handle ref types
            else if (parts.length >= 3 && parts[0] == "ref" && parts[1] == oldType)
                    {
                        parts[1] = newType;
                    }
                    // Handle array types
            else if (parts[0].startsWith(oldType ~ "["))
                    {
                        parts[0] = parts[0].replace(oldType ~ "[", newType ~ "[");
                    }
                }
                funcNode.params[i] = parts.join(" ");
            }
        }
    }
    else if (node.nodeType == "Declaration")
    {
        auto declNode = cast(DeclarationNode) node;
        if (declNode.typeName in typeMap)
        {
            declNode.typeName = typeMap[declNode.typeName];
        }
    }
    else if (node.nodeType == "ArrayDeclaration")
    {
        auto arrDeclNode = cast(ArrayDeclarationNode) node;
        if (arrDeclNode.elementType in typeMap)
        {
            arrDeclNode.elementType = typeMap[arrDeclNode.elementType];
        }
    }
    else if (node.nodeType == "ModelInstantiation")
    {
        auto modelInstNode = cast(ModelInstantiationNode) node;
        if (modelInstNode.modelName in typeMap)
        {
            modelInstNode.modelName = typeMap[modelInstNode.modelName];
        }
    }

    foreach (child; node.children)
    {
        renameTypeReferences(child, typeMap);
    }
}

/**
 * Get the user's home directory
 */
string getUserHomeDir()
{
    import std.process : environment;

    version (Windows)
    {
        return environment.get("USERPROFILE", "");
    }
    else
    {
        return environment.get("HOME", "");
    }
}
