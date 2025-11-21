/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * Contains struct and model definitions.
 */

module axe.structs;

import std.array;

/** 
 * Token types for the Axe language.
 */
enum TokenType
{
    MAIN,
    PRINTLN,
    PRINT,
    LOOP,
    BREAK,
    STR,
    CHAR,
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
    FOR,
    CONTINUE,
    IN,
    EXTERNAL,
    REF,
    ENUM,
    AND,
    OR,
    XOR,
    MOD,
    MACRO,
    OVERLOAD,
    TEST,
    ASSERT,
    PLATFORM,
    PARALLEL,
    SINGLE,
    WINDOWS,
    POSIX,
    TO,
    REDUCE,
    INTERPOLATED_STR,
    OPAQUE,
    EXTERN,
    UNSAFE,
    STAR_DOT,
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
 * Some macro definition.
 */
struct MacroDef
{
    string[] params;
    Token[] bodyTokens;
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

class OverloadNode : ASTNode
{
    string name;
    string paramName;
    string callExpr;
    string[] typeNames;
    string[] targetFunctions;

    this(string name, string paramName, string callExpr, string[] typeNames, string[] targetFunctions)
    {
        super("Overload");
        this.name = name;
        this.paramName = paramName;
        this.callExpr = callExpr;
        this.typeNames = typeNames;
        this.targetFunctions = targetFunctions;
    }
}

class DeclarationNode : ASTNode
{
    string name;
    bool isMutable;
    string initializer;
    string typeName;

    // Number of 'ref' modifiers (0 = not a reference, 1 = ref, 2 = ref ref, etc.)
    int refDepth;

    this(string name, bool isMutable, string initializer = "", string typeName = "", int refDepth = 0)
    {
        super("Declaration");
        this.name = name;
        this.isMutable = isMutable;
        this.initializer = initializer;
        this.typeName = typeName;
        this.refDepth = refDepth;
    }
}

class ArrayDeclarationNode : ASTNode
{
    string name;
    bool isMutable;
    string elementType;

    // Can be a number or expression
    string size;

    // For 2D arrays
    string size2;

    // For array literals like [1, 2, 3]
    string[] initializer;

    this(string name, bool isMutable, string elementType, string size, string[] initializer = [
        ], string size2 = "")
    {
        super("ArrayDeclaration");
        this.name = name;
        this.isMutable = isMutable;
        this.elementType = elementType;
        this.size = size;
        this.initializer = initializer;
        this.size2 = size2;
    }
}

class ArrayAccessNode : ASTNode
{
    string arrayName;
    string index;
    string index2;  // For 2D arrays

    this(string arrayName, string index, string index2 = "")
    {
        super("ArrayAccess");
        this.arrayName = arrayName;
        this.index = index;
        this.index2 = index2;
    }
}

class ArrayAssignmentNode : ASTNode
{
    string arrayName;
    string index;
    string index2;  // For 2D arrays
    string value;

    this(string arrayName, string index, string value, string index2 = "")
    {
        super("ArrayAssignment");
        this.arrayName = arrayName;
        this.index = index;
        this.index2 = index2;
        this.value = value;
    }
}

class ArrayLiteralNode : ASTNode
{
    string elementType;
    string[] elements;

