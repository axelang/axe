module axe.parser;

import std.exception : enforce;
import std.conv;
import std.string;
import std.algorithm;
import axe.structs;

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
    import std.stdio;

    writeln("Starting parse with tokens:");
    foreach (i, token; tokens)
    {
        writeln(i, ": ", token.type, " ('", token.value, "')");
    }

    size_t pos = 0;
    auto ast = new ProgramNode();

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
     *   string[] = Array of arguments (e.g., ["int a", "char b"])
     */
    string[] parseArgs()
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
                    string paramName = tokens[pos].value;
                    pos++;
                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON) {
                        pos++;
                        string typeName = parseType();
                        args ~= typeName ~ " " ~ paramName;
                    }
                    else {
                        args ~= paramName;
                    }
                    
                    if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                        pos++;
                }
                else
                {
                    enforce(false, "Unexpected token in function arguments: " ~ tokens[pos].value);
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after function arguments");
            pos++;
        }

        return args;
    }

    ASTNode currentScope = ast;

    while (pos < tokens.length)
    {
        writeln("Current token at pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

        switch (tokens[pos].type)
        {
        case TokenType.MAIN:
            writeln("Entering main block at pos ", pos);
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'main'");
            pos++;

            auto mainNode = new FunctionNode("main", []);
            writeln("Main block pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");
            size_t startPos = pos;
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                writeln("Main block pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

                switch (tokens[pos].type)
                {
                case TokenType.PRINTLN:
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                        "Expected string after println");
                    mainNode.children ~= new PrintlnNode(tokens[pos].value);
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after println");
                    pos++;
                    break;

                case TokenType.IDENTIFIER:
                    string funcName = tokens[pos].value;
                    pos++;

                    string args = "";
                    if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        pos++;

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
                                enforce(false, "Unexpected token in function call arguments");
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after function arguments");
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after function call");
                    pos++;

                    mainNode.children ~= new FunctionCallNode(funcName, args);
                    break;

                case TokenType.LOOP:
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after 'loop'");
                    pos++;

                    auto loopNode = new LoopNode();
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.BREAK:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after 'break'");
                            pos++;
                            loopNode.children ~= new BreakNode();
                            break;

                        default:
                            enforce(false, "Unexpected token in loop body");
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;

                    mainNode.children ~= loopNode;
                    break;

                case TokenType.IF:
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                        "Expected '(' after 'if'");
                    pos++;

                    string condition;
                    while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                    {
                        condition ~= tokens[pos].value;
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        "Expected ')' after if condition");
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after if condition");
                    pos++;

                    auto ifNode = new IfNode(condition);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.PRINTLN:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                                "Expected string after println");
                            ifNode.children ~= new PrintlnNode(tokens[pos].value);
                            pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;

                        default:
                            enforce(false, "Unexpected token in if body");
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after if body");
                    pos++;

                    mainNode.children ~= ifNode;
                    break;

                case TokenType.VAL:
                    bool isMutable = false;
                    pos++;

                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        string varName = tokens[pos].value;
                        pos++;

                        string initializer = "";
                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                        {
                            pos++;
                            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                            {
                                initializer ~= tokens[pos].value;
                                pos++;
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after val declaration");
                        pos++;

                        mainNode.children ~= new DeclarationNode(varName, isMutable, initializer);
                    }
                    break;

                default:
                    enforce(false, "Unexpected statement in main block: " ~ tokens[pos].value);
                }

                assert(pos > startPos, "Parser must advance position");
                startPos = pos;
            }

            writeln("Exited main block at pos ", pos);
            writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                pos < tokens.length ? tokens[pos].value : "", "')");
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after main body");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            assert(pos > startPos, "Parser must advance position");
            startPos = pos;
            ast.children ~= mainNode;
            continue;

        case TokenType.IDENTIFIER:
            if (tokens[pos].value == "main")
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                    "Expected '{' after 'main'");
                pos++;

                auto mainNode = new FunctionNode("main", []);
                writeln("Entering main block at pos ", pos);
                size_t startPos = pos;
                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                {
                    writeln("Main block pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

                    switch (tokens[pos].type)
                    {
                    case TokenType.PRINTLN:
                        pos++;
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                            "Expected string after println");
                        mainNode.children ~= new PrintlnNode(tokens[pos].value);
                        pos++;

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after println");
                        pos++;
                        break;

                    case TokenType.IDENTIFIER:
                        string funcName = tokens[pos].value;
                        pos++;

                        string args = "";
                        if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                        {
                            pos++;
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
                                    enforce(false, "Unexpected token in function call arguments");
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                "Expected ')' after function arguments");
                            pos++; // Skip ')'
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after function call");
                        pos++; // Skip ';'

                        mainNode.children ~= new FunctionCallNode(funcName, args);
                        break;

                    case TokenType.LOOP:
                        pos++; // Skip 'loop'
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after 'loop'");
                        pos++; // Skip '{'

                        auto loopNode = new LoopNode();
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            switch (tokens[pos].type)
                            {
                            case TokenType.BREAK:
                                pos++; // Skip 'break'
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after 'break'");
                                pos++; // Skip ';'
                                loopNode.children ~= new BreakNode();
                                break;

                            default:
                                enforce(false, "Unexpected token in loop body");
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after loop body");
                        pos++; // Skip '}'

                        mainNode.children ~= loopNode;
                        break;

                    case TokenType.IF:
                        pos++; // Skip 'if'
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                            "Expected '(' after 'if'");
                        pos++; // Skip '('

                        string condition;
                        while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                        {
                            condition ~= tokens[pos].value;
                            pos++;
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after if condition");
                        pos++; // Skip ')'

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after if condition");
                        pos++; // Skip '{'

                        auto ifNode = new IfNode(condition);
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            switch (tokens[pos].type)
                            {
                            case TokenType.PRINTLN:
                                pos++; // Skip 'println'
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                                    "Expected string after println");
                                ifNode.children ~= new PrintlnNode(tokens[pos].value);
                                pos++; // Skip string

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++; // Skip ';'
                                break;

                            default:
                                enforce(false, "Unexpected token in if body");
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after if body");
                        pos++;

                        mainNode.children ~= ifNode;
                        break;

                    case TokenType.VAL:
                        bool isMutable = false;
                        pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                        {
                            string varName = tokens[pos].value;
                            pos++;

                            string initializer = "";
                            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                            {
                                pos++;
                                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                                {
                                    initializer ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after val declaration");
                            pos++;

                            mainNode.children ~= new DeclarationNode(varName, isMutable, initializer);
                        }
                        break;

                    default:
                        enforce(false, "Unexpected statement in main block: " ~ tokens[pos].value);
                    }

                    assert(pos > startPos, "Parser must advance position");
                    startPos = pos;
                }

                writeln("Exited main block at pos ", pos);
                writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                    pos < tokens.length ? tokens[pos].value : "", "')");
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                    "Expected '}' after main body");
                pos++; 

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                assert(pos > startPos, "Parser must advance position");
                startPos = pos;
                ast.children ~= mainNode;
                continue;
            }
            goto default;

        case TokenType.DEF:
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected function name after 'def'");
            string currentFuncName = tokens[pos].value;
            pos++;

            string[] params = parseArgs();
            string returnType = "void";
            
            // Check for return type annotation
            if (pos < tokens.length && tokens[pos].type == TokenType.COLON) {
                pos++;
                returnType = parseType();
            }
            
            auto funcNode = new FunctionNode(currentFuncName, params, returnType);
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after function declaration");
            pos++;

            currentScope = funcNode;
            writeln("Entering function body at pos ", pos);
            size_t startPos = pos;
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                writeln("Function body pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

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
                    funcNode.children ~= new PrintlnNode(tokens[pos].value);
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
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                            (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<" ||
                                tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value == "!="))
                        {
                            cond ~= " " ~ tokens[pos].value ~ " "; // Preserve operator with spaces
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

                    ASTNode ifNode = new IfNode(cond);
                    currentScope = ifNode;
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
                            ifNode.children ~= new BreakNode();
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
                            ifNode.children ~= new PrintlnNode(tokens[pos].value);
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

                    writeln("Exited if body at pos ", pos);
                    writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                        pos < tokens.length ? tokens[pos].value : "", "')");
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after if body");
                    pos++;
                    currentScope = funcNode;
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
                    funcNode.children ~= new FunctionCallNode(callName, functionArgs);
                    break;

                case TokenType.LOOP:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after loop");
                    pos++;

                    ASTNode loopNode = new LoopNode();
                    currentScope = loopNode;
                    writeln("Entering loop body at pos ", pos);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        writeln("Loop body pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

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
                            loopNode.children ~= new PrintlnNode(tokens[pos].value);
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
                            loopNode.children ~= new BreakNode();
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
                                    (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<" ||
                                        tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos].value ==
                                        "!="))
                                {
                                    cond ~= " " ~ tokens[pos].value ~ " ";
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

                            ASTNode ifNode = new IfNode(cond);
                            currentScope = ifNode;
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
                                    ifNode.children ~= new BreakNode();
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
                                    ifNode.children ~= new PrintlnNode(tokens[pos].value);
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

                            writeln("Exited if body at pos ", pos);
                            writeln("Current token: ", pos < tokens.length ? to!string(
                                    tokens[pos].type) : "EOF", " ('",
                                pos < tokens.length ? tokens[pos].value : "", "')");
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after if body");
                            pos++;
                            currentScope = loopNode;
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
                                loopNode.children ~= new AssignmentNode(varName, expr);
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
                                loopNode.children ~= new FunctionCallNode(funcName, args);
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

                    writeln("Exited loop body at pos ", pos);
                    writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                        pos < tokens.length ? tokens[pos].value : "", "')");
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;
                    currentScope = funcNode;
                    funcNode.children ~= loopNode;
                    break;

                case TokenType.RETURN:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                    
                    string returnExpr;
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        returnExpr ~= tokens[pos].value;
                        pos++;
                    }
                    
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after return statement");
                    pos++;
                    
                    funcNode.children ~= new ReturnNode(returnExpr);
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

            writeln("Exited function body at pos ", pos);
            writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                pos < tokens.length ? tokens[pos].value : "", "')");
            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after function body");
            pos++;
            assert(pos > startPos, "Parser must advance position");
            startPos = pos;
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
    assert((cast(IfNode) loopAst.children[0].children[0].children[0]).condition == "x == 0");

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
    assert((cast(IfNode) funcAst.children[0].children[0]).condition == "y == 1");
}
