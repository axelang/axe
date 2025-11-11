import
    structs,
    strformat,
    sets

proc generateC*(ast: ASTNode): string =
    ## Code generation from abstract syntax tree (AST)

    var cCode = ""
    var includes = initHashSet[string]()
    includes.incl("#include <stdio.h>")
    
    case ast.nodeType
    of "Program":
        for i in includes:
            cCode.add(i & "\n")
        cCode.add("\n")
        for child in ast.children:
            cCode.add(generateC(child) & "\n")
    of "Main":
        cCode.add("int main() {\n")
        for child in ast.children:
            case child.nodeType
            of "Println":
                cCode.add("    printf(\"%s\\n\", \"" & child.value & "\");\n")
            of "Loop":
                cCode.add("    while (1) {\n")
                for loopChild in child.children:
                    case loopChild.nodeType
                    of "Println":
                        cCode.add("        printf(\"%s\\n\", \"" & loopChild.value & "\");\n")
                    of "Break":
                        cCode.add("        break;\n")
                cCode.add("    }\n")
            of "Break":
                cCode.add("    break;\n")
        cCode.add("    return 0;\n}")
    else:
        raise newException(ValueError, "Unsupported node type for C generation: " & ast.nodeType)
    
    return cCode

proc generateAsm*(ast: ASTNode): string =
    ## Generate x86 assembly code from AST
    ## Includes assembly code generation for main function, loop and break statements, and string handling

    var asmCode = ""
    
    case ast.nodeType
    of "Program":
        if ast.children.len > 0 and ast.children[0].nodeType == "Main":
            asmCode = generateAsm(ast.children[0])
    of "Main":
        asmCode = """
            section .data
                fmt db "%s", 10, 0
                hello db "hello", 0
            section .text
                global _start
            _start:
            """
        for child in ast.children:
            case child.nodeType
            of "Println":
                asmCode.add(fmt"""
                    push hello
                    push fmt
                    call printf
                    add esp, 8
                """)
            of "Loop":
                asmCode.add("loop_start:\n")
                for loopChild in child.children:
                    case loopChild.nodeType
                    of "Println":
                        asmCode.add(fmt"""
                            push hello
                            push fmt
                            call printf
                            add esp, 8
                        """)
                    of "Break":
                        asmCode.add("    jmp loop_end\n")
                asmCode.add("    jmp loop_start\n")
                asmCode.add("loop_end:\n")
        asmCode.add("""
            mov eax, 1
            mov ebx, 0
            int 0x80
        """)
    else:
        raise newException(ValueError, "Unsupported node type for ASM generation: " & ast.nodeType)
    
    return asmCode
