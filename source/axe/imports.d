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
    string[string] importedModels;  // Track model renames

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

            // Replace slashes with underscores for valid C identifiers
            string sanitizedModuleName = useNode.moduleName.replace("/", "_");

            foreach (importChild; importProgram.children)
            {
                if (importChild.nodeType == "Function")
                {
                    auto funcNode = cast(FunctionNode) importChild;
                    if (useNode.imports.canFind(funcNode.name))
                    {
                        string prefixedName = sanitizedModuleName ~ "_" ~ funcNode.name;
                        importedFunctions[funcNode.name] = prefixedName;
                        auto newFunc = new FunctionNode(prefixedName, funcNode.params);
                        newFunc.returnType = funcNode.returnType;
                        newFunc.children = funcNode.children;
                        newChildren ~= newFunc;
                    }
                }
                else if (importChild.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) importChild;
                    if (useNode.imports.canFind(modelNode.name))
                    {
                        string prefixedName = sanitizedModuleName ~ "_" ~ modelNode.name;
                        importedModels[modelNode.name] = prefixedName;
                        auto newModel = new ModelNode(prefixedName, null);
                        newModel.fields = modelNode.fields;
                        newChildren ~= newModel;
                    }
                }
            }
        }
        else
        {
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
    if (node.nodeType == "FunctionCall")
    {
        auto callNode = cast(FunctionCallNode) node;
        if (callNode.functionName in nameMap)
        {
            callNode.functionName = nameMap[callNode.functionName];
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
