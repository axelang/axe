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
        cCode = "#include <stdio.h>\n#include <stdbool.h>\n#include <stdlib.h>\n#include <string.h>\n\n";

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
                cCode ~= generateC(child) ~ "\n";
        }

        foreach (child; ast.children)
        {
            if (child.nodeType != "Model")
                cCode ~= generateC(child) ~ "\n";
        }
        break;

    case "Main":
        cCode ~= "int main() {\n";
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
            cCode ~= "int main() {\n";
        }
        else
        {
            cCode ~= funcNode.returnType ~ " " ~ funcName ~ "(";
            if (params.length > 0)
            {
                cCode ~= params.join(", ");
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
        string[] processedArgs;

        foreach (arg; callNode.args)
            processedArgs ~= processExpression(arg);

        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        cCode ~= indent ~ callName ~ "(" ~ processedArgs.join(", ") ~ ");\n";
        break;

    case "Assignment":
        auto assignNode = cast(AssignmentNode) ast;
        string dest = assignNode.variable.strip();
        string expr = assignNode.expression.strip();

        if (dest !in variables && !functionParams.canFind(dest) && currentFunction != "")
        {
            variables[dest] = "int";
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
            string processedExpr = processExpression(expr);
            cCode ~= dest ~ " = " ~ processedExpr ~ ";\n";
        }
        break;

    case "Declaration":
        auto declNode = cast(DeclarationNode) ast;
        
        // Use explicit type annotation if provided, otherwise default to int
        string baseType = declNode.typeName.length > 0 ? declNode.typeName : "int";
        string type = declNode.isMutable ? baseType : "const " ~ baseType;
        string decl = type ~ " " ~ declNode.name;

        if (declNode.initializer.length > 0)
        {
            string processedExpr = processExpression(declNode.initializer);
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

    case "If":
        auto ifNode = cast(IfNode) ast;
        cCode ~= "if (" ~ processCondition(ifNode.condition) ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
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

    case "Break":
        cCode ~= "break;\n";
        break;

    case "RawC":
        auto rawNode = cast(RawCNode) ast;
        cCode ~= rawNode.code ~ "\n";
        break;

    case "Return":
        auto returnNode = cast(ReturnNode) ast;
        string processedExpr = processExpression(returnNode.expression);
        cCode ~= "return " ~ processedExpr ~ ";\n";
        break;

    case "Model":
        auto modelNode = cast(ModelNode) ast;
        cCode ~= "typedef struct {\n";
        foreach (fieldName, fieldType; modelNode.fields)
        {
            cCode ~= "    " ~ fieldType ~ " " ~ fieldName ~ ";\n";
        }
        cCode ~= "} " ~ modelNode.name ~ ";\n";
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

        if (memberNode.value.length > 0)
        {
            // Member write
            cCode ~= indent ~ memberNode.objectName ~ "." ~ memberNode.memberName ~ " = " ~ memberNode.value ~ ";\n";
        }
        else
        {
            // Member read (used in expressions)
            cCode ~= memberNode.objectName ~ "." ~ memberNode.memberName;
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

    // Don't process if it's already parenthesized
    if (expr.canFind("(") && expr.endsWith(")"))
    {
        return expr;
    }

    // Check for operators, but be careful not to split on dots (member access)
    foreach (op; ["+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">="])
    {
        if (expr.canFind(op) && op != "")
        {
            auto parts = expr.split(op);
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

    // Return as-is (preserves member access like "cat.health")
    return expr;
}

private string processCondition(string condition)
{
    foreach (op; ["==", "!=", ">", "<", ">=", "<="])
    {
        if (condition.canFind(op))
        {
            auto parts = condition.split(op);
            if (parts.length == 2)
            {
                string result = "(" ~ processExpression(
                    parts[0]) ~ op ~ processExpression(parts[1]) ~ ")";
                return result;
            }
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

/**
 * Compiles and runs the generated assembly code
 * Returns NASM errors if any
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
        assert(asma.canFind("section .data"));
        assert(asma.canFind("msg_0 db 'hello', 0"));
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int main()"));
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
        assert(cCode.canFind("const int x = add(1,2);"));
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
        auto tokens = lex("main { val x = 5; x = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable reassignment test:");
        writeln(cCode);

        assert(cCode.canFind("const int x = 5;"), "Should declare x");
        assert(cCode.canFind("x = 10;"), "Should reassign x");
    }

    {
        auto tokens = lex(
            "def test() { val x = 0; loop { println \"test\"; x = x + 1; if x == 5 { break; } } }");
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

        assert(cCode.canFind("printf (\"raw C\");"), "Should have raw C code");
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

        assert(cCode.canFind("typedef struct {"), "Should have struct definition");
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

        assert(cCode.canFind("typedef struct {"), "Should have struct definition");
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

        assert(cCode.canFind("const char* x = \"hello\";"), "Should use char* type annotation");
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
        auto tokens = lex("main { mut val counter: int = 0; loop { counter++; if counter == 5 { break; } } }");
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
}
