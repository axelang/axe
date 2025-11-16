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
ASTNode processImports(ASTNode ast, string baseDir, bool isAxec, string currentFilePath = "")
{
    auto programNode = cast(ProgramNode) ast;
    if (programNode is null)
        return ast;

    ASTNode[] newChildren;
    string[string] importedFunctions;
    string[string] importedModels;

    string currentModulePrefix = "";
    if (currentFilePath.length > 0 && isAxec)
    {
        import std.path : baseName, stripExtension;
        import std.algorithm : canFind;

        if (currentFilePath.canFind("stdlib"))
        {
            auto fileName = baseName(currentFilePath).stripExtension();
            currentModulePrefix = "stdlib_" ~ fileName;
        }
    }

    string[string] localModels;
    string[string] localFunctions;
    if (currentModulePrefix.length > 0)
    {
        foreach (child; programNode.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                localModels[modelNode.name] = currentModulePrefix ~ "_" ~ modelNode.name;
                writeln("DEBUG: Added local model '", modelNode.name, "' -> '", currentModulePrefix ~ "_" ~
                        modelNode.name, "'");

                foreach (method; modelNode.methods)
                {
                    auto methodFunc = cast(FunctionNode) method;
                    if (methodFunc !is null)
                    {
                        string methodName = methodFunc.name[modelNode.name.length + 1 .. $];
                        string originalCallName = modelNode.name ~ "_" ~ methodName;
                        string prefixedCallName = currentModulePrefix ~ "_" ~ modelNode.name ~ "_" ~ methodName;
                        localFunctions[originalCallName] = prefixedCallName;
                        writeln("DEBUG: Added local function '", originalCallName, "' -> '", prefixedCallName, "'");
                    }
                }
            }
        }
        writeln("DEBUG: Total local models: ", localModels.length);
        writeln("DEBUG: Total local functions: ", localFunctions.length);
    }

    foreach (child; programNode.children)
    {
        if (child.nodeType == "Use")
        {
            auto useNode = cast(UseNode) child;
            string modulePath;

            if (useNode.moduleName.startsWith("stdlib/"))
            {
                string moduleName = useNode.moduleName[7 .. $];
                string homeDir = getUserHomeDir();
                if (homeDir.length == 0)
                {
                    throw new Exception("Could not determine user home directory");
                }

                modulePath = buildPath(homeDir, ".axe", "stdlib", moduleName ~ ".axec");

                if (!exists(modulePath))
                {
                    throw new Exception(
                        "Stdlib module not found: " ~ modulePath ~
                            "\nMake sure the module is installed in ~/.axe/stdlib/ or in a local stdlib/ directory");
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
            auto importAst = parse(importTokens, true, false);
            auto importProgram = cast(ProgramNode) importAst;
            string sanitizedModuleName = useNode.moduleName.replace("/", "_");

            string[string] moduleFunctionMap;
            string[string] moduleModelMap;
            string[string] moduleMacroMap;

            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    string prefixedName = sanitizedModuleName ~ "_" ~ funcNode.name;
                    moduleFunctionMap[funcNode.name] = prefixedName;
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    string prefixedName = sanitizedModuleName ~ "_" ~ modelNode.name;
                    moduleModelMap[modelNode.name] = prefixedName;

                    foreach (method; modelNode.methods)
                    {
                        auto methodFunc = cast(FunctionNode) method;
                        if (methodFunc !is null)
                        {
                            string prefixedMethodName = sanitizedModuleName ~ "_" ~ methodFunc.name;
                            moduleFunctionMap[methodFunc.name] = prefixedMethodName;
                        }
                    }
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;

                    // Macros don't get prefixed - they expand inline
                    moduleMacroMap[macroNode.name] = macroNode.name;
                }
            }

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

                        foreach (method; modelNode.methods)
                        {
                            auto methodFunc = cast(FunctionNode) method;
                            if (methodFunc !is null)
                            {
                                string prefixedMethodName = moduleFunctionMap[methodFunc.name];
                                auto newMethod = new FunctionNode(prefixedMethodName, methodFunc
                                        .params);
                                newMethod.returnType = methodFunc.returnType;
                                newMethod.children = methodFunc.children;

                                renameFunctionCalls(newMethod, moduleFunctionMap);
                                renameTypeReferences(newMethod, moduleModelMap);

                                newModel.methods ~= newMethod;

                                importedFunctions[methodFunc.name] = prefixedMethodName;
                            }
                        }

                        newChildren ~= newModel;
                    }
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;
                    if (useNode.imports.canFind(macroNode.name))
                    {
                        newChildren ~= macroNode;
                    }
                }
            }
        }
        else
        {
            // This is user code - rename function calls and type references
            writeln("DEBUG imports: Renaming user code with ", importedFunctions.length, " imported functions");
            foreach (key, value; importedFunctions)
            {
                writeln("  DEBUG: importedFunctions['", key, "'] = '", value, "'");
            }

            // If this is a model with methods in a .axec file, rename the model and its methods
            if (child.nodeType == "Model" && currentModulePrefix.length > 0)
            {
                auto modelNode = cast(ModelNode) child;
                string originalModelName = modelNode.name;
                string prefixedModelName = currentModulePrefix ~ "_" ~ originalModelName;

                string[string] modelTypeMap = importedModels.dup;
                modelTypeMap[originalModelName] = prefixedModelName;
                modelNode.name = prefixedModelName;

                foreach (method; modelNode.methods)
                {
                    auto methodFunc = cast(FunctionNode) method;
                    if (methodFunc !is null)
                    {
                        string methodName = methodFunc.name;
                        if (methodName.startsWith(originalModelName ~ "_"))
                        {
                            methodName = methodName[originalModelName.length + 1 .. $];
                        }
                        methodFunc.name = prefixedModelName ~ "_" ~ methodName;
                    }

                    renameFunctionCalls(method, importedFunctions);
                    renameTypeReferences(method, modelTypeMap);
                }

                // Apply type renaming to the entire file (for all functions)
                renameFunctionCalls(child, importedFunctions);
                renameTypeReferences(child, modelTypeMap);
            }
            else if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    renameFunctionCalls(method, importedFunctions);
                    renameTypeReferences(method, importedModels);
                }

                renameFunctionCalls(child, importedFunctions);
                renameTypeReferences(child, importedModels);
            }
            else if (child.nodeType == "Function" && currentModulePrefix.length > 0)
            {
                // For regular functions in .axec files, use local models map
                string[string] localTypeMap = importedModels.dup;
                foreach (modelName, prefixedName; localModels)
                {
                    localTypeMap[modelName] = prefixedName;
                }

                string[string] combinedFunctions = importedFunctions.dup;
                foreach (key, value; localFunctions)
                {
                    combinedFunctions[key] = value;
                }

                renameFunctionCalls(child, combinedFunctions);
                renameTypeReferences(child, localTypeMap);
            }
            else if (child.nodeType == "Test" && currentModulePrefix.length > 0)
            {
                // For test blocks in .axec files, use local models map
                string[string] localTypeMap = importedModels.dup;
                foreach (modelName, prefixedName; localModels)
                {
                    localTypeMap[modelName] = prefixedName;
                }

                string[string] combinedFunctions = importedFunctions.dup;
                foreach (key, value; localFunctions)
                {
                    combinedFunctions[key] = value;
                }

                renameFunctionCalls(child, combinedFunctions);
                renameTypeReferences(child, localTypeMap);
            }
            else
            {
                renameFunctionCalls(child, importedFunctions);
                renameTypeReferences(child, importedModels);
            }

            newChildren ~= child;
        }
    }

    programNode.children = newChildren;
    return programNode;
}

