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

private int[string] g_refDepths;
private bool[string] g_isMutable;
private string[string] g_arrayWidthVars;
private int[][string] g_functionParamReordering;
private MacroNode[string] g_macros;
private bool[string] g_pointerFields;

/** 
 * Converts a string to an operand.
 *
 * Params:
 *   s = String to convert to operand
 *   paramMap = Parameter mapping for function arguments
 *
 * Returns: 
 *   Operand string
 */
string operand(string s, string[string] paramMap = null)
{
    s = s.strip();
    if (s.length == 0)
        return s;
    if (paramMap !is null && s in paramMap)
        return paramMap[s];
    if (s[0].isDigit() || (s.length > 1 && s[0] == '-' && s[1].isDigit()))
        return s;
    if (s[0] == '"')
        return s;
    return "[" ~ s ~ "]";
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

        foreach (child; ast.children)
        {
            if (child.nodeType == "Macro")
            {
                auto macroNode = cast(MacroNode) child;
                g_macros[macroNode.name] = macroNode;
                writeln("DEBUG: Pre-stored macro '", macroNode.name, "' with ", macroNode.params.length, " parameters");
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (field; modelNode.fields)
                {
                    if (field.type == modelNode.name)
                        g_pointerFields[modelNode.name ~ "." ~ field.name] = true;
                }
            }
        }

        cCode ~= "#include <stdio.h>\n";
        cCode ~= "#include <stdbool.h>\n";
        cCode ~= "#include <stdlib.h>\n";
        cCode ~= "#include <string.h>\n";

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
                    cCode ~= funcNode.returnType ~ " " ~ funcNode.name ~ "(";
                    if (funcNode.params.length > 0)
                    {
                        foreach (i, param; funcNode.params)
                        {
                            import std.string : replace, split, strip;

                            string cParam = param;
                            if (param.canFind("ref "))
                            {
                                cParam = param.replace("ref ", "");
                                auto parts = cParam.split();
                                if (parts.length >= 2)
                                {
                                    cParam = parts[0] ~ "* " ~ parts[1];
                                }
                            }
                            cCode ~= cParam;
                            if (i < cast(int) funcNode.params.length - 1)
                                cCode ~= ", ";
                        }
                    }
                    cCode ~= ");\n";
                }
            }
        }
        cCode ~= "\n";

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
            cCode ~= "int main(int argc, char** argv) {\n";
            cCode ~= "__axe_argc = argc;\n";
            cCode ~= "__axe_argv = argv;\n";
            version (Windows)
            {
                cCode ~= "SetConsoleOutputCP(CP_UTF8);\n";
            }
        }
        else
        {
            cCode ~= funcNode.returnType ~ " " ~ funcName ~ "(";
            if (params.length > 0)
            {
                import std.stdio : writeln;
                import std.string : split, strip, indexOf, lastIndexOf;

                struct ParamInfo
                {
                    string type;
                    string name;
                    bool isArray;
                    int dimensions;
                    string[] dimNames;
                }

                ParamInfo[] paramInfos;

                foreach (param; funcNode.params)
                {
                    writeln("DEBUG: Processing param: '", param, "'");
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
                            import std.algorithm : count;
                            import std.regex : regex, matchAll;

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
                int[] reorderMap;

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
                            // No dimensions specified, fallback to pointer
                            otherParams ~= baseType ~ "* " ~ info.name;
                        }
                    }
                    else
                    {
                        string finalType = info.type;
                        if (finalType.startsWith("ref "))
                        {
                            finalType = finalType[4 .. $].strip() ~ "*";
                        }

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
                g_functionParamReordering[funcName] = reorderMap;
                string[] processedParams = dimensionParams ~ otherParams;
                cCode ~= processedParams.join(", ");
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
                paramMap[macroNode.params[i]] = callArgs[i];
                writeln("  DEBUG: Mapping '", macroNode.params[i], "' -> '", callArgs[i], "'");
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
            processedArgs ~= processExpression(arg);

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
        debug writeln("DEBUG Assignment: dest after processExpression='", dest, "'");
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
                string processedExpr = processExpression(expr);
                cCode ~= " = " ~ processedExpr;
            }
            cCode ~= ";\n";
        }
        else
        {
            if (baseVarName in g_isMutable && !g_isMutable[baseVarName])
                throw new Exception(
                    "Cannot assign to immutable variable '" ~ baseVarName ~ "' (declared with 'val')");

            string processedExpr = processExpression(expr);

            string destWithDeref = dest;
            if (baseVarName in g_refDepths && g_refDepths[baseVarName] > 0)
            {
                for (int i = 0; i < g_refDepths[baseVarName]; i++)
                {
                    destWithDeref = "*" ~ destWithDeref;
                }
            }

            cCode ~= destWithDeref ~ " = " ~ processedExpr ~ ";\n";
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
            // 2D array assignment - keep as-is
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

        string baseType = declNode.typeName.length > 0 ? declNode.typeName : "int";
        string arrayPart = "";

        // Extract array dimensions from type (e.g., "int[5]" -> "int" and "[5]")
        import std.string : indexOf, count;
        import std.conv : to;

        auto bracketPos = baseType.indexOf('[');
        if (bracketPos >= 0)
        {
            arrayPart = baseType[bracketPos .. $];
            baseType = baseType[0 .. bracketPos];

            // Keep 2D arrays as 2D for proper pointer arithmetic
            // int[10][10] stays as int[10][10]
        }

        for (int i = 0; i < declNode.refDepth; i++)
            baseType ~= "*";

        string type = declNode.isMutable ? baseType : "const " ~ baseType;
        string decl = type ~ " " ~ declNode.name ~ arrayPart;

        if (declNode.initializer.length > 0)
        {
            string processedExpr = processExpression(declNode.initializer);

            // Special case: char* with string literal should become char[] for writability
            if (baseType == "char*" && processedExpr.length > 0 && processedExpr[0] == '"')
            {
                import std.string : replace;

                // Calculate actual string length from the literal (subtract 2 for quotes, add 1 for null terminator)
                size_t bufferSize = processedExpr.length - 2 + 1;

                // Change from char* to char[] with exact size needed
                type = declNode.isMutable ? "char" : "const char";
                decl = type ~ " " ~ declNode.name ~ "[" ~ bufferSize.to!string ~ "]";
                // Use strcpy to copy the string literal into the buffer
                cCode ~= decl ~ ";\n";
                cCode ~= "strcpy(" ~ declNode.name ~ ", " ~ processedExpr ~ ");\n";
                break;
            }

            // Convert array initializer syntax: [1,2,3] -> {1,2,3}
            if (arrayPart.length > 0 && processedExpr.length > 0 && processedExpr[0] == '[')
            {
                import std.string : replace, split;

                // If array size not specified (e.g., int[]), calculate from initializer
                if (arrayPart == "[]")
                {
                    // Count elements in initializer
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
            string processedExpr = processExpression(printlnNode.message);
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
            string processedExpr = processExpression(printNode.message);
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

        // Handle elif/else chain - elif nodes are stored as IfNodes in elseBody
        IfNode currentNode = ifNode;
        while (currentNode.elseBody.length == 1 && currentNode.elseBody[0].nodeType == "If")
        {
            // This is an elif
            auto elifNode = cast(IfNode) currentNode.elseBody[0];
            cCode ~= " else if (" ~ processCondition(elifNode.condition) ~ ") {\n";
            loopLevel++;

            foreach (child; elifNode.children)
            {
                cCode ~= generateC(child);
            }

            loopLevel--;
            cCode ~= "}";

            // Move to the next node in the chain
            currentNode = elifNode;
        }

        // Handle final else block (if not another elif)
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
        cCode ~= "int main(int argc, char** argv) {\n";
        cCode ~= "    __axe_argc = argc;\n";
        cCode ~= "    __axe_argv = argv;\n";
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
        // Forward declare the struct for self-referencing
        cCode ~= "struct " ~ modelNode.name ~ ";\n";
        cCode ~= "typedef struct " ~ modelNode.name ~ " {\n";
        foreach (field; modelNode.fields)
        {
            string fieldType = field.type;
            // If field type is the same as the model name, make it a pointer
            if (field.type == modelNode.name)
            {
                fieldType = "struct " ~ field.type ~ "*";
            }
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
        // Check if this member access is to a pointer field or if the object is already a pointer (contains ->)
        if (memberNode.objectName.canFind("->") ||
            (memberNode.objectName ~ "." ~ memberNode.memberName in g_pointerFields))
        {
            accessOp = "->";
        }

        if (memberNode.value.length > 0)
        {
            // Member write
            cCode ~= indent ~ memberNode.objectName ~ accessOp ~ memberNode.memberName ~ " = " ~ memberNode.value ~ ";\n";
        }
        else
        {
            // Member read (used in expressions)
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
string processExpression(string expr)
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
                paramMap[macroNode.params[i]] = callArgs[i];
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
        expr = expr[0 .. startIdx] ~ "(long)&" ~ varName ~ expr[parenEnd + 1 .. $];
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
        expr = expr[0 .. startIdx] ~ "*" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    if (expr.canFind(".") && !expr.canFind(".len"))
    {
        auto parts = expr.split(".");
        if (parts.length == 2)
        {
            string firstPart = parts[0].strip();
            string secondPart = parts[1].strip();
            if (firstPart.length > 0 && firstPart[0] >= 'A' && firstPart[0] <= 'Z')
            {
                return secondPart;
            }
        }
    }

    // Handle .len property for arrays
    if (expr.canFind(".len"))
    {
        auto parts = expr.split(".len");
        if (parts.length == 2 && parts[1].strip().length == 0)
        {
            string arrayName = parts[0].strip();
            return "(sizeof(" ~ arrayName ~ ")/sizeof(" ~ arrayName ~ "[0]))";
        }
    }

    // Don't process if it's already parenthesized or contains array access
    if (expr.canFind("[") || (expr.canFind("(") && expr.endsWith(")")))
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
            // Smart split that respects string literals
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
                else if (!inString && i + op.length <= expr.length &&
                    expr[i .. i + op.length] == op &&
                    (i == 0 || expr[i - 1] != op[0]))
                {
                    parts ~= current;
                    current = "";
                    i += op.length - 1; // Skip the operator
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
        string result = expr;
        for (int i = 0; i < g_refDepths[expr]; i++)
        {
            result = "*" ~ result;
        }
        return result;
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

import std.conv;

/** 
 * Assembly/NASM backend renderer.
 *
 * Params:
 *   ast = Abstract syntax tree to render.
 * Returns: 
 *   Generated assembly code.
 */
string generateAsm(ASTNode ast)
{
    string asmCode;
    string dataSection;
    string[string] variables;
    string[] currentFunctionParams;

    void declareVariable(string name)
    {
        if (!(name in variables))
        {
            variables[name] = name;
            dataSection ~= "    " ~ name ~ " dd 0\n";
        }
    }

    bool isParameter(string name) => currentFunctionParams.canFind(name);

    final switch (ast.nodeType)
    {
    case "Program":
        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                asmCode ~= generateAsm(child) ~ "\n";
            }
        }
        foreach (child; ast.children)
        {
            if (child.nodeType == "Main")
            {
                asmCode ~= generateAsm(child);
            }
        }
        break;

    case "Main":
        asmCode = `
            section .data
                fmt db "%s", 0
                nl db 10, 0
            `
            ~ dataSection ~ `
            section .text
                extern printf
                global main
            main:
                sub rsp, 40
        `;
        int msgCounter = 0;
        foreach (child; ast.children)
        {
            final switch (child.nodeType)
            {
            case "Println":
                asmCode ~= `
                    section .data
                        msg_`
                    ~ msgCounter.to!string ~ ` db '` ~ (cast(PrintlnNode) child)
                    .message ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                msgCounter++;
                break;

            case "FunctionCall":
                auto callNode = cast(FunctionCallNode) child;
                string callName = callNode.functionName;
                string callArgs = callNode.functionName ~ "(" ~ callNode.args.join(", ") ~ ")";

                if (callArgs.length > 0)
                {
                    auto argList = callArgs.split(",");
                    foreach (i, a; argList)
                    {
                        string param = a.strip();
                        string reg = i == 0 ? "rcx" : i == 1 ? "rdx" : i == 2 ? "r8" : i == 3 ? "r9"
                            : "";

                        if (i < 4)
                        {
                            asmCode ~= "    mov " ~ reg ~ ", " ~ operand(param) ~ "\n";
                        }
                        else
                        {
                            asmCode ~= "    mov rcx, " ~ operand(param) ~ "\n";
                            asmCode ~= "    push rcx\n";
                        }
                    }
                }

                asmCode ~= "    call " ~ callName ~ "\n";

                if (callArgs.length > 0 && callArgs.split(",").length > 4)
                {
                    int numStackArgs = cast(int) callArgs.split(",").length - 4;
                    asmCode ~= "    add rsp, " ~ to!string(numStackArgs * 8) ~ "\n";
                }
                break;

            case "Loop":
                int loopId = 0;
                asmCode ~= "loop_" ~ loopId.to!string ~ "_start:\n";
                foreach (loopChild; child.children)
                {
                    final switch (loopChild.nodeType)
                    {
                    case "Println":
                        asmCode ~= `
                            section .data
                                msg_`
                            ~ msgCounter.to!string ~ ` db '` ~ (cast(PrintlnNode) loopChild)
                            .message ~ `', 0
                            section .text
                                mov rcx, msg_`
                            ~ msgCounter.to!string ~ `
                                call printf
                                mov rcx, nl
                                call printf
                        `;
                        msgCounter++;
                        break;
                    case "Break":
                        asmCode ~= "    jmp loop_" ~ loopId.to!string ~ "_end\n";
                        break;
                    case "Assignment":
                        auto parts = (cast(AssignmentNode) loopChild).expression.split("=");
                        string dest = parts[0].strip();
                        string src = parts[1].strip();

                        if (!isParameter(dest))
                            declareVariable(dest);

                        if (src.canFind(" - "))
                        {
                            auto exprParts = src.split(" - ");
                            asmCode ~= "    mov eax, " ~ operand(exprParts[0]) ~ "\n"
                                ~ "    sub eax, " ~ operand(
                                    exprParts[1]) ~ "\n"
                                ~ "    mov [" ~ dest ~ "], eax\n";
                        }
                        else
                        {
                            asmCode ~= "    mov eax, " ~ operand(
                                src) ~ "\n"
                                ~ "    mov [" ~ dest ~ "], eax\n";
                        }
                        break;
                    }
                }
                asmCode ~= "    jmp loop_" ~ loopId.to!string ~ "_start\n";
                asmCode ~= "loop_" ~ loopId.to!string ~ "_end:\n";
                break;

            case "Break":
                asmCode ~= "    jmp loop_0_end\n";
                break;
            case "Assignment":
                auto parts = (cast(AssignmentNode) child).expression.split("=");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                if (!isParameter(dest))
                    declareVariable(dest);

                if (src.canFind(" - "))
                {
                    auto exprParts = src.split(" - ");
                    asmCode ~= "    mov eax, " ~ operand(exprParts[0]) ~ "\n"
                        ~ "    sub eax, " ~ operand(
                            exprParts[1]) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                else
                {
                    asmCode ~= "    mov eax, " ~ operand(src) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                break;
            }
        }
        asmCode ~= `
            add rsp, 40
            xor eax, eax
            ret
        `;
        break;

    case "Function":
        auto funcNode = cast(FunctionNode) ast;
        string funcName = funcNode.name;
        string args = funcNode.params.join(", ");

        asmCode ~= "section .text\n"
            ~ "global " ~ funcName ~ "\n"
            ~ funcName ~ ":\n"
            ~ "    push rbp\n"
            ~ "    mov rbp, rsp\n"
            ~ "    sub rsp, 40\n";

        string[string] paramMap;
        if (args.length > 0)
        {
            auto params = args.split(",");
            int offset = 16;
            foreach (i, param; params)
            {
                string paramName = param.split(":")[0].strip();
                paramMap[paramName] = "[rbp+" ~ to!string(offset) ~ "]";
                asmCode ~= "    mov " ~ paramMap[paramName] ~ ", "
                    ~ (i == 0 ? "rcx" : i == 1 ? "rdx" : i == 2 ? "r8" : "r9") ~ "\n";
                offset += 8;
            }
        }
        int msgCounter = 0;
        foreach (child; ast.children)
        {
            switch (child.nodeType)
            {
            case "Println":
                asmCode ~= `
                    section .data
                        msg_`
                    ~ msgCounter.to!string ~ ` db '` ~ (cast(PrintlnNode) child)
                    .message ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                msgCounter++;
                break;

            case "FunctionCall":
                auto callNode = cast(FunctionCallNode) child;
                string callName = callNode.functionName;
                string callArgs = callNode.functionName ~ "(" ~ callNode.args.join(", ") ~ ")";

                if (callArgs.length > 0)
                {
                    auto argList = callArgs.split(",");
                    foreach (i, a; argList)
                    {
                        string param = a.strip();
                        string reg = i == 0 ? "rcx" : i == 1 ? "rdx" : i == 2 ? "r8" : i == 3 ? "r9"
                            : "";

                        if (i < 4)
                        {
                            asmCode ~= "    mov " ~ reg ~ ", " ~ operand(param) ~ "\n";
                        }
                        else
                        {
                            asmCode ~= "    mov rcx, " ~ operand(param) ~ "\n";
                            asmCode ~= "    push rcx\n";
                        }
                    }
                }

                asmCode ~= "    call " ~ callName ~ "\n";
                break;
            case "Assignment":
                auto parts = (cast(AssignmentNode) child).expression.split("=");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                if (!isParameter(dest))
                    declareVariable(dest);

                if (src.canFind(" - "))
                {
                    auto exprParts = src.split(" - ");
                    asmCode ~= "    mov eax, " ~ operand(exprParts[0]) ~ "\n"
                        ~ "    sub eax, " ~ operand(
                            exprParts[1]) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                else
                {
                    asmCode ~= "    mov eax, " ~ operand(src) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                break;

            case "If":
                auto condition = (cast(IfNode) child).condition;
                string endIfLabel = "endif_" ~ to!string(child.children.length);

                if (condition.canFind("=="))
                {
                    auto parts = condition.split("==");
                    string left = parts[0].strip();
                    string right = parts[1].strip();

                    if (paramMap !is null && left in paramMap)
                        asmCode ~= "    mov eax, " ~ paramMap[left] ~ "\n";
                    else
                        asmCode ~= "    mov eax, " ~ operand(left) ~ "\n";

                    asmCode ~= "    mov ebx, " ~ (right[0].isDigit() ? right
                            : operand(right, paramMap)) ~ "\n";
                    asmCode ~= "    cmp eax, ebx\n";
                    asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                }
                else if (paramMap !is null && condition in paramMap)
                {
                    asmCode ~= "    cmp " ~ paramMap[condition] ~ ", 1\n";
                    asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                }
                foreach (ifChild; child.children)
                {
                    if (ifChild.nodeType == "Break")
                    {
                        asmCode ~= "    jmp " ~ endIfLabel ~ "\n";
                    }
                }

                asmCode ~= endIfLabel ~ ":\n";
                break;

            case "Loop":
                string loopStart = "loop_" ~ to!string(msgCounter) ~ "_start";
                string loopEnd = "loop_" ~ to!string(msgCounter) ~ "_end";
                msgCounter++;

                asmCode ~= loopStart ~ ":\n";

                foreach (loopChild; child.children)
                {
                    switch (loopChild.nodeType)
                    {
                    case "Break":
                        asmCode ~= "    jmp " ~ loopEnd ~ "\n";
                        break;
                    case "Println":
                        asmCode ~= `
                            section .data
                                msg_`
                            ~ msgCounter.to!string ~ ` db '` ~ (cast(PrintlnNode) loopChild)
                            .message ~ `', 0
                            section .text
                                mov rcx, msg_`
                            ~ msgCounter.to!string ~ `
                                call printf
                                mov rcx, nl
                                call printf
                        `;
                        msgCounter++;
                        break;
                    case "If":
                        auto condition = (cast(IfNode) loopChild).condition;
                        string endIfLabel = "loop_if_end_" ~ to!string(msgCounter);
                        msgCounter++;

                        if (condition.canFind("=="))
                        {
                            auto parts = condition.split("==");
                            string left = parts[0].strip();
                            string right = parts[1].strip();

                            asmCode ~= "    mov eax, " ~ operand(left) ~ "\n";
                            asmCode ~= "    mov ebx, " ~ (right[0].isDigit() ? right : operand(right, paramMap)) ~ "\n";
                            asmCode ~= "    cmp eax, ebx\n";
                            asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                        }
                        else
                        {
                            asmCode ~= "    mov eax, " ~ operand(condition, paramMap) ~ "\n";
                            asmCode ~= "    cmp eax, 1\n";
                            asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                        }
                        foreach (ifChild; loopChild.children)
                        {
                            if (ifChild.nodeType == "Break")
                            {
                                asmCode ~= "    jmp " ~ loopEnd ~ "\n";
                            }
                        }

                        asmCode ~= endIfLabel ~ ":\n";
                        break;

                    default:
                        enforce(false, "Unsupported node type in loop: " ~ loopChild.nodeType);
                    }
                }

                asmCode ~= "    jmp " ~ loopStart ~ "\n";
                asmCode ~= loopEnd ~ ":\n";
                break;
            default:
                enforce(false, "Invalid node type: " ~ child.nodeType);
            }
        }
        asmCode ~= "    mov rsp, rbp\n"
            ~ "    pop rbp\n"
            ~ "    ret\n";
        break;

    case "FunctionCall":
        auto callNode = cast(FunctionCallNode) ast;
        string callName = callNode.functionName;
        string args = callNode.functionName ~ "(" ~ callNode.args.join(", ") ~ ")";

        if (args.length > 0)
        {
            auto argList = args.split(",");
            foreach (i, a; argList)
            {
                string param = a.strip();
                string reg = i == 0 ? "rcx" : i == 1 ? "rdx" : i == 2 ? "r8" : i == 3 ? "r9" : "";

                if (i < 4)
                {
                    asmCode ~= "    mov " ~ reg ~ ", " ~ operand(param) ~ "\n";
                }
                else
                {
                    asmCode ~= "    mov rcx, " ~ operand(param) ~ "\n";
                    asmCode ~= "    push rcx\n";
                }
            }
        }

        asmCode ~= "    call " ~ callName ~ "\n";
        break;

    case "Loop":
        int loopId = 0;
        asmCode ~= "loop_" ~ loopId.to!string ~ "_start:\n";
        foreach (child; ast.children)
        {
            final switch (child.nodeType)
            {
            case "Println":
                asmCode ~= `
                    section .data
                        msg_`
                    ~ loopId.to!string ~ ` db '` ~ (cast(PrintlnNode) child).message ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ loopId.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                break;
            case "Break":
                asmCode ~= "    jmp loop_" ~ loopId.to!string ~ "_end\n";
                break;
            case "Assignment":
                auto parts = (cast(AssignmentNode) child).expression.split("=");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                if (!isParameter(dest))
                    declareVariable(dest);

                if (src.canFind(" - "))
                {
                    auto exprParts = src.split(" - ");
                    asmCode ~= "    mov eax, " ~ operand(exprParts[0]) ~ "\n"
                        ~ "    sub eax, " ~ operand(
                            exprParts[1]) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                else
                {
                    asmCode ~= "    mov eax, " ~ operand(src) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                break;
            }
        }
        asmCode ~= "    jmp loop_" ~ loopId.to!string ~ "_start\n";
        asmCode ~= "loop_" ~ loopId.to!string ~ "_end:\n";
        break;

    case "Break":
        asmCode ~= "    jmp end\n";
        break;

    case "Assignment":
        auto parts = (cast(AssignmentNode) ast).expression.split("=");
        string dest = parts[0].strip();
        string src = parts[1].strip();

        if (!isParameter(dest))
            declareVariable(dest);

        if (src.canFind(" - "))
        {
            auto exprParts = src.split(" - ");
            asmCode ~= "    mov eax, " ~ operand(exprParts[0]) ~ "\n"
                ~ "    sub eax, " ~ operand(
                    exprParts[1]) ~ "\n"
                ~ "    mov [" ~ dest ~ "], eax\n";
        }
        else
        {
            asmCode ~= "    mov eax, " ~ operand(src) ~ "\n"
                ~ "    mov [" ~ dest ~ "], eax\n";
        }
        break;
    }

    if (dataSection.length > 0)
        asmCode = "section .data\n" ~ dataSection ~ "\n" ~ asmCode;

    return asmCode;
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
        auto asma = generateAsm(ast);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int main(int argc, char** argv)"));
        assert(cCode.canFind("printf(\"hello\\n\")"));
    }

    {
        auto tokens = lex("def foo { println \"hello\"; } main { foo(); }");
        auto ast = parse(tokens);

        auto asma = generateAsm(ast);
        assert(asma.canFind("call foo"));

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
        import std.stdio;

        writeln(cCode);

        assert(cCode.canFind("(x>5)"));
        assert(cCode.canFind(`printf("greater\n");`));
    }

    {
        auto tokens = lex("main { val x = 5 + 3; val y = x - 2; }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        import std.stdio;

        writeln(cCode);
        assert(cCode.canFind("const int x = (5+3)"));
        assert(cCode.canFind("const int y = (x-2)"));
    }

    {
        auto tokens = lex("def foo { println \"in foo\"; } main { foo(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);
        assert(cCode.canFind("void foo()"));
        assert(cCode.canFind(`printf("in foo\n");`));
        assert(cCode.canFind("foo();"));
    }

    {
        auto tokens = lex(
            "def add(a: int, b: int): int { return a + b; } main { val x = add(1, 2); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int add(int a, int b)"));
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
            "def testfunc() { mut val x = 0; loop { println \"test\"; x = x + 1; if x == 5 { break; } } }"
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
            "def greet(name: char*, t: int) { println \"hello\"; } main { greet(\"world\", 1); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function call with string literal test:");
        writeln(cCode);

        assert(cCode.canFind("void greet(char* name, int t)"), "Should declare greet function");
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
        auto tokens = lex("model Cat { name: char*, age: int } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model definition test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat {"), "Should have struct definition");
        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int age;"), "Should have age field");
        assert(cCode.canFind("} Cat;"), "Should have Cat typedef");
    }

    {
        auto tokens = lex("model Cat { name: char*, health: int } " ~
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
            "model Cat { health: int } main { mut val cat = new Cat(health: 100); cat.health = 90; }");
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
            "model Cat { health: int } main { mut val cat = new Cat(health: 100); println cat.health; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Member access in println test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have struct initialization");
        assert(cCode.canFind("printf(\"%d\\n\", cat.health);"), "Should print member access");
    }

    {
        auto tokens = lex("model Person { name: char*, age: int, height: int } main"
                ~ " { val p = new Person(name: \"Alice\", age: 30, height: 170); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multi-field model test:");
        writeln(cCode);

        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int age;"), "Should have age field");
        assert(cCode.canFind("int height;"), "Should have height field");
        assert(cCode.canFind(".name = \"Alice\""), "Should initialize name");
        assert(cCode.canFind(".age = 30"), "Should initialize age");
        assert(cCode.canFind(".height = 170"), "Should initialize height");
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex(
                "model Cat { health: int } main { val cat = new Cat(health: 100); cat.health = 90; }");
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
            "model Point { x: int, y: int } model Line { start: Point*, end: Point* } main { }");
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
        auto tokens = lex("main { val x: int = 1; switch x { case 1 { println \"one\"; } " ~
                "case 2 { println \"two\"; } default { println \"other\"; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Switch/case statement test:");
        writeln(cCode);

        assert(cCode.canFind("const int x = 1;"), "Should declare x with type annotation");
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
        auto tokens = lex("main { val x: char* = \"hello\"; mut val y: int = 42; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Type annotation test:");
        writeln(cCode);

        assert(cCode.canFind("const char x[6];"), "Should convert char* with string literal to char[] with exact size");
        assert(cCode.canFind("strcpy(x, \"hello\");"), "Should use strcpy for string literal initialization");
        assert(cCode.canFind("int y = 42;"), "Should use int type annotation for mutable");
        assert(!cCode.canFind("const int y"), "Mutable variable should not be const");
    }

    {
        auto tokens = lex("main { val a: int = 5; val b: int = 10; val c: int = a + b; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multiple type annotations test:");
        writeln(cCode);

        assert(cCode.canFind("const int a = 5;"), "Should declare a with int type");
        assert(cCode.canFind("const int b = 10;"), "Should declare b with int type");
        assert(cCode.canFind("const int c = (a+b);"), "Should declare c with int type");
    }

    {
        auto tokens = lex("main { mut val x: int = 0; x++; x--; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment/decrement operators test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 0;"), "Should declare mutable x");
        assert(cCode.canFind("x++;"), "Should have increment operator");
        assert(cCode.canFind("x--;"), "Should have decrement operator");
    }

    {
        auto tokens = lex(
            "main { mut val counter: int = 0; loop { counter++; if counter == 5 { break; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment in loop test (if without parens):");
        writeln(cCode);

        assert(cCode.canFind("int counter = 0;"), "Should declare counter");
        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("counter++;"), "Should increment in loop");
        assert(cCode.canFind("if ((counter==5))"), "Should have condition");
    }

    {
        auto tokens = lex("main { mut val x: int = 10; if (x > 5) { println \"big\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If with parentheses test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 10;"), "Should declare x");
        assert(cCode.canFind("if ((x>5))"), "Should have if with condition");
        assert(cCode.canFind("printf(\"big\\n\");"), "Should have println");
    }

    {
        auto tokens = lex("main { mut val y: int = 3; if y < 10 { println \"small\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If without parentheses test:");
        writeln(cCode);

        assert(cCode.canFind("int y = 3;"), "Should declare y");
        assert(cCode.canFind("if ((y<10))"), "Should have if with condition");
        assert(cCode.canFind("printf(\"small\\n\");"), "Should have println");
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex("main { val x: int = 0; x++; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Cannot increment immutable variable"),
                "Should prevent increment of immutable variable");
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught immutable increment error");
        }
    }

    {
        auto tokens = lex(
            "main { val x: int = 5; if x > 10 { println \"big\"; } else { println \"small\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If-else test:");
        writeln(cCode);

        assert(cCode.canFind("if ((x>10))"), "Should have if condition");
        assert(cCode.canFind("printf(\"big\\n\");"), "Should have println in if");
        assert(cCode.canFind("} else {"), "Should have else block");
        assert(cCode.canFind("printf(\"small\\n\");"), "Should have println in else");
    }

    {
        auto tokens = lex("main { val score: int = 75; if score >= 90 { println \"A\"; } " ~
                "elif score >= 80 { println \"B\"; } elif score >= 70 { println \"C\"; } else { println \"F\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If-elif-else test (without parens):");
        writeln(cCode);

        assert(cCode.canFind("if ((score>=90))"), "Should have if condition");
        assert(cCode.canFind("printf(\"A\\n\");"), "Should have println A");
        assert(cCode.canFind("} else if ((score>=80)) {"), "Should have first elif");
        assert(cCode.canFind("printf(\"B\\n\");"), "Should have println B");
        assert(cCode.canFind("} else if ((score>=70)) {"), "Should have second elif");
        assert(cCode.canFind("printf(\"C\\n\");"), "Should have println C");
        assert(cCode.canFind("} else {"), "Should have else");
        assert(cCode.canFind("printf(\"F\\n\");"), "Should have println F");
    }

    {
        auto tokens = lex(
            "main { val n: int = 15; if (n < 10) { println \"less\"; } elif (n == 15) { println \"equal\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If-elif test (with parens):");
        writeln(cCode);

        assert(cCode.canFind("if ((n<10))"), "Should have if condition");
        assert(cCode.canFind("printf(\"less\\n\");"), "Should have println in if");
        assert(cCode.canFind("} else if ((n==15)) {"), "Should have elif with parens");
        assert(cCode.canFind("printf(\"equal\\n\");"), "Should have println in elif");
        assert(!cCode.canFind("} else {"), "Should not have else block");
    }

    {
        auto tokens = lex(
            "main { val temp: int = 20; if temp < 0 { println \"freezing\"; } else { println \"ok\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Simple if-else test:");
        writeln(cCode);

        assert(cCode.canFind("if ((temp<0))"), "Should have if condition");
        assert(cCode.canFind("printf(\"freezing\\n\");"), "Should have println in if");
        assert(cCode.canFind("} else {"), "Should have else");
        assert(cCode.canFind("printf(\"ok\\n\");"), "Should have println in else");
    }

    {
        auto tokens = lex(
            "main { val age: int = 25; if (age >= 18) { println \"adult\"; } else { println \"minor\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("If-else with parens test:");
        writeln(cCode);

        assert(cCode.canFind("if ((age>=18))"), "Should have if with parens");
        assert(cCode.canFind("printf(\"adult\\n\");"), "Should have println in if");
        assert(cCode.canFind("} else {"), "Should have else");
        assert(cCode.canFind("printf(\"minor\\n\");"), "Should have println in else");
    }

    {
        auto tokens = lex("main { for mut val i = 0; i < 10; i++ { println \"loop\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Basic for loop test:");
        writeln(cCode);

        assert(cCode.canFind("for (int i = 0; (i<10); i++)"), "Should have for loop header");
        assert(cCode.canFind("printf(\"loop\\n\");"), "Should have println in for loop");
    }

    {
        auto tokens = lex("main { for mut val j: int = 5; j < 20; j++ { println \"counting\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with type annotation test:");
        writeln(cCode);

        assert(cCode.canFind("for (int j = 5; (j<20); j++)"), "Should have for loop with type");
        assert(cCode.canFind("printf(\"counting\\n\");"), "Should have println");
    }

    {
        auto tokens = lex("main { for mut val k = 10; k > 0; k-- { println \"countdown\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with decrement test:");
        writeln(cCode);

        assert(cCode.canFind("for (int k = 10; (k>0); k--)"), "Should have for loop with decrement");
        assert(cCode.canFind("printf(\"countdown\\n\");"), "Should have println");
    }

    {
        auto tokens = lex("main { for mut val n = 0; n < 5; n++ { if n == 3 { break; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with break test:");
        writeln(cCode);

        assert(cCode.canFind("for (int n = 0; (n<5); n++)"), "Should have for loop");
        assert(cCode.canFind("if ((n==3))"), "Should have if condition");
        assert(cCode.canFind("break;"), "Should have break statement");
    }

    {
        auto tokens = lex("main { for mut val x = 1; x <= 100; x++ { x++; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with body increment test:");
        writeln(cCode);

        assert(cCode.canFind("for (int x = 1; (x<=100); x++)"), "Should have for loop");
        assert(cCode.canFind("x++;"), "Should have increment in body");
    }

    {
        auto tokens = lex(
            "main { for mut val i = 0; i < 10; i++ { if i == 5 { continue; } println \"ok\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with continue test:");
        writeln(cCode);

        assert(cCode.canFind("for (int i = 0; (i<10); i++)"), "Should have for loop");
        assert(cCode.canFind("if ((i==5))"), "Should have if condition");
        assert(cCode.canFind("continue;"), "Should have continue statement");
        assert(cCode.canFind("printf(\"ok\\n\");"), "Should have println after continue");
    }

    {
        auto tokens = lex(
            "main { loop { mut val x: int = 0; x++; if x > 5 { continue; } break; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Loop with continue test:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Should have while loop");
        assert(cCode.canFind("continue;"), "Should have continue");
        assert(cCode.canFind("break;"), "Should have break");
    }

    {
        auto tokens = lex("def testfunc { return; } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Headless return test:");
        writeln(cCode);

        assert(cCode.canFind("void testfunc()"), "Should have function");
        assert(cCode.canFind("return;"), "Should have headless return");
        assert(!cCode.canFind("return ;"), "Should not have space before semicolon");
    }

    {
        auto tokens = lex("def getValue: int { return 42; } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Return with value test:");
        writeln(cCode);

        assert(cCode.canFind("int getValue()"), "Should have function with return type");
        assert(cCode.canFind("return 42;"), "Should have return with value");
    }

    {
        auto tokens = lex(
            "main { for mut val i = 0; i < 20; i++ { if i < 5 { continue; } if i > 15 { break; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For loop with both continue and break test:");
        writeln(cCode);

        assert(cCode.canFind("for (int i = 0; (i<20); i++)"), "Should have for loop");
        assert(cCode.canFind("if ((i<5))"), "Should have first if");
        assert(cCode.canFind("continue;"), "Should have continue");
        assert(cCode.canFind("if ((i>15))"), "Should have second if");
        assert(cCode.canFind("break;"), "Should have break");
    }

    {
        auto tokens = lex("main { val arr: int[5]; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Array declaration with size test:");
        writeln(cCode);

        assert(cCode.canFind("const int arr[5];"), "Should have array declaration with size");
    }

    {
        auto tokens = lex("main { mut val nums: int[] = [1, 2, 3, 4, 5]; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Array declaration with literal test:");
        writeln(cCode);

        assert(cCode.canFind("int nums[5] = { 1, 2, 3, 4, 5 };"), "Should have array with initializer");
    }

    {
        auto tokens = lex("main { mut val data: int[10]; data[0] = 42; data[5] = 99; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Array assignment test:");
        writeln(cCode);

        assert(cCode.canFind("int data[10];"), "Should have array declaration");
        assert(cCode.canFind("data[0] = 42;"), "Should have first array assignment");
        assert(cCode.canFind("data[5] = 99;"), "Should have second array assignment");
    }

    {
        auto tokens = lex("main { val values: int[] = [10, 20, 30]; mut val x: int = 0; x = 5; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Mixed array and variable test:");
        writeln(cCode);

        assert(cCode.canFind("const int values[3] = { 10, 20, 30 };"), "Should have const array");
        assert(cCode.canFind("int x = 0;"), "Should have variable");
        assert(cCode.canFind("x = 5;"), "Should have assignment");
    }

    {
        auto tokens = lex(
            "main { mut val arr: int[3] = [1, 2, 3]; for mut val i = 0; i < 3; i++ { arr[i] = 0; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Array in for loop test:");
        writeln(cCode);

        assert(cCode.canFind("int arr[3] = { 1, 2, 3 };"), "Should have array with initializer");
        assert(cCode.canFind("for (int i = 0; (i<3); i++)"), "Should have for loop");
        assert(cCode.canFind("arr[i] = 0;"), "Should have array assignment in loop");
    }

    {
        auto tokens = lex(
            "main { mut val nums: int[] = [10, 20, 30]; for n in nums { println n; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For-in loop test:");
        writeln(cCode);

        assert(cCode.canFind("int nums[3] = { 10, 20, 30 };"), "Should have array declaration");
        assert(cCode.canFind("for (size_t _i_n = 0; _i_n < sizeof(nums)/sizeof(nums[0]); _i_n++)"),
            "Should have for-in loop converted to C for loop");
        assert(cCode.canFind("int n = nums[_i_n];"), "Should declare loop variable from array");
        assert(cCode.canFind("printf(\"%d\\n\", n);"), "Should have println with variable");
    }

    {
        auto tokens = lex("main { val data: int[] = [1, 2, 3, 4, 5]; println data.len; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Array .len property test:");
        writeln(cCode);

        assert(cCode.canFind("const int data[5] = { 1, 2, 3, 4, 5 };"), "Should have array declaration");
        assert(cCode.canFind("printf(\"%d\\n\", (sizeof(data)/sizeof(data[0])));"),
            "Should convert .len to sizeof expression");
    }

    {
        auto tokens = lex("use external(\"raylib.h\"); main { println \"test\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("External import test:");
        writeln(cCode);

        assert(cCode.canFind("#include <raylib.h>"), "Should have external include directive");
        assert(cCode.canFind("#include <stdio.h>"), "Should have standard includes");
        assert(cCode.canFind("int main(int argc, char** argv)"), "Should have main function");
    }

    {
        auto tokens = lex("main { val x: int = 10; val y: ref int = ref_of(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Reference type test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 10;"), "Should have x declaration");
        assert(cCode.canFind("int* y = &x;"), "Should have y as pointer with address-of");
    }

    {
        auto tokens = lex("main { val x: int = 10; val addr: long = addr_of(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("addr_of test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 10;"), "Should have x declaration");
        assert(cCode.canFind("long addr = (long)&x;"), "Should convert address to long");
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
        assert(!cCode.canFind(" and "), "Should not have 'and' keyword in output");
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
        assert(!cCode.canFind("and"), "Should not have 'and' keyword in output");
        assert(cCode.canFind("1%3==0") || cCode.canFind("(1 % 3 == 0)") ||
                cCode.canFind("(1%3)==0"), "Should have proper first comparison");
        assert(cCode.canFind("2%5==0") || cCode.canFind("(2 % 5 == 0)") ||
                cCode.canFind("(2%5)==0"), "Should have proper second comparison");
    }

    {
        auto tokens = lex(
            "def get_value(x: int): int { return x; } def wrapper(y: int): int { return get_value(y); } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("int get_value(int x)"), "Should have get_value function");
        assert(cCode.canFind("int wrapper(int y)"), "Should have wrapper function");
        assert(cCode.canFind("return get_value(y)"), "Should have nested function call");
    }

    {
        auto tokens = lex(
            "def destroy(ptr: long) { } main { val x: int = 5; destroy(thing_of(x)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call in main test:");
        writeln(cCode);

        assert(cCode.canFind("void destroy(long ptr)"), "Should have destroy function");
        assert(cCode.canFind("destroy(thing_of(x))"), "Should have nested function call with ref_of(x)");
    }

    {
        auto tokens = lex("def inner(a: int): int { return a; } def middle(b: int): int { return inner(b); } def outer(c: int): int { return middle(inner(c)); } main { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deeply nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("return middle(inner(c))"), "Should handle deeply nested calls: middle(inner(c))");
    }

    // Macro system tests
    {
        auto tokens = lex(
            "macro add(a: int, b: int) { raw { a + b } } main { val x: int = add(5, 3); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Basic macro test:");
        writeln(cCode);

        assert(cCode.canFind("const int x = (5+3);") || cCode.canFind("const int x = ( 5 + 3 );"),
            "Should expand macro add(5, 3) to (5+3)");
        assert(!cCode.canFind("add(5, 3)"), "Should not have macro call in output");
    }

    {
        auto tokens = lex(
            "macro square(x: int) { raw { x * x } } main { val result: int = square(4); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with repeated parameter test:");
        writeln(cCode);

        assert(cCode.canFind("const int result = ( 4 * 4 );") || cCode.canFind(
                "const int result = (4 * 4);"),
            "Should expand square(4) to (4*4)");
    }

    {
        auto tokens = lex(
            "macro max(a: int, b: int) { raw { (a > b) ? a : b } } main { val m: int = max(10, 20); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with ternary operator test:");
        writeln(cCode);

        assert(cCode.canFind("(10>20)?10:20") || cCode.canFind("(10 > 20) ? 10 : 20"),
            "Should expand max(10, 20) to ternary expression");
    }

    {
        auto tokens = lex(
            "macro add(a: int, b: int) { raw { a + b } } def calc(x: int, y: int): int { return add(x, y); } main { }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in function body test:");
        writeln(cCode);

        assert(cCode.canFind("return ( x + y );") || cCode.canFind("return (x + y);"),
            "Should expand macro in function return statement");
    }

    {
        auto tokens = lex(
            "macro inc(x: int) { raw { x + 1 } } main { val a: int = 5; val b: int = inc(a); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with variable argument test:");
        writeln(cCode);

        assert(cCode.canFind("const int b = ( a + 1 );") || cCode.canFind("const int b = (a + 1);"),
            "Should expand inc(a) with variable argument");
    }

    {
        auto tokens = lex(
            "macro triple(x: int) { raw { x * 3 } } main { if triple(2) == 6 { println \"yes\"; } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in condition test:");
        writeln(cCode);

        assert(cCode.canFind("if") && (cCode.canFind("( 2 * 3 )==6") || cCode.canFind(
                "(2 * 3) == 6")),
            "Should expand macro in if condition");
    }

    {
        auto tokens = lex("main { mut val ptr: int* = NULL; val value: int = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref test:");
        writeln(cCode);

        assert(cCode.canFind("*ptr"), "Should replace deref(ptr) with *ptr");
        assert(cCode.canFind("int* ptr = NULL;"), "Should declare pointer variable");
        assert(cCode.canFind("const int value = (*ptr);"), "Should assign dereferenced value");
    }

    {
        auto tokens = lex("main { mut val ptr: int** = NULL; val value: int = deref(deref(ptr)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested deref test:");
        writeln(cCode);

        assert(cCode.canFind("*(*ptr)"), "Should handle nested deref(deref(ptr)) as **ptr");
        assert(cCode.canFind("int** ptr = NULL;"), "Should declare double pointer");
        assert(cCode.canFind("const int value = (*(*ptr));"), "Should assign double dereferenced value");
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
        auto tokens = lex("main { mut val ptr: int* = NULL; deref(ptr) = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref assignment test:");
        writeln(cCode);

        assert(cCode.canFind("(*ptr) = 10;"), "Should handle deref on left side of assignment");
    }
}
