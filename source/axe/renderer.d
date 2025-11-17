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
private bool[string] g_generatedTypedefs;
private bool[string] g_generatedFunctions;

string canonicalModelCName(string name)
{
    if (name in g_modelNames)
        return g_modelNames[name];

    foreach (baseName, cName; g_modelNames)
    {
        if (cName == name)
            return cName;
    }

    return "";
}

string formatModelFieldType(string fieldType)
{
    import std.string : strip, startsWith;

    string trimmed = fieldType.strip();
    string qualifiers;

    while (trimmed.startsWith("const "))
    {
        qualifiers ~= "const ";
        trimmed = trimmed[6 .. $].strip();
    }

    while (trimmed.startsWith("volatile "))
    {
        qualifiers ~= "volatile ";
        trimmed = trimmed[8 .. $].strip();
    }

    bool hadStructPrefix = false;
    if (trimmed.startsWith("struct "))
    {
        hadStructPrefix = true;
        trimmed = trimmed[7 .. $].strip();
    }

    string pointerSuffix;
    while (trimmed.length > 0 && trimmed[$ - 1] == '*')
    {
        pointerSuffix ~= "*";
        trimmed = trimmed[0 .. $ - 1].strip();
    }

    auto modelName = canonicalModelCName(trimmed);
    if (modelName.length > 0)
    {
        trimmed = "struct " ~ modelName;
    }
    else if (hadStructPrefix)
    {
        trimmed = "struct " ~ trimmed;
    }

    return qualifiers ~ trimmed ~ pointerSuffix;
}

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
            string baseType = info.type[0 .. bracketPos].strip();

            // Array references like "ref i32[]" should not add an extra pointer
            while (baseType.startsWith("ref "))
            {
                baseType = baseType[4 .. $].strip();
            }
            while (baseType.startsWith("mut "))
            {
                baseType = baseType[4 .. $].strip();
            }

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
    // Strip mut keyword if present (mut is not needed in C, variables are mutable by default)
    if (axeType.startsWith("mut "))
    {
        string baseType = axeType[4 .. $].strip();
        return mapAxeTypeToC(baseType);
    }

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
        string baseType = axeType[0 .. $ - 1].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }

    // Check if it's a standard type with mapping
    if (axeType in g_typeMappings)
    {
        return g_typeMappings[axeType];
    }

    // Check if it's a model name that needs prefixing
    if (axeType in g_modelNames)
    {
        return g_modelNames[axeType];
    }

    // Default case (user-defined types, etc)
    return axeType;
}

static class RendererConfiguration
{
    static bool releaseBuild = false;
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
        g_generatedTypedefs.clear();
        g_generatedFunctions.clear();

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
                        // Also add as model name for type mapping
                        g_modelNames[importName] = modulePrefix ~ "_" ~ importName;
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
                    // For stdlib files, prefix with module name
                    if (modelNode.name == "error") // temporary hack for stdlib/errors.axec
                        g_modelNames[modelNode.name] = "stdlib_errors_" ~ modelNode.name;
                    else
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
            if (child.nodeType != "Model" && child.nodeType != "ExternalImport" && child.nodeType != "Enum" && child
                .nodeType != "Use")
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

        if (funcName in g_generatedFunctions)
            return "";

        g_generatedFunctions[funcName] = true;

