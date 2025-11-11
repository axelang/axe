import structs

proc parse*(tokens: seq[Token]): ASTNode =
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
                    mainNode.children.add(ASTNode(nodeType: "Println",
                            children: @[], value: tokens[pos].value))
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
                            loopNode.children.add(ASTNode(nodeType: "Println",
                                    children: @[], value: tokens[pos].value))
                            inc(pos)
                            if tokens[pos].typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after println")
                            inc(pos)
                        of Break:
                            inc(pos)
                            if tokens[pos].typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after break")
                            loopNode.children.add(ASTNode(nodeType: "Break",
                                    children: @[], value: ""))
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
