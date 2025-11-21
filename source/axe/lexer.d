/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * Handles the lexical analysis and tokenization process.
 */

module axe.lexer;

import std.exception;
import std.string;
import std.algorithm.iteration;
import axe.structs;

/**
 * Lexical analysis and tokenization.
 * Includes whitespace skipping, tokenization, and string handling.
 */
Token[] lex(string source)
{
    import std.ascii;

    Token[] tokens;
    size_t pos = 0;

    while (pos < source.length)
    {
        switch (source[pos])
        {
        case '*':
            // Check for *. (pointer member access)
            if (pos + 1 < source.length && source[pos + 1] == '.')
            {
                tokens ~= Token(TokenType.STAR_DOT, "*.");
                pos += 2;
            }
            else if (tokens.length > 0 && tokens[$ - 1].type == TokenType.IDENTIFIER)
            {
                tokens[$ - 1].value ~= "*";
                pos++;
            }
            else
            {
                tokens ~= Token(TokenType.STAR, "*");
                pos++;
            }
            break;

        case ' ', '\t', '\r':
            tokens ~= Token(TokenType.WHITESPACE, source[pos .. pos + 1]);
            pos++;
            break;

        case '\n':
            tokens ~= Token(TokenType.NEWLINE, "\n");
            pos++;
            break;

        case '{':
            tokens ~= Token(TokenType.LBRACE, "{");
            pos++;
            break;

        case '}':
            tokens ~= Token(TokenType.RBRACE, "}");
            pos++;
            break;

        case ';':
            tokens ~= Token(TokenType.SEMICOLON, ";");
            pos++;
            break;

        case ':':
            tokens ~= Token(TokenType.COLON, ":");
            pos++;
            break;

        case '!':
            if (pos + 1 < source.length && source[pos + 1] == '=')
            {
                tokens ~= Token(TokenType.OPERATOR, "!=");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.OPERATOR, "!");
                pos++;
            }
            break;

        case '=':
            if (pos + 1 < source.length && source[pos + 1] == '=')
            {
                tokens ~= Token(TokenType.OPERATOR, "==");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.OPERATOR, "=");
                pos++;
            }
            break;

        case '-':
            if (pos + 1 < source.length && source[pos + 1] == '-')
            {
                tokens ~= Token(TokenType.DECREMENT, "--");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.MINUS, "-");
                pos++;
            }
            break;

        case '+':
            if (pos + 1 < source.length && source[pos + 1] == '+')
            {
                tokens ~= Token(TokenType.INCREMENT, "++");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.PLUS, "+");
                pos++;
            }
            break;

        case '>':
            if (pos + 1 < source.length && source[pos + 1] == '=')
            {
                tokens ~= Token(TokenType.OPERATOR, ">=");
                pos += 2;
            }
            else if (pos + 1 < source.length && source[pos + 1] == '>')
            {
                tokens ~= Token(TokenType.OPERATOR, ">>");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.OPERATOR, ">");
                pos++;
            }
            break;

        case '<':
            if (pos + 1 < source.length && source[pos + 1] == '=')
            {
                tokens ~= Token(TokenType.OPERATOR, "<=");
                pos += 2;
            }
            else if (pos + 1 < source.length && source[pos + 1] == '<')
            {
                tokens ~= Token(TokenType.OPERATOR, "<<");
                pos += 2;
            }
            else
            {
                tokens ~= Token(TokenType.OPERATOR, "<");
                pos++;
            }
            break;

        case '/':
            if (pos + 1 < source.length && source[pos + 1] == '/')
            {
                size_t start = pos;
                while (pos < source.length && source[pos] != '\n')
                {
                    pos++;
                }
                tokens ~= Token(TokenType.COMMENT, source[start .. pos]);
            }
            else
            {
                tokens ~= Token(TokenType.SLASH, "/");
                pos++;
            }
            break;

        case '&':
            tokens ~= Token(TokenType.OPERATOR, "&");
            pos++;
            break;

        case '|':
            tokens ~= Token(TokenType.OPERATOR, "|");
            pos++;
            break;

        case '^':
            tokens ~= Token(TokenType.OPERATOR, "^");
            pos++;
            break;

        case '~':
            tokens ~= Token(TokenType.OPERATOR, "~");
            pos++;
            break;

        case '$':
            // Check if this is an interpolated string ($"...")
            if (pos + 1 < source.length && source[pos + 1] == '"')
            {
                import std.conv : to;

                pos++; // Skip '$'
                pos++; // Skip '"'

                // Find the end of the interpolated string
                size_t strStart = pos;
                size_t ending = pos;
                while (ending < source.length)
                {
                    if (source[ending] == '"' && (ending == 0 || source[ending - 1] != '\\'))
                    {
                        break;
                    }
                    else if (source[ending] == '\\' && ending + 1 < source.length)
                    {
                        ending += 2;
                    }
                    else
                    {
                        ending++;
                    }
                }

                enforce(ending < source.length,
                    "Unterminated interpolated string at position " ~ pos.to!string);

                string interpContent = source[strStart .. ending];

                tokens ~= Token(TokenType.INTERPOLATED_STR, interpContent);

                pos = ending + 1;
            }
            else
            {
                import std.conv;

                enforce(false, "Unexpected '$' at position " ~ pos.to!string);
            }
            break;

        case '"':
            {
                size_t ending = pos + 1;
                while (ending < source.length)
                {
                    if (source[ending] == '"')
                    {
                        break;
                    }
                    else if (source[ending] == '\\' && ending + 1 < source.length)
                    {
                        ending += 2;
                    }
                    else
                    {
                        ending++;
                    }
                }

                import std.conv;

                enforce(ending < source.length, "Unterminated string at position " ~ pos.to!string);
                tokens ~= Token(TokenType.STR, source[pos + 1 .. ending]);
                pos = ending + 1;
                break;
            }

        case '\'':
            size_t cend = source.indexOf('\'', pos + 1);
            enforce(cend != -1, "Unterminated character literal");
            auto clen = cend - (pos + 1);
            enforce(clen >= 1 && clen <= 10,
                "Character literals must contain between 1 and 10 characters");
            tokens ~= Token(TokenType.CHAR, source[pos + 1 .. cend]);
            pos = cend + 1;
            break;

        case '(', ')', ',':
            tokens ~= Token(
                source[pos] == '(' ? TokenType.LPAREN : source[pos] == ')' ? TokenType.RPAREN
                    : TokenType.COMMA,
                    source[pos .. pos + 1]
            );
            pos++;
            break;

        case '[':
            tokens ~= Token(TokenType.LBRACKET, "[");
            pos++;
            break;

        case ']':
            tokens ~= Token(TokenType.RBRACKET, "]");
            pos++;
            break;

        case '.':
            tokens ~= Token(TokenType.DOT, ".");
            pos++;
            break;

        case 'a':
            if (pos + 5 < source.length && source[pos .. pos + 6] == "assert" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.ASSERT, "assert");
                pos += 6;
            }
            else if (pos + 2 < source.length && source[pos .. pos + 3] == "and" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.AND, "and");
                pos += 3;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        case 'b':
            if (pos + 4 < source.length && source[pos .. pos + 5] == "break")
            {
                tokens ~= Token(TokenType.BREAK, "break");
                pos += 5;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        case 'd':
            if (pos + 6 < source.length && source[pos .. pos + 7] == "default" &&
                (pos + 7 >= source.length || !(source[pos + 7].isAlphaNum || source[pos + 7] == '_')))
            {
                tokens ~= Token(TokenType.DEFAULT, "default");
                pos += 7;
            }
            else if (pos + 2 < source.length && source[pos .. pos + 3] == "def" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.DEF, "def");
                pos += 3;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        case 't':
            if (pos + 3 < source.length && source[pos .. pos + 4] == "test" &&
                (pos + 4 >= source.length || !(source[pos + 4].isAlphaNum || source[pos + 4] == '_')))
            {
                tokens ~= Token(TokenType.TEST, "test");
                pos += 4;
            }
            else if (pos + 1 < source.length && source[pos .. pos + 2] == "to" &&
                (pos + 2 >= source.length || !(source[pos + 2].isAlphaNum || source[pos + 2] == '_')))
            {
                tokens ~= Token(TokenType.TO, "to");
                pos += 2;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        case 'v':
            if (pos + 2 < source.length && source[pos .. pos + 3] == "val" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.VAL, "val");
                pos += 3;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        case 'm':
            if (pos + 4 < source.length && source[pos .. pos + 5] == "macro" &&
                (pos + 5 >= source.length || !(source[pos + 5].isAlphaNum || source[pos + 5] == '_')))
            {
                tokens ~= Token(TokenType.MACRO, "macro");
                pos += 5;
            }
            else if (pos + 4 < source.length && source[pos .. pos + 5] == "model" &&
                (pos + 5 >= source.length || !(source[pos + 5].isAlphaNum || source[pos + 5] == '_')))
            {
                tokens ~= Token(TokenType.MODEL, "model");
                pos += 5;
            }
            else if (pos + 3 < source.length && source[pos .. pos + 4] == "main" &&
                (pos + 4 >= source.length || !(source[pos + 4].isAlphaNum || source[pos + 4] == '_')))
            {
                tokens ~= Token(TokenType.MAIN, "main");
                pos += 4;
            }
            else if (pos + 2 < source.length && source[pos .. pos + 3] == "mut" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.MUT, "mut");
                pos += 3;
            }
            else if (pos + 2 < source.length && source[pos .. pos + 3] == "mod" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.MOD, "mod");
                pos += 3;
            }
            else
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            break;

        default:
            if (pos + 4 <= source.length && source[pos .. pos + 4] == "main")
            {
                tokens ~= Token(TokenType.MAIN, "main");
                pos += 4;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "put" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.PRINT, "put");
                pos += 3;
            }
            else if (pos + 8 <= source.length && source[pos .. pos + 8] == "platform" &&
                (pos + 8 >= source.length || !(source[pos + 8].isAlphaNum || source[pos + 8] == '_')))
            {
                tokens ~= Token(TokenType.PLATFORM, "platform");
                pos += 8;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "opaque" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.OPAQUE, "opaque");
                pos += 6;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "extern" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.EXTERN, "extern");
                pos += 6;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "unsafe" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.UNSAFE, "unsafe");
                pos += 6;
            }
            else if (pos + 8 <= source.length && source[pos .. pos + 8] == "parallel" &&
                (pos + 8 >= source.length || !(source[pos + 8].isAlphaNum || source[pos + 8] == '_')))
            {
                tokens ~= Token(TokenType.PARALLEL, "parallel");
                pos += 8;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "single" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.SINGLE, "single");
                pos += 6;
            }
            else if (pos + 5 <= source.length && source[pos .. pos + 5] == "posix" &&
                (pos + 5 >= source.length || !(source[pos + 5].isAlphaNum || source[pos + 5] == '_')))
            {
                tokens ~= Token(TokenType.POSIX, "posix");
                pos += 5;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "loop")
            {
                tokens ~= Token(TokenType.LOOP, "loop");
                pos += 4;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "for" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.FOR, "for");
                pos += 3;
            }
            else if (pos + 8 <= source.length && source[pos .. pos + 8] == "continue")
            {
                tokens ~= Token(TokenType.CONTINUE, "continue");
                pos += 8;
            }
            else if (pos + 5 <= source.length && source[pos .. pos + 5] == "break")
            {
                tokens ~= Token(TokenType.BREAK, "break");
                pos += 5;
            }
            else if (pos + 5 <= source.length && source[pos .. pos + 5] == "model")
            {
                tokens ~= Token(TokenType.MODEL, "model");
                pos += 5;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "new" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.NEW, "new");
                pos += 3;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "elif")
            {
                tokens ~= Token(TokenType.ELIF, "elif");
                pos += 4;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "else")
            {
                tokens ~= Token(TokenType.ELSE, "else");
                pos += 4;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "reduce" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.REDUCE, "reduce");
                pos += 6;
            }
            else if (pos + 2 <= source.length && source[pos .. pos + 2] == "in" &&
                (pos + 2 >= source.length || !(source[pos + 2].isAlphaNum || source[pos + 2] == '_')))
            {
                tokens ~= Token(TokenType.IN, "in");
                pos += 2;
            }
            else if (pos + 2 <= source.length && source[pos .. pos + 2] == "if" &&
                (pos + 2 >= source.length || !(source[pos + 2].isAlphaNum || source[pos + 2] == '_')))
            {
                tokens ~= Token(TokenType.IF, "if");
                pos += 2;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "return")
            {
                tokens ~= Token(TokenType.RETURN, "return");
                pos += 6;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "ref" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.REF, "ref");
                pos += 3;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "raw")
            {
                tokens ~= Token(TokenType.RAW, "raw");
                pos += 3;

                // Skip whitespace and find opening brace
                while (pos < source.length && (source[pos] == ' ' || source[pos] == '\t' ||
                        source[pos] == '\n' || source[pos] == '\r'))
                {
                    if (source[pos] == '\n')
                        tokens ~= Token(TokenType.NEWLINE, "\n");
                    else if (source[pos] == ' ' || source[pos] == '\t')
                        tokens ~= Token(TokenType.WHITESPACE, [source[pos]]);
                    pos++;
                }

                // If we find '{', skip the entire raw block content
                if (pos < source.length && source[pos] == '{')
                {
                    tokens ~= Token(TokenType.LBRACE, "{");
                    pos++;

                    // Find matching closing brace, tracking depth
                    int braceDepth = 1;
                    size_t contentStart = pos;
                    while (pos < source.length && braceDepth > 0)
                    {
                        if (source[pos] == '{')
                            braceDepth++;
                        else if (source[pos] == '}')
                        {
                            braceDepth--;
                            if (braceDepth == 0)
                                break;
                        }
                        pos++;
                    }

                    // Store the raw content as a single IDENTIFIER token (parser will handle it)
                    if (pos > contentStart)
                    {
                        string rawContent = source[contentStart .. pos];
                        tokens ~= Token(TokenType.IDENTIFIER, rawContent);
                    }

                    // Add closing brace
                    if (pos < source.length && source[pos] == '}')
                    {
                        tokens ~= Token(TokenType.RBRACE, "}");
                        pos++;
                    }
                }
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "use" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.USE, "use");
                pos += 3;
            }
            else if (pos + 8 <= source.length && source[pos .. pos + 8] == "overload" &&
                (pos + 8 >= source.length || !(source[pos + 8].isAlphaNum || source[pos + 8] == '_')))
            {
                tokens ~= Token(TokenType.OVERLOAD, "overload");
                pos += 8;
            }
            else if (pos + 8 <= source.length && source[pos .. pos + 8] == "external" &&
                (pos + 8 >= source.length || !(source[pos + 8].isAlphaNum || source[pos + 8] == '_')))
            {
                tokens ~= Token(TokenType.EXTERNAL, "external");
                pos += 8;
            }
            else if (pos + 7 <= source.length && source[pos .. pos + 7] == "windows" &&
                (pos + 7 >= source.length || !(source[pos + 7].isAlphaNum || source[pos + 7] == '_')))
            {
                tokens ~= Token(TokenType.WINDOWS, "windows");
                pos += 7;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "switch" &&
                (pos + 6 >= source.length || !(source[pos + 6].isAlphaNum || source[pos + 6] == '_')))
            {
                tokens ~= Token(TokenType.SWITCH, "switch");
                pos += 6;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "case" &&
                (pos + 4 >= source.length || !(source[pos + 4].isAlphaNum || source[pos + 4] == '_')))
            {
                tokens ~= Token(TokenType.CASE, "case");
                pos += 4;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "enum" &&
                (pos + 4 >= source.length || !(source[pos + 4].isAlphaNum || source[pos + 4] == '_')))
            {
                tokens ~= Token(TokenType.ENUM, "enum");
                pos += 4;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "and" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.AND, "and");
                pos += 3;
            }
            else if (pos + 2 <= source.length && source[pos .. pos + 2] == "or" &&
                (pos + 2 >= source.length || !(source[pos + 2].isAlphaNum || source[pos + 2] == '_')))
            {
                tokens ~= Token(TokenType.OR, "or");
                pos += 2;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "xor" &&
                (pos + 3 >= source.length || !(source[pos + 3].isAlphaNum || source[pos + 3] == '_')))
            {
                tokens ~= Token(TokenType.XOR, "xor");
                pos += 3;
            }
            else if (source[pos] == '0' && pos + 1 < source.length &&
                (source[pos + 1] == 'x' || source[pos + 1] == 'X'))
            {
                // Handle hex literals: 0x1A, 0xFF, 0x90befffa, etc.
                size_t start = pos;
                pos += 2; // Skip '0x'
                while (pos < source.length && ((source[pos] >= '0' && source[pos] <= '9') ||
                        (source[pos] >= 'a' && source[pos] <= 'f') ||
                        (source[pos] >= 'A' && source[pos] <= 'F')))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            else if (source[pos].isAlphaNum() || source[pos] == '_')
            {
                size_t start = pos;
                while (pos < source.length && (source[pos].isAlphaNum() || source[pos] == '_'))
                {
                    pos++;
                }
                tokens ~= Token(TokenType.IDENTIFIER, source[start .. pos]);
            }
            else
            {
                import std.conv;

                enforce(false, "Unexpected character at position " ~ pos.to!string ~ ": " ~ source[pos .. pos + 1] ~
                        "\nFull context: " ~ source[pos - 10 .. pos + 10]);
            }
        }
    }

    import std.array;

    return tokens.filter!(t => t.type != TokenType.WHITESPACE
            && t.type != TokenType.NEWLINE
            && t.type != TokenType.COMMENT).array;
}