/**
 * Convert ModelName_methodName to a regex pattern ModelName\s*\.\s*methodName
 * Only replaces the FIRST underscore (between model and method name)
 */
string convertToModelMethodPattern(string modelMethodName)
{
    import std.string : indexOf;

    auto firstUnderscore = modelMethodName.indexOf('_');
    if (firstUnderscore == -1)
        return modelMethodName;

    return modelMethodName[0 .. firstUnderscore] ~ "\\s*\\.\\s*" ~ modelMethodName[firstUnderscore + 1 .. $];
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
            callNode.functionName = nameMap[callNode.functionName];
        else
        {
            foreach (oldName, newName; nameMap)
            {
                if (oldName.canFind("_"))
                {
                    import std.regex : regex, matchFirst;

                    string modelMethod = convertToModelMethodPattern(oldName);
                    auto pattern = regex("^" ~ modelMethod ~ "$");
                    if (matchFirst(callNode.functionName, pattern))
                    {
                        callNode.functionName = newName;
                        break;
                    }
                }
            }
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

                // Also replace dot notation
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                printNode.message = printNode.message.replace(oldCallDot, newName ~ "(");
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
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                printlnNode.message = printlnNode.message.replace(oldCallDot, newName ~ "(");
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
            }

            string oldCallDot = oldName.replace("_", ".") ~ "(";
            if (returnNode.expression.canFind(oldCallDot))
            {
                returnNode.expression = returnNode.expression.replace(oldCallDot, newName ~ "(");
            }

            import std.regex : regex, replaceAll;

            if (returnNode.expression.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                string newExpr = replaceAll(returnNode.expression, dotPattern, newName ~ "(");
                if (newExpr != returnNode.expression)
                {
                    returnNode.expression = newExpr;
                }
            }
        }
    }
    else if (node.nodeType == "Declaration")
    {
        auto declNode = cast(DeclarationNode) node;
        debug writeln("    DEBUG renameFunctionCalls Declaration: initializer='", declNode.initializer, "'");
        foreach (oldName, newName; nameMap)
        {
            string oldCall = oldName ~ "(";
            if (declNode.initializer.canFind(oldCall))
            {
                debug writeln("    DEBUG renameFunctionCalls: Renamed call in declaration: '",
                    oldName, "' -> '", newName, "'");
                declNode.initializer = declNode.initializer.replace(oldCall, newName ~ "(");
            }

            string oldCallDot = oldName.replace("_", ".") ~ "(";
            if (declNode.initializer.canFind(oldCallDot))
            {
                debug writeln("    DEBUG renameFunctionCalls: Renamed dot call in declaration: '",
                    oldCallDot, "' -> '", newName, "(");
                declNode.initializer = declNode.initializer.replace(oldCallDot, newName ~ "(");
            }

            // Also check for dot notation with regex: Model.method( or Model . method(
            // Use word boundary to ensure we don't match floating point literals like 0.5
            import std.regex : regex, replaceAll;

            if (declNode.initializer.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                writeln("    DEBUG: Trying regex pattern '\\b", modelMethod, "\\s*\\(' on '",
                    declNode.initializer, "'");
                string newInit = replaceAll(declNode.initializer, dotPattern, newName ~ "(");
                if (newInit != declNode.initializer)
                {
                    writeln("    DEBUG: Regex matched! Replaced '", declNode.initializer, "' -> '", newInit, "'");
                    declNode.initializer = newInit;
                }
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
            }

            // Also replace dot notation
            string oldCallDot = oldName.replace("_", ".") ~ "(";
            if (assignNode.expression.canFind(oldCallDot))
            {
                assignNode.expression = assignNode.expression.replace(oldCallDot, newName ~ "(");
            }

            import std.regex : regex, replaceAll;

            if (assignNode.expression.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                string newExpr = replaceAll(assignNode.expression, dotPattern, newName ~ "(");
                if (newExpr != assignNode.expression)
                {
                    assignNode.expression = newExpr;
                }
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

        // Handle return type renaming, including ref types
        if (funcNode.returnType in typeMap)
        {
            funcNode.returnType = typeMap[funcNode.returnType];
        }
        else if (funcNode.returnType.startsWith("ref "))
        {
            string baseType = funcNode.returnType[4 .. $].strip();
            if (baseType in typeMap)
            {
                funcNode.returnType = "ref " ~ typeMap[baseType];
            }
        }

        for (size_t i = 0; i < funcNode.params.length; i++)
        {
            string param = funcNode.params[i];
            auto parts = param.split(" ");
            if (parts.length >= 2)
            {
                foreach (oldType, newType; typeMap)
                {
                    if (parts[0] == oldType)
                    {
                        parts[0] = newType;
                    }
                    else if (parts.length >= 3 && parts[0] == "ref" && parts[1] == oldType)
                    {
                        parts[1] = newType;
                    }
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
    else if (node.nodeType == "RawC")
    {
        auto rawNode = cast(RawCNode) node;
        import std.regex : regex, replaceAll;

        // Replace type names in raw C code blocks
        // We need to be careful to only replace whole words (type names)
        foreach (oldType, newType; typeMap)
        {
            // Match type name as a whole word, accounting for common C patterns:
            // - Type declarations: "String*"
            // - Casts: "(String*)"
            // - sizeof: "sizeof(String)"
            auto wordPattern = regex("\\b" ~ oldType ~ "\\b");
            rawNode.code = replaceAll(rawNode.code, wordPattern, newType);
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
