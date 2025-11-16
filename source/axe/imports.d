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
            auto importAst = parse(importTokens, true);
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

                    // Also map all methods within this model
                    foreach (method; modelNode.methods)
                    {
                        auto methodFunc = cast(FunctionNode) method;
                        if (methodFunc !is null)
                        {
                            // Method names are already prefixed as ModelName_methodName in parser
                            // We need to prefix them with the module name
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

                        // Process model methods - rename and add them to newChildren
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

                                // Rename function calls within the method to use prefixed names
                                renameFunctionCalls(newMethod, moduleFunctionMap);
                                renameTypeReferences(newMethod, moduleModelMap);

                                // Add method to newModel's methods array
                                newModel.methods ~= newMethod;

                                // Also add this method to importedFunctions so user code can call it
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
                        // Macros are added directly without prefixing - they expand inline
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
            renameFunctionCalls(child, importedFunctions);
            renameTypeReferences(child, importedModels);

            // If this is a model with methods, also rename calls within those methods
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    renameFunctionCalls(method, importedFunctions);
                    renameTypeReferences(method, importedModels);
                }
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
        // Check direct match first
        if (callNode.functionName in nameMap)
        {
            callNode.functionName = nameMap[callNode.functionName];
        }
        // Also check if it's in dot notation and needs to be converted
    else
        {
            foreach (oldName, newName; nameMap)
            {
                if (oldName.canFind("_"))
                {
                    // Convert Model_method to Model.method pattern with regex
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
            // Check for underscore notation: Model_method(
            string oldCall = oldName ~ "(";
            if (returnNode.expression.canFind(oldCall))
            {
                returnNode.expression = returnNode.expression.replace(oldCall, newName ~ "(");
            }

            // Also check for dot notation: Model.method( or Model . method(
            // Use word boundary to ensure we don't match floating point literals like 0.5
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
        writeln("    DEBUG renameFunctionCalls Declaration: initializer='", declNode.initializer, "'");
        foreach (oldName, newName; nameMap)
        {
            // Check for underscore notation: Model_method(
            string oldCall = oldName ~ "(";
            if (declNode.initializer.canFind(oldCall))
            {
                writeln("    DEBUG renameFunctionCalls: Renamed call in declaration: '", oldName, "' -> '", newName, "'");
                declNode.initializer = declNode.initializer.replace(oldCall, newName ~ "(");
            }

            // Also check for dot notation: Model.method( or Model . method(
            // Use word boundary to ensure we don't match floating point literals like 0.5
            import std.regex : regex, replaceAll;

            if (declNode.initializer.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                writeln("    DEBUG: Trying regex pattern '\\b", modelMethod, "\\s*\\(' on '", declNode.initializer, "'");
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
            // Check for underscore notation: Model_method(
            string oldCall = oldName ~ "(";
            if (assignNode.expression.canFind(oldCall))
            {
                assignNode.expression = assignNode.expression.replace(oldCall, newName ~ "(");
            }

            // Also check for dot notation: Model.method( or Model . method(
            // Use word boundary to ensure we don't match floating point literals like 0.5
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
