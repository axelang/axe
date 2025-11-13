module axe.structs;

import std.array;

/** 
 * Token types for the Axe language.
 */
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
    RETURN,
    WHITESPACE,
    NEWLINE,
    LPAREN,
    RPAREN,
    LBRACKET,
    RBRACKET,
    COMMA,
    DOT,
    COLON,
    OPERATOR,
    IF,
    VAL,
    MUT,
    PLUS,
    MINUS,
    STAR,
    SLASH,
    PERCENT,
    CARET,
    AMPERSAND,
    PIPE,
    TILDE,
}

/** 
 * Token struct for the Axe language.
 */
struct Token
{
    TokenType type;
    string value;
}

/** 
 * Abstract syntax tree node for the Axe language.
 */
abstract class ASTNode
{
    string nodeType;
    ASTNode[] children;

    this(string type)
    {
        this.nodeType = type;
        this.children = [];
    }
}

class DeclarationNode : ASTNode
{
    string name;
    bool isMutable;
    string initializer;

    this(string name, bool isMutable, string initializer = "")
    {
        super("Declaration");
        this.name = name;
        this.isMutable = isMutable;
        this.initializer = initializer;
    }
}

class FunctionNode : ASTNode
{
    string name;
    string[] params;
    string returnType;

    this(string name, string[] params, string returnType = "void")
    {
        super("Function");
        this.name = name;
        this.params = params;
        this.returnType = returnType;
    }
}

class IfNode : ASTNode
{
    string condition;

    this(string condition)
    {
        super("If");
        this.condition = condition;
    }
}

class ProgramNode : ASTNode
{
    this()
    {
        super("Program");
    }
}

class PrintlnNode : ASTNode
{
    string message;

    this(string message)
    {
        super("Println");
        this.message = message;
    }
}

class BreakNode : ASTNode
{
    this()
    {
        super("Break");
    }
}

class AssignmentNode : ASTNode
{
    string variable;
    string expression;

    this(string variable, string expression)
    {
        super("Assignment");
        this.variable = variable;
        this.expression = expression;
    }
}

class FunctionCallNode : ASTNode
{
    string functionName;
    string[] args;

    this(string functionName, string argsStr)
    {
        super("FunctionCall");
        this.functionName = functionName;
        this.args = argsStr.split(", ");
    }
}

class LoopNode : ASTNode
{
    this()
    {
        super("Loop");
    }
}

class ReturnNode : ASTNode
{
    string expression;

    this(string expression)
    {
        super("Return");
        this.expression = expression;
    }
}

class Scope
{
    string[string] variables;
    bool[string] mutability;

    this()
    {
        variables = null;
        mutability = null;
    }

    void addVariable(string name, bool isMutable)
    {
        variables[name] = "int";
        mutability[name] = isMutable;
    }

    bool isDeclared(string name)
    {
        return (name in variables) !is null;
    }

    bool isMutable(string name)
    {
        return mutability.get(name, false);
    }
}
