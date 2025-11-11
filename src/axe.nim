import 
    os, 
    strutils, 
    strformat,
    osproc

type
    TokenType = enum
        Main, Println, Loop, Break, String, Semicolon, LBrace, RBrace

    Token = object
        typ: TokenType
        value: string

    ASTNode = object
        nodeType: string
        children: seq[ASTNode]
        value: string

proc lex(source: string): seq[Token] =
    ## Lexical analysis and tokenization
    ## Includes whitespace skipping, basic tokenization, and string handling
    
    var tokens: seq[Token]
    var pos = 0

    while pos < source.len:
        case source[pos]
        of ' ', '\n', '\t', '\r':
            inc(pos)
        of '{':
            tokens.add(Token(typ: LBrace, value: "{"))
            inc(pos)
        of '}':
            tokens.add(Token(typ: RBrace, value: "}"))
            inc(pos)
        of ';':
            tokens.add(Token(typ: Semicolon, value: ";"))
            inc(pos)
        of '"':
            let ending = source.find('"', pos + 1)
            if ending == -1:
                raise newException(ValueError, "Unterminated string")
            tokens.add(Token(typ: String, value: source[(pos+1)..(ending-1)]))
            pos = ending + 1
        else:
            if pos + 4 <= source.len and source[pos ..< pos+4] == "main":
                tokens.add(Token(typ: Main, value: "main"))
                pos += 4
            elif pos + 7 <= source.len and source[pos ..< pos+7] == "println":
                tokens.add(Token(typ: Println, value: "println"))
                pos += 7
            elif pos + 4 <= source.len and source[pos ..< pos+4] == "loop":
                tokens.add(Token(typ: Loop, value: "loop"))
                pos += 4
            elif pos + 5 <= source.len and source[pos ..< pos+5] == "break":
                tokens.add(Token(typ: Break, value: "break"))
                pos += 5
            else:
                let charAtPos = if pos < source.len: source[pos] else: '.'
                echo "Charatpos: " & charAtPos
                echo "Pos: " & $pos
                echo "Char code: " & $ord(charAtPos)
                raise newException(ValueError, &"Unexpected character at position {pos}: '{charAtPos}'")
    return tokens

proc parse(tokens: seq[Token]): ASTNode =
    ## Syntax analysis and abstract syntax tree (AST) construction
    ## Includes main function parsing, loop and break statement parsing, and string handling
    var pos = 0
    var ast: ASTNode
    while pos < tokens.len:
        if tokens[pos].typ == Main:
            inc(pos)
            if pos >= tokens.len or tokens[pos].typ != LBrace:
                raise newException(ValueError, "Expected '{' after main")
            inc(pos)

            var mainNode = ASTNode(nodeType: "Main", children: @[], value: "")
            while pos < tokens.len and tokens[pos].typ != RBrace:
                case tokens[pos].typ
                of Println:
                    inc(pos)
                    if pos >= tokens.len or tokens[pos].typ != String:
                        raise newException(ValueError, "Expected string after println")
                    mainNode.children.add(ASTNode(nodeType: "Println", children: @[], value: tokens[pos].value))
                    inc(pos)
                    if pos >= tokens.len or tokens[pos].typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after println")
                    inc(pos)
                of Loop:
                    inc(pos)
                    if pos >= tokens.len or tokens[pos].typ != LBrace:
                        raise newException(ValueError, "Expected '{' after loop")
                    inc(pos)
                    var loopNode = ASTNode(nodeType: "Loop", children: @[], value: "")
                    while pos < tokens.len and tokens[pos].typ != RBrace:
                        case tokens[pos].typ
                        of Println:
                            inc(pos)
                            if tokens[pos].typ != String:
                                raise newException(ValueError, "Expected string after println")
                            loopNode.children.add(ASTNode(nodeType: "Println", children: @[], value: tokens[pos].value))
                            inc(pos)
                            if tokens[pos].typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after println")
                            inc(pos)
                        of Break:
                            inc(pos)
                            if tokens[pos].typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after break")
                            loopNode.children.add(ASTNode(nodeType: "Break", children: @[], value: ""))
                            inc(pos)
                        else:
                            raise newException(ValueError, "Unexpected token in loop body")
                    if pos >= tokens.len or tokens[pos].typ != RBrace:
                        raise newException(ValueError, "Expected '}' after loop body")
                    inc(pos)
                    mainNode.children.add(loopNode)
                else:
                    discard
            if pos >= tokens.len or tokens[pos].typ != RBrace:
                raise newException(ValueError, "Expected '}' after main body")
            inc(pos)
            ast = mainNode
    return ast

proc generateC(ast: ASTNode): string =
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

when isMainModule:
    if paramCount() < 1:
        echo "Usage: axe input.axe"
    else:
        try:
            let source = readFile(paramStr(1))
            let tokens = lex(source)
            let ast = parse(tokens)
            let cCode = generateC(ast)
            writeFile("output.c", cCode)
            discard execProcess(command="gcc", args=["output.c", "-o", "output"], options={poStdErrToStdOut})
        except ValueError as e:
            echo "Error: ", e.msg
        except OSError as e:
            echo "LL Error: ", e.msg.replace("OS error:", "")
        except Exception as e:
            echo "Unknown Error: ", e.msg
