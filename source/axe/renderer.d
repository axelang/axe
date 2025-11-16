module axe.renderer;

import axe.structs;
import std.string;
import std.array;
import std.exception;
import std.algorithm;
import std.file;
import std.process;
import std.path;
import std.stdio;
import std.ascii;
import std.string;

import std.string : startsWith;

static immutable string[string] g_typeMappings = [
    "i8": "int8_t",
    "u8": "uint8_t",
    "i16": "int16_t",
    "u16": "uint16_t",
    "i32": "int32_t",
    "u32": "uint32_t",
    "i64": "int64_t",
    "u64": "uint64_t",
    "isize": "intptr_t",
    "usize": "uintptr_t",
    "f32": "float",
    "f64": "double",
    "bool": "bool",
    "char": "char",
    "byte": "uint8_t",
    "size": "usize",
    "ptrdiff": "isize"
];

private int[string] g_refDepths;
private bool[string] g_isMutable;
private string[string] g_arrayWidthVars;
private int[][string] g_functionParamReordering;
private MacroNode[string] g_macros;
private bool[string] g_pointerFields;
private string[string] g_varType;
private string[string] g_isPointerVar;
private string[string] g_functionPrefixes;
private string[string] g_modelNames;

struct ParamInfo
{
    string type;
    string name;
    bool isArray;
    int dimensions;
    string[] dimNames;
}

/** 
 * Function to compute reordered C parameters for functions with variable-length arrays.
 * Returns the reordered parameter strings, reorder map, and parameter info array.
 */
string[] computeReorderedCParams(FunctionNode funcNode, out int[] reorderMap, out ParamInfo[] paramInfos)
{
    import std.stdio : writeln;
    import std.string : split, strip, indexOf, lastIndexOf;
    import std.algorithm : count;
    import std.regex : regex, matchAll;

    foreach (param; funcNode.params)
    {
        debug writeln("DEBUG: Processing param: '", param, "'");
        auto lastSpace = param.lastIndexOf(' ');
        while (lastSpace > 0)
        {
            int openBrackets = 0;
            for (size_t i = 0; i < lastSpace; i++)
            {
                if (param[i] == '[')
                    openBrackets++;
                if (param[i] == ']')
                    openBrackets--;
            }
            if (openBrackets == 0)
                break;
            lastSpace = param[0 .. lastSpace].lastIndexOf(' ');
        }

        if (lastSpace > 0)
        {
            string paramType = param[0 .. lastSpace].strip();
            string paramName = param[lastSpace + 1 .. $].strip();

            ParamInfo info;
            info.type = paramType;
            info.name = paramName;
            info.isArray = paramType.canFind('[');
            if (info.isArray)
            {
                info.dimensions = cast(int) paramType.count('[');

                auto dimPattern = regex(r"\[([^\]]+)\]");
                foreach (match; matchAll(paramType, dimPattern))
                {
                    info.dimNames ~= match[1].strip();
                }
            }
            paramInfos ~= info;
        }
    }

    // Second pass: reorder so dimensions come before arrays
    // and convert array syntax to VLA
    string[] dimensionParams;
    string[] otherParams;

    // Collect all dimension parameter names referenced by arrays
    bool[string] referencedDimensions;
    foreach (info; paramInfos)
    {
        if (info.isArray)
        {
            foreach (dimName; info.dimNames)
            {
                referencedDimensions[dimName] = true;
            }
        }
    }

    // Track indices for reordering
    int[] dimensionIndices;
    int[] otherIndices;

    for (int i = 0; i < paramInfos.length; i++)
    {
        if (!paramInfos[i].isArray && paramInfos[i].name in referencedDimensions)
            dimensionIndices ~= i;
        else
            otherIndices ~= i;
    }

    foreach (info; paramInfos)
    {
        if (info.isArray)
        {
            // Convert int[n][m] to VLA syntax: int arrayName[n][m]
            auto bracketPos = info.type.indexOf('[');
            string baseType = info.type[0 .. bracketPos];

            // Apply type mapping to the base type
            baseType = mapAxeTypeToC(baseType);

            if (info.dimNames.length > 0)
            {
                string dimString = "";
                foreach (dimName; info.dimNames)
                {
                    dimString ~= "[" ~ dimName ~ "]";
                }
                otherParams ~= baseType ~ " " ~ info.name ~ dimString;
            }
            else
            {
                otherParams ~= baseType ~ "* " ~ info.name;
            }
        }
        else
        {
            string finalType = mapAxeTypeToC(info.type);
            if (info.name in referencedDimensions)
            {
                dimensionParams ~= finalType ~ " " ~ info.name;
            }
            else
            {
                otherParams ~= finalType ~ " " ~ info.name;
            }
        }
    }
    reorderMap = dimensionIndices ~ otherIndices;
    return dimensionParams ~ otherParams;
}

string mapAxeTypeToC(string axeType)
{
    // Handle pointers/references first
    if (axeType.startsWith("ref "))
    {
        string baseType = axeType[4 .. $].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.startsWith("&mut "))
    {
        string baseType = axeType[5 .. $].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.startsWith("& "))
    {
        string baseType = axeType[2 .. $].strip();
        return "const " ~ mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.endsWith("*"))
    {
        string baseType = axeType[0 .. $-1].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }
    
    // Check if it's a standard type with mapping
    if (axeType in g_typeMappings)
    {
        return g_typeMappings[axeType];
    }
    
    // Default case (user-defined types, etc)
    return axeType;
}

/** 
 * C backend renderer.
 *
 * Params:
 *   ast = Abstract syntax tree to render.
 * Returns: 
 *   Generated C code.
 */
