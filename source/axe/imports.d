/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * Handles the import process.
 */

module axe.imports;

import axe.structs;
import axe.lexer;
import axe.parser;
import axe.gstate;
import std.file;
import std.path;
import std.stdio;
import std.algorithm;
import std.string;
import std.array;
import std.exception;

private string[string] g_processedModules;
private bool[string] g_addedNodeNames;

/**
 * Reset the processed modules cache before a new compilation
 */
void resetProcessedModules()
{
    g_processedModules.clear();
    g_addedNodeNames.clear();
}

/**
 * Check if a specific stdlib module was imported during compilation
 */
bool hasImportedModule(string moduleName)
{
    foreach (key; g_processedModules.byKey())
    {
        if (key.canFind(moduleName))
            return true;
    }
    return false;
}

/**
 * Process use statements and merge imported ASTs, recursively handling transitive dependencies
 */
ASTNode processImports(ASTNode ast, string baseDir, bool isAxec, string currentFilePath = "",
    bool isTopLevel = true)
{
    auto programNode = cast(ProgramNode) ast;
    if (programNode is null)
        return ast;

    if (currentFilePath.length > 0)
    {
        string normalizedPath = currentFilePath.replace("\\", "/");
        if (normalizedPath in g_processedModules)
        {
            debugWriteln("DEBUG: Module already processed, skipping: ", normalizedPath);
            return ast;
        }
        g_processedModules[normalizedPath] = "1";
    }

    auto startsWithLower = (string s) {
        return s.length > 0 && s[0] >= 'a' && s[0] <= 'z';
    };

    if (currentFilePath.length > 0 && !currentFilePath.canFind("std"))
    {
        foreach (child; programNode.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                if (startsWithLower(modelNode.name))
                {
                    throw new Exception(
                        "Declaring primitive types outside of the standard library is disallowed: " ~
                            modelNode.name);
                }
            }
        }
    }

    ASTNode[] newChildren;
    string[string] importedFunctions;
    string[string] importedModels;

    string currentModulePrefix = "";
    if (isTopLevel && currentFilePath.length > 0 && isAxec)
    {
        import std.path : baseName, stripExtension;
        import std.algorithm : canFind;

        if (currentFilePath.canFind("std"))
        {
            auto fileName = baseName(currentFilePath).stripExtension();
            currentModulePrefix = "std_" ~ fileName;
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
                debugWriteln("DEBUG: Added local model '", modelNode.name, "' -> '", currentModulePrefix ~ "_" ~
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
                        debugWriteln("DEBUG: Added local function '", originalCallName, "' -> '",
                            prefixedCallName, "'");
                    }
                }
            }
        }
        debugWriteln("DEBUG: Total local models: ", localModels.length);
        debugWriteln("DEBUG: Total local functions: ", localFunctions.length);
    }

    bool[string] isTransitiveDependency;

    foreach (child; programNode.children)
    {
        if (child.nodeType == "Use")
        {
            auto useNode = cast(UseNode) child;
            string modulePath;

            if (useNode.moduleName.startsWith("std."))
            {
                string moduleName = useNode.moduleName[4 .. $].replace(".", dirSeparator);

                if (baseDir.endsWith("std") || baseDir.endsWith("std/"))
                {
                    modulePath = buildPath(baseDir, moduleName ~ ".axec");
                }
                else
                {
                    modulePath = buildPath(baseDir, "std", moduleName ~ ".axec");
                }

                if (!exists(modulePath))
                {
                    string homeDir = getUserHomeDir();
                    if (homeDir.length == 0)
                    {
                        throw new Exception("Could not determine user home directory");
                    }

                    modulePath = buildPath(homeDir, ".axe", "std", moduleName ~ ".axec");

                    if (!exists(modulePath))
                    {
                        throw new Exception(
                            "Standard library module not found: " ~ modulePath ~
                                "\nMake sure the module is installed in ~/.axe/std/ " ~
                                "or in a local std/ directory");
                    }
                }
            }
            else
            {
                string processedModuleName = useNode.moduleName;
                // Handle relative paths (../ and ./) and dot-separated module paths
                // Replace dots with directory separators, but keep ../ and ./
                // This preserves relative path prefixes while converting module.submodule to module/submodule
                if (!processedModuleName.startsWith("../") && !processedModuleName.startsWith("./"))
                {
                    processedModuleName = processedModuleName.replace(".", dirSeparator);
                }
                
                modulePath = buildPath(baseDir, processedModuleName ~ ".axe");

                if (!exists(modulePath))
                {
                    throw new Exception("Module not found: " ~ modulePath);
                }
            }

            string importSource = readText(modulePath);
            auto importTokens = lex(importSource);
            bool importIsAxec = modulePath.endsWith(".axec");
            auto importAst = parse(importTokens, importIsAxec, false, useNode.moduleName);
            string importBaseDir = dirName(modulePath);
            importAst = processImports(importAst, importBaseDir, importIsAxec, modulePath, false);

            auto importProgram = cast(ProgramNode) importAst;

            if (!modulePath.canFind("std") && importProgram !is null)
            {
                foreach (importChild; importProgram.children)
                {
                    if (importChild.nodeType == "Model")
                    {
                        auto mNode = cast(ModelNode) importChild;
                        if (startsWithLower(mNode.name))
                        {
                            string msg = "Declaring primitive types outside of the standard library is disallowed: "
                                ~ mNode.name;
                            throw new Exception(msg);
                        }
                    }
                }
            }

            string sanitizedModuleName = useNode.moduleName.replace(".", "_");
            string[string] moduleFunctionMap;
            string[string] moduleModelMap;
            string[string] moduleMacroMap;

            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "ExternalImport")
                {
                    auto extNode = cast(ExternalImportNode) importChild;
                    string key = "__external_import__" ~ extNode.headerFile;
                    if (key !in g_addedNodeNames)
                    {
                        g_addedNodeNames[key] = true;
                        newChildren ~= importChild;
                    }
                    continue;
                }
                else if (importChild.nodeType == "Platform")
                {
                    auto platformNode = cast(PlatformNode) importChild;

                    PlatformNode platformImports = null;
                    foreach (pChild; platformNode.children)
                    {
                        if (pChild.nodeType == "ExternalImport")
                        {
                            if (platformImports is null)
                            {
                                platformImports = new PlatformNode(platformNode.platform);
                            }
                            platformImports.children ~= pChild;
                        }

                        if (pChild.nodeType == "Function")
                        {
                            auto funcNode = cast(FunctionNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                            {
                                string prefixedName = funcNode.name.startsWith("std_") ? funcNode.name
                                    : (sanitizedModuleName ~ "_" ~ funcNode.name);
                                moduleFunctionMap[funcNode.name] = prefixedName;
                            }
                        }
                        else if (pChild.nodeType == "Model")
                        {
                            auto modelNode = cast(ModelNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(modelNode.name))
                            {
                                string prefixedName = modelNode.name.startsWith("std_") ? modelNode.name
                                    : (sanitizedModuleName ~ "_" ~ modelNode.name);
                                moduleModelMap[modelNode.name] = prefixedName;

                                foreach (method; modelNode.methods)
                                {
                                    auto methodFunc = cast(FunctionNode) method;
                                    if (methodFunc !is null)
                                    {
                                        string prefixedMethodName = methodFunc.name.startsWith("std_") ? methodFunc.name
                                            : (sanitizedModuleName ~ "_" ~ methodFunc.name);
                                        moduleFunctionMap[methodFunc.name] = prefixedMethodName;
                                    }
                                }
                            }
                        }
                        else if (pChild.nodeType == "Enum")
                        {
                            auto enumNode = cast(EnumNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(enumNode.name))
                            {
                                moduleModelMap[enumNode.name] = enumNode.name;
                            }
                        }
                        else if (pChild.nodeType == "Macro")
                        {
                            auto macroNode = cast(MacroNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(macroNode.name))
                            {
                                moduleMacroMap[macroNode.name] = macroNode.name;
                            }
                        }
                        else if (pChild.nodeType == "Overload")
                        {
                            auto overloadNode = cast(OverloadNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(overloadNode.name))
                            {
                                moduleMacroMap[overloadNode.name] = overloadNode.name;
                            }
                        }
                    }

                    if (platformImports !is null)
                    {
                        string headerKey;
                        foreach (pChild; platformImports.children)
                        {
                            auto extChild = cast(ExternalImportNode) pChild;
                            if (headerKey.length > 0)
                                headerKey ~= ",";
                            headerKey ~= extChild.headerFile;
                        }
                        string key = "__platform_external_imports__" ~ platformImports.platform ~ "__" ~ headerKey;
                        if (key !in g_addedNodeNames)
                        {
                            g_addedNodeNames[key] = true;
                            newChildren ~= platformImports;
                        }
                    }
                }

                if (importChild.nodeType == "Use")
                {
                    newChildren ~= importChild;
                }
                else if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                    {
                        string prefixedName = funcNode.name.startsWith("std_") ? funcNode.name
                            : (sanitizedModuleName ~ "_" ~ funcNode.name);
                        moduleFunctionMap[funcNode.name] = prefixedName;
                    }
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(modelNode.name))
                    {
                        string prefixedName = modelNode.name.startsWith("std_") ? modelNode.name
                            : (sanitizedModuleName ~ "_" ~ modelNode.name);
                        moduleModelMap[modelNode.name] = prefixedName;

                        foreach (method; modelNode.methods)
                        {
                            auto methodFunc = cast(FunctionNode) method;
                            if (methodFunc !is null)
                            {
                                string prefixedMethodName = methodFunc.name.startsWith("std_") ? methodFunc.name
                                    : (sanitizedModuleName ~ "_" ~ methodFunc.name);
                                moduleFunctionMap[methodFunc.name] = prefixedMethodName;
                            }
                        }
                    }
                }
                else if (importChild.nodeType == "Enum")
                {
                    auto enumNode = cast(EnumNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(enumNode.name))
                    {
                        moduleModelMap[enumNode.name] = enumNode.name;
                    }
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(macroNode.name))
                    {
                        moduleMacroMap[macroNode.name] = macroNode.name;
                    }
                }
                else if (importChild.nodeType == "Overload")
                {
                    auto overloadNode = cast(OverloadNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(overloadNode.name))
                    {
                        moduleMacroMap[overloadNode.name] = overloadNode.name;
                    }
                }
            }

            if (useNode.importAll)
            {
                import std.algorithm : canFind;

                foreach (name; moduleMacroMap.keys)
                {
                    if (!useNode.imports.canFind(name))
                        useNode.imports ~= name;
                }
            }

            bool[string] resolvedImports;

            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Platform")
                {
                    auto platformNode = cast(PlatformNode) importChild;
                    PlatformNode newPlatform = new PlatformNode(platformNode.platform);

                    foreach (pChild; platformNode.children)
                    {
                        if (pChild.nodeType == "Function")
                        {
                            auto funcNode = cast(FunctionNode) pChild;

                            if (funcNode.name == "main")
                                continue;

                            if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                                resolvedImports[funcNode.name] = true;

                            if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                            {
                                string originalName = funcNode.name;
                                string prefixedName = moduleFunctionMap[originalName];

                                funcNode.name = prefixedName;
                                importedFunctions[originalName] = prefixedName;
                                renameFunctionCalls(funcNode, moduleFunctionMap);
                                renameTypeReferences(funcNode, moduleModelMap);
                                newPlatform.children ~= funcNode;
                                g_addedNodeNames[prefixedName] = true;
                            }
                            else
                            {
                                bool alreadyAdded = false;
                                foreach (existingChild; newPlatform.children)
                                {
                                    if (existingChild.nodeType == "Function")
                                    {
                                        auto existingFunc = cast(FunctionNode) existingChild;
                                        if (existingFunc.name == funcNode.name)
                                        {
                                            alreadyAdded = true;
                                            break;
                                        }
                                    }
                                }

                                if (!alreadyAdded)
                                {
                                    renameFunctionCalls(funcNode, moduleFunctionMap);
                                    renameTypeReferences(funcNode, moduleModelMap);
                                    foreach (childNode; funcNode.children)
                                    {
                                        renameFunctionCalls(childNode, moduleFunctionMap);
                                        renameTypeReferences(childNode, moduleModelMap);
                                    }
                                    newPlatform.children ~= funcNode;
                                }
                            }
                        }
                        else if (pChild.nodeType == "Model")
                        {
                            auto modelNode = cast(ModelNode) pChild;

                            if (useNode.importAll || useNode.imports.canFind(modelNode.name))
                            {
                                resolvedImports[modelNode.name] = true;
                            }

                            if (useNode.importAll || useNode.imports.canFind(modelNode.name))
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
                                        auto newMethod = new FunctionNode(prefixedMethodName, methodFunc.params);
                                        newMethod.returnType = methodFunc.returnType;
                                        newMethod.children = methodFunc.children;

                                        renameFunctionCalls(newMethod, moduleFunctionMap);
                                        renameTypeReferences(newMethod, moduleModelMap);

                                        newModel.methods ~= newMethod;
                                        importedFunctions[methodFunc.name] = prefixedMethodName;
                                    }
                                }

                                newPlatform.children ~= newModel;
                                g_addedNodeNames[prefixedName] = true;
                            }
                            else
                            {
                                bool alreadyAdded = false;
                                foreach (existingChild; newPlatform.children)
                                {
                                    if (existingChild.nodeType == "Model")
                                    {
                                        auto existingModel = cast(ModelNode) existingChild;
                                        if (existingModel.name == modelNode.name)
                                        {
                                            alreadyAdded = true;
                                            break;
                                        }
                                    }
                                }

                                if (!alreadyAdded)
                                {
                                    isTransitiveDependency[modelNode.name] = true;

                                    foreach (method; modelNode.methods)
                                    {
                                        auto methodFunc = cast(FunctionNode) method;
                                        if (methodFunc !is null)
                                        {
                                            renameFunctionCalls(methodFunc, moduleFunctionMap);
                                            renameTypeReferences(methodFunc, moduleModelMap);
                                        }
                                    }

                                    newPlatform.children ~= modelNode;
                                }
                            }
                        }
                        else if (pChild.nodeType == "Enum")
                        {
                            auto enumNode = cast(EnumNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(enumNode.name))
                            {
                                resolvedImports[enumNode.name] = true;
                                enumNode.name = moduleModelMap[enumNode.name];
                                newPlatform.children ~= enumNode;
                            }
                            else
                            {
                                bool alreadyAdded = false;
                                foreach (existingChild; newPlatform.children)
                                {
                                    if (existingChild.nodeType == "Enum")
                                    {
                                        auto existingEnum = cast(EnumNode) existingChild;
                                        if (existingEnum.name == enumNode.name)
                                        {
                                            alreadyAdded = true;
                                            break;
                                        }
                                    }
                                }

                                if (!alreadyAdded)
                                {
                                    newPlatform.children ~= enumNode;
                                }
                            }
                        }
                        else if (pChild.nodeType == "Macro")
                        {
                            auto macroNode = cast(MacroNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(macroNode.name))
                            {
                                resolvedImports[macroNode.name] = true;
                                macroNode.name = moduleMacroMap[macroNode.name];
                                newPlatform.children ~= macroNode;
                            }
                            else
                            {
                                bool alreadyAdded = false;
                                foreach (existingChild; newPlatform.children)
                                {
                                    if (existingChild.nodeType == "Macro")
                                    {
                                        auto existingMacro = cast(MacroNode) existingChild;
                                        if (existingMacro.name == macroNode.name)
                                        {
                                            alreadyAdded = true;
                                            break;
                                        }
                                    }
                                }

                                if (!alreadyAdded)
                                {
                                    newPlatform.children ~= macroNode;
                                }
                            }
                        }
                        else if (pChild.nodeType == "Overload")
                        {
                            auto overloadNode = cast(OverloadNode) pChild;
                            if (useNode.importAll || useNode.imports.canFind(overloadNode.name))
                            {
                                resolvedImports[overloadNode.name] = true;
                                overloadNode.name = moduleMacroMap[overloadNode.name];
                                newPlatform.children ~= overloadNode;
                            }
                            else
                            {
                                bool alreadyAdded = false;
                                foreach (existingChild; newPlatform.children)
                                {
                                    if (existingChild.nodeType == "Overload")
                                    {
                                        auto existingOverload = cast(OverloadNode) existingChild;
                                        if (existingOverload.name == overloadNode.name)
                                        {
                                            alreadyAdded = true;
                                            break;
                                        }
                                    }
                                }

                                if (!alreadyAdded)
                                {
                                    newPlatform.children ~= overloadNode;
                                }
                            }
                        }
                    }

                    if (newPlatform.children.length > 0)
                    {
                        newChildren ~= newPlatform;
                    }

                    continue;
                }

                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    
                    if (funcNode.name == "main")
                        continue;
                    
                    if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                        resolvedImports[funcNode.name] = true;

                    // Always add functions from imported modules (including transitive dependencies)
                    // But only rename if explicitly imported
                    if (useNode.importAll || useNode.imports.canFind(funcNode.name))
                    {
                        string originalName = funcNode.name;
                        string prefixedName = moduleFunctionMap[originalName];

                        // Rename the function definition itself so that
                        // generated C has a matching symbol for rewritten
                        // call sites (e.g., std_io_read_int).
                        funcNode.name = prefixedName;

                        // Name map must use the ORIGINAL name as key so that
                        // call sites like read_int() or randomize() get
                        // rewritten to the prefixed symbol.
                        importedFunctions[originalName] = prefixedName;
                        renameFunctionCalls(funcNode, moduleFunctionMap);
                        renameTypeReferences(funcNode, moduleModelMap);
                        newChildren ~= funcNode;
                        g_addedNodeNames[prefixedName] = true;
                    }
                    else
                    {
                        // Add transitive dependency functions as-is (don't rename them)
                        // But avoid duplicates by checking if already in newChildren
                        bool alreadyAdded = false;
                        foreach (existingChild; newChildren)
                        {
                            if (existingChild.nodeType == "Function")
                            {
                                auto existingFunc = cast(FunctionNode) existingChild;
                                if (existingFunc.name == funcNode.name)
                                {
                                    alreadyAdded = true;
                                    debugWriteln("DEBUG: Skipping duplicate transitive function: ", funcNode
                                            .name);
                                    break;
                                }
                            }
                        }

                        if (!alreadyAdded)
                        {
                            debugWriteln("DEBUG: Adding transitive function: ", funcNode.name);

                            renameFunctionCalls(funcNode, moduleFunctionMap);
                            renameTypeReferences(funcNode, moduleModelMap);
                            foreach (childNode; funcNode.children)
                            {
                                renameFunctionCalls(childNode, moduleFunctionMap);
                                renameTypeReferences(childNode, moduleModelMap);
                            }
                            newChildren ~= funcNode;
                        }
                    }
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(modelNode.name))
                    {
                        resolvedImports[modelNode.name] = true;
                    }

                    if (useNode.importAll || useNode.imports.canFind(modelNode.name))
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
                        g_addedNodeNames[prefixedName] = true;
                    }
                    else
                    {
                        bool alreadyAdded = false;
                        foreach (existingChild; newChildren)
                        {
                            if (existingChild.nodeType == "Model")
                            {
                                auto existingModel = cast(ModelNode) existingChild;
                                if (existingModel.name == modelNode.name)
                                {
                                    alreadyAdded = true;
                                    debugWriteln("DEBUG: Skipping duplicate transitive model: ", modelNode
                                            .name);
                                    break;
                                }
                            }
                        }

                        if (!alreadyAdded)
                        {
                            isTransitiveDependency[modelNode.name] = true;
                            debugWriteln("DEBUG: Adding transitive model: ", modelNode.name);

                            foreach (method; modelNode.methods)
                            {
                                auto methodFunc = cast(FunctionNode) method;
                                if (methodFunc !is null)
                                {
                                    renameFunctionCalls(methodFunc, moduleFunctionMap);
                                    renameTypeReferences(methodFunc, moduleModelMap);
                                }
                            }

                            newChildren ~= modelNode;
                        }
                    }
                }
                else if (importChild.nodeType == "Enum")
                {
                    auto enumNode = cast(EnumNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(enumNode.name))
                    {
                        resolvedImports[enumNode.name] = true;
                        enumNode.name = moduleModelMap[enumNode.name]; // Prefix the name
                        newChildren ~= enumNode;
                    }
                    else
                    {
                        bool alreadyAdded = false;
                        foreach (existingChild; newChildren)
                        {
                            if (existingChild.nodeType == "Enum")
                            {
                                auto existingEnum = cast(EnumNode) existingChild;
                                if (existingEnum.name == enumNode.name)
                                {
                                    alreadyAdded = true;
                                    break;
                                }
                            }
                        }

                        if (!alreadyAdded)
                        {
                            newChildren ~= enumNode;
                        }
                    }
                }
                else if (importChild.nodeType == "Macro")
                {
                    auto macroNode = cast(MacroNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(macroNode.name))
                    {
                        resolvedImports[macroNode.name] = true;
                        macroNode.name = moduleMacroMap[macroNode.name];
                        newChildren ~= macroNode;
                    }
                    else
                    {
                        bool alreadyAdded = false;
                        foreach (existingChild; newChildren)
                        {
                            if (existingChild.nodeType == "Macro")
                            {
                                auto existingMacro = cast(MacroNode) existingChild;
                                if (existingMacro.name == macroNode.name)
                                {
                                    alreadyAdded = true;
                                    break;
                                }
                            }
                        }

                        if (!alreadyAdded)
                        {
                            newChildren ~= macroNode;
                        }
                    }
                }
                else if (importChild.nodeType == "Overload")
                {
                    auto overloadNode = cast(OverloadNode) importChild;
                    if (useNode.importAll || useNode.imports.canFind(overloadNode.name))
                    {
                        resolvedImports[overloadNode.name] = true;
                        overloadNode.name = moduleMacroMap[overloadNode.name];
                        newChildren ~= overloadNode;
                    }
                    else
                    {
                        bool alreadyAdded = false;
                        foreach (existingChild; newChildren)
                        {
                            if (existingChild.nodeType == "Overload")
                            {
                                auto existingOverload = cast(OverloadNode) existingChild;
                                if (existingOverload.name == overloadNode.name)
                                {
                                    alreadyAdded = true;
                                    break;
                                }
                            }
                        }

                        if (!alreadyAdded)
                        {
                            newChildren ~= overloadNode;
                        }
                    }
                }
            }

            foreach (importName; useNode.imports)
            {
                if (importName !in resolvedImports)
                {
                    throw new Exception(
                        "Import '" ~ importName ~ "' not found in module '" ~
                            useNode.moduleName ~ "'");
                }
            }

            newChildren ~= child;
        }
        else
        {
            debugWriteln("DEBUG imports: Renaming user code with ", importedFunctions.length, " imported functions");
            foreach (key, value; importedFunctions)
            {
                debugWriteln("  DEBUG: importedFunctions['", key, "'] = '", value, "'");
            }

            if (child.nodeType == "Model" && currentModulePrefix.length > 0)
            {
                auto modelNode = cast(ModelNode) child;

                if (modelNode.name in isTransitiveDependency)
                {
                    newChildren ~= child;
                    continue;
                }

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

                        string[string] localTypeMap = importedModels.dup;
                        foreach (modelName, prefixedName; localModels)
                        {
                            localTypeMap[modelName] = prefixedName;
                        }

                        renameFunctionCalls(methodFunc, importedFunctions);
                        renameTypeReferences(methodFunc, localTypeMap);
                    }
                }
            }
            else if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;

                if (modelNode.name in isTransitiveDependency)
                {
                    newChildren ~= child;
                    continue;
                }

                string[string] localTypeMap = importedModels.dup;
                foreach (modelName, prefixedName; localModels)
                {
                    localTypeMap[modelName] = prefixedName;
                }

                foreach (method; modelNode.methods)
                {
                    renameFunctionCalls(method, importedFunctions);
                    renameTypeReferences(method, localTypeMap);
                }

                foreach (ref field; modelNode.fields)
                {
                    if (field.type in localTypeMap)
                        field.type = localTypeMap[field.type];
                }

                renameFunctionCalls(child, importedFunctions);
                renameTypeReferences(child, importedModels);
            }
            else if (child.nodeType == "Function" && (currentModulePrefix.length > 0 || importedFunctions.length > 0))
            {
                auto funcNode = cast(FunctionNode) child;
                if (funcNode.name in isTransitiveDependency)
                {
                    newChildren ~= child;
                    continue;
                }

                string[string] localTypeMap = importedModels.dup;
                foreach (modelName, prefixedName; localModels)
                {
                    localTypeMap[modelName] = prefixedName;
                }

                // Don't apply localFunctions renaming - they're in the same compilation unit
                // and should not be prefixed when called from main
                renameFunctionCalls(child, importedFunctions);
                renameTypeReferences(child, localTypeMap);
            }
            else if (child.nodeType == "Test" && currentModulePrefix.length > 0)
            {
                string[string] localTypeMap = importedModels.dup;
                string[string] localNameMap = importedFunctions.dup;
                string normalizedFilePath = currentFilePath.replace("\\", "/");
                if (normalizedFilePath.canFind("std/") && currentModulePrefix.length > 0)
                {
                    foreach (modelMethod, prefixedName; localFunctions)
                    {
                        localNameMap[modelMethod] = prefixedName;
                    }
                }

                renameFunctionCalls(child, localNameMap);
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

string escapeRegexLiteral(string value)
{
    import std.array : appender;

    auto buffer = appender!string();
    foreach (ch; value)
    {
        immutable bool needsEscape = ch == '\\' || ch == '.' || ch == '+' || ch == '*' || ch == '?' || ch == '|' ||
            ch == '{' || ch == '}' || ch == '[' || ch == ']' || ch == '(' || ch == ')' || ch == '^' || ch == '$';
        if (needsEscape)
            buffer.put('\\');
        buffer.put(ch);
    }
    return buffer.data;
}

string replaceStandaloneCall(string text, string oldName, string newName)
{
    import std.regex : regex, replaceAll;

    if (newName.canFind("_" ~ oldName) && text.canFind(newName ~ "("))
    {
        return text;
    }

    auto escaped = escapeRegexLiteral(oldName);
    auto pattern = regex("(?<![A-Za-z0-9_])" ~ escaped ~ "(\\s*)\\(");
    return replaceAll(text, pattern, newName ~ "$1(");
}

/**
 * TODO: Fix double-prefixed function names (e.g., stdlib_string_stdlib_string_concat -> stdlib_string_concat)
 * This is a NOOP for the moment.
 */
string fixDoublePrefix(string expr)
{
    import std.regex : regex, replaceAll;

    string fixedExpr = expr;

    return fixedExpr;
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

        // Also apply renaming inside FunctionCall arguments. This is
        // important for nested calls like `compare(upper, string.create("X"))`
        // where `string.create` only appears as text in the args.
        foreach (ref arg; callNode.args)
        {
            foreach (oldName, newName; nameMap)
            {
                arg = replaceStandaloneCall(arg, oldName, newName);

                if (oldName.canFind("_"))
                {
                    string oldCallDot = oldName.replace("_", ".") ~ "(";
                    if (arg.canFind(oldCallDot))
                    {
                        arg = arg.replace(oldCallDot, newName ~ "(");
                    }
                }
            }
        }
    }
    else if (node.nodeType == "Print")
    {
        auto printNode = cast(PrintNode) node;
        for (size_t i = 0; i < printNode.messages.length; i++)
        {
            if (i >= printNode.isExpressions.length || !printNode.isExpressions[i])
                continue;
            {
                foreach (oldName, newName; nameMap)
                {
                    printNode.messages[i] = replaceStandaloneCall(printNode.messages[i], oldName, newName);

                    if (oldName.canFind("_"))
                    {
                        string oldCallDot = oldName.replace("_", ".") ~ "(";
                        printNode.messages[i] = printNode.messages[i].replace(oldCallDot, newName ~ "(");
                    }
                }
                // FIX DOUBLE-PREFIXING in Print
                printNode.messages[i] = fixDoublePrefix(printNode.messages[i]);
            }
        }
    }
    else if (node.nodeType == "Println")
    {
        auto printlnNode = cast(PrintlnNode) node;
        for (size_t i = 0; i < printlnNode.messages.length; i++)
        {
            if (printlnNode.isExpressions[i])
            {
                foreach (oldName, newName; nameMap)
                {
                    printlnNode.messages[i] = replaceStandaloneCall(printlnNode.messages[i], oldName, newName);
                    if (oldName.canFind("_"))
                    {
                        string oldCallDot = oldName.replace("_", ".") ~ "(";
                        printlnNode.messages[i] = printlnNode.messages[i].replace(oldCallDot, newName ~ "(");
                    }
                }
                // FIX DOUBLE-PREFIXING in Println
                printlnNode.messages[i] = fixDoublePrefix(printlnNode.messages[i]);
            }
        }
    }
    else if (node.nodeType == "Return")
    {
        auto returnNode = cast(ReturnNode) node;
        debugWriteln("    DEBUG Return before processing: '", returnNode.expression, "'");
        debugWriteln("    DEBUG Return nameMap: ", nameMap);
        foreach (oldName, newName; nameMap)
        {
            string before = returnNode.expression;
            returnNode.expression = replaceStandaloneCall(returnNode.expression, oldName, newName);
            if (before != returnNode.expression)
                debugWriteln("      DEBUG Return replaced '", oldName, "' -> '", newName, "': '", returnNode
                        .expression, "'");

            if (oldName.canFind("_"))
            {
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                if (returnNode.expression.canFind(oldCallDot))
                {
                    before = returnNode.expression;
                    returnNode.expression = returnNode.expression.replace(oldCallDot, newName ~ "(");
                    debugWriteln("      DEBUG Return replaced dot call '", oldCallDot, "' -> '", newName, "(': '",
                        returnNode.expression, "'");
                }
            }

            import std.regex : regex, replaceAll;

            if (returnNode.expression.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                string newExpr = replaceAll(returnNode.expression, dotPattern, newName ~ "(");
                if (newExpr != returnNode.expression)
                {
                    debugWriteln("      DEBUG Return regex replaced pattern: '", returnNode.expression, "' -> '",
                        newExpr, "'");
                    returnNode.expression = newExpr;
                }
            }
        }

        // FIX DOUBLE-PREFIXING: Apply post-processing fix
        returnNode.expression = fixDoublePrefix(returnNode.expression);

        debugWriteln("    DEBUG Return after processing: '", returnNode.expression, "'");
    }
    else if (node.nodeType == "Declaration")
    {
        auto declNode = cast(DeclarationNode) node;
        debugWriteln("    DEBUG renameFunctionCalls Declaration: initializer='", declNode.initializer, "'");
        foreach (oldName, newName; nameMap)
        {
            auto newInit = replaceStandaloneCall(declNode.initializer, oldName, newName);
            if (newInit != declNode.initializer)
            {
                debugWriteln("    DEBUG renameFunctionCalls: Renamed call in declaration: '", oldName,
                    "' -> '", newName, "'");
                declNode.initializer = newInit;
            }

            if (oldName.canFind("_"))
            {
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                if (declNode.initializer.canFind(oldCallDot))
                {
                    debugWriteln("    DEBUG renameFunctionCalls: Renamed dot call in declaration: '",
                        oldCallDot, "' -> '", newName, "(");
                    declNode.initializer = declNode.initializer.replace(oldCallDot, newName ~ "(");
                }
            }

            // Also check for dot notation with regex: Model.method( or Model . method(
            // Use word boundary to ensure we don't match floating point literals like 0.5
            import std.regex : regex, replaceAll;

            if (declNode.initializer.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                debugWriteln("    DEBUG: Trying regex pattern '\\b", modelMethod, "\\s*\\(' on '",
                    declNode.initializer, "'");
                string regexInit = replaceAll(declNode.initializer, dotPattern, newName ~ "(");
                if (regexInit != declNode.initializer)
                {
                    debugWriteln("    DEBUG: Regex matched! Replaced '", declNode.initializer,
                        "' -> '", regexInit, "'");
                    declNode.initializer = regexInit;
                }
            }
        }
        declNode.initializer = fixDoublePrefix(declNode.initializer);
    }
    else if (node.nodeType == "Assignment")
    {
        auto assignNode = cast(AssignmentNode) node;
        foreach (oldName, newName; nameMap)
        {
            assignNode.expression = replaceStandaloneCall(assignNode.expression, oldName, newName);

            if (oldName.canFind("_"))
            {
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                if (assignNode.expression.canFind(oldCallDot))
                {
                    assignNode.expression = assignNode.expression.replace(oldCallDot, newName ~ "(");
                }
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
        assignNode.expression = fixDoublePrefix(assignNode.expression);

        // TODO: Remove.
        if (assignNode.expression.canFind("read_int("))
        {
            assignNode.expression = assignNode.expression.replace("read_int(", "std_io_read_int(");
        }
        if (assignNode.expression.canFind("read_float("))
        {
            assignNode.expression = assignNode.expression.replace("read_float(", "std_io_read_float(");
        }
        if (assignNode.expression.canFind("read_string("))
        {
            assignNode.expression = assignNode.expression.replace("read_string(", "std_io_read_string(");
        }
    }
    else if (node.nodeType == "If")
    {
        auto ifNode = cast(IfNode) node;

        debugWriteln("    DEBUG renameFunctionCalls If: condition='", ifNode.condition, "'");
        foreach (oldName, newName; nameMap)
        {
            auto newCond = replaceStandaloneCall(ifNode.condition, oldName, newName);
            if (newCond != ifNode.condition)
            {
                debugWriteln("    DEBUG renameFunctionCalls: Renamed call in if condition: '", oldName,
                    "' -> '", newName, "'");
                ifNode.condition = newCond;
            }

            // For model methods with dot notation in conditions, reuse the
            // underscore-based mapping. Guard on '_' to avoid substring
            // issues for plain functions like 'strip' vs 'lstrip'.
            if (oldName.canFind("_"))
            {
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                if (ifNode.condition.canFind(oldCallDot))
                {
                    debugWriteln("    DEBUG renameFunctionCalls: Renamed dot call in if condition: '",
                        oldCallDot, "' -> '", newName, "(");
                    ifNode.condition = ifNode.condition.replace(oldCallDot, newName ~ "(");
                }
            }
        }

        // Also propagate renaming into elif and else branches, which are
        // stored separately from the main children array.
        foreach (elifBranch; ifNode.elifBranches)
        {
            renameFunctionCalls(elifBranch, nameMap);
        }

        foreach (elseChild; ifNode.elseBody)
        {
            renameFunctionCalls(elseChild, nameMap);
        }

        ifNode.condition = fixDoublePrefix(ifNode.condition);
    }
    else if (node.nodeType == "Assert")
    {
        auto assertNode = cast(AssertNode) node;
        foreach (oldName, newName; nameMap)
        {
            assertNode.condition = replaceStandaloneCall(assertNode.condition, oldName, newName);

            if (oldName.canFind("_"))
            {
                string oldCallDot = oldName.replace("_", ".") ~ "(";
                if (assertNode.condition.canFind(oldCallDot))
                {
                    assertNode.condition = assertNode.condition.replace(oldCallDot, newName ~ "(");
                }
            }

            import std.regex : regex, replaceAll;

            if (assertNode.condition.canFind(".") && oldName.canFind("_"))
            {
                string modelMethod = convertToModelMethodPattern(oldName);
                auto dotPattern = regex("\\b" ~ modelMethod ~ "\\s*\\(");
                string newCond = replaceAll(assertNode.condition, dotPattern, newName ~ "(");
                if (newCond != assertNode.condition)
                {
                    assertNode.condition = newCond;
                }
            }
        }
        // FIX DOUBLE-PREFIXING in Assert
        assertNode.condition = fixDoublePrefix(assertNode.condition);
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

        if (funcNode.returnType in typeMap)
            funcNode.returnType = typeMap[funcNode.returnType];
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
        // We need to try hard to only replace whole words (type names)
        foreach (oldType, newType; typeMap)
        {
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

unittest
{
    import std.string : indexOf;

    assert(convertToModelMethodPattern("Model_method") == r"Model\s*\.\s*method");
    assert(convertToModelMethodPattern("Arena_create") == r"Arena\s*\.\s*create");
}

unittest
{
    import std.string : indexOf;

    string expr1 = "my_func(10)";
    string expr2 = "x + my_func(10)";
    string expr3 = "my_func(10) + x";
    string expr4 = "foo(bar(baz(5)))";

    assert(expr1.indexOf("(") >= 0, "Should find function call");
    assert(expr2.indexOf("my_func") >= 0, "Should find function call in expression");
    assert(expr3.indexOf("my_func") >= 0, "Should find function call in expression");
    assert(expr4.indexOf("(") >= 0, "Should find nested function calls");
}

unittest
{
    assert(convertToModelMethodPattern("List_push") == r"List\s*\.\s*push");
    assert(convertToModelMethodPattern("Arena_alloc") == r"Arena\s*\.\s*alloc");

    import std.regex : regex, matchFirst;

    auto pattern = regex("^" ~ convertToModelMethodPattern("List_push") ~ "$");
    assert(matchFirst("List.push", pattern), "Should match List.push");
    assert(matchFirst("List . push", pattern), "Should match List . push");
}
