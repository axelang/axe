import 
    structs,
    strutils

proc parse*(tokens: seq[Token]): ASTNode =
    var pos = 0
    var ast = ASTNode(nodeType: "Program", children: @[], value: "")
    
    template current: Token = tokens[pos]
    template advance = inc(pos)
    
    proc parseType(): string =
        while pos < tokens.len and current.typ == Whitespace: advance
        if pos >= tokens.len:
            raise newException(ValueError, "Expected type after ':'")
        
        var typeName = ""
        case current.typ
        of Identifier:
            typeName = current.value
            advance
            if pos < tokens.len and current.typ == Operator and current.value == "*":
                typeName.add "*"
                advance
        else:
            raise newException(ValueError, "Invalid type specification")
        
        return typeName
    
    proc parseArgs(): string =
        var args: seq[string]
        while pos < tokens.len and current.typ == Whitespace: advance
        if pos < tokens.len and current.typ == LParen:
            advance
            while pos < tokens.len and current.typ != RParen:
                case current.typ
                of Whitespace, Comma: advance
                of Identifier:
                    let argName = current.value
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos < tokens.len and current.typ == Colon:
                        advance
                        let argType = parseType()
                        args.add(argType & " " & argName)
                    else:
                        args.add("int " & argName)
                else: raise newException(ValueError, "Unexpected token in argument list")
            if pos >= tokens.len or current.typ != RParen:
                raise newException(ValueError, "Expected ')' after arguments")
            advance
        return args.join(", ")
    
    while pos < tokens.len:
        case current.typ
        of Main:
            advance
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != LBrace:
                raise newException(ValueError, "Expected '{' after main")
            advance
            
            var mainNode = ASTNode(nodeType: "Main", children: @[], value: "")
            while pos < tokens.len and current.typ != RBrace:
                case current.typ
                of Whitespace, Newline: advance
                of Println:
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != String:
                        raise newException(ValueError, "Expected string after println")
                    mainNode.children.add(ASTNode(nodeType: "Println", children: @[], value: current.value))
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after println")
                    advance
                of Loop:
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != LBrace:
                        raise newException(ValueError, "Expected '{' after loop")
                    advance
                    
                    var loopNode = ASTNode(nodeType: "Loop", children: @[], value: "")
                    while pos < tokens.len and current.typ != RBrace:
                        case current.typ
                        of Whitespace, Newline: advance
                        of Println:
                            advance
                            while pos < tokens.len and current.typ == Whitespace: advance
                            if pos >= tokens.len or current.typ != String:
                                raise newException(ValueError, "Expected string after println")
                            loopNode.children.add(ASTNode(nodeType: "Println", children: @[], value: current.value))
                            advance
                            while pos < tokens.len and current.typ == Whitespace: advance
                            if pos >= tokens.len or current.typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after println")
                            advance
                        of Break:
                            advance
                            while pos < tokens.len and current.typ == Whitespace: advance
                            if pos >= tokens.len or current.typ != Semicolon:
                                raise newException(ValueError, "Expected ';' after break")
                            advance
                            loopNode.children.add(ASTNode(nodeType: "Break", children: @[], value: ""))
                        else:
                            raise newException(ValueError, "Unexpected token in loop body")
                    
                    if pos >= tokens.len or current.typ != RBrace:
                        raise newException(ValueError, "Expected '}' after loop body")
                    advance
                    mainNode.children.add(loopNode)
                of Break:
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after break")
                    advance
                    mainNode.children.add(ASTNode(nodeType: "Break", children: @[], value: ""))
                of Identifier:
                    let funcName = current.value
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != LParen:
                        raise newException(ValueError, "Expected '(' after function name")
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != RParen:
                        raise newException(ValueError, "Expected ')' after function arguments")
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after function call")
                    advance
                    
                    mainNode.children.add(ASTNode(nodeType: "FunctionCall", children: @[], value: funcName))
                else:
                    raise newException(ValueError, "Unexpected token in main body")
            
            if pos >= tokens.len or current.typ != RBrace:
                raise newException(ValueError, "Expected '}' after main body")
            advance
            ast.children.add(mainNode)
            
        of Def:
            advance
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != Identifier:
                raise newException(ValueError, "Expected function name after 'def'")
            let funcName = current.value
            advance
            
            var args = parseArgs()
            
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != LBrace:
                raise newException(ValueError, "Expected '{' after function declaration")
            advance
            
            var funcNode = ASTNode(nodeType: "Function", children: @[], value: funcName & "(" & args & ")")
            
            while pos < tokens.len and current.typ != RBrace:
                case current.typ
                of Whitespace, Newline: advance
                of Println:
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != String:
                        raise newException(ValueError, "Expected string after println")
                    funcNode.children.add(ASTNode(nodeType: "Println", children: @[], value: current.value))
                    advance
                    while pos < tokens.len and current.typ == Whitespace: advance
                    if pos >= tokens.len or current.typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after println")
                    advance
                of Identifier:
                    let funcName = current.value
                    advance
                    
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != LParen:
                        raise newException(ValueError, "Expected '(' after function name")
                    advance
                    
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != RParen:
                        raise newException(ValueError, "Expected ')' after function arguments")
                    advance
                    
                    while pos < tokens.len and current.typ == Whitespace: advance
                    
                    if pos >= tokens.len or current.typ != Semicolon:
                        raise newException(ValueError, "Expected ';' after function call")
                    advance
                    
                    funcNode.children.add(ASTNode(nodeType: "FunctionCall", children: @[], value: funcName))
                else:
                    raise newException(ValueError, "Unexpected token in function body")
            
            if pos >= tokens.len or current.typ != RBrace:
                raise newException(ValueError, "Expected '}' after function body")
            advance
            ast.children.add(funcNode)
            
        of Identifier:
            let funcName = current.value
            advance
            
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != LParen:
                raise newException(ValueError, "Expected '(' after function name")
            advance
            
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != RParen:
                raise newException(ValueError, "Expected ')' after function arguments")
            advance
            
            while pos < tokens.len and current.typ == Whitespace: advance
            
            if pos >= tokens.len or current.typ != Semicolon:
                raise newException(ValueError, "Expected ';' after function call")
            advance
            
            ast.children.add(ASTNode(nodeType: "FunctionCall", children: @[], value: funcName))
            
        of Whitespace, Newline:
            advance
            
        else:
            raise newException(ValueError, "Unexpected token at top level")
    
    return ast
