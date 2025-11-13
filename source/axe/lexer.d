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
            if (tokens.length > 0 && tokens[$ - 1].type == TokenType.IDENTIFIER)
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
            tokens ~= Token(TokenType.MINUS, "-");
            pos++;
            break;

        case '+':
            tokens ~= Token(TokenType.PLUS, "+");
            pos++;
            break;

        case '>':
            if (pos + 1 < source.length && source[pos + 1] == '=')
            {
                tokens ~= Token(TokenType.OPERATOR, ">=");
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
            else
            {
                tokens ~= Token(TokenType.OPERATOR, "<");
                pos++;
            }
            break;

        case '/':
            if (pos + 1 < source.length && source[pos + 1] == '/')
            {
                // Comment - skip until end of line
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

        case '"':
            size_t ending = source.indexOf('"', pos + 1);
            enforce(ending != -1, "Unterminated string");
            tokens ~= Token(TokenType.STR, source[pos + 1 .. ending]);
            pos = ending + 1;
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

        case ']':
            tokens ~= Token(TokenType.RBRACKET, "]");
            pos++;
            break;

        case '.':
            tokens ~= Token(TokenType.DOT, ".");
            pos++;
            break;

        case 'v':
            if (pos + 2 < source.length && source[pos .. pos + 3] == "val")
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
            if (pos + 2 < source.length && source[pos .. pos + 3] == "mut")
            {
                tokens ~= Token(TokenType.MUT, "mut");
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
            else if (pos + 7 <= source.length && source[pos .. pos + 7] == "println")
            {
                tokens ~= Token(TokenType.PRINTLN, "println");
                pos += 7;
            }
            else if (pos + 4 <= source.length && source[pos .. pos + 4] == "loop")
            {
                tokens ~= Token(TokenType.LOOP, "loop");
                pos += 4;
            }
            else if (pos + 5 <= source.length && source[pos .. pos + 5] == "break")
            {
                tokens ~= Token(TokenType.BREAK, "break");
                pos += 5;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "def")
            {
                tokens ~= Token(TokenType.DEF, "def");
                pos += 3;
            }
            else if (pos + 2 <= source.length && source[pos .. pos + 2] == "if")
            {
                tokens ~= Token(TokenType.IF, "if");
                pos += 2;
            }
            else if (pos + 6 <= source.length && source[pos .. pos + 6] == "return")
            {
                tokens ~= Token(TokenType.RETURN, "return");
                pos += 6;
            }
            else if (pos + 3 <= source.length && source[pos .. pos + 3] == "raw")
            {
                tokens ~= Token(TokenType.RAW, "raw");
                pos += 3;
            }
            else if (source[pos].isAlphaNum())
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

                enforce(false, "Unexpected character at position " ~ pos.to!string ~ ": " ~ source[pos .. pos + 1]);
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
        auto tokens = lex("println \"hello\";");
        assert(tokens.length == 3);
        assert(tokens[0].type == TokenType.PRINTLN);
        assert(tokens[1].type == TokenType.STR);
        assert(tokens[1].value == "hello");
        assert(tokens[2].type == TokenType.SEMICOLON);
    }
    {
        import axe.parser;

        auto tokens = lex("main { println \"test\"; }");
        auto ast = parse(tokens);
        assert(ast.nodeType == "Program");
        assert(ast.children.length == 1);
        assert(ast.children[0].nodeType == "Function");
        assert(ast.children[0].children[0].nodeType == "Println");
        assert((cast(PrintlnNode) ast.children[0].children[0]).message == "test");
    }
}
