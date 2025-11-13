module axe.parser;

import std.exception : enforce;
import std.conv;
import std.string;
import std.algorithm;
import axe.structs : ASTNode, Token, TokenType;

/** 
 * Parses an array of tokens into an abstract syntax tree (AST).
 * 
 * Params:
 *   tokens = Array of tokens to parse
 * Returns: 
 *   ASTNode = Abstract syntax tree representing the parsed tokens
 */
ASTNode parse(Token[] tokens)
{
    size_t pos = 0;
    ASTNode ast = ASTNode("Program", [], "");

    /** 
     * Parses a type from the current position in the token stream.
     * 
     * Returns: 
     *   string = Type name (e.g., "int", "char", "int*")
     */
    string parseType()
    {
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length, "Expected type after ':'");

        string typeName;
        if (tokens[pos].type == TokenType.IDENTIFIER)
        {
            typeName = tokens[pos].value;
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "*")
            {
                typeName ~= "*";
                pos++;
            }
        }
        else
        {
            enforce(false, "Invalid type specification");
        }

        return typeName;
    }

    /** 
     * Parses function arguments from the current position in the token stream.
     * 
     * Returns: 
     *   string = Comma-separated list of arguments (e.g., "int a, char b")
     */
    string parseArgs()
    {
        string[] args;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.COMMA)
                {
                    pos++;
                }
                else if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string argName = tokens[pos].value;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++;
                        string argType = parseType();
                        args ~= argType ~ " " ~ argName;
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                    {
                        args ~= "int " ~ argName;
                    }
                }
                else if (tokens[pos].type == TokenType.STR || tokens[pos].type == TokenType
                    .IDENTIFIER)
                {
                    args ~= tokens[pos].value;
                    pos++;
                }
                else
                {
                    enforce(false, "Unexpected token in argument list: " ~ tokens[pos].value);
                }
            }
            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN, "Expected ')' after arguments");
            pos++;
        }

        return args.join(", ");
    }

    while (pos < tokens.length)
    {
        switch (tokens[pos].type)
        {
        case TokenType.MAIN:
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'main'");
            pos++;
            auto mainNode = ASTNode("Main", []);
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                switch (tokens[pos].type)
                {
                case TokenType.WHITESPACE, TokenType.NEWLINE:
                    pos++;
                    break;

                case TokenType.PRINTLN:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.STR, "Expected string after println");
                    mainNode.children ~= ASTNode("Println", [], tokens[pos].value);
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                    enforce(
                        pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON, "Expected ';' after println");
                    pos++;
                    break;

                case TokenType.LOOP:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE, "Expected '{' after loop");
                    pos++;

                    ASTNode loopNode = ASTNode("Loop", [], "");
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.WHITESPACE, TokenType.NEWLINE:
                            pos++;
                            break;

                        case TokenType.PRINTLN:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(
                                pos < tokens.length && tokens[pos].type == TokenType.STR,
                                "Expected string after println"
                            );
                            loopNode.children ~= ASTNode("Println", [], tokens[pos].value);
                            pos++;

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;

                        case TokenType.BREAK:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after break");
                            pos++;
                            loopNode.children ~= ASTNode("Break", [], "");
                            break;

                        case TokenType.IF:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            string cond;
                            bool hasParen = false;
                            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                            {
                                hasParen = true;
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;
                            }

                            if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                            {
                                cond = tokens[pos].value;
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                                    (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<"
                                        ||
                                        tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value ==
                                        "!="))
                                {
                                    cond ~= " " ~ tokens[pos].value ~ " ";  // Preserve operator with spaces
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    if (pos < tokens.length && tokens[pos].type == TokenType
                                        .IDENTIFIER)
                                    {
                                        cond ~= tokens[pos].value;
                                        pos++;
                                    }
                                }
                            }

                            if (hasParen)
                            {
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after if condition");
                                pos++;
                            }

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after if condition");
                            pos++;

                            ASTNode ifNode = ASTNode("If", [], cond);
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                switch (tokens[pos].type)
                                {
                                case TokenType.BREAK:
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after break");
                                    pos++;
                                    ifNode.children ~= ASTNode("Break", [], "");
                                    break;
                                case TokenType.WHITESPACE, TokenType.NEWLINE:
                                    pos++;
                                    break;
                                case TokenType.PRINTLN:
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    enforce(
                                        pos < tokens.length && tokens[pos].type == TokenType.STR,
                                        "Expected string after println"
                                    );
                                    ifNode.children ~= ASTNode("Println", [], tokens[pos].value);
                                    pos++;

                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after println");
                                    pos++;
                                    break;
                                default:
                                    import std.stdio;

                                    writeln("Token type: ", tokens[pos].type);

                                    enforce(false, "Unexpected token in if body: " ~ tokens[pos]
                                            .value);
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after if body");
                            pos++;
                            loopNode.children ~= ifNode;
                            break;

                        case TokenType.IDENTIFIER:
                            string varName = tokens[pos].value;
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            if (pos < tokens.length &&
                                tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                            {
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                string expr;
                                if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                                {
                                    expr = tokens[pos].value;
                                    pos++;

                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR
                                        && tokens[pos].value == "-")
                                    {
                                        pos++;
                                        while (pos < tokens.length && tokens[pos].type == TokenType
                                            .WHITESPACE)
                                            pos++;

                                        if (pos < tokens.length && tokens[pos].type == TokenType
                                            .IDENTIFIER)
                                        {
                                            expr ~= " - " ~ tokens[pos].value;
                                            pos++;
                                        }
                                    }
                                }

                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after assignment");
                                pos++;
                                loopNode.children ~= ASTNode("Assignment", [], varName ~ " = " ~ expr);
                                break;
                            }
                            else
                            {
                                string funcName = tokens[pos - 1].value;
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                                    "Expected '(' after function name");
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                                    "Expected '(' after function name");
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                string args;
                                while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                                {
                                    if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                                        .COMMA)
                                    {
                                        pos++;
                                    }
                                    else if (tokens[pos].type == TokenType.STR || tokens[pos].type == TokenType
                                        .IDENTIFIER)
                                    {
                                        args ~= tokens[pos].value;
                                        pos++;
                                        if (pos < tokens.length && tokens[pos].type == TokenType
                                            .COMMA)
                                        {
                                            args ~= ", ";
                                            pos++;
                                        }
                                    }
                                    else
                                    {
                                        enforce(false, "Unexpected token in function call arguments");
                                    }
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after function arguments");
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after function call");
                                pos++;
                                loopNode.children ~= ASTNode("FunctionCall", [], funcName ~ "(" ~ args ~ ")");
                                break;
                            }

                        default:
                            import std.stdio;

                            writeln("Token type: ", tokens[pos].type);

                            writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('", tokens[pos]
                                    .value, "')");
                            writeln("Previous tokens:");
                            foreach (i; max(0, cast(int) pos - 5) .. pos)
                            {
                                writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
                            }
                            enforce(false, "Unexpected token in loop body at " ~ to!string(pos));
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;
                    mainNode.children ~= loopNode;
                    break;

                case TokenType.BREAK:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON, "Expected ';' after break");
                    pos++;
                    mainNode.children ~= ASTNode("Break", [], "");
                    break;

                case TokenType.IDENTIFIER:
                    string funcName = tokens[pos].value;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                        format("Expected '(' after function name '%s' at position %s", funcName, pos
                            .to!string));
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    string args;
                    while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                    {
                        if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .COMMA)
                        {
                            pos++;
                        }
                        else if (tokens[pos].type == TokenType.STR || tokens[pos].type == TokenType
                            .IDENTIFIER)
                        {
                            args ~= tokens[pos].value;
                            pos++;
                            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                            {
                                args ~= ", ";
                                pos++;
                            }
                        }
                        else
                        {
                            enforce(false, format("Unexpected argument in function call: %s", tokens[pos]
                                    .value));
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        format("Expected ')' after function arguments for '%s'", funcName));
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        format("Expected ';' after function call to '%s'", funcName));
                    pos++;
                    mainNode.children ~= ASTNode("FunctionCall", [], funcName ~ "(" ~ args ~ ")");
                    break;

                case TokenType.IF:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    string cond;
                    bool hasParen = false;
                    if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        hasParen = true;
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                    }

                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        cond = tokens[pos].value;
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                            (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<" ||
                                tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value == "!="))
                        {
                            cond ~= " " ~ tokens[pos].value ~ " ";  // Preserve operator with spaces
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                            {
                                cond ~= tokens[pos].value;
                                pos++;
                            }
                        }
                    }

                    if (hasParen)
                    {
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after if condition");
                        pos++;
                    }

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after if condition");
                    pos++;

                    ASTNode ifNode = ASTNode("If", [], cond);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.BREAK:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after break");
                            pos++;
                            ifNode.children ~= ASTNode("Break", [], "");
                            break;
                        case TokenType.WHITESPACE, TokenType.NEWLINE:
                            pos++;
                            break;
                        case TokenType.PRINTLN:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(
                                pos < tokens.length && tokens[pos].type == TokenType.STR,
                                "Expected string after println"
                            );
                            ifNode.children ~= ASTNode("Println", [], tokens[pos].value);
                            pos++;

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;
                        default:
                            enforce(false, "Unexpected token in if body: " ~ tokens[pos].value);
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after if body");
                    pos++;
                    mainNode.children ~= ifNode;
                    break;

                default:
                    import std.stdio;

                    writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('",
                        tokens[pos].value, "')");
                    writeln("Previous tokens:");
                    foreach (i; max(0, cast(int) pos - 5) .. pos)
                    {
                        writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
                    }
                    enforce(false, "Unexpected token in main body at " ~ to!string(pos));
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after main body");
            pos++;
            ast.children ~= mainNode;
            break;

        case TokenType.DEF:
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected function name after 'def'");
            string funcName = tokens[pos].value;
            pos++;

            string args = parseArgs();
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after function declaration");
            pos++;

            ASTNode funcNode = ASTNode("Function", [], funcName ~ "(" ~ args ~ ")");
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                switch (tokens[pos].type)
                {
                case TokenType.WHITESPACE, TokenType.NEWLINE:
                    pos++;
                    break;

                case TokenType.PRINTLN:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.STR, "Expected string after println");
                    funcNode.children ~= ASTNode("Println", [], tokens[pos].value);
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after println");
                    pos++;
                    break;

                case TokenType.IF:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    string cond;
                    bool hasParen = false;
                    if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        hasParen = true;
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                    }

                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        cond = tokens[pos].value;
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType
                            .WHITESPACE)
                            pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                            (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<" ||
                                tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value == "!="))
                        {
                            cond ~= " " ~ tokens[pos].value ~ " ";  // Preserve operator with spaces
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType
                                .WHITESPACE)
                                pos++;

                            if (pos < tokens.length && tokens[pos].type == TokenType
                                .IDENTIFIER)
                            {
                                cond ~= tokens[pos].value;
                                pos++;
                            }
                        }
                    }

                    if (hasParen)
                    {
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after if condition");
                        pos++;
                    }

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after if condition");
                    pos++;

                    ASTNode ifNode = ASTNode("If", [], cond);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.BREAK:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after break");
                            pos++;
                            ifNode.children ~= ASTNode("Break", [], "");
                            break;
                        case TokenType.WHITESPACE, TokenType.NEWLINE:
                            pos++;
                            break;
                        case TokenType.PRINTLN:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(
                                pos < tokens.length && tokens[pos].type == TokenType.STR,
                                "Expected string after println"
                            );
                            ifNode.children ~= ASTNode("Println", [], tokens[pos].value);
                            pos++;

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;
                        default:
                            import std.stdio;

                            writeln("Token type: ", tokens[pos].type);

                            enforce(false, "Unexpected token in if body: " ~ tokens[pos]
                                    .value);

                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after if body");
                    pos++;
                    funcNode.children ~= ifNode;
                    break;

                case TokenType.IDENTIFIER:
                    string callName = tokens[pos].value;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                        "Expected '(' after function name");
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    string functionArgs;
                    while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                    {
                        if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .COMMA)
                        {
                            pos++;
                        }
                        else if (tokens[pos].type == TokenType.STR || tokens[pos].type == TokenType
                            .IDENTIFIER)
                        {
                            functionArgs ~= tokens[pos].value;
                            pos++;
                            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                            {
                                functionArgs ~= ", ";
                                pos++;
                            }
                        }
                        else
                        {
                            enforce(false, "Unexpected token in function call arguments");
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        "Expected ')' after function arguments");
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after function call");
                    pos++;
                    funcNode.children ~= ASTNode("FunctionCall", [], callName ~ "(" ~ args ~ ")");
                    break;

                case TokenType.LOOP:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after loop");
                    pos++;

                    ASTNode loopNode = ASTNode("Loop", [], "");
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.WHITESPACE, TokenType.NEWLINE:
                            pos++;
                            break;

                        case TokenType.PRINTLN:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(
                                pos < tokens.length && tokens[pos].type == TokenType.STR,
                                "Expected string after println"
                            );
                            loopNode.children ~= ASTNode("Println", [], tokens[pos].value);
                            pos++;

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;

                        case TokenType.BREAK:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after break");
                            pos++;
                            loopNode.children ~= ASTNode("Break", [], "");
                            break;

                        case TokenType.IF:
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            string cond;
                            bool hasParen = false;
                            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                            {
                                hasParen = true;
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;
                            }

                            if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                            {
                                cond = tokens[pos].value;
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                                    (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<"
                                        ||
                                        tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value ==
                                        "!="))
                                {
                                    cond ~= " " ~ tokens[pos].value ~ " ";  // Preserve operator with spaces
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    if (pos < tokens.length && tokens[pos].type == TokenType
                                        .IDENTIFIER)
                                    {
                                        cond ~= tokens[pos].value;
                                        pos++;
                                    }
                                }
                            }

                            if (hasParen)
                            {
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after if condition");
                                pos++;
                            }

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after if condition");
                            pos++;

                            ASTNode ifNode = ASTNode("If", [], cond);
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                switch (tokens[pos].type)
                                {
                                case TokenType.BREAK:
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after break");
                                    pos++;
                                    ifNode.children ~= ASTNode("Break", [], "");
                                    break;
                                case TokenType.WHITESPACE, TokenType.NEWLINE:
                                    pos++;
                                    break;
                                case TokenType.PRINTLN:
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    enforce(
                                        pos < tokens.length && tokens[pos].type == TokenType.STR,
                                        "Expected string after println"
                                    );
                                    ifNode.children ~= ASTNode("Println", [], tokens[pos].value);
                                    pos++;

                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after println");
                                    pos++;
                                    break;
                                default:
                                    import std.stdio;

                                    writeln("Token type: ", tokens[pos].type);

                                    enforce(false, "Unexpected token in if body: " ~ tokens[pos]
                                            .value);
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after if body");
                            pos++;
                            loopNode.children ~= ifNode;
                            break;

                        default:
                            import std.stdio;

                            writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('", tokens[pos]
                                    .value, "')");
                            writeln("Previous tokens:");
                            foreach (i; max(0, cast(int) pos - 5) .. pos)
                            {
                                writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
                            }
                            enforce(false,
                                format("Unexpected token in function body at" ~
                                    " position %s: %s (type: %s)\nExpected one of: %s",
                                    pos.to!string,
                                    tokens[pos].value,
                                    tokens[pos].type.to!string,
                                    [
                                        TokenType.IDENTIFIER, TokenType.IF,
                                        TokenType.LOOP,
                                        TokenType.PRINTLN, TokenType.BREAK
                                    ].map!(
                                    t => t.to!string).join(", "))
                            );
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;
                    funcNode.children ~= loopNode;
                    break;

                default:
                    import std.stdio;

                    writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('",
                        tokens[pos].value, "')");
                    writeln("Previous tokens:");
                    foreach (i; max(0, cast(int) pos - 5) .. pos)
                    {
                        writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
                    }
                    enforce(false, format(
                            "Unexpected token in function body at position %s: %s (type: %s)\nExpected one of: %s",
                            pos.to!string,
                            tokens[pos].value,
                            tokens[pos].type.to!string,
                            [
                                TokenType.IDENTIFIER, TokenType.IF, TokenType.LOOP,
                                TokenType.PRINTLN, TokenType.BREAK
                            ].map!(
                            t => t.to!string).join(", ")));
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after function body");
            pos++;
            ast.children ~= funcNode;
            break;

        case TokenType.WHITESPACE, TokenType.NEWLINE:
            pos++;
            break;

        default:
            import std.stdio;

            writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");
            writeln("Previous tokens:");
            foreach (i; max(0, cast(int) pos - 5) .. pos)
            {
                writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
            }
            enforce(false, "Unexpected token at top level: " ~ tokens[pos].value);
        }
    }

    return ast;
}

