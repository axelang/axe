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
    RAW,
    COMMENT,
    USE,
    MODEL,
    NEW,
    EQUALS,
    SWITCH,
    CASE,
    DEFAULT,
    INCREMENT,
    DECREMENT,
    ELSE,
    ELIF,
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
    string typeName;

    this(string name, bool isMutable, string initializer = "", string typeName = "")
    {
        super("Declaration");
        this.name = name;
        this.isMutable = isMutable;
        this.initializer = initializer;
        this.typeName = typeName;
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
    ASTNode[] elifBranches;  // Array of IfNode for elif branches
    ASTNode[] elseBody;      // Statements in else block

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
    bool isExpression;

    this(string message, bool isExpression = false)
    {
        super("Println");
        this.message = message;
        this.isExpression = isExpression;
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

class RawCNode : ASTNode
{
    string code;

    this(string code)
    {
        super("RawC");
        this.code = code;
    }
}

class UseNode : ASTNode
{
    string moduleName;
    string[] imports;

    this(string moduleName, string[] imports)
    {
        super("Use");
        this.moduleName = moduleName;
        this.imports = imports;
    }
}

class ModelNode : ASTNode
{
    string name;

    // field name -> type
    string[string] fields;

    this(string name, string[string] fields)
    {
        super("Model");
        this.name = name;
        this.fields = fields;
    }
}

class ModelInstantiationNode : ASTNode
{
    string modelName;
    string variableName;
    bool isMutable;

    // field name -> value
    string[string] fieldValues;

    this(string modelName, string variableName, string[string] fieldValues, bool isMutable = false)
    {
        super("ModelInstantiation");
        this.modelName = modelName;
        this.variableName = variableName;
        this.fieldValues = fieldValues;
        this.isMutable = isMutable;
    }
}

class MemberAccessNode : ASTNode
{
    string objectName;
    string memberName;

    // empty for reads, filled for writes
    string value;

    this(string objectName, string memberName, string value = "")
    {
        super("MemberAccess");
        this.objectName = objectName;
        this.memberName = memberName;
        this.value = value;
    }
}

class SwitchNode : ASTNode
{
    string expression;

    this(string expression)
    {
        super("Switch");
        this.expression = expression;
    }
}

class CaseNode : ASTNode
{
    string value;
    bool isDefault;

    this(string value, bool isDefault = false)
    {
        super("Case");
        this.value = value;
        this.isDefault = isDefault;
    }
}

class IncrementDecrementNode : ASTNode
{
    string variable;
    bool isIncrement; // true for ++, false for --

    this(string variable, bool isIncrement)
    {
        super("IncrementDecrement");
        this.variable = variable;
        this.isIncrement = isIncrement;
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