string generateC(ASTNode ast)
{
    string cCode;
    string[string] variables;
    string currentFunction = "";
    string[] functionParams;
    int loopLevel = 0;

    switch (ast.nodeType)
    {
    case "Program":
        g_refDepths.clear();
        g_isMutable.clear();
        g_macros.clear();
        g_pointerFields.clear();
        g_isPointerVar.clear();
        g_varType.clear();
        g_functionPrefixes.clear();
        g_modelNames.clear();

        foreach (child; ast.children)
        {
            if (child.nodeType == "Macro")
            {
                auto macroNode = cast(MacroNode) child;
                g_macros[macroNode.name] = macroNode;
                debug writeln("DEBUG: Pre-stored macro '", macroNode.name, "' with ", macroNode.params.length, " parameters");
            }
            if (child.nodeType == "Use")
            {
                auto useNode = cast(UseNode) child;
                string modulePrefix = useNode.moduleName.replace("/", "_");
                foreach (importName; useNode.imports)
                {
                    if (importName.length > 0 && !(importName[0] >= 'A' && importName[0] <= 'Z'))
                    {
                        g_functionPrefixes[importName] = modulePrefix ~ "_" ~ importName;
                    }
                }
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                // Store the model name mapping
                // Extract base name from prefixed name (e.g., "stdlib_arena_Arena" -> "Arena")
                string baseName = modelNode.name;
                // Check if it's a prefixed name (contains underscore and starts with stdlib_)
                if (modelNode.name.canFind("_") && modelNode.name.startsWith("stdlib_"))
                {
                    // Find the last underscore to get the base name
                    auto lastUnderscore = modelNode.name.lastIndexOf('_');
                    if (lastUnderscore >= 0)
                    {
                        baseName = modelNode.name[lastUnderscore + 1 .. $];
                        g_modelNames[baseName] = modelNode.name;
                    }
                }
                else
                {
                    // Not prefixed, so base name is the same as the model name
                    g_modelNames[modelNode.name] = modelNode.name;
                }
                
                foreach (field; modelNode.fields)
                {
                    if (field.type == modelNode.name)
                        g_pointerFields[modelNode.name ~ "." ~ field.name] = true;
                }
            }
        }

        cCode ~= "#define nil ((void*)0)\n";
        cCode ~= "#include <stdio.h>\n";
        cCode ~= "#include <stdbool.h>\n";
        cCode ~= "#include <stdlib.h>\n";
        cCode ~= "#include <string.h>\n";
        cCode ~= "#include <stdint.h>\n";
        cCode ~= "\n";

        version (Windows)
        {
            cCode ~= "#include <windows.h>\n";
        }

        cCode ~= "\n";

        foreach (child; ast.children)
        {
            if (child.nodeType == "ExternalImport")
                cCode ~= generateC(child);
        }

        cCode ~= "int __axe_argc = 0;\n";
        cCode ~= "char** __axe_argv = NULL;\n\n\n";

        foreach (child; ast.children)
        {
            if (child.nodeType == "Enum")
                cCode ~= generateC(child) ~ "\n";
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
                cCode ~= generateC(child) ~ "\n";
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                if (funcNode.name != "main")
                {
                    string processedReturnType = mapAxeTypeToC(funcNode.returnType);
                    cCode ~= processedReturnType ~ " " ~ funcNode.name ~ "(";
                    if (funcNode.params.length > 0)
                    {
                        int[] reorderMap;
                        ParamInfo[] paramInfos;
                        string[] processedParams = computeReorderedCParams(funcNode, reorderMap, paramInfos);
                        cCode ~= processedParams.join(", ");
                        g_functionParamReordering[funcNode.name] = reorderMap;

                        foreach (info; paramInfos)
                        {
                            g_varType[info.name] = info.type;
                            if (info.type.canFind("*"))
                                g_refDepths[info.name] = 1;
                        }
                    }
                    cCode ~= ");\n";
                }
            }
            else if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    auto methodFunc = cast(FunctionNode) method;
                    if (methodFunc !is null)
                    {
                        string processedReturnType = mapAxeTypeToC(methodFunc.returnType);
                        cCode ~= processedReturnType ~ " " ~ methodFunc.name ~ "(";
                        if (methodFunc.params.length > 0)
                        {
                            int[] reorderMap;
                            ParamInfo[] paramInfos;
                            string[] processedParams = computeReorderedCParams(methodFunc, reorderMap, paramInfos);
                            cCode ~= processedParams.join(", ");
                            g_functionParamReordering[methodFunc.name] = reorderMap;
                        }
                        cCode ~= ");\n";
                    }
                }
            }
        }
        cCode ~= "\n";

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    cCode ~= generateC(method) ~ "\n";
                }
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType != "Model" && child.nodeType != "ExternalImport" && child.nodeType != "Enum")
                cCode ~= generateC(child) ~ "\n";
        }
        break;

    case "Main":
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        cCode ~= "    return 0;\n";
        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Function":
        auto funcNode = cast(FunctionNode) ast;
        string funcName = funcNode.name;
        string[] params = funcNode.params;
        string prevFunction = currentFunction;
        currentFunction = funcName;
        functionParams = params;

        if (funcNode.name == "main")
        {
            cCode ~= generateStackTraceHandlers();
            cCode ~= "int main(int argc, char** argv) {\n";
            cCode ~= "__axe_argc = argc;\n";
            cCode ~= "__axe_argv = argv;\n";
            cCode ~= generateStackTraceSetup();
            version (Windows)
            {
                cCode ~= "SetConsoleOutputCP(CP_UTF8);\n";
            }
        }
        else
        {
            string processedReturnType = mapAxeTypeToC(funcNode.returnType);
            cCode ~= processedReturnType ~ " " ~ funcName ~ "(";
            if (params.length > 0)
            {
                int[] reorderMap;
                ParamInfo[] paramInfos;
                string[] processedParams = computeReorderedCParams(funcNode, reorderMap, paramInfos);
                cCode ~= processedParams.join(", ");
                g_functionParamReordering[funcName] = reorderMap;

                foreach (info; paramInfos)
                {
                    g_varType[info.name] = info.type;
                    if (info.type.canFind("*"))
                        g_refDepths[info.name] = 1;
                }
            }
            cCode ~= ") {\n";
        }

        foreach (child; ast.children)
            cCode ~= generateC(child);

        if (funcNode.name == "main")
            cCode ~= "return 0;\n";

        currentFunction = prevFunction;
        cCode ~= "}\n";
        break;

    case "FunctionCall":
        auto callNode = cast(FunctionCallNode) ast;
        string callName = callNode.functionName;

        if (callName.canFind("."))
        {
            // Handle method calls (e.g., Arena.create -> stdlib_arena_Arena_create)
            auto parts = callName.split(".");
            string modelName = parts[0].strip();
            string methodName = parts[1].strip();
            
            // Look up the prefixed model name
            if (modelName in g_modelNames)
            {
                string prefixedModelName = g_modelNames[modelName];
                callName = prefixedModelName ~ "_" ~ methodName;
            }
            else
            {
                // Fallback: just replace dot with underscore
                callName = callName.replace(".", "_");
            }
        }
        else if (callName in g_functionPrefixes)
        {
            callName = g_functionPrefixes[callName];
        }
        else if (currentFunction.canFind("stdlib_arena_"))
        {
            // Prefix calls within stdlib modules
            callName = "stdlib_arena_" ~ callName;
        }

        if (callName in g_macros)
        {
            writeln("DEBUG: Expanding macro '", callName, "'");
            auto macroNode = g_macros[callName];

            import std.string : split, strip;

            string[] callArgs;
            if (callNode.args.length > 0)
            {
                foreach (arg; callNode.args)
                    callArgs ~= arg.strip();
            }

            string[string] paramMap;
            for (size_t i = 0; i < macroNode.params.length && i < callArgs.length;
                i++)
            {
                string processedArg = processExpression(callArgs[i]);
                paramMap[macroNode.params[i]] = processedArg;
                writeln("  DEBUG: Mapping '", macroNode.params[i], "' -> '", processedArg, "'");
            }

            string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
            foreach (child; macroNode.children)
            {
                if (child.nodeType == "RawC")
                {
                    auto rawNode = cast(RawCNode) child;
                    string expandedCode = rawNode.code;

                    foreach (paramName, paramValue; paramMap)
                    {
                        expandedCode = expandedCode.replace(paramName, paramValue);
                    }

                    cCode ~= indent ~ expandedCode ~ "\n";
                }
            }
            break;
        }

        string[] processedArgs;

        foreach (arg; callNode.args)
            processedArgs ~= processExpression(arg, "function_call");

        if (callName in g_functionParamReordering)
        {
            int[] reorderMap = g_functionParamReordering[callName];
            string[] reorderedArgs;
            reorderedArgs.length = processedArgs.length;

            for (int i = 0; i < reorderMap.length && i < processedArgs.length; i++)
            {
                reorderedArgs[i] = processedArgs[reorderMap[i]];
            }
            processedArgs = reorderedArgs;
        }

        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        cCode ~= indent ~ callName ~ "(" ~ processedArgs.join(", ") ~ ");\n";
        break;

    case "Assignment":
        auto assignNode = cast(AssignmentNode) ast;

        import std.stdio : writeln;
        import std.string : indexOf;

        debug writeln("DEBUG Assignment: variable='", assignNode.variable, "'");
        string dest = processExpression(assignNode.variable.strip());
        writeln("DEBUG Assignment: variable='", assignNode.variable, "' dest='", dest, "'");
        string expr = assignNode.expression.strip();

        string baseVarName = dest;
        auto bracketPos = dest.indexOf('[');
        if (bracketPos > 0)
        {
            baseVarName = dest[0 .. bracketPos];
        }

        if (baseVarName !in variables && !functionParams.canFind(baseVarName) && currentFunction != "")
        {
            variables[baseVarName] = "int";
            cCode ~= "int " ~ dest;

            if (expr.length > 0)
            {
                string processedExpr = processExpression(expr, "assignment");
                cCode ~= " = " ~ processedExpr;
            }
            cCode ~= ";\n";
        }
        else
        {
            if (baseVarName in g_isMutable && !g_isMutable[baseVarName])
                throw new Exception(
                    "Cannot assign to immutable variable '" ~ baseVarName ~ "' (declared with 'val')");

            string processedExpr = processExpression(expr, "assignment");

            cCode ~= dest ~ " = " ~ processedExpr ~ ";\n";
        }
        break;

    case "ArrayDeclaration":
        auto arrayNode = cast(ArrayDeclarationNode) ast;
        string arrayType = arrayNode.isMutable ? arrayNode.elementType
            : "const " ~ arrayNode.elementType;

        if (arrayNode.size2.length > 0)
        {
            cCode ~= arrayType ~ " " ~ arrayNode.name ~ "[" ~ arrayNode.size ~ "][" ~ arrayNode.size2 ~ "]";
        }
        else
        {
            cCode ~= arrayType ~ " " ~ arrayNode.name ~ "[" ~ arrayNode.size ~ "]";
        }
        if (arrayNode.initializer.length > 0)
        {
            cCode ~= " = {" ~ arrayNode.initializer.join(", ") ~ "}";
        }

        cCode ~= ";\n";
        break;

    case "ArrayAccess":
        auto accessNode = cast(ArrayAccessNode) ast;
        if (accessNode.index2.length > 0)
        {
            cCode ~= accessNode.arrayName ~ "[" ~ processExpression(
                accessNode.index) ~ "][" ~ processExpression(accessNode.index2) ~ "]";
        }
        else
        {
            cCode ~= accessNode.arrayName ~ "[" ~ processExpression(accessNode.index) ~ "]";
        }
        break;

    case "ArrayAssignment":
        auto arrayAssignNode = cast(ArrayAssignmentNode) ast;
        string processedIndex = processExpression(arrayAssignNode.index);
        string processedValue = processExpression(arrayAssignNode.value);
        if (arrayAssignNode.index2.length > 0)
        {
            string processedIndex2 = processExpression(arrayAssignNode.index2);
            cCode ~= arrayAssignNode.arrayName ~ "[" ~ processedIndex ~ "][" ~ processedIndex2 ~ "] = " ~ processedValue ~ ";\n";
        }
        else
        {
            cCode ~= arrayAssignNode.arrayName ~ "[" ~ processedIndex ~ "] = " ~ processedValue ~ ";\n";
        }
        break;

    case "Declaration":
        auto declNode = cast(DeclarationNode) ast;

        g_isMutable[declNode.name] = declNode.isMutable;
        if (declNode.refDepth > 0)
        {
            g_refDepths[declNode.name] = declNode.refDepth;
        }

        string baseType = declNode.typeName.length > 0 ? mapAxeTypeToC(declNode.typeName) : "int";
        string arrayPart = "";

        import std.string : indexOf, count;
        import std.conv : to;

        auto bracketPos = baseType.indexOf('[');
        if (bracketPos >= 0)
        {
            arrayPart = baseType[bracketPos .. $];
            baseType = baseType[0 .. bracketPos];
        }

        for (int i = 0; i < declNode.refDepth; i++)
            baseType ~= "*";

        g_varType[declNode.name] = baseType;
        g_isPointerVar[declNode.name] = declNode.refDepth > 0 ? "true" : "false";
        if (declNode.refDepth > 0)
            debug writeln("DEBUG set g_isPointerVar['", declNode.name, "'] = true");

        string type = declNode.isMutable ? baseType : "const " ~ baseType;
        string decl = type ~ " " ~ declNode.name ~ arrayPart;

        if (declNode.initializer.length > 0)
        {
            string processedExpr = processExpression(declNode.initializer, "assignment");

            string var = "";
            if (processedExpr.startsWith("*"))
            {
                var = processedExpr[1 .. $];
            }
            else if (processedExpr.startsWith("(*") && processedExpr.endsWith(")"))
            {
                var = processedExpr[2 .. $ - 1];
            }
            if (var != "")
            {
                if (var in g_varType && g_varType[var] == "int64_t")
                {
                    string T = type;
                    if (T.endsWith("*"))
                        T = T[0 .. $ - 1];
                    if (type.endsWith("*"))
                        processedExpr = "(" ~ T ~ "*)" ~ var;
                    else
                        processedExpr = "*(" ~ T ~ "*)" ~ var;
                }
            }

            if (baseType == "char*" && processedExpr.length > 0 && processedExpr[0] == '"')
            {
                import std.string : replace;

                size_t bufferSize = cast(int)processedExpr.length - 2 + 1;

                type = declNode.isMutable ? "char" : "const char";
                decl = type ~ " " ~ declNode.name ~ "[" ~ bufferSize.to!string ~ "]";
                cCode ~= decl ~ ";\n";
                cCode ~= "strcpy(" ~ declNode.name ~ ", " ~ processedExpr ~ ");\n";
                break;
            }

            if (arrayPart.length > 0 && processedExpr.length > 0 && processedExpr[0] == '[')
            {
                import std.string : replace, split;

                if (arrayPart == "[]")
                {
                    auto elements = processedExpr[1 .. $ - 1].split(",");
                    arrayPart = "[" ~ elements.length.to!string ~ "]";
                    decl = type ~ " " ~ declNode.name ~ arrayPart;
                }

                processedExpr = processedExpr.replace("[", "{").replace("]", "}");
            }

            decl ~= " = " ~ processedExpr;
        }

        cCode ~= decl ~ ";\n";
        break;

    case "Println":
        auto printlnNode = cast(PrintlnNode) ast;
        if (printlnNode.isExpression)
        {
            string processedExpr = processExpression(printlnNode.message, "println");
            cCode ~= "printf(\"%d\\n\", " ~ processedExpr ~ ");\n";
        }
        else
        {
            cCode ~= "printf(\"" ~ printlnNode.message ~ "\\n\");\n";
        }
        break;

    case "Print":
        auto printNode = cast(PrintNode) ast;
        if (printNode.isExpression)
        {
            string processedExpr = processExpression(printNode.message, "println");
            cCode ~= "printf(\"%d\", " ~ processedExpr ~ ");\n";
        }
        else
        {
            cCode ~= "printf(\"" ~ printNode.message ~ "\");\n";
        }
        break;

    case "If":
        auto ifNode = cast(IfNode) ast;
        cCode ~= "if (" ~ processCondition(ifNode.condition) ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}";

        IfNode currentNode = ifNode;
        while (currentNode.elseBody.length == 1 && currentNode.elseBody[0].nodeType == "If")
        {
            auto elifNode = cast(IfNode) currentNode.elseBody[0];
            cCode ~= " else if (" ~ processCondition(elifNode.condition) ~ ") {\n";
            loopLevel++;

            foreach (child; elifNode.children)
            {
                cCode ~= generateC(child);
            }

            loopLevel--;
            cCode ~= "}";
            currentNode = elifNode;
        }

        if (currentNode.elseBody.length > 0)
        {
            cCode ~= " else {\n";
            loopLevel++;

            foreach (elseChild; currentNode.elseBody)
            {
                cCode ~= generateC(elseChild);
            }

            loopLevel--;
            cCode ~= "}";
        }

        cCode ~= "\n";
        break;

    case "Loop":
        cCode ~= "while (1) {\n";

        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Platform":
        auto platformNode = cast(PlatformNode) ast;

        // Generate #ifdef for windows, #ifndef for posix
        if (platformNode.platform == "windows")
            cCode ~= "#ifdef _WIN32\n";
        else if (platformNode.platform == "posix")
            cCode ~= "#ifndef _WIN32\n";

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        cCode ~= "#endif\n";
        break;

    case "ParallelFor":
        auto parallelForNode = cast(ParallelForNode) ast;

        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        cCode ~= indent ~ "#pragma omp parallel for\n";
        cCode ~= indent ~ "for (" ~ parallelForNode.initialization ~ "; "
            ~ processCondition(
                parallelForNode.condition) ~ "; "
            ~ parallelForNode.increment ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= indent ~ "}\n";
        break;

    case "For":
        auto forNode = cast(ForNode) ast;

        string forType = forNode.isMutable ? forNode.varType : "const " ~ forNode.varType;
        string forInit = forType ~ " " ~ forNode.varName ~ " = " ~ processExpression(
            forNode.initValue);
        string forCond = processCondition(forNode.condition);
        string forIncr = forNode.increment;

        cCode ~= "for (" ~ forInit ~ "; " ~ forCond ~ "; " ~ forIncr ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "ForIn":
        auto forInNode = cast(ForInNode) ast;

        // Generate: for (size_t i = 0; i < sizeof(array)/sizeof(array[0]); i++) {
        //              type varName = array[i];
        //              ... body ...
        //          }
        string indexVar = "_i_" ~ forInNode.varName;
        string arraySize = "sizeof(" ~ forInNode.arrayName ~ ")/sizeof(" ~ forInNode.arrayName ~ "[0])";

        cCode ~= "for (size_t " ~ indexVar ~ " = 0; " ~ indexVar ~ " < " ~ arraySize ~ "; " ~ indexVar ~ "++) {\n";
        loopLevel++;

        // Declare the loop variable and assign it from the array
        string indent = "    ".replicate(loopLevel);
        cCode ~= indent ~ "int " ~ forInNode.varName ~ " = " ~ forInNode.arrayName ~ "[" ~ indexVar ~ "];\n";

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Break":
        cCode ~= "break;\n";
        break;

    case "Continue":
        cCode ~= "continue;\n";
        break;

    case "RawC":
        auto rawNode = cast(RawCNode) ast;
        cCode ~= rawNode.code ~ "\n";
        break;

    case "Return":
        auto returnNode = cast(ReturnNode) ast;
        if (returnNode.expression.length > 0)
        {
            string processedExpr = processExpression(returnNode.expression);
            cCode ~= "return " ~ processedExpr ~ ";\n";
        }
        else
        {
            cCode ~= "return;\n";
        }
        break;

    case "Enum":
        auto enumNode = cast(EnumNode) ast;
        cCode ~= "typedef enum {\n";
        foreach (i, value; enumNode.values)
        {
            cCode ~= "    " ~ value;
            if (i < enumNode.values.length - 1)
                cCode ~= ",";
            cCode ~= "\n";
        }
        cCode ~= "} " ~ enumNode.name ~ ";\n";
        break;

    case "Test":
        auto testNode = cast(TestNode) ast;

        // Generate main function with test runner
        cCode ~= generateStackTraceHandlers();
        cCode ~= "int main(int argc, char** argv) {\n";
        cCode ~= "    __axe_argc = argc;\n";
        cCode ~= "    __axe_argv = argv;\n";
        cCode ~= generateStackTraceSetup();
        version (Windows)
        {
            cCode ~= "SetConsoleOutputCP(65001);\n";
        }
        cCode ~= "    int passed = 0;\n";
        cCode ~= "    int failed = 0;\n\n";

        // Process all statements in test block
        foreach (child; testNode.children)
        {
            if (child.nodeType == "Assert")
            {
                auto assertNode = cast(AssertNode) child;
                string condition = processExpression(assertNode.condition);

                cCode ~= "    if (" ~ condition ~ ") {\n";
                cCode ~= "        printf(\"\\033[32m✓ PASS:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
                cCode ~= "        passed++;\n";
                cCode ~= "    } else {\n";
                cCode ~= "        printf(\"\\033[31m✗ FAIL:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
                cCode ~= "        failed++;\n";
                cCode ~= "    }\n\n";
            }
            else
            {
                // Handle other statements (declarations, function calls, etc.)
                string stmt = generateC(child);
                if (stmt.length > 0)
                {
                    // Indent the statement
                    cCode ~= "    " ~ stmt.replace("\n", "\n    ");
                    if (!stmt.endsWith("\n"))
                        cCode ~= "\n";
                }
            }
        }

        // Print summary
        cCode ~= "    printf(\"\\n\");\n";
        cCode ~= "    if (failed == 0) {\n";
        cCode ~= "        printf(\"\\033[32mAll tests passed. (%d/%d)\\033[0m\\n\", passed, passed + failed);\n";
        cCode ~= "    } else {\n";
        cCode ~= "        printf(\"\\033[31m%d test(s) failed, %d passed\\033[0m\\n\", failed, passed);\n";
        cCode ~= "    }\n";
        cCode ~= "    return failed > 0 ? 1 : 0;\n";
        cCode ~= "}\n";
        break;

    case "Macro":
        // Store macro for later expansion, don't generate code now
        auto macroNode = cast(MacroNode) ast;
        g_macros[macroNode.name] = macroNode;
        writeln("DEBUG: Stored macro '", macroNode.name, "' with ", macroNode.params.length, " parameters");
        break;

    case "Model":
        auto modelNode = cast(ModelNode) ast;
        cCode ~= "struct " ~ modelNode.name ~ ";\n";
        cCode ~= "typedef struct " ~ modelNode.name ~ " {\n";
        foreach (field; modelNode.fields)
        {
            string fieldType = mapAxeTypeToC(field.type);
            writeln("DEBUG model field: name='", field.name, "' type='", field.type, "' mapped='", fieldType, "'");

            // Handle ref types - convert "ref T" to "T*"
            if (fieldType.startsWith("ref "))
            {
                fieldType = fieldType[4 .. $].strip() ~ "*";
            }

            // If field type is the same as the model name, make it a pointer
            // This logic is now handled by the 'ref' type conversion above
            // if (field.type == modelNode.name)
            // {
            //     fieldType = "struct " ~ field.type ~ "*";
            // }

            cCode ~= "    " ~ fieldType ~ " " ~ field.name ~ ";\n";
        }
        cCode ~= "} " ~ modelNode.name ~ ";\n\n";
        break;

    case "ModelInstantiation":
        auto instNode = cast(ModelInstantiationNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        // Generate struct initialization using compound literal (const for val, mutable for mut val)
        string constQualifier = instNode.isMutable ? "" : "const ";
        cCode ~= indent ~ constQualifier ~ instNode.modelName ~ " " ~ instNode.variableName ~ " = {";

        // Add field initializers
        bool first = true;
        foreach (fieldName, fieldValue; instNode.fieldValues)
        {
            if (!first)
                cCode ~= ", ";
            cCode ~= "." ~ fieldName ~ " = " ~ fieldValue;
            first = false;
        }

        cCode ~= "};\n";
        break;

    case "MemberAccess":
        auto memberNode = cast(MemberAccessNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        string accessOp = ".";
        // Check if this member access is to a pointer field, if the object is already a pointer (contains ->), or if the object is a pointer variable
        if (memberNode.objectName.canFind("->") ||
            (memberNode.objectName ~ "." ~ memberNode.memberName in g_pointerFields) ||
            (memberNode.objectName in g_isPointerVar && g_isPointerVar[memberNode.objectName] == "true"))
        {
            accessOp = "->";
        }

        if (memberNode.value.length > 0)
        {
            cCode ~= indent ~ memberNode.objectName ~ accessOp ~ memberNode.memberName;
            cCode ~= " = " ~ memberNode.value ~ ";\n";
        }
        else
        {
            cCode ~= memberNode.objectName ~ accessOp ~ memberNode.memberName;
        }
        break;

    case "Switch":
        auto switchNode = cast(SwitchNode) ast;
        cCode ~= "switch (" ~ processExpression(switchNode.expression) ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Case":
        auto caseNode = cast(CaseNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        if (caseNode.isDefault)
        {
            cCode ~= indent ~ "default:\n";
        }
        else
        {
            cCode ~= indent ~ "case " ~ caseNode.value ~ ":\n";
        }

        loopLevel++;
        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        // Add implicit break at end of case
        string breakIndent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        cCode ~= breakIndent ~ "break;\n";
        loopLevel--;
        break;

    case "IncrementDecrement":
        auto incDecNode = cast(IncrementDecrementNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        if (incDecNode.isIncrement)
            cCode ~= indent ~ incDecNode.variable ~ "++;\n";
        else
            cCode ~= indent ~ incDecNode.variable ~ "--;\n";
        break;

    case "ExternalImport":
        auto extImportNode = cast(ExternalImportNode) ast;
        cCode ~= "#include <" ~ extImportNode.headerFile ~ ">\n";
        break;

    default:
        enforce(false, "Unsupported node type for C generation: " ~ ast.nodeType);
    }

    return cCode;
}

/**
 * Helper function to process arithmetic expressions
 */
string processExpression(string expr, string context = "")
{
    expr = expr.strip();

    import std.regex : regex, matchFirst;
    import std.array : replace;

    // FIRST: Replace Axe operators with C equivalents before any other processing
    import std.regex : replaceAll;
    import std.string : replace;

    // Use regex to replace operators that are not part of identifiers
    // First handle the common case with spaces explicitly
    expr = expr.replace(" mod ", " % ");

    // Then match 'mod' when preceded/followed by non-letter/underscore characters
    expr = expr.replaceAll(regex(r"([^a-zA-Z_])mod([^a-zA-Z_])"), "$1%$2");
    expr = expr.replaceAll(regex(r"^mod([^a-zA-Z_])"), "%$1");
    expr = expr.replaceAll(regex(r"([^a-zA-Z_])mod$"), "$1%");

    expr = expr.replace(" and ", " && ");
    expr = expr.replace(" or ", " || ");
    expr = expr.replace(" xor ", " ^ ");

    // Check for macro calls in expressions
    writeln("DEBUG processExpression: Checking for macros in expr: '", expr, "'");
    writeln("DEBUG processExpression: Available macros: ", g_macros.keys);
    foreach (macroName, macroNode; g_macros)
    {
        import std.string : indexOf, split, strip;
        import std.regex : regex, matchFirst;

        // Match macro name followed by optional whitespace and opening paren
        auto macroPattern = regex(macroName ~ r"\s*\(");
        auto match = matchFirst(expr, macroPattern);

        if (match)
        {
            writeln("DEBUG processExpression: Found macro call '", macroName, "' in expression");
        }

        while (match)
        {
            auto startIdx = match.pre.length;
            // Find the opening paren (skip any whitespace after macro name)
            size_t parenStart = startIdx + macroName.length;
            while (parenStart < expr.length && (expr[parenStart] == ' ' || expr[parenStart] == '\t'))
                parenStart++;
            parenStart++; // Skip the '(' itself

            // Find matching closing paren
            int depth = 1;
            size_t parenEnd = parenStart;
            while (parenEnd < expr.length && depth > 0)
            {
                if (expr[parenEnd] == '(')
                    depth++;
                else if (expr[parenEnd] == ')')
                    depth--;
                if (depth > 0)
                    parenEnd++;
            }

            // Extract arguments
            string argsStr = expr[parenStart .. parenEnd];
            string[] callArgs;

            // Simple argument parsing (split by comma, but respect nested parens)
            int argDepth = 0;
            size_t argStart = 0;
            for (size_t i = 0; i < argsStr.length; i++)
            {
                if (argsStr[i] == '(')
                    argDepth++;
                else if (argsStr[i] == ')')
                    argDepth--;
                else if (argsStr[i] == ',' && argDepth == 0)
                {
                    callArgs ~= argsStr[argStart .. i].strip();
                    argStart = i + 1;
                }
            }
            if (argStart < argsStr.length)
                callArgs ~= argsStr[argStart .. $].strip();

            // Build parameter substitution map
            string[string] paramMap;
            for (size_t i = 0; i < macroNode.params.length && i < callArgs.length;
                i++)
            {
                paramMap[macroNode.params[i]] = processExpression(callArgs[i]);
            }

            // Expand macro body
            string expandedCode = "";
            foreach (child; macroNode.children)
            {
                if (child.nodeType == "RawC")
                {
                    auto rawNode = cast(RawCNode) child;
                    expandedCode = rawNode.code;

                    // Replace parameters in the raw code
                    foreach (paramName, paramValue; paramMap)
                    {
                        expandedCode = expandedCode.replace(paramName, paramValue);
                    }
                }
            }

            // Replace macro call with expanded code
            expr = expr[0 .. startIdx] ~ "(" ~ expandedCode ~ ")" ~ expr[parenEnd + 1 .. $];

            // Search for next occurrence
            match = matchFirst(expr, macroPattern);
        }
    }

    // No transformation needed for 2D arrays - they work naturally in C!

    // Handle ref_of() built-in function - replace all occurrences (with or without spaces)
    import std.regex : regex, replaceAll;

    while (expr.canFind("ref_of"))
    {
        auto startIdx = expr.indexOf("ref_of");
        if (startIdx == -1)
            break;

        // Skip past "ref_of" and any whitespace
        size_t pos = startIdx + 6;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1; // After "("

        // Find matching closing paren
        int depth = 1;
        size_t parenEnd = parenStart;
        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "&" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    // Handle addr_of() built-in function - replace all occurrences (with or without spaces)
    while (expr.canFind("addr_of"))
    {
        auto startIdx = expr.indexOf("addr_of");
        if (startIdx == -1)
            break;

        // Skip past "addr_of" and any whitespace
        size_t pos = startIdx + 7;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1; // After "("

        // Find matching closing paren
        int depth = 1;
        size_t parenEnd = parenStart;
        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "(int64_t)&" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    // Handle deref() built-in function - replace all occurrences (with or without spaces)
    while (expr.canFind("deref"))
    {
        auto startIdx = expr.indexOf("deref");
        if (startIdx == -1)
            break;

        // Skip past "deref" and any whitespace
        size_t pos = startIdx + 5;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1;
        int depth = 1;
        size_t parenEnd = parenStart;

        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "*" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    // Handle array access
    if (expr.canFind("["))
    {
        size_t bracketPos = expr.indexOf("[");
        string base = expr[0 .. bracketPos].strip();
        size_t endPos = bracketPos + 1;
        int depth = 1;
        while (endPos < expr.length && depth > 0)
        {
            if (expr[endPos] == '[')
                depth++;
            else if (expr[endPos] == ']')
                depth--;
            endPos++;
        }
        if (depth > 0)
            return expr; // malformed
        string index = expr[bracketPos + 1 .. endPos - 1].strip();
        string rest = expr[endPos .. $].strip();
        string processedBase = processExpression(base);
        string processedIndex = processExpression(index);
        string processedRest = rest.length > 0 ? processExpression(rest) : "";
        return processedBase ~ "[" ~ processedIndex ~ "]" ~ processedRest;
    }

    // Handle member access with auto-detection of pointer types
    if (expr.canFind("."))
    {
        auto parts = expr.split(".");
        if (parts.length >= 2)
        {
            // Handle enum access if first part is uppercase
            string first = parts[0].strip();
            string second = parts[1].strip();

            // Skip if this is a numeric literal (e.g., 2.0, 3.14)
            // Check if both parts are all digits
            import std.algorithm : all;
            import std.ascii : isDigit;

            if (first.length > 0 && first.all!isDigit && second.length > 0 && second.all!isDigit)
            {
                // This is a float literal - return it with spaces removed
                import std.array : replace;

                return expr.replace(" ", "");
            }

            // Check if this is a function call (Model.method(...)) - convert to {prefixedModelName}_method(...)
            // But not if the first part is a numeric literal (e.g., 0.5) or contains operators
            bool firstHasOps = first.canFind("/") || first.canFind("*") || first.canFind("+") || first.canFind(
                "-");
            if (second.canFind("(") && first.length > 0 && !firstHasOps &&
                (first[0] >= 'A' && first[0] <= 'Z' || first[0] >= 'a' && first[0] <= 'z' || first[0] == '_'))
            {
                // This is a static method call like Arena.create(...)
                // Look up the prefixed model name and construct the function name
                string modelName = first.strip();
                string methodPart = second.strip();
                
                if (modelName in g_modelNames)
                {
                    string prefixedModelName = g_modelNames[modelName];
                    // Extract method name (everything before the opening parenthesis)
                    auto parenPos = methodPart.indexOf('(');
                    if (parenPos >= 0)
                    {
                        string methodName = methodPart[0 .. parenPos].strip();
                        // Find the matching closing parenthesis
                        int parenDepth = 1;
                        size_t argEnd = parenPos + 1;
                        while (argEnd < methodPart.length && parenDepth > 0)
                        {
                            if (methodPart[argEnd] == '(')
                                parenDepth++;
                            else if (methodPart[argEnd] == ')')
                                parenDepth--;
                            argEnd++;
                        }
                        string args = methodPart[parenPos .. argEnd];
                        string functionCall = prefixedModelName ~ "_" ~ methodName ~ args;
                        
                        // If there are more parts after the function call, process them as member access
                        if (parts.length > 2)
                        {
                            // Reconstruct the rest of the expression with the function call as the base
                            string result = functionCall;
                            for (size_t i = 2; i < parts.length; i++)
                            {
                                result ~= "." ~ parts[i].strip();
                            }
                            return result;
                        }
                        else
                        {
                            return functionCall;
                        }
                    }
                    else
                    {
                        return prefixedModelName ~ "_" ~ methodPart;
                    }
                }
                else
                {
                    // Fallback: Replace the dot (and any surrounding spaces) with underscore
                    import std.regex : regex, replaceFirst;
                    return replaceFirst(expr, regex(r"\s*\.\s*"), "_");
                }
            }

            if (first.length > 0 && first[0] >= 'A' && first[0] <= 'Z')
            {
                // Enum access: State.RUNNING -> RUNNING
                return parts[1].strip();
            }

            // Handle member access chain
            string result = first;
            string currentType = g_varType.get(first, "");
            bool isPointer = g_isPointerVar.get(first, "false") == "true";
            writeln("DEBUG get g_isPointerVar for '", first, "' = ", g_isPointerVar.get(first, "false"));
            writeln("DEBUG: processExpression member access: first='", first, "' isPointer=", isPointer, " expr='", expr, "'");

            for (size_t i = 1; i < parts.length; i++)
            {
                string field = parts[i].strip();
                string op = isPointer ? "->" : ".";
                result ~= op ~ field;

                // Update pointer status for next field
                if (currentType ~ "." ~ field in g_pointerFields)
                    isPointer = true;
                else
                    isPointer = false;
            }
            return result;
        }
    }

    // Handle .len property for arrays
    // import std.regex : regex, matchFirst;
    // auto lenMatch = matchFirst(expr, regex(r"^(.+)\.len$"));
    // if (lenMatch)
    // {
    //     string arrayName = lenMatch[1].strip();
    //     return "(sizeof(" ~ arrayName ~ ")/sizeof(" ~ arrayName ~ "[0]))";
    // }

    // Don't process if it's already parenthesized
    if (expr.canFind("(") && expr.endsWith(")"))
    {
        return expr;
    }

    // Check for operators, but be careful not to split on dots (member access) or operators inside strings
    foreach (op; [
            "+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||"
        ])
    {
        if (expr.canFind(op) && op != "")
        {
            // Smart split that respects string literals and parentheses
            string[] parts;
            string current = "";
            bool inString = false;
            int parenDepth = 0;

            for (size_t i = 0; i < expr.length; i++)
            {
                if (expr[i] == '"' && (i == 0 || expr[i - 1] != '\\'))
                {
                    inString = !inString;
                    current ~= expr[i];
                }
                else if (!inString && expr[i] == '(')
                {
                    parenDepth++;
                    current ~= expr[i];
                }
                else if (!inString && expr[i] == ')')
                {
                    parenDepth--;
                    current ~= expr[i];
                }
                else if (!inString && parenDepth == 0 && i + op.length <= expr.length &&
                    expr[i .. i + op.length] == op &&
                    (i == 0 || expr[i - 1] != op[0]))
                {
                    parts ~= current;
                    current = "";
                    i += cast(int) op.length - 1;
                }
                else
                {
                    current ~= expr[i];
                }
            }
            parts ~= current;

            if (parts.length == 2)
            {
                return "(" ~ processExpression(parts[0]) ~ op ~ processExpression(parts[1]) ~ ")";
            }
            else if (parts.length > 2)
            {
                string result = processExpression(parts[0]);
                for (int i = 1; i < parts.length; i++)
                {
                    result = "(" ~ result ~ op ~ processExpression(parts[i]) ~ ")";
                }
                return result;
            }
        }
    }

    // Auto-dereference if this is a reference variable
    if (expr in g_refDepths && g_refDepths[expr] > 0)
    {
        if (context == "println") // Remove "assignment" from here
        {
            string result = expr;
            for (int i = 0; i < g_refDepths[expr]; i++)
            {
                result = "*" ~ result;
            }
            return result;
        }
    }

    return expr;
}

import std.array;

private string processCondition(string condition)
{
    import std.array : replace;
    import std.string : indexOf;
    import std.stdio : writeln;

    writeln("DEBUG processCondition input: '", condition, "'");

    condition = condition.replace(" mod ", " % ");
    condition = condition.replace(" and ", " && ");
    condition = condition.replace(" band ", " & ");
    condition = condition.replace(" bor ", " | ");
    condition = condition.replace(" shl ", " << ");
    condition = condition.replace(" shr ", " >> ");
    condition = condition.replace(" not ", " ! ");
    condition = condition.replace(" or ", " || ");
    condition = condition.replace(" xor ", " ^ ");

    writeln("DEBUG processCondition after replace: '", condition, "'");

    // Handle logical operators (&&, ||) first - they have lowest precedence
    foreach (op; ["&&", "||"])
    {
        auto idx = condition.indexOf(op);
        if (idx >= 0)
        {
            string left = condition[0 .. idx].strip();
            string right = condition[idx + op.length .. $].strip();
            string result = "(" ~ processCondition(left) ~ " " ~ op ~ " " ~ processCondition(
                right) ~ ")";
            return result;
        }
    }

    // Then handle comparison operators - check longer operators first to avoid partial matches
    foreach (op; ["==", "!=", ">=", "<=", ">", "<"])
    {
        auto idx = condition.indexOf(op);
        if (idx >= 0)
        {
            string left = condition[0 .. idx].strip();
            string right = condition[idx + op.length .. $].strip();
            string result = "(" ~ processExpression(left) ~ op ~ processExpression(right) ~ ")";
            return result;
        }
    }

    string result = processExpression(condition);
    return result;
}

string generateStackTraceHandlers()
{
    string code = "";
    version (Windows)
    {
        code ~= "#include <dbghelp.h>\n";
    }
    else version (Posix)
    {
        code ~= "#include <execinfo.h>\n";
        code ~= "#include <signal.h>\n";
        code ~= "#include <unistd.h>\n";
    }
    code ~= "\n";
    version (Windows)
    {
        code ~= "static void axe_win_print_backtrace(void) {\n";
        code ~= "    HANDLE process = GetCurrentProcess();\n";
        code ~= "    SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME | SYMOPT_LOAD_LINES);\n";
        code ~= "    SymInitialize(process, NULL, TRUE);\n";
        code ~= "\n";
        code ~= "    void* stack[64];\n";
        code ~= "    USHORT frames = CaptureStackBackTrace(0, 64, stack, NULL);\n";
        code ~= "    fprintf(stderr, \"Backtrace (%u frames):\\n\", (unsigned)frames);\n";
        code ~= "\n";
        code ~= "    SYMBOL_INFO* symbol = (SYMBOL_INFO*)malloc(sizeof(SYMBOL_INFO) + 256);\n";
        code ~= "    if (!symbol) return;\n";
        code ~= "    memset(symbol, 0, sizeof(SYMBOL_INFO) + 256);\n";
        code ~= "    symbol->MaxNameLen = 255;\n";
        code ~= "    symbol->SizeOfStruct = sizeof(SYMBOL_INFO);\n";
        code ~= "\n";
        code ~= "    for (USHORT i = 0; i < frames; i++) {\n";
        code ~= "        DWORD64 address = (DWORD64)(stack[i]);\n";
        code ~= "        if (SymFromAddr(process, address, 0, symbol)) {\n";
        code ~= "            fprintf(stderr, \"  #%02u 0x%llx %s\\n\", (unsigned)i, (unsigned long long)address, symbol->Name);\n";
        code ~= "        } else {\n";
        code ~= "            fprintf(stderr, \"  #%02u 0x%llx <unknown>\\n\", (unsigned)i, (unsigned long long)address);\n";
        code ~= "        }\n";
        code ~= "    }\n";
        code ~= "    free(symbol);\n";
        code ~= "}\n";
        code ~= "\n";
        code ~= "static LONG WINAPI axe_unhandled_exception_filter(EXCEPTION_POINTERS* info) {\n";
        code ~= "    (void)info;\n";
        code ~= "    fprintf(stderr, \"Fatal: Unhandled exception.\\n\");\n";
        code ~= "    axe_win_print_backtrace();\n";
        code ~= "    fflush(stderr);\n";
        code ~= "    ExitProcess(1);\n";
        code ~= "    return EXCEPTION_EXECUTE_HANDLER;\n";
        code ~= "}\n";
    }
    else version (Posix)
    {
        code ~= "static void axe_segv_handler(int sig) {\n";
        code ~= "    const char* name = (sig == SIGSEGV ? \"SIGSEGV\" : (sig == SIGABRT ? \"SIGABRT\" : \"SIGNAL\"));\n";
        code ~= "    fprintf(stderr, \"Fatal: %s received.\\n\", name);\n";
        code ~= "    void* frames[64];\n";
        code ~= "    int n = backtrace(frames, 64);\n";
        code ~= "    if (n > 0) {\n";
        code ~= "        fprintf(stderr, \"Backtrace (%d frames):\\n\", n);\n";
        code ~= "        backtrace_symbols_fd(frames, n, fileno(stderr));\n";
        code ~= "    }\n";
        code ~= "    fflush(stderr);\n";
        code ~= "    _exit(139);\n";
        code ~= "}\n";
    }
    code ~= "\n";
    return code;
}

string generateStackTraceSetup()
{
    string code;
    version (Windows)
    {
        code ~= "    SetUnhandledExceptionFilter(axe_unhandled_exception_filter);\n";
    }
    else version (Posix)
    {
        code ~= "    signal(SIGSEGV, axe_segv_handler);\n";
        code ~= "    signal(SIGABRT, axe_segv_handler);\n";
    }
    return code;
}

unittest
{
    import axe.parser;
    import axe.lexer;
    import std.stdio;
    import std.string;

    {
        auto tokens = lex("main { println \"hello\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int main(int argc, char** argv)"));
        assert(cCode.canFind("printf(\"hello\\n\")"));
    }

    {
        auto tokens = lex("def foo { println \"hello\"; } main { foo(); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("foo()"));
    }

    {
        auto tokens = lex("main { foo(1, 2); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("foo(1, 2)"));
    }

    {
        auto tokens = lex("main { loop { break; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("while (1) {"));
        assert(cCode.canFind("break;"));
    }

    {
        auto tokens = lex("main { if (x > 5) { println \"greater\"; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);

        assert(cCode.canFind("(x>5)"));
        assert(cCode.canFind(`printf("greater\n");`));
    }

    {
        auto tokens = lex("main { val x = 5 + 3; val y = x - 2; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("const int x = (5+3)"));
        assert(cCode.canFind("const int y = (x-2)"));
    }

    {
        auto tokens = lex(
            "def foo { println \"in foo\"; } main { foo(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);
        assert(cCode.canFind("void foo()"));
        assert(cCode.canFind(`printf("in foo\n");`));
        assert(cCode.canFind("foo();"));
    }

    {
        auto tokens = lex(
            "def add(a: i32, b: i32): i32 { return a + b; } main { val x = add(1, 2); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int32_t add(int32_t a, int32_t b)"));
        assert(cCode.canFind("return (a+b);"));
        assert(cCode.canFind("const int x = add( 1, 2);"));
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex("main { y = y + 1; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Undeclared variable: y"));
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught undeclared variable error");
        }
    }

    {
        auto tokens = lex("main { println \"start\"; loop { println \"in loop\"; break; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Loop test output:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Loop should start with while (1) {");
        assert(cCode.canFind("printf(\"in loop\\n\");"), "Loop should contain println");
        assert(cCode.canFind("break;"), "Loop should contain break");

        import std.algorithm : count;
        import std.string : indexOf;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced in loop code");

        auto loopStart = cCode.indexOf("while (1)");
        auto returnPos = cCode.indexOf("return 0;");
        assert(loopStart < returnPos, "return should come after loop");
    }

    {
        auto tokens = lex("main { mut val x = 5; x = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable reassignment test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 5;"), "Should declare x");
        assert(cCode.canFind("x = 10;"), "Should reassign x");
    }

    {
        auto tokens = lex(
            "def testfunc() { mut val x = 0; loop { println \"test\"; x = x + 1; if x == 5 { break; } } } main { testfunc(); }"
        );
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Complex loop test:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("printf(\"test\\n\");"), "Should have println in loop");
        assert(cCode.canFind("x = (x+1);"), "Should have assignment in loop");
        assert(cCode.canFind("if ((x==5))"), "Should have if statement");

        import std.algorithm : count;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced");
    }

    {
        auto tokens = lex(
            "def greet(name: char*, t: i32) { println \"hello\"; } main { greet(\"world\", 1); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function call with string literal test:");
        writeln(cCode);

        assert(cCode.canFind("void greet(char* name, int32_t t)"), "Should declare greet function");
        assert(cCode.canFind("greet(\"world\", 1);"), "String literal should have quotes in function call");
        assert(!cCode.canFind("greet(world, 1);"), "String literal should not lose quotes");
    }

    {
        auto tokens = lex("// This is a comment\nmain { println \"test\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Comment filtering test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"test\\n\");"), "Should have println statement");
        assert(!cCode.canFind("//"), "Comments should be filtered out");
        assert(!cCode.canFind("This is a comment"), "Comment text should not appear in output");
    }

    {
        auto tokens = lex("main { raw { printf(\"raw C\"); } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Raw C block test (.axec):");
        writeln(cCode);

        assert(cCode.canFind("printf(\"raw C\");"), "Should have raw C code");
        assert(!cCode.canFind("raw {"), "Raw keyword should not appear in output");
    }

    {
        auto tokens = lex("main { println \"before\"; raw { int x = 5; } println \"after\"; }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Mixed raw C and Axe code test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"before\\n\");"), "Should have first println");
        assert(cCode.canFind("int x = 5;"), "Should have raw C code");
        assert(cCode.canFind("printf(\"after\\n\");"), "Should have second println");
    }

    {
        import std.exception : assertThrown;

        auto tokens = lex("main { raw { test(); } }");

        writeln("Raw C block rejection test (.axe):");
        assertThrown(parse(tokens, false), "Should reject raw blocks in .axe files");
        writeln("Correctly rejected raw block in .axe file");
    }

    {
        auto tokens = lex("model Cat { name: char*, age: i32 } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model definition test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat {"), "Should have struct definition");
        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int32_t age;"), "Should have age field");
        assert(cCode.canFind("} Cat;"), "Should have Cat typedef");
    }

    {
        auto tokens = lex(
            "model Cat { name: char*, health: i32 } " ~
                "main { val cat = new Cat(name: \"Garfield\", health: 100); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model instantiation test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat {"), "Should have struct definition");
        assert(cCode.canFind("const Cat cat = {"), "Should have const struct initialization");
        assert(cCode.canFind(".name = \"Garfield\""), "Should initialize name field");
        assert(cCode.canFind(".health = 100"), "Should initialize health field");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } main { mut val cat = new Cat(health: 100); cat.health = 90; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Mutable model and member assignment test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have mutable struct (no const)");
        assert(!cCode.canFind("const Cat cat"), "Should not have const for mut val");
        assert(cCode.canFind("cat.health = 90;"), "Should have member assignment");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } main { val ptr: i64 = 123; mut val n: ref Cat = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deref on long test:");
        writeln(cCode);

        assert(cCode.canFind("Cat* n = (Cat*)ptr;"), "Should cast long to pointer type when deref in declaration");
    }

    {
        auto tokens = lex("model SomeModel { value: i32, def some_function() { println \"Hello from model method\"; } } main { mut val obj: SomeModel; obj.some_function(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model with function test:");
        writeln(cCode);

        assert(cCode.canFind("struct SomeModel"), "Should generate struct for model");
        assert(cCode.canFind("void SomeModel_some_function("), "Should generate function declaration for model method");
        assert(cCode.canFind("obj_some_function();"), "Should generate function call in main");
    }

    {
        auto tokens = lex("def test_func(grid: i32[height][width], width: i32, height: i32) { } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable-length array parameter reordering test:");
        writeln(cCode);

        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width]);"), 
               "Forward declaration should have dimension parameters before array parameter");
        
        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width])"), 
               "Function definition should have dimension parameters before array parameter");
    }

    {
        auto tokens = lex(
            "model stdlib_arena_Arena { capacity: i32, offset: i32, def stdlib_arena_Arena_create(size: i32): stdlib_arena_Arena { return new stdlib_arena_Arena(capacity: size, offset: 0); } } " ~
            "main { val arena = Arena.create(1024); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Prefixed model method call test:");
        writeln(cCode);

        assert(cCode.canFind("struct stdlib_arena_Arena"), "Should have prefixed struct name");
        assert(cCode.canFind("stdlib_arena_Arena_create"), "Should have prefixed function name");
        assert(cCode.canFind("Arena_create( 1024)"), "Should find the original call in source");
        assert(cCode.canFind("stdlib_arena_Arena_create( 1024 )") || cCode.canFind("stdlib_arena_Arena_create( 1024)"), 
               "Function call should use prefixed name stdlib_arena_Arena_create");
    }

    {
        auto tokens = lex(
            "model stdlib_arena_Arena { capacity: i32, offset: i32, def stdlib_arena_Arena_create(size: i32): stdlib_arena_Arena { return new stdlib_arena_Arena(capacity: size, offset: 0); } } " ~
            "main { val cap = Arena.create(1024).capacity; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Member access after function call test:");
        writeln(cCode);

        assert((cCode.canFind("stdlib_arena_Arena_create( 1024).capacity") || 
                cCode.canFind("stdlib_arena_Arena_create(1024).capacity") ||
                cCode.canFind("stdlib_arena_Arena_create( 1024 ).capacity")), 
               "Should preserve member access after prefixed function call");
    }

    {
        auto tokens = lex(
            "model stdlib_arena_Arena { capacity: i32, offset: i32, def stdlib_arena_Arena_create(size: i32): stdlib_arena_Arena { return new stdlib_arena_Arena(capacity: size, offset: 0); } } " ~
            "test { assert(Arena.create(1024).capacity == 1024, \"test message\"); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Assertion with function call and member access test:");
        writeln(cCode);

        assert((cCode.canFind("stdlib_arena_Arena_create( 1024 ) . capacity == 1024") ||
                cCode.canFind("stdlib_arena_Arena_create(1024).capacity == 1024") ||
                cCode.canFind("stdlib_arena_Arena_create( 1024 ).capacity == 1024")), 
               "Assertion condition should preserve full expression chain with member access");
        assert(!cCode.canFind("if (stdlib_arena_Arena_create( 1024 )) {") &&
               !cCode.canFind("if (stdlib_arena_Arena_create(1024)) {"), 
               "Should not have incomplete condition without member access");
    }

    {
        auto tokens = lex(
            "model stdlib_arena_Arena { capacity: i32, offset: i32, def stdlib_arena_Arena_create(size: i32): stdlib_arena_Arena { return new stdlib_arena_Arena(capacity: size, offset: 0); } } " ~
            "main { val x = Arena.create(2048).offset; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multiple member access after function call test:");
        writeln(cCode);

        assert((cCode.canFind("stdlib_arena_Arena_create( 2048 ) . offset") ||
                cCode.canFind("stdlib_arena_Arena_create(2048).offset") ||
                cCode.canFind("stdlib_arena_Arena_create( 2048).offset")), 
               "Should preserve member access for offset field");
    }

    {
        auto tokens = lex(
            "model stdlib_arena_Arena { capacity: i32, offset: i32, def stdlib_arena_Arena_create(size: i32): stdlib_arena_Arena { return new stdlib_arena_Arena(capacity: size, offset: 0); } } " ~
            "main { val arena = Arena.create(512); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function call without member access test:");
        writeln(cCode);

        assert((cCode.canFind("stdlib_arena_Arena_create( 512 )") ||
                cCode.canFind("stdlib_arena_Arena_create( 512)")), 
               "Should still prefix function call even without member access");
    }

    {
        auto tokens = lex(
            "model String { data: char*, len: usize } " ~
            "def str_cmp(a: String, b: String): i32 { " ~
            "    mut val len: usize = 0; " ~
            "    if a.len < b.len { len = a.len; } else { len = b.len; } " ~
            "    for mut val i = 0; i < len; i++ { " ~
            "        if a.data[i] < b.data[i] { return -1; } " ~
            "    } " ~
            "    return 0; " ~
            "} " ~
            "main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function parameter and variable scope test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t str_cmp(String a, String b)"), 
               "Should have function declaration with parameters");
        
        assert(cCode.canFind("uintptr_t len = 0;") || cCode.canFind("uintptr_t len=0;"), 
               "Should have len variable declaration");
        
        assert((cCode.canFind("if ((a.len<b.len)") || cCode.canFind("if ((a.len < b.len)") ||
                cCode.canFind("if (a.len < b.len")), 
               "Should use function parameter 'a' in if condition");
        
        assert((cCode.canFind("i < len") || cCode.canFind("i<len")), 
               "Should use declared variable 'len' in for loop condition");
        
        assert((cCode.canFind("a.data[i]") || cCode.canFind("a.data[ i ]")), 
               "Should use function parameter 'a' in for loop body");
    }
}
