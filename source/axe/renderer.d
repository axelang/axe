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
    string[] includes = ["#include <stdio.h>"];

    switch (ast.nodeType)
    {
    case "Program":
        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcDecl = child.value.split("(");
                string funcName = funcDecl[0];
                string args = funcDecl.length > 1 ?
                    funcDecl[1].strip(")") : "";
                cCode ~= "void " ~ funcName ~ "(" ~
                    (args.length > 0 ? "int " ~ args.replace(",", ", int ") : "void") ~ ");\n";
            }
        }
        cCode ~= includes.join("\n") ~ "\n\n";
        foreach (child; ast.children)
        {
            cCode ~= generateC(child) ~ "\n";
        }
        break;

    case "Main":
        cCode ~= "int main() {\n";
        foreach (child; ast.children)
        {
            if (child.nodeType == "Println")
            {
                cCode ~= "    printf(\"%s\\n\", \"" ~ child.value ~ "\");\n";
            }
            else if (child.nodeType == "Loop")
            {
                cCode ~= "    while (1) {\n";
                foreach (loopChild; child.children)
                {
                    if (loopChild.nodeType == "Println")
                    {
                        cCode ~= "        printf(\"%s\\n\", \"" ~ loopChild.value ~ "\");\n";
                    }
                    else if (loopChild.nodeType == "Break")
                    {
                        cCode ~= "        break;\n";
                    }
                    else if (loopChild.nodeType == "Assignment")
                    {
                        cCode ~= "        " ~ loopChild.value ~ ";\n";
                    }
                    else if (loopChild.nodeType == "If")
                    {
                        cCode ~= "        if (" ~ loopChild.value ~ ") {\n";
                        foreach (ifChild; loopChild.children)
                        {
                            if (ifChild.nodeType == "Break")
                            {
                                cCode ~= "            break;\n";
                            }
                            else if (ifChild.nodeType == "FunctionCall")
                            {
                                auto parts = ifChild.value.split("(");
                                string funcName = parts[0];
                                string args = parts.length > 1 ? parts[1].strip(")") : "";
                                cCode ~= "            " ~ funcName ~ "(" ~ args ~ ");\n";
                            }
                            else if (ifChild.nodeType == "Assignment")
                            {
                                cCode ~= "            " ~ ifChild.value ~ ";\n";
                            }
                        }
                        cCode ~= "        }\n";
                    }
                    else if (loopChild.nodeType == "FunctionCall")
                    {
                        auto parts = loopChild.value.split("(");
                        string funcName = parts[0];
                        string args = parts.length > 1 ? parts[1].strip(")") : "";
                        cCode ~= "        " ~ funcName ~ "(" ~ args ~ ");\n";
                    }
                }
                cCode ~= "    }\n";
            }
            else if (child.nodeType == "Break")
            {
                cCode ~= "    break;\n";
            }
            else if (child.nodeType == "FunctionCall")
            {
                auto parts = child.value.split("(");
                string funcName = parts[0];
                string args = parts.length > 1 ? parts[1].strip(")") : "";
                cCode ~= "    " ~ funcName ~ "(" ~ args ~ ");\n";
            }
            else if (child.nodeType == "Assignment")
            {
                cCode ~= "    " ~ child.value ~ ";\n";
            }
            else if (child.nodeType == "If")
            {
                cCode ~= "    if (" ~ child.value ~ ") {\n";
                foreach (ifChild; child.children)
                {
                    if (ifChild.nodeType == "Break")
                    {
                        cCode ~= "        break;\n";
                    }
                    else if (ifChild.nodeType == "FunctionCall")
                    {
                        auto parts = ifChild.value.split("(");
                        string funcName = parts[0];
                        string args = parts.length > 1 ? parts[1].strip(")") : "";
                        cCode ~= "        " ~ funcName ~ "(" ~ args ~ ");\n";
                    }
                    else if (ifChild.nodeType == "Assignment")
                    {
                        cCode ~= "        " ~ ifChild.value ~ ";\n";
                    }
                }
                cCode ~= "    }\n";
            }
        }
        cCode ~= "    return 0;\n}";
        break;

    case "Function":
        auto funcDecl = ast.value.split("(");
        string funcName = funcDecl[0];
        string args = funcDecl.length > 1 ?
            funcDecl[1].strip(")") : "";
        cCode ~= "void " ~ funcName ~ "(" ~
            (args.length > 0 ? "int " ~ args.replace(",", ", int ") : "void") ~ ") {\n";
        foreach (child; ast.children)
        {
            final switch (child.nodeType)
            {
            case "Println":
                cCode ~= "    printf(\"%s\\n\", \"" ~ child.value ~ "\");\n";
                cCode ~= "printf(\"%s\\n\", \"" ~ child.value ~ "\");\n";
                break;
            case "FunctionCall":
                auto parts = child.value.split("(");
                auto calledFuncName = parts[0];
                auto calledFuncArgs = parts.length > 1 ? parts[1].strip(")") : "";
                cCode ~= "    " ~ calledFuncName ~ "(" ~ calledFuncArgs ~ ");\n";
                break;
            case "Assignment":
                cCode ~= child.value ~ ";\n";
                break;
            case "If":
                cCode ~= "if (" ~ child.value ~ ") {\n";
                foreach (ifChild; child.children)
                {
                    final switch (ifChild.nodeType)
                    {
                    case "Break":
                        cCode ~= "break;\n";
                        break;
                    }
                }
                cCode ~= "}\n";
                break;
            }
        }
        cCode ~= "}";
        break;

    case "FunctionCall":
        auto parts = ast.value.split("(");
        string funcName = parts[0];
        string args = parts.length > 1 ? parts[1].strip(")") : "";
        cCode ~= funcName ~ "(" ~ args ~ ");\n";
        break;

    case "Assignment":
        cCode ~= ast.value ~ ";\n";
        break;

    case "If":
        cCode ~= "if (" ~ ast.value ~ ") {\n";
        foreach (child; ast.children)
        {
            final switch (child.nodeType)
            {
            case "Break":
                cCode ~= "break;\n";
                break;
            }
        }
        cCode ~= "}\n";
        break;

    default:
        enforce(false, "Unsupported node type for C generation: " ~ ast.nodeType);
    }

    return cCode;
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
                    ~ msgCounter.to!string ~ ` db '` ~ child.value ~ `', 0
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
                auto callDecl = child.value.split("(");
                string callName = callDecl[0];
                string callArgs = callDecl.length > 1 ? callDecl[1].strip(")") : "";

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
                            ~ msgCounter.to!string ~ ` db '` ~ loopChild.value ~ `', 0
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
                        auto parts = loopChild.value.split(" = ");
                        string dest = parts[0].strip();
                        string src = parts[1].strip();

                        // Declare the variable if it's not a parameter
                        if (!isParameter(dest))
                        {
                            declareVariable(dest);
                        }

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
                auto parts = child.value.split(" = ");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                // Declare the variable if it's not a parameter
                if (!isParameter(dest))
                {
                    declareVariable(dest);
                }

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
        auto funcDecl = ast.value.split("(");
        string funcName = funcDecl[0].strip();
        string args = funcDecl.length > 1 ? funcDecl[1].strip(")").strip() : "";

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
                    ~ msgCounter.to!string ~ ` db '` ~ child.value ~ `', 0
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
                auto callDecl = child.value.split("(");
                string callName = callDecl[0];
                string callArgs = callDecl.length > 1 ? callDecl[1].strip(")") : "";

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
                            asmCode ~= "    mov " ~ reg ~ ", " ~ operand(param, paramMap) ~ "\n";
                        }
                        else
                        {
                            asmCode ~= "    mov rcx, " ~ operand(param, paramMap) ~ "\n";
                            asmCode ~= "    push rcx\n";
                        }
                    }
                }

                asmCode ~= "    call " ~ callName ~ "\n";
                break;
            case "Assignment":
                auto parts = child.value.split(" = ");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                // Declare the variable if it's not a parameter
                if (!isParameter(dest))
                {
                    declareVariable(dest);
                }

                if (src.canFind(" - "))
                {
                    auto exprParts = src.split(" - ");
                    asmCode ~= "    mov eax, " ~ operand(exprParts[0], paramMap) ~ "\n"
                        ~ "    sub eax, " ~ operand(
                            exprParts[1], paramMap) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                else
                {
                    asmCode ~= "    mov eax, " ~ operand(src, paramMap) ~ "\n"
                        ~ "    mov [" ~ dest ~ "], eax\n";
                }
                break;

            case "If":
                auto condition = child.value;
                string endIfLabel = "endif_" ~ to!string(child.children.length);

                if (condition.canFind("=="))
                {
                    auto parts = condition.split("==");
                    string left = parts[0].strip();
                    string right = parts[1].strip();

                    asmCode ~= "    mov eax, " ~ operand(left, paramMap) ~ "\n";
                    asmCode ~= "    mov ebx, " ~ operand(right, paramMap) ~ "\n";
                    asmCode ~= "    cmp eax, ebx\n";
                    asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                }
                else if (condition.canFind("!="))
                {
                    auto parts = condition.split("!=");
                    string left = parts[0].strip();
                    string right = parts[1].strip();

                    asmCode ~= "    mov eax, " ~ operand(left, paramMap) ~ "\n";
                    asmCode ~= "    mov ebx, " ~ operand(right, paramMap) ~ "\n";
                    asmCode ~= "    cmp eax, ebx\n";
                    asmCode ~= "    je " ~ endIfLabel ~ "\n";
                }
                else
                {
                    // Handle simple variable checks (like just "times")
                    asmCode ~= "    mov eax, " ~ operand(condition, paramMap) ~ "\n";
                    asmCode ~= "    test eax, eax\n";
                    asmCode ~= "    jz " ~ endIfLabel ~ "\n";
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
                            ~ msgCounter.to!string ~ ` db '` ~ loopChild.value ~ `', 0
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
                        auto condition = loopChild.value;
                        string endIfLabel = "loop_if_end_" ~ to!string(msgCounter);
                        msgCounter++;

                        if (condition.canFind("=="))
                        {
                            auto parts = condition.split("==");
                            string left = parts[0].strip();
                            string right = parts[1].strip();

                            asmCode ~= "    mov eax, " ~ operand(left, paramMap) ~ "\n";
                            asmCode ~= "    mov ebx, " ~ operand(right, paramMap) ~ "\n";
                            asmCode ~= "    cmp eax, ebx\n";
                            asmCode ~= "    jne " ~ endIfLabel ~ "\n";
                        }
                        else if (condition.canFind("!="))
                        {
                            auto parts = condition.split("!=");
                            string left = parts[0].strip();
                            string right = parts[1].strip();

                            asmCode ~= "    mov eax, " ~ operand(left, paramMap) ~ "\n";
                            asmCode ~= "    mov ebx, " ~ operand(right, paramMap) ~ "\n";
                            asmCode ~= "    cmp eax, ebx\n";
                            asmCode ~= "    je " ~ endIfLabel ~ "\n";
                        }
                        else
                        {
                            // Handle simple variable checks (like just "times")
                            asmCode ~= "    mov eax, " ~ operand(condition, paramMap) ~ "\n";
                            asmCode ~= "    test eax, eax\n";
                            asmCode ~= "    jz " ~ endIfLabel ~ "\n";
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
        auto funcDecl = ast.value.split("(");
        string funcName = funcDecl[0];
        string args = funcDecl.length > 1 ? funcDecl[1].strip(")") : "";

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

        asmCode ~= "    call " ~ funcName ~ "\n";
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
                    ~ loopId.to!string ~ ` db '` ~ child.value ~ `', 0
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
                auto parts = child.value.split(" = ");
                string dest = parts[0].strip();
                string src = parts[1].strip();

                // Declare the variable if it's not a parameter
                if (!isParameter(dest))
                {
                    declareVariable(dest);
                }

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
        auto parts = ast.value.split(" = ");
        string dest = parts[0].strip();
        string src = parts[1].strip();

        // Declare the variable if it's not a parameter
        if (!isParameter(dest))
        {
            declareVariable(dest);
        }

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

    // Add .data section if we have variables
    if (dataSection.length > 0)
    {
        asmCode = "section .data\n" ~ dataSection ~ "\n" ~ asmCode;
    }

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

    auto linkResult = execute(["gcc", "-o", exeFile, objFile]);

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

    {
        auto tokens = lex("main { println \"hello\"; }");
        auto ast = parse(tokens);
        auto asma = generateAsm(ast);
        assert(asma.canFind("section .data"));
        assert(asma.canFind("msg_0 db 'hello', 0"));
        assert(asma.canFind("call printf"));
    }

    {
        auto tokens = lex("main { foo(); }");
        auto ast = parse(tokens);
        auto asma = generateAsm(ast);
        assert(asma.canFind("call foo"));
    }

    {
        auto tokens = lex("main { foo(1, 2); }");
        auto ast = parse(tokens);
        auto asma = generateAsm(ast);
        assert(asma.canFind("mov rcx, 1"));
        assert(asma.canFind("mov rdx, 2"));
        assert(asma.canFind("call foo"));
    }

    {
        auto tokens = lex("main { loop { break; } }");
        auto ast = parse(tokens);
        auto asma = generateAsm(ast);
        assert(asma.canFind("loop_0_start:"));
        assert(asma.canFind("jmp loop_0_end"));
        assert(asma.canFind("loop_0_end:"));
    }
}