unittest
{
    auto loopIfTokens = [
        Token(TokenType.DEF, "def"),
        Token(TokenType.IDENTIFIER, "test"),
        Token(TokenType.LPAREN, "("),
        Token(TokenType.RPAREN, ")"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.LOOP, "loop"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.IF, "if"),
        Token(TokenType.IDENTIFIER, "x"),
        Token(TokenType.OPERATOR, "=="),
        Token(TokenType.IDENTIFIER, "0"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.BREAK, "break"),
        Token(TokenType.SEMICOLON, ";"),
        Token(TokenType.RBRACE, "}"),
        Token(TokenType.RBRACE, "}"),
        Token(TokenType.RBRACE, "}")
    ];

    auto loopAst = parse(loopIfTokens);
    assert(loopAst.children[0].nodeType == "Function");
    assert(loopAst.children[0].children[0].nodeType == "Loop");
    assert(loopAst.children[0].children[0].children[0].nodeType == "If");
    assert(loopAst.children[0].children[0].children[0].value == "x == 0");

    auto funcIfTokens = [
        Token(TokenType.DEF, "def"),
        Token(TokenType.IDENTIFIER, "test"),
        Token(TokenType.LPAREN, "("),
        Token(TokenType.RPAREN, ")"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.IF, "if"),
        Token(TokenType.IDENTIFIER, "y"),
        Token(TokenType.OPERATOR, "=="),
        Token(TokenType.IDENTIFIER, "1"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.BREAK, "break"),
        Token(TokenType.SEMICOLON, ";"),
        Token(TokenType.RBRACE, "}"),
        Token(TokenType.RBRACE, "}")
    ];

    auto funcAst = parse(funcIfTokens);
    assert(funcAst.children[0].nodeType == "Function");
    assert(funcAst.children[0].children[0].nodeType == "If");
    assert(funcAst.children[0].children[0].value == "y == 1");
}
