type
    TokenType* = enum
        Main,
        Println,
        Loop,
        Break,
        String,
        Semicolon,
        LBrace,
        RBrace,
        Def,
        Identifier,
        Whitespace,
        Newline,
        LParen,
        RParen,
        LBracket,
        RBracket,
        Comma,
        Dot,
        Colon,
        Operator

    Token* = object
        typ*: TokenType
        value*: string

    ASTNode* = object
        nodeType*: string
        children*: seq[ASTNode]
        value*: string

proc debugTokens*(tokens: seq[Token]): string =
    result = "@["
    for i, token in tokens:
        if token.typ notin {Whitespace, Newline}:
            if result.len > 2: result.add ", "
            result.add $token
    result.add "]"