        if (funcNode.name == "main")
        {
            if (!RendererConfiguration.releaseBuild)
            {
                cCode ~= generateStackTraceHandlers();
            }
            cCode ~= "int main(int argc, char** argv) {\n";
            cCode ~= "__axe_argc = argc;\n";
            cCode ~= "__axe_argv = argv;\n";
            if (!RendererConfiguration.releaseBuild)
            {
                cCode ~= generateStackTraceSetup();
            }
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
                // For macro arguments, use them as-is without processing
                // This is important for untyped parameters used in raw C blocks
                // They should be literal string substitutions, not processed expressions
                string processedArg = callArgs[i].strip();
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

                    writeln("  DEBUG: RawC code before substitution: '", expandedCode, "'");
                    writeln("  DEBUG: Parameter map: ", paramMap);

                    foreach (paramName, paramValue; paramMap)
                    {
                        // Use {{param}} syntax for explicit macro parameter substitution
                        import std.string : replace;

                        string pattern = "{{" ~ paramName ~ "}}";
                        if (expandedCode.canFind(pattern))
                        {
                            writeln("  DEBUG: Found pattern '", pattern, "' in code");
                            writeln("  DEBUG: Replacing '", pattern, "' with '", paramValue, "'");
                            string beforeReplace = expandedCode;
                            // replace() in std.string replaces all occurrences
                            expandedCode = expandedCode.replace(pattern, paramValue);
                            if (beforeReplace == expandedCode)
                            {
                                writeln("  DEBUG: WARNING - replacement didn't change code!");
                            }
                        }
                        // Also support exact match for backward compatibility (but prefer {{param}})
                else if (expandedCode == paramName)
                        {
                            writeln("  DEBUG: Exact match (legacy) - replacing '", paramName, "' with '", paramValue, "'");
                            expandedCode = paramValue;
                        }
                    }

                    writeln("  DEBUG: RawC code after substitution: '", expandedCode, "'");

                    cCode ~= indent ~ expandedCode ~ "\n";
                }
                else
                {
                    // Handle non-RawC children (e.g., other AST nodes from macro body)
                    cCode ~= generateC(child);
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
        // Map the element type to C type (e.g., i32 -> int32_t)
        writeln("DEBUG ArrayDeclaration: elementType='", arrayNode.elementType, "' name='", arrayNode.name, "'");
        string mappedElementType = mapAxeTypeToC(arrayNode.elementType);
        writeln("DEBUG ArrayDeclaration: mappedElementType='", mappedElementType, "'");
        string arrayType = arrayNode.isMutable ? mappedElementType : "const " ~ mappedElementType;

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

        string arrayPart = "";
        string baseType;

        import std.string : indexOf, count;
        import std.conv : to;

        // Extract array part first, then map the base type to C
        if (declNode.typeName.length > 0)
        {
            auto bracketPos = declNode.typeName.indexOf('[');
            if (bracketPos >= 0)
            {
                arrayPart = declNode.typeName[bracketPos .. $];
                string rawBaseType = declNode.typeName[0 .. bracketPos].strip();
                baseType = mapAxeTypeToC(rawBaseType);
            }
            else
            {
                baseType = mapAxeTypeToC(declNode.typeName);
            }
        }
        else
        {
            baseType = "int";
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

                size_t bufferSize = cast(int) processedExpr.length - 2 + 1;

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
        {
            string formatString = "";
            string[] exprArgs;

            // Build format string and collect expression arguments
            for (size_t i = 0; i < printlnNode.messages.length; i++)
            {
                if (printlnNode.isExpressions[i])
                {
                    // Expression: determine format specifier based on type
                    string formatSpec = getFormatSpecifier(printlnNode.messages[i]);
                    formatString ~= formatSpec;
                    string processedExpr = processExpression(printlnNode.messages[i], "println");
                    exprArgs ~= processedExpr;
                }
                else
                {
                    // String literal: add directly to format string
                    formatString ~= printlnNode.messages[i];
                }
            }

            formatString ~= "\\n";

            // Generate printf call
            if (exprArgs.length > 0)
            {
                cCode ~= "printf(\"" ~ formatString ~ "\", " ~ exprArgs.join(", ") ~ ");\n";
            }
            else
            {
                cCode ~= "printf(\"" ~ formatString ~ "\");\n";
            }
        }
        break;

    case "Print":
        auto printNode = cast(PrintNode) ast;
        {
            string formatString = "";
            string[] exprArgs;

            // Build format string and collect expression arguments
            for (size_t i = 0; i < printNode.messages.length; i++)
            {
                if (printNode.isExpressions[i])
                {
                    // Expression: determine format specifier based on type
                    string formatSpec = getFormatSpecifier(printNode.messages[i]);
                    formatString ~= formatSpec;
                    string processedExpr = processExpression(printNode.messages[i], "println");
                    exprArgs ~= processedExpr;
                }
                else
                {
                    // String literal: add directly to format string
                    formatString ~= printNode.messages[i];
                }
            }

            // Generate printf call
            if (exprArgs.length > 0)
            {
                cCode ~= "printf(\"" ~ formatString ~ "\", " ~ exprArgs.join(", ") ~ ");\n";
            }
            else
            {
                cCode ~= "printf(\"" ~ formatString ~ "\");\n";
            }
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
        if (returnNode.expressionNode !is null)
        {
            // Handle complex expressions like model instantiation
            string processedExpr = generateC(returnNode.expressionNode);
            // Remove trailing newline if present
            if (processedExpr.endsWith("\n"))
                processedExpr = processedExpr[0 .. $ - 1];
            cCode ~= "return " ~ processedExpr ~ ";\n";
        }
        else if (returnNode.expression.length > 0)
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

        if (!RendererConfiguration.releaseBuild)
        {
            writeln("Not a release build, adding stack trace handlers.");
            cCode ~= generateStackTraceHandlers();
        }
        cCode ~= "int main(int argc, char** argv) {\n";
        cCode ~= "    __axe_argc = argc;\n";
        cCode ~= "    __axe_argv = argv;\n";
        if (!RendererConfiguration.releaseBuild)
        {
            cCode ~= generateStackTraceSetup();
        }
        version (Windows)
        {
            cCode ~= "SetConsoleOutputCP(65001);\n";
        }
        cCode ~= "    int passed = 0;\n";
        cCode ~= "    int failed = 0;\n\n";

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
        string modelName = canonicalModelCName(modelNode.name);
        if (modelName.length == 0)
            modelName = modelNode.name;

        if (modelName in g_generatedTypedefs)
            return "";

        g_generatedTypedefs[modelName] = true;

        cCode ~= "struct " ~ modelName ~ ";\n";
        cCode ~= "typedef struct " ~ modelName ~ " {\n";

        bool hasSelfReference = false;
        foreach (field; modelNode.fields)
        {
            string fieldType = field.type;
            auto bracketPos = fieldType.indexOf('[');
            if (bracketPos >= 0)
            {
                fieldType = fieldType[0 .. bracketPos].strip();
            }

            if (fieldType == modelNode.name)
            {
                hasSelfReference = true;
                break;
            }
        }

        foreach (field; modelNode.fields)
        {
            string fieldType;
            string arrayPart = "";

            // Extract array part first, then map the base type to C
            import std.string : indexOf;

            auto bracketPos = field.type.indexOf('[');
            if (bracketPos >= 0)
            {
                arrayPart = field.type[bracketPos .. $];
                string rawBaseType = field.type[0 .. bracketPos].strip();
                fieldType = mapAxeTypeToC(rawBaseType);
            }
            else
            {
                fieldType = mapAxeTypeToC(field.type);
            }

            writeln("DEBUG model field: name='", field.name, "' type='", field.type, "' mapped='", fieldType, "' arrayPart='", arrayPart, "'");

            // Handle ref types - convert "ref T" to "T*"
            if (fieldType.startsWith("ref "))
            {
                fieldType = fieldType[4 .. $].strip() ~ "*";
            }

            fieldType = formatModelFieldType(fieldType);

            // If field type is the same as the model name, use the forward-declared struct
            if (field.type == modelNode.name)
            {
                fieldType = "struct " ~ field.type ~ "*";
            }

            cCode ~= "    " ~ fieldType ~ " " ~ field.name ~ arrayPart ~ ";\n";
        }
        cCode ~= "} " ~ modelNode.name ~ ";\n\n";
        break;

    case "ModelInstantiation":
        auto instNode = cast(ModelInstantiationNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        string cModelName = canonicalModelCName(instNode.modelName);
        if (cModelName.length == 0)
            cModelName = instNode.modelName;

        // If variableName is empty, generate just the struct literal (for return statements)
        if (instNode.variableName.length == 0)
        {
            cCode ~= "(struct " ~ cModelName ~ "){";
        }
        else
        {
            // Generate struct initialization using compound literal (const for val, mutable for mut val)
            string constQualifier = instNode.isMutable ? "" : "const ";
            cCode ~= indent ~ constQualifier ~ cModelName ~ " " ~ instNode.variableName ~ " = {";
        }

        // Add field initializers
        bool first = true;
        foreach (fieldName, fieldValue; instNode.fieldValues)
        {
            if (!first)
                cCode ~= ", ";
            cCode ~= "." ~ fieldName ~ " = " ~ processExpression(fieldValue);
            first = false;
        }

        if (instNode.variableName.length == 0)
        {
            cCode ~= "}";
        }
        else
        {
            cCode ~= "};\n";
        }
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

    case "MemberIncrementDecrement":
        auto memberIncDecNode = cast(MemberIncrementDecrementNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        if (memberIncDecNode.isIncrement)
            cCode ~= indent ~ memberIncDecNode.objectName ~ "." ~ memberIncDecNode.memberName ~ "++;\n";
        else
            cCode ~= indent ~ memberIncDecNode.objectName ~ "." ~ memberIncDecNode.memberName ~ "--;\n";
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
                // For macro arguments, use them as-is without processing
                // This is important for untyped parameters used in raw C blocks
                // They should be literal string substitutions, not processed expressions
                paramMap[macroNode.params[i]] = callArgs[i].strip();
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
            return expr;

        string index = expr[bracketPos + 1 .. endPos - 1].strip();
        string rest = expr[endPos .. $].strip();
        string processedBase = processExpression(base);
        string processedIndex = processExpression(index);
        string processedRest = rest.length > 0 ? processExpression(rest) : "";
        return processedBase ~ "[" ~ processedIndex ~ "]" ~ processedRest;
    }

    // Handle member access with auto-detection of pointer types.
    //
    // IMPORTANT: Be string-literal aware so we never rewrite dots inside quoted strings
    if (expr.canFind("."))
    {
        string[] parts;
        string current = "";
        bool inString = false;

        for (size_t i = 0; i < expr.length; i++)
        {
            if (expr[i] == '"' && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
                current ~= expr[i];
            }
            else if (!inString && expr[i] == '.')
            {
                parts ~= current;
                current = "";
            }
            else
            {
                current ~= expr[i];
            }
        }
        parts ~= current;
        if (parts.length >= 2)
        {
            // Handle enum access if first part is uppercase
            string first = parts[0].strip();
            string second = parts[1].strip();

            // Special case: pure numeric float literal like "1 . 0" or "3.14"
            // Only trigger this when the *entire* expression is numeric.
            import std.algorithm : all;
            import std.ascii : isDigit;
            import std.string : strip;

            string noSpace = expr.strip().replace(" ", "");
            bool onlyDigitsAndDot = noSpace.length > 0 &&
                noSpace.all!(c => isDigit(c) || c == '.');

            if (onlyDigitsAndDot)
            {
                return noSpace;
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

            // Enum access: only when the left side is a simple identifier (no operators/parentheses)
            if (!firstHasOps && first.length > 0 && first[0] >= 'A' && first[0] <= 'Z')
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

/**
 * Determines the printf format specifier for an expression.
 * Returns "%s" for strings, "%d" for integers (default).
 */
private string getFormatSpecifier(string expr)
{
    // Check if expression contains .data (common for String types)
    if (expr.canFind(".data"))
    {
        return "%s";
    }

    // Check if it's a simple variable with string type
    import std.string : strip;

    string varName = expr.strip();

    // Remove any member access to get base variable name
    if (varName.canFind("."))
    {
        varName = varName[0 .. varName.indexOf(".")];
    }
    else if (varName.canFind("->"))
    {
        varName = varName[0 .. varName.indexOf("->")];
    }

    // Check if variable type is a string/pointer type
    if (varName in g_varType)
    {
        string varType = g_varType[varName];
        if (varType.canFind("*") || varType.canFind("char"))
        {
            return "%s";
        }
    }

    // Default to integer format (maintains backward compatibility)
    return "%d";
}

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
        auto tokens = lex(
            "def test_func(grid: i32[height][width], width: i32, height: i32) { } main { }");
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
            "model Cat { health: i32 } main { mut val cat = new Cat(health: 100); println cat.health; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Member access in println test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have struct initialization");
        assert(cCode.canFind("printf(\"%d\\n\", cat.health);"), "Should print member access");
    }

    {
        auto tokens = lex("model Person { name: char*, age: i32, height: i32 } main"
                ~ " { val p = new Person(name: \"Alice\", age: 30, height: 170); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multi-field model test:");
        writeln(cCode);

        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int32_t age;"), "Should have age field");
        assert(cCode.canFind("int32_t height;"), "Should have height field");
        assert(cCode.canFind(".name = \"Alice\""), "Should initialize name");
        assert(cCode.canFind(".age = 30"), "Should initialize age");
        assert(cCode.canFind(".height = 170"), "Should initialize height");
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex(
                "model Cat { health: i32 } main { val cat = new Cat(health: 100); cat.health = 90; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Cannot assign to member") || e.msg.canFind("immutable"),
                "Should prevent assignment to immutable struct member");
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught immutable member assignment error");
        }
    }

    {
        auto tokens = lex(
            "model Point { x: i32, y: i32 } model Line { start: Point*, end: Point* } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested model types test:");
        writeln(cCode);

        assert(cCode.canFind("} Point;"), "Should define Point struct");
        assert(cCode.canFind("} Line;"), "Should define Line struct");
        assert(cCode.canFind("Point* start;"), "Should have Point* field in Line");
        assert(cCode.canFind("Point* end;"), "Should have Point* field in Line");
    }

    {
        auto tokens = lex("main { val x: i32 = 1; switch x { case 1 { println \"one\"; } " ~
                "case 2 { println \"two\"; } default { println \"other\"; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Switch/case statement test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t x = 1;"), "Should declare x with type annotation");
        assert(cCode.canFind("switch (x) {"), "Should have switch statement");
        assert(cCode.canFind("case 1:"), "Should have case 1");
        assert(cCode.canFind("printf(\"one\\n\");"), "Should have println in case 1");
        assert(cCode.canFind("case 2:"), "Should have case 2");
        assert(cCode.canFind("printf(\"two\\n\");"), "Should have println in case 2");
        assert(cCode.canFind("default:"), "Should have default case");
        assert(cCode.canFind("printf(\"other\\n\");"), "Should have println in default");
        assert(cCode.canFind("break;"), "Should have break statements");
    }

    {
        auto tokens = lex("main { val x: char* = \"hello\"; mut val y: i32 = 42; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Type annotation test:");
        writeln(cCode);

        assert(cCode.canFind("const char x[6];"), "Should convert char* with string literal to char[] with exact size");
        assert(cCode.canFind("strcpy(x, \"hello\");"), "Should use strcpy for string literal initialization");
        assert(cCode.canFind("int32_t y = 42;"), "Should use int type annotation for mutable");
        assert(!cCode.canFind("const int y"), "Mutable variable should not be const");
    }

    {
        auto tokens = lex("main { val a: i32 = 5; val b: i32 = 10; val c: i32 = a + b; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multiple type annotations test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t a = 5;"), "Should declare a with int type");
        assert(cCode.canFind("const int32_t b = 10;"), "Should declare b with int type");
        assert(cCode.canFind("const int32_t c = (a+b);"), "Should declare c with int type");
    }

    {
        auto tokens = lex("main { mut val x: i32 = 0; x++; x--; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment/decrement operators test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 0;"), "Should declare mutable x");
        assert(cCode.canFind("x++;"), "Should have increment operator");
        assert(cCode.canFind("x--;"), "Should have decrement operator");
    }

