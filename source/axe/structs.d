module axe.structs;

enum TokenType
{
    MAIN,
    PRINTLN,
    LOOP,
    BREAK,
    STR,
    SEMICOLON,
    LBRACE,
    RBRACE,
    DEF,
    IDENTIFIER,
    WHITESPACE,
    NEWLINE,
    LPAREN,
    RPAREN,
    LBRACKET,
    RBRACKET,
    COMMA,
    DOT,
    COLON,
    OPERATOR
}

struct Token
{
    TokenType type;
    string value;
}

struct ASTNode
{
    string nodeType;
    ASTNode[] children;
    string value;
}