    this(string elementType, string[] elements)
    {
        super("ArrayLiteral");
        this.elementType = elementType;
        this.elements = elements;
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

class MacroNode : ASTNode
{
    string name;
    string[] params;  // Parameter names
    string[] paramTypes;  // Parameter types (e.g., "untyped")
    Token[] bodyTokens;  // Store the macro body as tokens for expansion
    
    this(string name, string[] params, string[] paramTypes)
    {
        super("Macro");
        this.name = name;
        this.params = params;
        this.paramTypes = paramTypes;
    }
}

class TestNode : ASTNode
{
    this()
    {
        super("Test");
    }
}

class AssertNode : ASTNode
{
    string condition;
    string message;
    
    this(string condition, string message)
    {
        super("Assert");
        this.condition = condition;
        this.message = message;
    }
}

class IfNode : ASTNode
{
    string condition;

    // Array of IfNode for elif branches
    ASTNode[] elifBranches;

    // Statements in else block
    ASTNode[] elseBody;

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
    string[] messages;
    bool[] isExpressions;

    // Backward compatibility: single message constructor
    this(string message, bool isExpression = false)
    {
        super("Println");
        this.messages = [message];
        this.isExpressions = [isExpression];
    }

    // Multiple arguments constructor
    this(string[] messages, bool[] isExpressions)
    {
        super("Println");
        this.messages = messages;
        this.isExpressions = isExpressions;
    }
}

class PrintNode : ASTNode
{
    string[] messages;
    bool[] isExpressions;

    // Backward compatibility: single message constructor
    this(string message, bool isExpression = false)
    {
        super("Print");
        this.messages = [message];
        this.isExpressions = [isExpression];
    }

    // Multiple arguments constructor
    this(string[] messages, bool[] isExpressions)
    {
        super("Print");
        this.messages = messages;
        this.isExpressions = isExpressions;
    }
}

class BreakNode : ASTNode
{
    this()
    {
        super("Break");
    }
}

class ContinueNode : ASTNode
{
    this()
    {
        super("Continue");
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
        
        // Smart split that respects nested structures
        this.args = splitArgs(argsStr);
    }
    
    private static string[] splitArgs(string argsStr)
    {
        import std.string;
        
        string[] result;
        string current = "";
        int parenDepth = 0;
        int bracketDepth = 0;
        int braceDepth = 0;
        bool inInterpolated = false;
        
        for (size_t i = 0; i < argsStr.length; i++)
        {
            char c = argsStr[i];
            
            // Check for __INTERPOLATED__ markers
            if (i + 16 <= argsStr.length && argsStr[i .. i + 16] == "__INTERPOLATED__")
            {
                inInterpolated = !inInterpolated;
                // Add the marker to current
                current ~= "__INTERPOLATED__";
                i += 15; // Skip the rest of the marker (loop will increment by 1)
                continue;
            }
            
            if (c == '(')
                parenDepth++;
            else if (c == ')')
                parenDepth--;
            else if (c == '[')
                bracketDepth++;
            else if (c == ']')
                bracketDepth--;
            else if (c == '{')
                braceDepth++;
            else if (c == '}')
                braceDepth--;
            else if (c == ',' && parenDepth == 0 && bracketDepth == 0 && 
                braceDepth == 0 && !inInterpolated)
            {
                // This is an argument separator
                result ~= current.strip();
                current = "";
                
                // Skip the space after comma if present
                if (i + 1 < argsStr.length && argsStr[i + 1] == ' ')
                    i++;
                continue;
            }
            
            current ~= c;
        }
        
        if (current.length > 0)
            result ~= current.strip();
        
        return result;
    }
}

class InterpolatedStringNode : ASTNode
{
    string[] parts;        // String literal parts
    string[] expressions;  // Expressions to interpolate

    this(string[] parts, string[] expressions)
    {
        super("InterpolatedString");
        this.parts = parts;
        this.expressions = expressions;
    }
}

class LoopNode : ASTNode
{
    this()
    {
        super("Loop");
    }
}

class ForNode : ASTNode
{
    string initialization; // e.g., "mut val i = 0"
    string condition; // e.g., "i < 10"
    string increment; // e.g., "i++"
    bool isMutable; // whether the loop variable is mutable
    string varName; // loop variable name
    string varType; // loop variable type
    string initValue; // initial value
    bool isParallel; // whether this is a parallel for loop
    string[] reductionClauses; // reduction clauses like "+:sum"

    this(string initialization, string condition, string increment)
    {
        super("For");
        this.initialization = initialization;
        this.condition = condition;
        this.increment = increment;
        this.isParallel = false;
        this.reductionClauses = [];
    }
}

class ForInNode : ASTNode
{
    string varName; // loop variable name
    string arrayName; // array to iterate over
    string arraySize; // size of the array (for C code generation)

    this(string varName, string arrayName, string arraySize = "")
    {
        super("ForIn");
        this.varName = varName;
        this.arrayName = arrayName;
        this.arraySize = arraySize;
    }
}

class ParallelNode : ASTNode
{
    this()
    {
        super("Parallel");
    }
}

class SingleNode : ASTNode
{
    this()
    {
        super("Single");
    }
}

class ReturnNode : ASTNode
{
    string expression;
    ASTNode expressionNode; // For complex expressions like model instantiation

    this(string expression)
    {
        super("Return");
        this.expression = expression;
    }

    this(ASTNode expressionNode)
    {
        super("Return");
        this.expressionNode = expressionNode;
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
    string[string] functionPrefixes;
    bool importAll;
    
    this(string moduleName, string[] imports, bool importAll = false)
    {
        super("Use");
        this.moduleName = moduleName;
        this.imports = imports;
        this.importAll = importAll;
    }
}

class ModelNode : ASTNode
{
    string name;

    // Array of (fieldName, fieldType) tuples to preserve order
    struct Field {
        string name;
        string type;
        bool isUnion; // Flag to indicate if the field is a union
        Field[] nestedFields; // List of nested fields for union types

        this(string name, string type)
        {
            this.name = name;
            this.type = type;
            this.isUnion = false;
            this.nestedFields = null;
        }
    }

    Field[] fields;
    FunctionNode[] methods;

    this(string name, string[string] fieldsMap)
    {
        super("Model");
        this.name = name;
        // Convert map to ordered array (order will be arbitrary from map)
        // Parser should set fields array directly to preserve source order
        foreach (fieldName, fieldType; fieldsMap)
        {
            fields ~= Field(fieldName, fieldType);
        }
    }
}

class EnumNode : ASTNode
{
    string name;
    string[] values;

    this(string name, string[] values)
    {
        super("Enum");
        this.name = name;
        this.values = values;
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

class ExternalImportNode : ASTNode
{
    string headerFile;

    this(string headerFile)
    {
        super("ExternalImport");
        this.headerFile = headerFile;
    }
}

class OpaqueNode : ASTNode
{
    string[] typeNames;

    this(string[] typeNames)
    {
        super("Opaque");
        this.typeNames = typeNames;
    }
}

class ExternNode : ASTNode
{
    string functionName;
    string[] params;
    string returnType;

    this(string functionName, string[] params, string returnType)
    {
        super("Extern");
        this.functionName = functionName;
        this.params = params;
        this.returnType = returnType;
    }
}

class UnsafeNode : ASTNode
{
    ASTNode[] body;

    this(ASTNode[] body)
    {
        super("Unsafe");
        this.body = body;
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

    // true for ++, false for --
    bool isIncrement;

    this(string variable, bool isIncrement)
    {
        super("IncrementDecrement");
        this.variable = variable;
        this.isIncrement = isIncrement;
    }
}

class MemberIncrementDecrementNode : ASTNode
{
    string objectName;
    string memberName;

    // true for ++, false for --
    bool isIncrement;

    this(string objectName, string memberName, bool isIncrement)
    {
        super("MemberIncrementDecrement");
        this.objectName = objectName;
        this.memberName = memberName;
        this.isIncrement = isIncrement;
    }
}

class Scope
{
    string[string] variables;
    bool[string] mutability;
    Scope parent;

    this(Scope parent = null)
    {
        variables = null;
        mutability = null;
        this.parent = parent;
    }

    void addVariable(string name, bool isMutable)
    {
        variables[name] = "int";
        mutability[name] = isMutable;
    }

    bool isDeclared(string name)
    {
        if ((name in variables) !is null)
            return true;
        if (parent !is null)
            return parent.isDeclared(name);
        return false;
    }

    bool isMutable(string name)
    {
        if ((name in mutability) !is null)
            return mutability[name];
        if (parent !is null)
            return parent.isMutable(name);
        return false;
    }
}

class PlatformNode : ASTNode
{
    string platform;
    
    this(string platform)
    {
        super("Platform");
        this.platform = platform;
    }
}

class ParallelForNode : ASTNode
{
    string initialization;
    string condition;
    string increment;
    string[] reductionClauses;
    
    this(string init, string cond, string incr)
    {
        super("ParallelFor");
        this.initialization = init;
        this.condition = cond;
        this.increment = incr;
        this.reductionClauses = [];
    }
}
