/** 
 * Axe Programming Language Compiler.
 * Author: Navid Momtahen (C) 2025
 * License: GPL-3.0
 * 
 * Handles the assembly rendering process.
 */

module axe.renderer_asm;

import axe.structs;
import std.conv;
import std.string;
import std.algorithm;
import std.ascii;
import std.exception;

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
                {
                    auto printlnNode = cast(PrintlnNode) child;
                    string combinedMsg = "";
                    foreach (i, msg; printlnNode.messages)
                    {
                        if (!printlnNode.isExpressions[i])
                        {
                            combinedMsg ~= msg;
                        }
                    }
                    asmCode ~= `
                    section .data
                        msg_`
                    ~ msgCounter.to!string ~ ` db '` ~ combinedMsg ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                    msgCounter++;
                }
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
                        {
                            auto printlnNode = cast(PrintlnNode) loopChild;
                            string combinedMsg = "";
                            foreach (i, msg; printlnNode.messages)
                            {
                                if (!printlnNode.isExpressions[i])
                                {
                                    combinedMsg ~= msg;
                                }
                            }
                            asmCode ~= `
                            section .data
                                msg_`
                            ~ msgCounter.to!string ~ ` db '` ~ combinedMsg ~ `', 0
                            section .text
                                mov rcx, msg_`
                            ~ msgCounter.to!string ~ `
                                call printf
                                mov rcx, nl
                                call printf
                        `;
                            msgCounter++;
                        }
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
                {
                    auto printlnNode = cast(PrintlnNode) child;
                    string combinedMsg = "";
                    foreach (i, msg; printlnNode.messages)
                    {
                        if (!printlnNode.isExpressions[i])
                        {
                            combinedMsg ~= msg;
                        }
                    }
                    asmCode ~= `
                    section .data
                        msg_`
                    ~ msgCounter.to!string ~ ` db '` ~ combinedMsg ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                    msgCounter++;
                }
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
                        {
                            auto printlnNode = cast(PrintlnNode) loopChild;
                            string combinedMsg = "";
                            foreach (i, msg; printlnNode.messages)
                            {
                                if (!printlnNode.isExpressions[i])
                                {
                                    combinedMsg ~= msg;
                                }
                            }
                            asmCode ~= `
                            section .data
                                msg_`
                            ~ msgCounter.to!string ~ ` db '` ~ combinedMsg ~ `', 0
                            section .text
                                mov rcx, msg_`
                            ~ msgCounter.to!string ~ `
                                call printf
                                mov rcx, nl
                                call printf
                        `;
                            msgCounter++;
                        }
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
                {
                    auto printlnNode = cast(PrintlnNode) child;
                    string combinedMsg = "";
                    foreach (i, msg; printlnNode.messages)
                    {
                        if (!printlnNode.isExpressions[i])
                        {
                            combinedMsg ~= msg;
                        }
                    }
                    asmCode ~= `
                    section .data
                        msg_`
                    ~ loopId.to!string ~ ` db '` ~ combinedMsg ~ `', 0
                    section .text
                        mov rcx, msg_`
                    ~ loopId.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                }
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
    import axe.lexer;
    import axe.parser;

    auto tokens = lex("def main() { println \"hello\"; }");
    auto ast = parse(tokens);

    generateAsm(ast);
}