    {
        auto tokens = lex(
            "main { mut val counter: i32 = 0; loop { counter++; if counter == 5 { break; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment in loop test (if without parens):");
        writeln(cCode);

        assert(cCode.canFind("int32_t counter = 0;"), "Should declare counter");
        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("counter++;"), "Should increment in loop");
        assert(cCode.canFind("if ((counter==5))"), "Should have condition");
    }

    {
        auto tokens = lex("main { val x: i32 = 10; val y: ref i32 = ref_of(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Reference type test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 10;"), "Should have x declaration");
        assert(cCode.canFind("int32_t* y = &x;"), "Should have y as pointer with address-of");
    }

    {
        auto tokens = lex("main { val x: i32 = 10; val addr: i64 = addr_of(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("addr_of test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 10;"), "Should have x declaration");
        assert(cCode.canFind("int64_t addr = (int64_t)&x;"), "Should convert address to long");
    }

    {
        auto tokens = lex(
            "enum State { RUNNING, STOPPED } main { val s: State = State.RUNNING; println s; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Enum test:");
        writeln(cCode);

        assert(cCode.canFind("typedef enum {"), "Should have typedef enum declaration");
        assert(cCode.canFind("} State;"), "Should have State typedef");
        assert(cCode.canFind("RUNNING"), "Should have enum value RUNNING");
        assert(cCode.canFind("STOPPED"), "Should have enum value STOPPED");
        assert(cCode.canFind("State s = RUNNING;"), "Should use enum value without prefix");
    }

    {
        auto tokens = lex("main { if 5 mod 3 == 2 { println \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Modulo operator test:");
        writeln(cCode);

        assert(cCode.canFind("5%3"), "Should translate 'mod' to '%'");
        assert(!cCode.canFind("mod"), "Should not have 'mod' keyword in output");
    }

    {
        auto tokens = lex("main { if 1 == 1 and 2 == 2 { println \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Logical AND operator test:");
        writeln(cCode);

        assert(cCode.canFind("&&"), "Should translate 'and' to '&&'");
    }

    {
        auto tokens = lex("main { if 1 mod 3 == 0 and 2 mod 5 == 0 { println \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Complex condition with mod and and test:");
        writeln(cCode);

        assert(cCode.canFind("1%3"), "Should translate first 'mod' to '%'");
        assert(cCode.canFind("2%5"), "Should translate second 'mod' to '%'");
        assert(cCode.canFind("&&"), "Should translate 'and' to '&&'");
        assert(!cCode.canFind("mod"), "Should not have 'mod' keyword in output");
        assert(cCode.canFind("1%3==0") || cCode.canFind("(1 % 3 == 0)") ||
                cCode.canFind("(1%3)==0"), "Should have proper first comparison");
        assert(cCode.canFind("2%5==0") || cCode.canFind("(2 % 5 == 0)") ||
                cCode.canFind("(2%5)==0"), "Should have proper second comparison");
    }

    {
        auto tokens = lex(
            "def get_value(x: i32): i32 { return x; } def wrapper(y: i32): i32 { return get_value(y); } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t get_value(int32_t x)"), "Should have get_value function");
        assert(cCode.canFind("int32_t wrapper(int32_t y)"), "Should have wrapper function");
        assert(cCode.canFind("return get_value(y)"), "Should have nested function call");
    }

    {
        auto tokens = lex(
            "def destroy(ptr: i64) { } main { val x: i32 = 5; destroy(thing_of(x)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call in main test:");
        writeln(cCode);

        assert(cCode.canFind("void destroy(int64_t ptr)"), "Should have destroy function");
        assert(cCode.canFind("destroy(thing_of(x))"), "Should have nested function call with ref_of(x)");
    }

    {
        auto tokens = lex(
            "def inner(a: i32): i32 { return a; } def middle(b: i32): i32 { return inner(b); } def outer(c: i32): i32 { return middle(inner(c)); } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deeply nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("return middle(inner(c))"), "Should handle deeply nested calls: middle(inner(c))");
    }

    // Macro system tests
    {
        auto tokens = lex(
            "macro add(a: i32, b: i32) { raw { a + b } } main { val x: i32 = add(5, 3); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Basic macro test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t x = (5+3);") || cCode.canFind(
                "const int32_t x = ( 5 + 3 );"),
            "Should expand macro add(5, 3) to (5+3)");
        assert(!cCode.canFind("add(5, 3)"), "Should not have macro call in output");
    }

    {
        auto tokens = lex(
            "macro square(x: i32) { raw { x * x } } main { val result: i32 = square(4); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with repeated parameter test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t result = ( 4 * 4 );") || cCode.canFind(
                "const int32_t result = (4 * 4);"),
            "Should expand square(4) to (4*4)");
    }

    {
        auto tokens = lex(
            "macro max(a: i32, b: i32) { raw { (a > b) ? a : b } } main { val m: i32 = max(10, 20); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with ternary operator test:");
        writeln(cCode);

        assert(cCode.canFind("(10>20)?10:20") || cCode.canFind("(10 > 20) ? 10 : 20"),
            "Should expand max(10, 20) to ternary expression");
    }

    {
        auto tokens = lex(
            "macro add(a: i32, b: i32) { raw { a + b } } def calc(x: i32, y: i32): i32 { return add(x, y); } main { }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in function body test:");
        writeln(cCode);

        assert(cCode.canFind("return ( x + y );") || cCode.canFind("return (x + y);"),
            "Should expand macro in function return statement");
    }

    {
        auto tokens = lex(
            "macro inc(x: i32) { raw { x + 1 } } main { val a: i32 = 5; val b: i32 = inc(a); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with variable argument test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t b = ( a + 1 );") || cCode.canFind(
                "const int32_t b = (a + 1);"),
            "Should expand inc(a) with variable argument");
    }

    {
        auto tokens = lex(
            "macro triple(x: i32) { raw { x * 3 } } main { if triple(2) == 6 { println \"yes\"; } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in condition test:");
        writeln(cCode);

        assert(cCode.canFind("if") && (cCode.canFind("( 2 * 3 )==6") || cCode.canFind(
                "(2 * 3) == 6")),
            "Should expand macro in if condition");
    }

    {
        auto tokens = lex("main { mut val ptr: i32* = NULL; val value: i32 = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref test:");
        writeln(cCode);

        assert(cCode.canFind("*ptr"), "Should replace deref(ptr) with *ptr");
        assert(cCode.canFind("int32_t* ptr = NULL;"), "Should declare pointer variable");
        assert(cCode.canFind("const int32_t value = (*ptr);"), "Should assign dereferenced value");
    }

    {
        auto tokens = lex("main { mut val ptr: i32** = NULL; val value: i32 = deref(deref(ptr)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested deref test:");
        writeln(cCode);

        assert(cCode.canFind("*(*ptr)"), "Should handle nested deref(deref(ptr)) as **ptr");
        assert(cCode.canFind("int32_t** ptr = NULL;"), "Should declare double pointer");
        assert(cCode.canFind("const int32_t value = (*(*ptr));"), "Should assign double dereferenced value");
    }

    {
        auto tokens = lex(
            "main { mut val ptr: int* = NULL; if deref(ptr) == 5 { println \"equal\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref in condition test:");
        writeln(cCode);

        assert(cCode.canFind("if (((*ptr)==5))"), "Should handle deref in if condition");
    }

    {
        auto tokens = lex("main { mut val ptr: i32* = NULL; deref(ptr) = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref assignment test:");
        writeln(cCode);

        assert(cCode.canFind("(*ptr) = 10;"), "Should handle deref on left side of assignment");
    }

    {
        auto tokens = lex("model Test { field: i32 } main { mut val obj: Test; obj.field = 5; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Non-pointer member access test:");
        writeln(cCode);

        assert(cCode.canFind("obj.field = 5;"), "Should use . for non-pointer object");
    }

    {
        auto tokens = lex(
            "model Test { field: i32 } main { mut val ptr: ref Test; ptr.field = 5; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Pointer variable member access test:");
        writeln(cCode);

        assert(cCode.canFind("ptr->field = 5;"), "Should use -> for pointer variable");
    }

    {
        auto tokens = lex("model Node { value: i32, next: Node } main { val head: Node; if head.next.value == 5 { println \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Pointer field access in if condition test:");
        writeln(cCode);

        assert(cCode.canFind("if ((head.next->value==5))"), "Should use -> for pointer field access in if condition");
    }

    {
        auto tokens = lex(
            "model Test { value: i32 } main { val ptr: i64 = 123; mut val n: ref Test = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deref on long test:");
        writeln(cCode);

        assert(cCode.canFind("Test* n = (Test*)ptr;"), "Should cast long to pointer type when deref in declaration");
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
        auto tokens = lex(
            "def test_func(grid: i32[height][width], width: i32, height: i32) { } main { }");
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
            "model stdlib_string_String { data: char*, len: usize } " ~
                "def str_copy(src: String, dest: mut String): void { " ~
                "dest.data = src.data; " ~
                "dest.len = src.len; " ~
                "} " ~
                "main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Mut parameter with prefixed type test:");
        writeln(cCode);

        assert(cCode.canFind("void str_copy(stdlib_string_String src, stdlib_string_String dest);") ||
                cCode.canFind("void str_copy(stdlib_string_String src,stdlib_string_String dest);"),
                "Forward declaration should strip mut keyword and apply type prefix");

        assert(cCode.canFind("void str_copy(stdlib_string_String src, stdlib_string_String dest)") ||
                cCode.canFind("void str_copy(stdlib_string_String src,stdlib_string_String dest)"),
                "Function definition should strip mut keyword and apply type prefix");

        assert(!cCode.canFind("mut stdlib_string_String") && !cCode.canFind("mut String"),
            "mut keyword should not appear in generated C code");

        assert(cCode.canFind("dest.data = src.data;") || cCode.canFind("dest.data=src.data;"),
            "Function parameter should be usable in function body");
    }

    {
        auto tokens = lex("model Test { data: i32[10][20]; } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("2D array test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t data[10][20];"), "2D array should be rendered as int32_t data[10][20];");
    }

    {
        auto tokens = lex(
            "model Node { value: i32; next: ref Node; } " ~
                "main { mut val head: ref Node = nil; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Self-referential model hoist test:");
        writeln(cCode);

        assert(cCode.canFind("struct Node;"), "Model should emit forward declaration before typedef");
        assert(cCode.canFind("typedef struct Node {"), "Model should emit typedef for struct Node");
        assert(cCode.canFind("struct Node* next;"),
            "Self-referential fields should use 'struct Node*' to avoid undeclared identifier errors");
    }

    {
        auto tokens = lex(
            "def use_grid(grid: ref i32[], width: i32) { } " ~
                "main { use_grid(nil, 0); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Ref array parameter test:");
        writeln(cCode);

        assert(cCode.canFind("void use_grid(int32_t* grid, int32_t width);"),
            "ref i32[] parameters should compile to single pointer");
        assert(cCode.canFind("void use_grid(int32_t* grid, int32_t width)"),
            "Function definition should also use single pointer");
    }

    {
        auto tokens = lex(
            `
            model error {
                msg: string;
            }

            def __test_error(): error {
                return new error(msg: string.create("test"));
            }

            test {}
            `
        );
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Prefixed model instantiation test:");
        writeln(cCode);

        assert(cCode.canFind("struct stdlib_errors_error"), "Should have generated struct with prefixed name");
        assert(cCode.canFind("struct stdlib_errors_error){.msg = string_create(\"test\")}"),
            "Should instantiate with correct prefixed struct name");
    }

    {
        auto tokens = lex(`
        model Counter {
            value: i32,
        }

        main {
            mut val counter: Counter;
            counter.value = 5;
            counter.value++;
            println counter.value;
            counter.value--;
            println counter.value;
        }`);
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment/decrement on struct member test:");
        writeln(cCode);

        assert(cCode.canFind("counter.value++;"), "Should increment struct member correctly");
        assert(cCode.canFind("counter.value--;"), "Should decrement struct member correctly");
    }

    {
        auto tokens = lex(`
        model error {
            msg: string;

            def create(msg: char*): error {
                return new error(msg: string.create(msg));
            }

            def print_self(err: error) {
                print_str(err.msg);
            }
        }

        def panic(err: error) {
            print "\nRuntimeError: ";
            error.print_self(err);
            
            raw {
                exit(1);
            }
        }

        def __test_error(): error {
            return new error(msg: string.create("Some bad thing happened"));
        }

        test {
            println_str(__test_error().msg);
            panic(error.create("Uh oh"));
        }`);
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);
        writeln("Model method calls test:");
        writeln(cCode);
        assert(cCode.canFind("void error_print_self(stdlib_errors_error err)"),
            "Should generate method function with correct signature");

    }
}
