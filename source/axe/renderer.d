module axe.renderer;

import std.string;
import std.array;
import axe.structs;
import std.exception;

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
            final switch (child.nodeType)
            {
            case "Println":
                cCode ~= "printf(\"%s\\n\", \"" ~ child.value ~ "\");\n";
                break;
            case "Loop":
                cCode ~= "while (1) {\n";
                foreach (loopChild; child.children)
                {
                    final switch (loopChild.nodeType)
                    {
                    case "Println":
                        cCode ~= "printf(\"%s\\n\", \"" ~ loopChild.value ~ "\");\n";
                        break;
                    case "Break":
                        cCode ~= "break;\n";
                        break;
                    case "Assignment":
                        auto parts = loopChild.value.split(" = ");
                        cCode ~= parts[0] ~ " = " ~ parts[1] ~ ";\n";
                        break;
                    }
                }
                cCode ~= "}\n";
                break;
            case "Break":
                cCode ~= "break;\n";
                break;
            case "FunctionCall":
                auto funcDecl = child.value.split("(");
                string funcName = funcDecl[0];
                string args = funcDecl.length > 1 ?
                    funcDecl[1].strip(")") : "";
                cCode ~= funcName ~ "(" ~ args ~ ");\n";
                break;
            case "Assignment":
                auto parts = child.value.split(" = ");
                cCode ~= parts[0] ~ " = " ~ parts[1] ~ ";\n";
                break;
            }
        }
        cCode ~= "return 0;\n}";
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
                cCode ~= "printf(\"%s\\n\", \"" ~ child.value ~ "\");\n";
                break;
            case "FunctionCall":
                auto callDecl = child.value.split("(");
                string callName = callDecl[0];
                string callArgs = callDecl.length > 1 ?
                    callDecl[1].strip(")") : "";
                cCode ~= callName ~ "(" ~ callArgs ~ ");\n";
                break;
            case "Assignment":
                auto parts = child.value.split(" = ");
                cCode ~= parts[0] ~ " = " ~ parts[1] ~ ";\n";
                break;
            }
        }
        cCode ~= "}";
        break;

    case "FunctionCall":
        auto funcDecl = ast.value.split("(");
        string funcName = funcDecl[0];
        string args = funcDecl.length > 1 ?
            funcDecl[1].strip(")") : "";
        cCode ~= funcName ~ "(" ~ args ~ ");\n";
        break;

    case "Assignment":
        auto parts = ast.value.split(" = ");
        cCode ~= parts[0] ~ " = " ~ parts[1] ~ ";\n";
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
                        msg_` ~ msgCounter.to!string ~ ` db '` ~ child.value ~ `', 0
                    section .text
                        mov rcx, msg_` ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                msgCounter++;
                break;

            case "FunctionCall":
                auto callDecl = child.value.split("(");
                string callName = callDecl[0];
                string callArgs = callDecl.length > 1 ?
                    callDecl[1].strip(")") : "";
                asmCode ~= "    call " ~ callName ~ "\n";
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
                                msg_` ~ msgCounter.to!string ~ ` db '` ~ loopChild.value ~ `', 0
                            section .text
                                mov rcx, msg_` ~ msgCounter.to!string ~ `
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
                        asmCode ~= "    mov eax, " ~ parts[1] ~ "\n"
                            ~ "    mov " ~ parts[0] ~ ", eax\n";
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
                asmCode ~= "    mov eax, " ~ parts[1] ~ "\n"
                    ~ "    mov " ~ parts[0] ~ ", eax\n";
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
        string funcName = funcDecl[0];
        string args = funcDecl.length > 1 ?
            funcDecl[1].strip(")") : "";
        asmCode ~= "section .text\n"
            ~ "global " ~ funcName ~ "\n"
            ~ funcName ~ ":\n"
            ~ "    sub rsp, 40\n";
        int msgCounter = 0;
        foreach (child; ast.children)
        {
            final switch (child.nodeType)
            {
            case "Println":
                asmCode ~= `
                    section .data
                        msg_` ~ msgCounter.to!string ~ ` db '` ~ child.value ~ `', 0
                    section .text
                        mov rcx, msg_` ~ msgCounter.to!string ~ `
                        call printf
                        mov rcx, nl
                        call printf
                `;
                msgCounter++;
                break;

            case "FunctionCall":
                auto callDecl = child.value.split("(");
                string callName = callDecl[0];
                string callArgs = callDecl.length > 1 ?
                    callDecl[1].strip(")") : "";
                asmCode ~= "    call " ~ callName ~ "\n";
                break;
            case "Assignment":
                auto parts = child.value.split(" = ");
                asmCode ~= "    mov eax, " ~ parts[1] ~ "\n"
                    ~ "    mov " ~ parts[0] ~ ", eax\n";
                break;
            }
        }
        asmCode ~= "    add rsp, 40\n"
            ~ "    ret\n";
        break;

    case "FunctionCall":
        auto funcDecl = ast.value.split("(");
        string funcName = funcDecl[0];
        string args = funcDecl.length > 1 ?
            funcDecl[1].strip(")") : "";
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
                        msg_` ~ loopId.to!string ~ ` db '` ~ child.value ~ `', 0
                    section .text
                        mov rcx, msg_` ~ loopId.to!string ~ `
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
                asmCode ~= "    mov eax, " ~ parts[1] ~ "\n"
                    ~ "    mov " ~ parts[0] ~ ", eax\n";
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
        asmCode ~= "    mov eax, " ~ parts[1] ~ "\n"
            ~ "    mov " ~ parts[0] ~ ", eax\n";
        break;

    }

    return asmCode;
}
