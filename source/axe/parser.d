module axe.parser;

import std.exception : enforce;
import std.conv;
import std.string;
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
            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "*")
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
                    else
                    {
                        args ~= "int " ~ argName;
                    }
                }
                else
                {
                    enforce(false, "Unexpected token in argument list");
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

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE, "Expected '{' after main");
            pos++;

            ASTNode mainNode = ASTNode("Main", [], "");
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

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after function arguments");
                                pos++;
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after function call");
                                pos++;
                                loopNode.children ~= ASTNode("FunctionCall", [], funcName);
                                break;
                            }

                        default:
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
                        "Expected '(' after function name");
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        "Expected ')' after function arguments");
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after function call");
                    pos++;
                    mainNode.children ~= ASTNode("FunctionCall", [], funcName);
                    break;

                default:
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

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        "Expected ')' after function arguments");
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after function call");
                    pos++;
                    funcNode.children ~= ASTNode("FunctionCall", [], callName);
                    break;

                default:
                    enforce(false, "Unexpected token in function body at position " ~ to!string(pos));
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
            enforce(false, "Unexpected token at top level: " ~ tokens[pos].value);
        }
    }

    return ast;
}
