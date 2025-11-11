import
    structs,
    strformat

proc generateC*(ast: ASTNode): string =
    ## Code generation from abstract syntax tree (AST)
    ## Includes C code generation for main function, loop and break statements, and string handling

    var cCode = "#include <stdio.h>\n\n"
    if ast.nodeType == "Main":
        cCode.add("int main() {\n")
        for child in ast.children:
            case child.nodeType
            of "Println":
                cCode.add(fmt"""    printf("%s\n", "{child.value}");""")
            of "Loop":
                cCode.add("    while (1) {\n")
                for loopChild in child.children:
                    case loopChild.nodeType
                    of "Println":
                        cCode.add(fmt"""        printf("%s\n", "{loopChild.value}");""")
                    of "Break":
                        cCode.add("        break;\n")
                cCode.add("    }\n")
        cCode.add("    return 0;\n}\n")
    return cCode
