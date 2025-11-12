module axe.lexer;

import std.exception;
import std.string;
import std.algorithm.iteration;
import axe.structs;

/**
 * Lexical analysis and tokenization
 * Includes whitespace skipping, tokenization, and string handling
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
                enforce(false, "Unexpected '*'");
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

        case ']':
            tokens ~= Token(TokenType.RBRACKET, "]");
            pos++;
            break;

        case '.':
            tokens ~= Token(TokenType.DOT, ".");
            pos++;
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
                enforce(false, "Unexpected character: " ~ source[pos .. pos + 1]);
            }
        }
    }

    return tokens;
}