unittest
{
    import std.array;
    import std.stdio;

    {
        auto tokens = lex("if x == 0 { break; }");
        auto filtered = tokens.filter!(t => t.type != TokenType.WHITESPACE).array;
        assert(filtered.length == 8);
        assert(filtered[0].type == TokenType.IF);
        assert(filtered[0].value == "if");
        assert(filtered[1].type == TokenType.IDENTIFIER);
        assert(filtered[1].value == "x");
        assert(filtered[2].type == TokenType.OPERATOR);
        assert(filtered[2].value == "==");
        assert(filtered[3].type == TokenType.IDENTIFIER);
        assert(filtered[3].value == "0");
        assert(filtered[4].type == TokenType.LBRACE);
    }
    {
        auto tokens = lex("put \"hello\";");
        assert(tokens.length == 3);
        assert(tokens[0].type == TokenType.PRINT);
        assert(tokens[1].type == TokenType.STR);
        assert(tokens[1].value == "hello");
        assert(tokens[2].type == TokenType.SEMICOLON);
    }
    {
        import axe.parser;

        auto tokens = lex("main { put \"test\"; }");
        auto ast = parse(tokens);
        assert(ast.nodeType == "Program");
        assert(ast.children.length == 1);
        assert(ast.children[0].nodeType == "Function");
        assert(ast.children[0].children[0].nodeType == "Print");
        assert((cast(PrintNode) ast.children[0].children[0]).messages.length == 1);
        assert((cast(PrintNode) ast.children[0].children[0]).messages[0] == "test");
    }
}
