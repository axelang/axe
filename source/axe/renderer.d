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
    string[] includes = ["#include <stdio.h>", "#include <stdbool.h>"];
    string[string] variables;
    string currentFunction = "";
    string[] functionParams;
    int loopLevel = 0;

    switch (ast.nodeType)
    {
    case "Program":
        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                string funcName = funcNode.name;
                string args = funcNode.params.join(", ");

                cCode ~= "void " ~ funcName ~ "(" ~
                    (args.length > 0 ? "int " ~ args.replace(",", ", int ") : "void") ~
                    ");\n";
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
            cCode ~= "void " ~ funcName ~ "(" ~
                (params.length > 0 ? "int " ~ params.join(", int ") : "void") ~
                ") {\n";
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
        auto parts = (cast(AssignmentNode) ast).expression.split("=");
        string dest = parts[0].strip();
        string expr = parts[1].strip();

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
        string type = declNode.isMutable ? "int" : "const int";
        string decl = type ~ " " ~ declNode.name;

        if (declNode.initializer.length > 0)
        {
            string initializer = processExpression(declNode.initializer);
            decl ~= " = " ~ initializer;
        }

        cCode ~= decl ~ ";\n";
        variables[declNode.name] = type;
        break;

    case "Println":
        auto printlnNode = cast(PrintlnNode) ast;
        cCode ~= "printf(\"" ~ printlnNode.message ~ "\\n\");\n";
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
        break;

    case "Break":
        cCode ~= "break;\n";
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

    if (expr.canFind("(") && expr.endsWith(")"))
    {
        int depth = 0;
        int splitPos = -1;

        for (int i = 0; i < expr.length; i++)
        {
            if (expr[i] == '(')
                depth++;
            else if (expr[i] == ')')
                depth--;

            if (depth == 0 && i < cast(int) expr.length - 1)
            {
                if (expr[i] == '+' || expr[i] == '-' || expr[i] == '*' || expr[i] == '/' ||
                    expr[i] == '>' || expr[i] == '<' || expr[i] == '=' || expr[i] == '!')
                {
                    splitPos = i;
                    break;
                }
            }
        }

        if (splitPos != -1)
        {
            string left = expr[0 .. splitPos].strip();
            char op = expr[splitPos];
            string right = expr[splitPos + 1 .. $].strip();

            if ((op == '=' && splitPos + 1 < expr.length && expr[splitPos + 1] == '=') ||
                (op == '!' && splitPos + 1 < expr.length && expr[splitPos + 1] == '=') ||
                (op == '<' && splitPos + 1 < expr.length && expr[splitPos + 1] == '=') ||
                (op == '>' && splitPos + 1 < expr.length && expr[splitPos + 1] == '='))
            {
                op = to!char(expr[splitPos .. splitPos + 2]);
                right = expr[splitPos + 2 .. $].strip();
            }

            return "(" ~ processExpression(left) ~ " " ~ op ~ " " ~ processExpression(right) ~ ")";
        }
        else
        {
            return processExpression(expr[1 .. $ - 1]);
        }
    }

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

    // {
    //     auto tokens = lex("def foo { println \"in foo\"; } main { foo(); }");
    //     auto ast = parse(tokens);

    //     auto cCode = generateC(ast);
    //     assert(cCode.canFind("void foo()"));
    //     assert(cCode.canFind("printf(\\\"in foo\\n\\\")"));
    //     assert(cCode.canFind("foo()"));
    // }

    // {
    //     auto tokens = lex("def add(a, b) { return a + b; } main { x = add(1, 2); }");
    //     auto ast = parse(tokens);

    //     auto cCode = generateC(ast);
    //     assert(cCode.canFind("void add(int a, int b)"));
    //     assert(cCode.canFind("return (a + b)"));
    //     assert(cCode.canFind("x = add(1, 2)"));
    // }
}
