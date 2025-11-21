/** 
 * Axe Programming Language Compiler.
 * Author: Navid M (C) 2025
 * License: GPL-3.0
 * 
 * Handles the parsing process.
 */

module axe.parser;

import std.exception : enforce;
import std.conv;
import std.string;
import std.algorithm;
import axe.structs;
import axe.gstate;

private string[string] g_typeAliases;
private MacroDef[string] g_macros;
private bool[string] g_importedModules;

/**
 * Parses an array of tokens into an abstract syntax tree (AST).
 * 
 * Params:
 *   tokens = Array of tokens to parse
 *   isAxec = Whether the source file is .axec
 *   checkEntryPoint = Whether to validate that the file has an entry point (main/test)
 *   currentModule = Name of the module being parsed (e.g., "std.string") for auto-import
 * Returns: 
 *   ASTNode = Abstract syntax tree representing the parsed tokens
 */
ASTNode parse(Token[] tokens, bool isAxec = false, bool checkEntryPoint = true, string currentModule = "")
{
    import std.stdio;
    import std.exception : enforce;
    import std.conv;
    import std.string;
    import std.algorithm;
    import axe.structs : Scope;

    g_typeAliases.clear();

    if (currentModule.length > 0)
    {
        g_importedModules[currentModule] = true;
        debugWriteln("Auto-imported current module: ", currentModule);
    }

    debug
    {
        debugWriteln("Starting parse with tokens:");

        foreach (i, token; tokens)
            debugWriteln(i, ": ", token.type, " ('", token.value, "')");
    }

    if (!isAxec)
        enforceNoCKeys(tokens);

    size_t pos = 0;
    auto ast = new ProgramNode();
    Scope currentScope;
    currentScope = new Scope();

    /** 
     * Parses ref modifiers and returns the depth
     * e.g., "ref int" returns 1, "ref ref int" returns 2
     */
    int parseRefDepth()
    {
        int refDepth = 0;
        while (pos < tokens.length)
        {
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.REF)
            {
                refDepth++;
                pos++;
            }
            else
            {
                break;
            }
        }
        return refDepth;
    }

    /** 
     * Parses a type.
     * 
     * Returns: 
     *   string = Type name (e.g., "int", "char")
     */
    string parseType()
    {
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length, "Expected type after ':'");

        string refPrefix = "";
        while (pos < tokens.length && tokens[pos].type == TokenType.REF)
        {
            refPrefix ~= "ref ";
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }

        string typeName;
        if (tokens[pos].type == TokenType.IDENTIFIER)
        {
            typeName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
            {
                typeName ~= "[";
                pos++;

                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                {
                    typeName ~= tokens[pos].value;
                    pos++;
                }

                if (pos < tokens.length && tokens[pos].type == TokenType.RBRACKET)
                {
                    typeName ~= "]";
                    pos++;
                }
            }

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

        validateTypeNotForbidden(typeName);

        if (typeName in g_typeAliases)
        {
            typeName = g_typeAliases[typeName];
        }

        return refPrefix ~ typeName;
    }

    /** 
     * Parses array type and size (e.g., int[10] or int[])
     * 
     * Returns: 
     *   Tuple of (elementType, size) where size is empty string for unsized arrays
     */
    auto parseArrayType()
    {
        struct ArrayTypeInfo
        {
            string elementType;
            string size;
            string size2;
            bool hasSecondDimension;
        }

        string elementType = parseType();
        string size = "";
        string size2 = "";
        bool hasSecondDimension = false;

        if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
        {
            pos++; // Skip '['

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
            {
                size ~= tokens[pos].value;
                pos++;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                "Expected ']' after array size");
            pos++; // Skip ']'

            if (pos < tokens.length)
                debugWriteln("DEBUG parseArrayType: After first ], pos=", pos, " token=", tokens[pos].type, " value='", tokens[pos]
                        .value, "'");
            else
                debugWriteln("DEBUG parseArrayType: After first ], pos=", pos, " END OF TOKENS");

            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
            {
                debugWriteln("DEBUG parseArrayType: Found second [");
                hasSecondDimension = true;
                pos++; // Skip '['

                if (pos < tokens.length)
                    debugWriteln("DEBUG parseArrayType: After second [, token=", tokens[pos].type, " value='", tokens[pos]
                            .value, "'");

                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                {
                    debugWriteln("DEBUG parseArrayType: Adding to size2: '", tokens[pos].value, "'");
                    size2 ~= tokens[pos].value;
                    pos++;
                }

                debugWriteln("DEBUG parseArrayType: size2='", size2, "' hasSecondDimension=", hasSecondDimension);

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                    "Expected ']' after second array size");
                pos++; // Skip ']'
            }
        }

        return ArrayTypeInfo(elementType, size, size2, hasSecondDimension);
    }

    /** 
     * Parses println arguments (string literals or expressions, comma-separated)
     * 
     * Returns: 
     *   PrintlnNode = Node with messages and isExpression flags
     */
    PrintlnNode parsePrintln()
    {
        pos++;

        string[] messages;
        bool[] isExpressions;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
        {
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos >= tokens.length || tokens[pos].type == TokenType.SEMICOLON)
                break;

            if (tokens[pos].type == TokenType.STR)
            {
                string msg = tokens[pos].value;
                pos++;
                messages ~= msg;
                isExpressions ~= false;
            }
            else
            {
                string expr = "";
                while (pos < tokens.length &&
                    tokens[pos].type != TokenType.SEMICOLON &&
                    tokens[pos].type != TokenType.COMMA)
                {
                    if (tokens[pos].type == TokenType.STR)
                        expr ~= "\"" ~ tokens[pos].value ~ "\"";
                    else if (tokens[pos].type == TokenType.CHAR)
                        expr ~= "'" ~ tokens[pos].value ~ "'";
                    else if (tokens[pos].type == TokenType.DOT)
                        expr ~= ".";
                    else
                        expr ~= tokens[pos].value;
                    pos++;
                }
                if (expr.length > 0)
                {
                    messages ~= expr.strip();
                    isExpressions ~= true;
                }
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
            }
        }

        if (messages.length == 0)
            return new PrintlnNode("", false);

        return new PrintlnNode(messages, isExpressions);
    }

    /** 
     * Parses print arguments (string literals or expressions, comma-separated)
     * 
     * Returns: 
     *   PrintNode = Node with messages and isExpression flags
     */
    PrintNode parsePrint()
    {
        pos++;

        string[] messages;
        bool[] isExpressions;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
        {
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos >= tokens.length || tokens[pos].type == TokenType.SEMICOLON)
                break;

            if (tokens[pos].type == TokenType.STR)
            {
                string msg = tokens[pos].value;
                pos++;
                messages ~= msg;
                isExpressions ~= false;
            }
            else
            {
                string expr = "";
                while (pos < tokens.length &&
                    tokens[pos].type != TokenType.SEMICOLON &&
                    tokens[pos].type != TokenType.COMMA)
                {
                    if (tokens[pos].type == TokenType.STR)
                        expr ~= "\"" ~ tokens[pos].value ~ "\"";
                    else if (tokens[pos].type == TokenType.DOT)
                        expr ~= ".";
                    else
                        expr ~= tokens[pos].value;
                    pos++;
                }
                if (expr.length > 0)
                {
                    messages ~= expr.strip();
                    isExpressions ~= true;
                }
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
            }
        }

        if (messages.length == 0)
            return new PrintNode("", false);

        return new PrintNode(messages, isExpressions);
    }

    /**
     * Parse a simple statement (println or print) and return the node.
     * Handles the semicolon requirement.
     * Returns null if the current token is not a simple statement.
     */
    ASTNode parseSimpleStatement()
    {
        ASTNode result = null;

        if (tokens[pos].type == TokenType.PRINTLN)
        {
            result = parsePrintln();
        }
        else if (tokens[pos].type == TokenType.PRINT)
        {
            result = parsePrint();
        }
        else
        {
            return null;
        }

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after statement");
        pos++;

        return result;
    }

    ASTNode currentScopeNode = ast;

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
                else if (tokens[pos].type == TokenType.MUT || tokens[pos].type == TokenType
                    .IDENTIFIER)
                {
                    bool isMutable = false;
                    if (tokens[pos].type == TokenType.MUT)
                    {
                        isMutable = true;
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                            "Expected parameter name after 'mut'");
                    }

                    string paramName = tokens[pos].value;
                    pos++;
                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++;

                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        if (pos < tokens.length && tokens[pos].type == TokenType.MUT)
                        {
                            isMutable = true;
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                        }

                        string refPrefix = "";
                        if (pos < tokens.length && tokens[pos].type == TokenType.REF)
                        {
                            refPrefix = "ref ";
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                        }

                        size_t savedPos = pos;
                        string baseType = parseType();

                        if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                        {
                            pos = savedPos;
                            auto arrayInfo = parseArrayType();
                            debugWriteln("DEBUG parseArgs: elementType='", arrayInfo.elementType, "' size='", arrayInfo.size, "' size2='", arrayInfo
                                    .size2, "' hasSecondDimension=", arrayInfo.hasSecondDimension);
                            string fullType = refPrefix ~ arrayInfo.elementType;
                            if (arrayInfo.size.length > 0)
                                fullType ~= "[" ~ arrayInfo.size ~ "]";
                            else
                                fullType ~= "[]";

                            if (arrayInfo.hasSecondDimension)
                            {
                                if (arrayInfo.size2.length > 0)
                                    fullType ~= "[" ~ arrayInfo.size2 ~ "]";
                                else
                                    fullType ~= "[]";
                            }

                            debugWriteln("DEBUG parseArgs: fullType='", fullType, "' paramName='", paramName, "' isMutable=", isMutable);
                            string mutPrefix = isMutable ? "mut " : "";
                            string paramStr = mutPrefix ~ fullType ~ " " ~ paramName;
                            debugWriteln("DEBUG parseArgs: storing param as '", paramStr, "'");
                            args ~= paramStr;
                        }
                        else
                        {
                            string mutPrefix = isMutable ? "mut " : "";
                            string paramStr = mutPrefix ~ refPrefix ~ baseType ~ " " ~ paramName;
                            debugWriteln("DEBUG parseArgs: storing param as '", paramStr, "' (non-array, isMutable=", isMutable, ")");
                            args ~= paramStr;
                        }
                    }
                    else
                    {
                        args ~= paramName;
                    }

                    if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                        pos++;
                }
                else
                {
                    enforce(false, "Unexpected token in function arguments: " ~ tokens[pos].value ~ " (type: " ~
                            tokens[pos].type.to!string ~ ")");
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after function arguments");
            pos++;
        }

        return args;
    }

    while (pos < tokens.length)
    {
        debugWriteln("Current token at pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

        switch (tokens[pos].type)
        {
        case TokenType.PLATFORM:
            pos++; // Skip 'platform'

            enforce(pos < tokens.length && (tokens[pos].type == TokenType.WINDOWS ||
                    tokens[pos].type == TokenType.POSIX),
                "Expected 'windows' or 'posix' after 'platform'");
            string platformName = tokens[pos].value; // "windows" or "posix"
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after platform name");
            pos++; // Skip '{'

            auto platformNode = new PlatformNode(platformName);

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE)
                {
                    pos++;
                    continue;
                }

                // Platform blocks at top-level can contain DEF and other top-level constructs
                // We need to handle the parsing inline rather than using parseStatementHelper
                if (tokens[pos].type == TokenType.DEF)
                {
                    pos++; // Skip 'def'
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected function name after 'def'");
                    string funcName = tokens[pos].value;
                    pos++;

                    string[] params = parseArgs();
                    string returnType = "void";

                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        int refDepth = 0;
                        while (pos < tokens.length && tokens[pos].type == TokenType.REF)
                        {
                            refDepth++;
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                        }

                        returnType = parseType();
                        for (int i = 0; i < refDepth; i++)
                            returnType = "ref " ~ returnType;
                    }

                    auto funcNode = new FunctionNode(funcName, params, returnType);
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after function declaration");
                    pos++;

                    Scope funcScope = new Scope();
                    ASTNode funcScopeNode = funcNode;

                    // Register function parameters in the scope
                    foreach (param; params)
                    {
                        import std.string : split, strip;

                        auto parts = param.strip().split();
                        if (parts.length >= 2)
                        {
                            string paramName = parts[$ - 1];
                            // Check for both "mut " prefix and "ref " in type
                            // Check if param starts with "mut " or contains " ref " (with spaces to avoid false matches)
                            bool isMutable = param.startsWith("mut ") || param.canFind(" ref ") || param.startsWith(
                                "ref ");
                            debugWriteln("DEBUG: Registering parameter '", paramName, "' from param string '", param, "' as mutable=", isMutable);
                            funcScope.addVariable(paramName, isMutable);
                        }
                    }

                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        auto stmt = parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                        if (stmt !is null)
                            funcNode.children ~= stmt;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after function body");
                    pos++;

                    platformNode.children ~= funcNode;
                }
                else
                {
                    ASTNode platformScopeNode = platformNode;
                    auto stmt = parseStatementHelper(pos, tokens, currentScope, platformScopeNode, isAxec);
                    if (stmt !is null)
                        platformNode.children ~= stmt;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after platform block");
            pos++; // Skip '}'

            ast.children ~= platformNode;
            continue;

        case TokenType.MODEL:
            pos++; // Skip 'model'

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected model name after 'model'");
            string modelName = tokens[pos].value;
            pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after model name");
            pos++; // Skip '{'

            ModelNode.Field[] orderedFields;
            FunctionNode[] modelMethods;

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE)
                {
                    pos++;
                    continue;
                }

                if (tokens[pos].type == TokenType.DEF)
                {
                    pos++; // Skip 'def'

                    while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE ||
                            tokens[pos].type == TokenType.NEWLINE))
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected method name after 'def', full context: " ~ tokens[max(0, cast(int) pos - 5) .. pos]
                            .map!(t => t.value)
                            .join(""));
                    string methodName = tokens[pos].value;
                    pos++;

                    string[] params = parseArgs();
                    string returnType = "void";

                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        int refDepth = 0;
                        while (pos < tokens.length && tokens[pos].type == TokenType.REF)
                        {
                            refDepth++;
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                        }

                        returnType = parseType();
                        for (int i = 0; i < refDepth; i++)
                            returnType = "ref " ~ returnType;
                    }

                    string namespacedName = modelName ~ "_" ~ methodName;
                    auto funcNode = new FunctionNode(namespacedName, params, returnType);

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after method declaration");
                    pos++;

                    Scope methodScope = new Scope();

                    foreach (param; params)
                    {
                        import std.string : split, strip;

                        auto parts = param.strip().split();
                        if (parts.length >= 2)
                        {
                            string paramName = parts[$ - 1];
                            bool isMutable = param.startsWith("mut ") || param.canFind(" ref ") || param.startsWith(
                                "ref ");
                            methodScope.addVariable(paramName, isMutable);
                        }
                    }

                    ASTNode methodScopeNode = funcNode;

                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        auto stmt = parseStatementHelper(pos, tokens, methodScope, methodScopeNode, isAxec);
                        if (stmt !is null)
                            funcNode.children ~= stmt;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after method body");
                    pos++;

                    modelMethods ~= funcNode;
                }
                else if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string fieldName = tokens[pos].value;
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                        "Expected ':' after field name");
                    pos++; // Skip ':'

                    size_t savedPos = pos;
                    string baseType = parseType();

                    if (baseType == "union" && pos < tokens.length && tokens[pos].type == TokenType
                        .LBRACE)
                    {
                        ModelNode.Field unionField;
                        unionField.name = fieldName;
                        unionField.type = "union";
                        unionField.isUnion = true;

                        pos++; // Skip '{'
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE
                                || tokens[pos].type == TokenType.SEMICOLON)
                            {
                                pos++;
                                continue;
                            }

                            enforce(tokens[pos].type == TokenType.IDENTIFIER,
                                "Expected field name inside union block");
                            string innerName = tokens[pos].value;
                            pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                                "Expected ':' after union field name");
                            pos++; // Skip ':'

                            size_t innerSavedPos = pos;
                            string innerBaseType = parseType();
                            string innerFieldType;

                            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                            {
                                pos = innerSavedPos;
                                auto innerArrayInfo = parseArrayType();
                                innerFieldType = innerArrayInfo.elementType;
                                if (innerArrayInfo.size.length > 0)
                                    innerFieldType ~= "[" ~ innerArrayInfo.size ~ "]";
                                else
                                    innerFieldType ~= "[]";

                                if (innerArrayInfo.hasSecondDimension)
                                {
                                    if (innerArrayInfo.size2.length > 0)
                                        innerFieldType ~= "[" ~ innerArrayInfo.size2 ~ "]";
                                    else
                                        innerFieldType ~= "[]";
                                }
                            }
                            else
                            {
                                innerFieldType = innerBaseType;
                            }

                            ModelNode.Field innerField;
                            innerField.name = innerName;
                            innerField.type = innerFieldType;
                            unionField.nestedFields ~= innerField;

                            if (pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON)
                                pos++;
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after union field body");
                        pos++; // Skip '}'

                        orderedFields ~= unionField;
                    }
                    else
                    {
                        string fieldType;

                        if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                        {
                            pos = savedPos;
                            auto arrayInfo = parseArrayType();
                            fieldType = arrayInfo.elementType;
                            if (arrayInfo.size.length > 0)
                                fieldType ~= "[" ~ arrayInfo.size ~ "]";
                            else
                                fieldType ~= "[]";

                            if (arrayInfo.hasSecondDimension)
                            {
                                if (arrayInfo.size2.length > 0)
                                    fieldType ~= "[" ~ arrayInfo.size2 ~ "]";
                                else
                                    fieldType ~= "[]";
                            }
                        }
                        else
                        {
                            fieldType = baseType;
                        }

                        orderedFields ~= ModelNode.Field(fieldName, fieldType);
                    }
                }
                else
                {
                    pos++; // Skip other tokens
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after model body");
            pos++; // Skip '}'

            auto modelNode = new ModelNode(modelName, null);
            modelNode.fields = orderedFields;
            modelNode.methods = modelMethods;
            ast.children ~= modelNode;
            continue;
        case TokenType.ENUM:
            pos++; // Skip 'enum'

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected enum name after 'enum'");
            string enumName = tokens[pos].value;
            pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after enum name");
            pos++; // Skip '{'

            string[] enumValues;
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    enumValues ~= tokens[pos].value;
                    pos++;
                }
                // else if (tokens[pos].type == TokenType.COMMA)
                // {
                //     pos++; // Skip comma
                // }
                else
                {
                    pos++; // Skip whitespace/newlines
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after enum body");
            pos++; // Skip '}'

            ast.children ~= new EnumNode(enumName, enumValues);
            continue;

        case TokenType.USE:
            pos++; // Skip 'use'

            // Check if this is an external import: use external("header.h")
            if (pos < tokens.length && tokens[pos].type == TokenType.EXTERNAL)
            {
                pos++; // Skip 'external'

                enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                    "Expected '(' after 'external'");
                pos++; // Skip '('

                enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                    "Expected string literal for header file");
                string headerFile = tokens[pos].value;
                pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                    "Expected ')' after header file");
                pos++; // Skip ')'

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after external import");
                pos++; // Skip ';'

                ast.children ~= new ExternalImportNode(headerFile);
                continue;
            }

            string moduleName = "";

            while (pos < tokens.length && tokens[pos].type == TokenType.DOT)
            {
                size_t lookAhead = pos + 1;

                if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.DOT)
                {
                    lookAhead++;
                    if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.SLASH)
                    {
                        moduleName ~= "../";
                        pos = lookAhead + 1;
                        continue;
                    }
                }
                else if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.SLASH)
                {
                    moduleName ~= "./";
                    pos = lookAhead + 1;
                    continue;
                }

                break;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected module name after 'use'");
            moduleName ~= tokens[pos].value;
            pos++;

            // Handle module paths like "std.io" or "std/io" (dots or slashes)
            while (pos < tokens.length && (tokens[pos].type == TokenType.DOT || tokens[pos].type == TokenType
                    .SLASH))
            {
                if (tokens[pos].type == TokenType.DOT)
                {
                    moduleName ~= ".";
                }
                else
                {
                    moduleName ~= "/";
                }
                pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected identifier after '.' or '/' in module path");
                moduleName ~= tokens[pos].value;
                pos++;
            }

            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE))
                pos++;

            // Check for import all syntax: use module;
            if (pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON)
            {
                pos++; // Skip ';'
                ast.children ~= new UseNode(moduleName, [], true);
                g_importedModules[moduleName] = true;
                debugWriteln("Tracked import: ", moduleName);
                continue;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after module name");
            pos++; // Skip '('

            string[] imports;
            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                        .NEWLINE))
                    pos++;

                if (pos >= tokens.length || tokens[pos].type == TokenType.RPAREN)
                    break;

                if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    imports ~= tokens[pos].value;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.COMMA)
                {
                    pos++;
                }
                else
                {
                    enforce(false, "Unexpected token in use statement");
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after imports");
            pos++; // Skip ')'

            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after use statement");
            pos++; // Skip ';'

            string modulePrefix = moduleName.replace(".", "_"); // "stdlib_arena"

            // For each imported identifier, create a type alias
            foreach (importName; imports)
            {
                // Assume imports that start with uppercase are types
                if (importName.length > 0 && importName[0] >= 'A' && importName[0] <= 'Z')
                {
                    debugWriteln("Storing alias, ", importName, " -> ", modulePrefix ~ "_" ~ importName);
                    g_typeAliases[importName] = modulePrefix ~ "_" ~ importName;
                }
            }

            ast.children ~= new UseNode(moduleName, imports);
            g_importedModules[moduleName] = true;
            debugWriteln("Tracked import: ", moduleName);
            continue;

        case TokenType.OPAQUE:
            pos++; // Skip 'opaque'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'opaque'");
            pos++; // Skip '{'

            string[] opaqueTypes;
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                // Skip whitespace
                while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                    pos++;

                if (pos >= tokens.length || tokens[pos].type == TokenType.RBRACE)
                    break;

                if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    opaqueTypes ~= tokens[pos].value;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.COMMA)
                {
                    pos++; // Skip comma
                }
                else
                {
                    enforce(false, "Expected identifier or ',' in opaque declaration");
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after opaque type list");
            pos++; // Skip '}'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after opaque declaration");
            pos++; // Skip ';'

            ast.children ~= new OpaqueNode(opaqueTypes);
            continue;

        case TokenType.EXTERN:
            pos++; // Skip 'extern'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.DEF,
                "Expected 'def' after 'extern'");
            pos++; // Skip 'def'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected function name after 'extern def'");
            string externFuncName = tokens[pos].value;
            pos++;

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after extern function name");
            pos++; // Skip '('

            string[] externParams;
            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                // Skip whitespace
                while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                    pos++;

                if (pos >= tokens.length || tokens[pos].type == TokenType.RPAREN)
                    break;

                // Parse parameter: name: type
                string paramStr = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType.RPAREN)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
                    {
                        paramStr ~= tokens[pos].value;
                    }
                    else
                    {
                        paramStr ~= " ";
                    }
                    pos++;
                }

                if (paramStr.strip().length > 0)
                    externParams ~= paramStr.strip();

                if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                    pos++; // Skip comma
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after extern parameters");
            pos++; // Skip ')'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            string externReturnType = "";
            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
            {
                pos++; // Skip ':'

                // Skip whitespace
                while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                    pos++;

                // Parse return type
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
                    {
                        externReturnType ~= tokens[pos].value;
                    }
                    else if (externReturnType.length > 0)
                    {
                        externReturnType ~= " ";
                    }
                    pos++;
                }
                externReturnType = externReturnType.strip();
            }

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after extern declaration");
            pos++; // Skip ';'

            ast.children ~= new ExternNode(externFuncName, externParams, externReturnType);
            continue;

        case TokenType.UNSAFE:
            pos++; // Skip 'unsafe'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'unsafe'");
            pos++; // Skip '{'

            // Parse the body of the unsafe block
            ASTNode[] unsafeBody;
            int braceDepth = 1;
            size_t blockStart = pos;

            // Find the matching closing brace
            while (pos < tokens.length && braceDepth > 0)
            {
                if (tokens[pos].type == TokenType.LBRACE)
                    braceDepth++;
                else if (tokens[pos].type == TokenType.RBRACE)
                    braceDepth--;
                
                if (braceDepth > 0)
                    pos++;
            }

            enforce(braceDepth == 0, "Unclosed unsafe block");
            
            size_t blockEnd = pos;
            pos++; // Skip closing '}'

            // Parse the body tokens
            if (blockEnd > blockStart)
            {
                Token[] bodyTokens = tokens[blockStart .. blockEnd];
                unsafeBody = parse(bodyTokens).children;
            }

            ast.children ~= new UnsafeNode(unsafeBody);
            continue;

        case TokenType.MAIN:
            // Fall through to IDENTIFIER case which handles main
            goto case TokenType.IDENTIFIER;

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
                debugWriteln("Entering main block at pos ", pos);

                auto previousScope = currentScopeNode;
                currentScopeNode = mainNode;

                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                {
                    auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                    if (stmt !is null)
                        mainNode.children ~= stmt;
                }

                currentScopeNode = previousScope;

                // OLD CODE - keeping structure for reference
                static if (false)
                {
                    switch (tokens[pos].type)
                    {
                    case TokenType.PRINTLN:
                        mainNode.children ~= parsePrintln();
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after println");
                        pos++;
                        break;

                    case TokenType.PRINT:
                        mainNode.children ~= parsePrint();
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after print");
                        pos++;
                        break;

                    case TokenType.IDENTIFIER:
                        string identName = tokens[pos].value;
                        pos++;

                        // Skip whitespace
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        // Check if this is array indexing
                        if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                        {
                            pos++; // Skip '['

                            string index = "";
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                            {
                                index ~= tokens[pos].value;
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                "Expected ']' after array index");
                            pos++; // Skip ']'

                            // Check for second dimension (2D array)
                            string index2 = "";
                            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                            {
                                pos++; // Skip '['

                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .RBRACKET)
                                {
                                    index2 ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                    "Expected ']' after second array index");
                                pos++; // Skip ']'
                            }

                            // Check if this is array element assignment
                            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR &&
                                tokens[pos].value == "=")
                            {
                                pos++; // Skip '='

                                string value = "";
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    if (tokens[pos].type == TokenType.STR)
                                        value ~= "\"" ~ tokens[pos].value ~ "\"";
                                    else
                                        value ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after array assignment");
                                pos++;

                                mainNode.children ~= new ArrayAssignmentNode(identName, index.strip(), value.strip(), index2
                                        .strip());
                            }
                            else
                            {
                                enforce(false, "Array indexing without assignment not yet supported in statements");
                            }
                        }
                        // Check if this is an assignment
                else if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                        {
                            // Variable assignment
                            if (!currentScope.isDeclared(identName))
                            {
                                enforce(false, "Undeclared variable: " ~ identName);
                            }
                            pos++;

                            string expr = "";
                            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                            {
                                expr ~= tokens[pos].value;
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after assignment");
                            pos++;

                            mainNode.children ~= new AssignmentNode(identName, expr);
                        }
                        else if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                        {
                            // Function call
                            string args = "";
                            pos++;

                            int parenDepth = 0;
                            int bracketDepth = 0;
                            int braceDepth = 0;
                            bool lastWasRef = false;
                            while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                            {
                                if (tokens[pos].type == TokenType.LPAREN)
                                {
                                    parenDepth++;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.RPAREN)
                                {
                                    parenDepth--;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.LBRACKET)
                                {
                                    bracketDepth++;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.RBRACKET)
                                {
                                    bracketDepth--;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.LBRACE)
                                {
                                    braceDepth++;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.RBRACE)
                                {
                                    braceDepth--;
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.WHITESPACE)
                                {
                                    // Preserve space after 'ref' keyword
                                    if (lastWasRef)
                                    {
                                        args ~= " ";
                                        lastWasRef = false;
                                    }
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.COMMA &&
                                    bracketDepth == 0 && braceDepth == 0 && parenDepth == 0)
                                {
                                    args ~= ", ";
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.COMMA)
                                {
                                    // Comma inside brackets/braces/parens
                                    args ~= tokens[pos].value;
                                    lastWasRef = false;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.STR)
                                {
                                    args ~= "\"" ~ tokens[pos].value ~ "\"";
                                    lastWasRef = false;
                                    pos++;
                                }
                                else
                                {
                                    // Check if this token is 'ref'
                                    if (tokens[pos].value == "ref")
                                    {
                                        lastWasRef = true;
                                    }
                                    else
                                    {
                                        lastWasRef = false;
                                    }
                                    args ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                "Expected ')' after function arguments");
                            pos++; // Skip ')'

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after function call");
                            pos++; // Skip ';'

                            mainNode.children ~= new FunctionCallNode(identName, args);
                        }
                        else
                        {
                            enforce(false, "Expected '=' or '(' after identifier");
                        }
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
                            case TokenType.PRINTLN:
                                loopNode.children ~= parsePrintln();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++;
                                break;

                            case TokenType.PRINT:
                                loopNode.children ~= parsePrint();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after print");
                                pos++;
                                break;

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
                                ifNode.children ~= parsePrintln();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++; // Skip ';'
                                break;

                            case TokenType.PRINT:
                                ifNode.children ~= parsePrint();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after print");
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
                            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR
                                && tokens[pos].value == "=")
                            {
                                pos++;
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    initializer ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after val declaration");
                            pos++;

                            currentScope.addVariable(varName, isMutable);
                            mainNode.children ~= new DeclarationNode(varName, isMutable, initializer);
                        }
                        break;

                    case TokenType.RAW:
                        enforce(isAxec, "Raw C blocks are only allowed in .axec files");
                        pos++; // Skip 'raw'

                        // Skip whitespace/newlines
                        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                                .NEWLINE))
                            pos++;

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after 'raw'");
                        pos++; // Skip '{'

                        // Lexer provides raw content as single IDENTIFIER token
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                            "Expected raw code content");
                        string rawCode = tokens[pos].value;
                        pos++;

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after raw block");
                        pos++;

                        mainNode.children ~= new RawCNode(rawCode);
                        break;

                    default:
                        enforce(false, "Unexpected statement in main block: " ~ tokens[pos].value);
                    }
                }

                debugWriteln("Exited main block at pos ", pos);
                debugWriteln("Current token: ", pos < tokens.length ? to!string(
                        tokens[pos].type) : "EOF", " ('",
                    pos < tokens.length ? tokens[pos].value : "", "')");
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                    "Expected '}' after main body");
                pos++;

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                ast.children ~= mainNode;
                continue;
            }

            // Check if this is a macro invocation
            string identName = tokens[pos].value;
            if (identName in g_macros)
            {
                pos++; // Skip macro name
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                    "Expected '(' after macro name");
                pos++; // Skip '('

                // Parse macro arguments (handle comma-separated arguments properly)
                string[] macroArgs;
                string currentArg = "";
                int parenDepth = 0;
                bool hasContent = false; // Track if current arg has any non-whitespace content

                while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                {
                    if (tokens[pos].type == TokenType.LPAREN)
                    {
                        parenDepth++;
                        currentArg ~= tokens[pos].value;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.RPAREN)
                    {
                        parenDepth--;
                        if (parenDepth > 0)
                            currentArg ~= tokens[pos].value;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                    {
                        // Always add the argument, even if it's empty (for empty string literals)
                        macroArgs ~= currentArg.strip();
                        currentArg = "";
                        hasContent = false;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.WHITESPACE)
                    {
                        // Preserve whitespace within arguments, but don't add it between args
                        if (currentArg.length > 0 || parenDepth > 0)
                            currentArg ~= " ";
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.STR)
                    {
                        // String literals (including empty strings) are important
                        currentArg ~= "\"" ~ tokens[pos].value ~ "\"";
                        hasContent = true;
                        pos++;
                    }
                    else
                    {
                        currentArg ~= tokens[pos].value;
                        hasContent = true;
                        pos++;
                    }
                }

                // Add the last argument if there is one (even if empty)
                macroArgs ~= currentArg.strip();

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                    "Expected ')' after macro arguments");
                pos++; // Skip ')'

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after macro invocation");
                pos++; // Skip ';'

                // Expand macro
                auto macroDef = g_macros[identName];
                Token[] expandedTokens = macroDef.bodyTokens.dup;

                // Substitute parameters in the token stream
                // Use {{param}} syntax for explicit macro parameter substitution
                debugWriteln("DEBUG macro expansion: Substituting parameters for macro '", identName, "'");
                debugWriteln("  Macro params: ", macroDef.params);
                debugWriteln("  Macro args: ", macroArgs);
                macroArgs[2] = balanceParentheses(macroArgs[2]);
                foreach (ref token; expandedTokens)
                {
                    for (size_t i = 0; i < macroDef.params.length && i < macroArgs.length;
                        i++)
                    {
                        // Substitute in all token types that have string values
                        // Look for {{param}} pattern for explicit macro parameter substitution
                        if (token.value.length > 0)
                        {
                            import std.string : replace;

                            string pattern = "{{" ~ macroDef.params[i] ~ "}}";

                            if (token.value.canFind(pattern))
                            {
                                string oldValue = token.value;
                                debugWriteln("  DEBUG: Found pattern '", pattern, "' in token value (type: ", token
                                        .type, ")");
                                debugWriteln("    Token value: '", oldValue, "'");
                                // replace() in std.string replaces all occurrences
                                token.value = token.value.replace(pattern, macroArgs[i]);
                                if (oldValue != token.value)
                                {
                                    debugWriteln("  DEBUG: Replaced '", pattern, "' with '", macroArgs[i], "'");
                                    debugWriteln("    Result: '", token.value, "'");
                                }
                                else
                                {
                                    debugWriteln(
                                        "  DEBUG: WARNING - pattern found but replacement didn't change value!");
                                }
                            }
                            // Also support exact match for backward compatibility (but prefer {{param}})
                        else if (token.value == macroDef.params[i])
                            {
                                debugWriteln("  DEBUG: Exact match (legacy) - replacing '", token.value, "' with '", macroArgs[i], "'");
                                token.value = macroArgs[i];
                            }
                        }
                    }
                }

                // Parse the expanded tokens
                auto expandedAST = parse(expandedTokens, isAxec, false);
                foreach (child; expandedAST.children)
                {
                    ast.children ~= child;
                }

                continue;
            }

            goto default;

        case TokenType.TEST:
            pos++; // Skip 'test'
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            auto testNode = new TestNode();

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'test'");
            pos++;

            Scope testScope = new Scope();
            ASTNode testScopeNode = testNode;

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                auto stmt = parseStatementHelper(pos, tokens, testScope, testScopeNode, isAxec);
                if (stmt !is null)
                    testNode.children ~= stmt;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after test body");
            pos++;

            ast.children ~= testNode;
            continue;

        case TokenType.MACRO:
            pos++; // Skip 'macro'
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected macro name after 'macro'");
            string macroName = tokens[pos].value;
            pos++;

            // Parse macro parameters with types
            string[] macroParams;
            string[] macroParamTypes;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after macro name");
            pos++;

            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE)
                {
                    pos++;
                    continue;
                }

                if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string paramName = tokens[pos].value;
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                        "Expected ':' after macro parameter name");
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected type after ':' in macro parameter");
                    string paramType = tokens[pos].value;
                    pos++;

                    macroParams ~= paramName;
                    macroParamTypes ~= paramType;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                    {
                        pos++;
                    }
                }
                else
                {
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after macro parameters");
            pos++;

            auto macroNode = new MacroNode(macroName, macroParams, macroParamTypes);

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after macro declaration");
            pos++;

            // Store macro body tokens for later expansion (don't parse now)
            Token[] bodyTokens;
            int braceDepth = 1;

            while (pos < tokens.length && braceDepth > 0)
            {
                auto t = tokens[pos];

                if (t.type == TokenType.LBRACE)
                {
                    braceDepth++;
                    bodyTokens ~= t;
                    pos++;
                    continue;
                }
                else if (t.type == TokenType.RBRACE)
                {
                    braceDepth--;
                    if (braceDepth == 0)
                    {
                        pos++;
                        break;
                    }
                    bodyTokens ~= t;
                    pos++;
                    continue;
                }

                bodyTokens ~= t;
                pos++;
            }

            enforce(braceDepth == 0, "Expected '}' after macro body");
            macroNode.bodyTokens = bodyTokens;

            if (bodyTokens.length > 0)
            {
                size_t bodyPos = 0;
                while (bodyPos < bodyTokens.length)
                {
                    if (bodyTokens[bodyPos].type == TokenType.WHITESPACE ||
                        bodyTokens[bodyPos].type == TokenType.NEWLINE)
                    {
                        bodyPos++;
                        continue;
                    }

                    if (bodyTokens[bodyPos].type == TokenType.RAW)
                    {
                        bodyPos++; // Skip 'raw'

                        while (bodyPos < bodyTokens.length &&
                            (bodyTokens[bodyPos].type == TokenType.WHITESPACE ||
                                bodyTokens[bodyPos].type == TokenType.NEWLINE))
                            bodyPos++;

                        enforce(bodyPos < bodyTokens.length &&
                                bodyTokens[bodyPos].type == TokenType.LBRACE,
                                "Expected '{' after 'raw' in macro");
                        bodyPos++; // Skip '{'

                        enforce(bodyPos < bodyTokens.length &&
                                bodyTokens[bodyPos].type == TokenType.IDENTIFIER,
                                "Expected raw code content in macro");
                        string rawCode = bodyTokens[bodyPos].value;
                        bodyPos++;

                        enforce(bodyPos < bodyTokens.length &&
                                bodyTokens[bodyPos].type == TokenType.RBRACE,
                                "Expected '}' after raw block in macro");
                        bodyPos++;

                        macroNode.children ~= new RawCNode(rawCode);
                    }
                    else
                    {
                        bodyPos++;
                    }
                }
            }

            // Store macro for later expansion
            g_macros[macroName] = MacroDef(macroParams, bodyTokens);

            ast.children ~= macroNode;
            continue;

        case TokenType.OVERLOAD:
            pos++; // Skip 'overload'
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected overload name after 'overload'");
            string overloadName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after overload name");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected parameter name in overload");
            string paramName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            // Optional ': generic' annotation
            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected type after ':' in overload parameter");
                // We currently ignore the specific type name (e.g., 'generic')
                pos++;
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after overload parameter");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after overload header");
            pos++;

            string[] typeNames;
            string[] targetFuncs;

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                    pos++;
                if (pos < tokens.length && tokens[pos].type == TokenType.RBRACE)
                    break;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected type name in overload mapping");
                string typeName = tokens[pos].value;
                pos++;

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=>",
                    "Expected '=>' in overload mapping");
                pos++;

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected target function name in overload mapping");
                string targetName = tokens[pos].value;
                pos++;

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after overload mapping");
                pos++;

                typeNames ~= typeName;
                targetFuncs ~= targetName;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after overload mappings");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' with call expression after overload block");
            pos++;

            string callExpr;
            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                if (tokens[pos].type == TokenType.STR)
                    callExpr ~= "\"" ~ tokens[pos].value ~ "\"";
                else if (tokens[pos].type == TokenType.CHAR)
                    callExpr ~= "'" ~ tokens[pos].value ~ "'";
                else
                    callExpr ~= tokens[pos].value;
                pos++;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after overload call expression");
            pos++;

            auto overloadNode = new OverloadNode(overloadName, paramName, callExpr.strip(), typeNames, targetFuncs);
            ast.children ~= overloadNode;
            continue;

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
            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                // Handle ref keyword(s)
                int refDepth = 0;
                while (pos < tokens.length && tokens[pos].type == TokenType.REF)
                {
                    refDepth++;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                }

                returnType = parseType();
                for (int i = 0; i < refDepth; i++)
                    returnType = "ref " ~ returnType;
            }

            auto funcNode = new FunctionNode(currentFuncName, params, returnType);
            debugWriteln("DEBUG: Function '", currentFuncName, "' has ", params.length, " parameters:");
            foreach (p; params)
                debugWriteln("  DEBUG: param='", p, "'");
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after function declaration");
            pos++;

            // Create function scope and register parameters
            Scope funcScope = new Scope();
            ASTNode funcScopeNode = funcNode;

            // Register function parameters in the scope
            foreach (param; params)
            {
                import std.string : split, strip;

                auto parts = param.strip().split();
                if (parts.length >= 2)
                {
                    string paramName = parts[$ - 1];
                    // Check for both "mut " prefix and "ref " in type
                    // Check if param starts with "mut " or contains " ref " (with spaces to avoid false matches)
                    bool isMutable = param.startsWith("mut ") || param.canFind(" ref ") || param.startsWith(
                        "ref ");
                    debugWriteln("DEBUG: Registering parameter '", paramName, "' from param string '", param, "' as mutable=", isMutable);
                    funcScope.addVariable(paramName, isMutable);
                }
            }

            debugWriteln("Entering function body at pos ", pos);
            size_t startPos = pos;
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                debugWriteln("Function body pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

                switch (tokens[pos].type)
                {
                case TokenType.WHITESPACE, TokenType.NEWLINE:
                    pos++;
                    break;

                case TokenType.PRINTLN, TokenType.PRINT:
                    auto stmt = parseSimpleStatement();
                    if (stmt !is null)
                        funcNode.children ~= stmt;
                    break;

                case TokenType.MUT:
                case TokenType.VAL:
                    // Use parseStatementHelper for variable declarations to get proper scope handling
                    auto declNode = parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    if (declNode !is null)
                        funcNode.children ~= declNode;
                    break;

                case TokenType.IF:
                    // Use parseIfHelper to handle if/elif/else chains
                    auto ifNode = parseIfHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    funcNode.children ~= ifNode;
                    break;

                case TokenType.FOR:
                    // Use parseStatementHelper for for loops to get proper scope handling
                    auto forNode = parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    if (forNode !is null)
                        funcNode.children ~= forNode;
                    break;

                case TokenType.IDENTIFIER:
                    string identName = tokens[pos].value;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    if (pos < tokens.length && tokens[pos].type != TokenType.LPAREN &&
                        tokens[pos].type != TokenType.LBRACKET &&
                        tokens[pos].type != TokenType.DOT &&
                        tokens[pos].type != TokenType.STAR_DOT &&
                        !(tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=") &&
                        tokens[pos].type != TokenType.INCREMENT &&
                        tokens[pos].type != TokenType.DECREMENT)
                    {
                        size_t look = pos;
                        bool hasSemicolon = false;
                        while (look < tokens.length)
                        {
                            if (tokens[look].type == TokenType.SEMICOLON)
                            {
                                hasSemicolon = true;
                                break;
                            }
                            if (tokens[look].type == TokenType.LBRACE || tokens[look].type == TokenType.RBRACE)
                                break;
                            look++;
                        }

                        if (hasSemicolon)
                        {
                            string functionArgs;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                            {
                                if (tokens[pos].type == TokenType.STR)
                                {
                                    if (functionArgs.length > 0)
                                        functionArgs ~= " ";
                                    functionArgs ~= "\"" ~ tokens[pos].value ~ "\"";
                                }
                                else
                                {
                                    if (functionArgs.length > 0)
                                        functionArgs ~= " ";
                                    functionArgs ~= tokens[pos].value;
                                }
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after function call");
                            pos++;

                            funcNode.children ~= new FunctionCallNode(identName, functionArgs);
                            break;
                        }
                    }

                    string leftSide = identName;

                    // Handle array access on base identifier
                    while (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                    {
                        pos++; // Skip '['
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        string indexExpr = "";
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                        {
                            indexExpr ~= tokens[pos].value;
                            pos++;
                        }
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                            "Expected ']' after array index");
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        leftSide ~= "[" ~ indexExpr ~ "]";
                    }

                    // Check for member access (dot notation) - loop to handle chained access like row.fields.data
                    while (pos < tokens.length && tokens[pos].type == TokenType.DOT)
                    {
                        pos++; // Skip '.'
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                            "Expected field name after '.'");
                        string fieldName = tokens[pos].value;
                        pos++;

                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        // Handle array access after field
                        while (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                        {
                            pos++; // Skip '['
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            string indexExpr = "";
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                            {
                                indexExpr ~= tokens[pos].value;
                                pos++;
                            }
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                "Expected ']' after array index");
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                            fieldName ~= "[" ~ indexExpr ~ "]";
                        }

                        // Append this field to leftSide for chained access
                        leftSide ~= "." ~ fieldName;
                    }

                    // After building the full member access chain, check what comes next
                    if (leftSide != identName && pos < tokens.length && tokens[pos].type == TokenType
                        .LPAREN)
                    {
                        // Method call like error.print_self(err) or Arena.alloc(arena, size)
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        string functionArgs;
                        int parenDepth = 0;
                        bool lastWasRef = false;
                        while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                        {
                            if (tokens[pos].type == TokenType.LPAREN)
                            {
                                parenDepth++;
                                functionArgs ~= tokens[pos].value;
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.RPAREN)
                            {
                                parenDepth--;
                                functionArgs ~= tokens[pos].value;
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.WHITESPACE)
                            {
                                // Preserve space after 'ref' keyword
                                if (lastWasRef)
                                {
                                    functionArgs ~= " ";
                                    lastWasRef = false;
                                }
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.COMMA)
                            {
                                functionArgs ~= ", ";
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.STR)
                            {
                                functionArgs ~= "\"" ~ tokens[pos].value ~ "\"";
                                lastWasRef = false;
                                pos++;
                            }
                            else
                            {
                                // Check if this token is 'ref'
                                if (tokens[pos].value == "ref")
                                {
                                    lastWasRef = true;
                                }
                                else
                                {
                                    lastWasRef = false;
                                }
                                functionArgs ~= tokens[pos].value;
                                pos++;
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after method arguments");
                        pos++;

                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after method call");
                        pos++;

                        funcNode.children ~= new FunctionCallNode(leftSide, functionArgs);
                    }
                    else if (leftSide != identName && pos < tokens.length && tokens[pos].type == TokenType.OPERATOR
                        && tokens[pos].value == "=")
                    {
                        // Field assignment like row.fields.data = nil
                        // Check if the base object is declared (could be a function parameter or local variable)
                        if (!funcScope.isDeclared(identName))
                        {
                            enforce(false, "Undeclared variable: " ~ identName);
                        }

                        // Check mutability: In function body, allow member access for function parameters
                        // (even if immutable) because they're often used to modify data structures.
                        // Function parameters are registered in funcScope when the function starts,
                        // so if a variable is in funcScope and not mutable, it's likely a function parameter.
                        // Local variables declared later in the function will be mutable if declared with 'mut val'.
                        // So we allow member access here for function parameters.
                        // Note: Local variables in main() will go through parseStatementHelper which enforces mutability.

                        pos++;
                        string value = "";
                        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                        {
                            if (tokens[pos].type == TokenType.STR)
                                value ~= "\"" ~ tokens[pos].value ~ "\"";
                            else
                                value ~= tokens[pos].value;
                            pos++;
                        }
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after field assignment");
                        pos++;
                        // Use AssignmentNode with dot notation for field assignment
                        funcNode.children ~= new AssignmentNode(leftSide, value.strip());
                    }
                    // Check if this is an assignment
                    else if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                    {
                        // Variable assignment
                        if (!funcScope.isDeclared(identName))
                        {
                            enforce(false, "Undeclared variable: " ~ identName);
                        }
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        string expr = "";
                        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                        {
                            if (tokens[pos].type == TokenType.STR)
                                expr ~= "\"" ~ tokens[pos].value ~ "\"";
                            else if (tokens[pos].type == TokenType.CHAR)
                                expr ~= "'" ~ tokens[pos].value ~ "'";
                            else
                                expr ~= tokens[pos].value;
                            pos++;
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after assignment");
                        pos++;

                        funcNode.children ~= new AssignmentNode(leftSide, expr);
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        // Function call
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        string functionArgs;
                        int parenDepth = 0;
                        bool lastWasRef = false;
                        while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                        {
                            if (tokens[pos].type == TokenType.LPAREN)
                            {
                                parenDepth++;
                                functionArgs ~= tokens[pos].value;
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.RPAREN)
                            {
                                parenDepth--;
                                functionArgs ~= tokens[pos].value;
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.WHITESPACE)
                            {
                                // Preserve space after 'ref' keyword
                                if (lastWasRef)
                                {
                                    functionArgs ~= " ";
                                    lastWasRef = false;
                                }
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.COMMA)
                            {
                                functionArgs ~= ", ";
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.STR)
                            {
                                functionArgs ~= "\"" ~ tokens[pos].value ~ "\"";
                                lastWasRef = false;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.CHAR)
                            {
                                functionArgs ~= "'" ~ tokens[pos].value ~ "'";
                                lastWasRef = false;
                                pos++;
                            }
                            else
                            {
                                if (tokens[pos].value == "ref")
                                {
                                    lastWasRef = true;
                                }
                                else
                                {
                                    lastWasRef = false;
                                }
                                functionArgs ~= tokens[pos].value;
                                pos++;
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
                        funcNode.children ~= new FunctionCallNode(identName, functionArgs);
                    }
                    else
                    {
                        import std.stdio;

                        writeln("Unexpected token at position ", pos, ": ", tokens[pos].type, " ('",
                            tokens[pos].value, "')");
                        writeln("Previous tokens:");
                        foreach (i; max(0, cast(int) pos - 5) .. pos)
                        {
                            writeln(i, ": ", tokens[i].type, " ('", tokens[i].value, "')");
                        }
                        enforce(false, "Expected '=' or '(' after identifier here");
                    }
                    break;

                case TokenType.LOOP:
                    funcNode.children ~= parseLoopHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    break;

                case TokenType.PLATFORM:
                    funcNode.children ~= parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    break;

                case TokenType.PARALLEL:
                    funcNode.children ~= parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    break;

                case TokenType.RAW:
                    enforce(isAxec, "Raw C blocks are only allowed in .axec files");
                    pos++; // Skip 'raw'

                    // Skip whitespace/newlines
                    while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .NEWLINE))
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after 'raw'");
                    pos++; // Skip '{'

                    // Lexer provides raw content as single IDENTIFIER token
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected raw code content");
                    string rawCode = tokens[pos].value;
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after raw block");
                    pos++;

                    funcNode.children ~= new RawCNode(rawCode);
                    break;

                case TokenType.RETURN:
                    auto stmt = parseStatementHelper(pos, tokens, funcScope, funcScopeNode, isAxec);
                    if (stmt !is null)
                        funcNode.children ~= stmt;
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
                                TokenType.PRINTLN, TokenType.BREAK, TokenType.FOR,
                                TokenType.RETURN
                            ].map!(
                            t => t.to!string).join(", ")));
                }
            }

            debugWriteln("Exited function body at pos ", pos);
            debugWriteln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                pos < tokens.length ? tokens[pos].value : "", "')");
            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE, "Expected '}' after function body");
            pos++;
            assert(pos > startPos, "Parser must advance position");
            startPos = pos;
            ast.children ~= funcNode;
            break;

        case TokenType.MUT:
            pos++; // Skip 'mut'
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
            goto case TokenType.VAL;

        case TokenType.VAL:
            bool hasValKeyword = (pos < tokens.length && tokens[pos].type == TokenType.VAL);
            bool isMutable = false;
            if (hasValKeyword)
            {
                isMutable = (pos > 0 && tokens[pos - 1].type == TokenType.MUT);
                pos++; // Skip 'val'
            }
            else
            {
                isMutable = true;
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected variable name after 'val'");
            string varName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                "Expected ':' after variable name");
            pos++;

            string varType = parseType();
            string initializer = "";

            // Check for initializer
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                pos++; // Skip '='

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                // Collect initializer until semicolon
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (tokens[pos].type == TokenType.STR)
                        initializer ~= "\"" ~ tokens[pos].value ~ "\"";
                    else if (tokens[pos].type == TokenType.CHAR)
                        initializer ~= "'" ~ tokens[pos].value ~ "'";
                    else
                        initializer ~= tokens[pos].value;
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        initializer ~= " ";
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after variable declaration");
            pos++;

            auto declNode = new DeclarationNode(varName, isMutable, initializer.strip(), varType);
            ast.children ~= declNode;
            continue;

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
            enforce(false, "Unexpected token at top level: " ~ tokens[pos].value ~
                    "\nFull context: " ~ tokens[max(0, cast(int) pos - 5) .. pos].map!(t => t.value)
                    .join(""));
        }
    }

    if (checkEntryPoint)
    {
        bool hasEntryPoint = false;
        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                if (funcNode.name == "main")
                {
                    hasEntryPoint = true;
                    break;
                }
            }
            else if (child.nodeType == "Test")
            {
                hasEntryPoint = true;
                break;
            }
        }

        if (!hasEntryPoint)
        {
            enforce(false, "No entry point defined. You must have either a 'main { }' or 'test { }' block.");
        }
    }

    return ast;
}

/**
 * Parse a single statement recursively (module-level helper).
 * Returns null for whitespace/newlines.
 */
private ASTNode parseStatementHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.array : join;
    import std.stdio : writeln;

    debugWriteln("[parseStatementHelper] pos=", pos, " token=", tokens[pos].type, " value='", tokens[pos].value, "'");

    switch (tokens[pos].type)
    {
    case TokenType.WHITESPACE, TokenType.NEWLINE:
        pos++;
        return null;

    case TokenType.PRINTLN:
        return parsePrintlnHelper(pos, tokens);

    case TokenType.PRINT:
        return parsePrintHelper(pos, tokens);

    case TokenType.BREAK:
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after break");
        pos++;
        return new BreakNode();

    case TokenType.ASSERT:
        pos++; // Skip 'assert'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        bool hasParens = pos < tokens.length && tokens[pos].type == TokenType.LPAREN;
        if (hasParens)
        {
            pos++;
        }

        string condition = "";
        int parenDepth = 0;
        while (pos < tokens.length)
        {
            if (tokens[pos].type == TokenType.LPAREN)
                parenDepth++;
            else if (tokens[pos].type == TokenType.RPAREN)
            {
                if (parenDepth == 0)
                {
                    if (hasParens)
                        break;
                }
                else
                    parenDepth--;
            }
            else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                break;

            if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
            {
                if (tokens[pos].type == TokenType.STR)
                    condition ~= "\"" ~ tokens[pos].value ~ "\" ";
                else
                    condition ~= tokens[pos].value ~ " ";
            }
            pos++;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.COMMA,
            "Expected ',' after assert condition");
        pos++;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
            "Expected string message after comma in assert");
        string message = tokens[pos].value;
        pos++;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (hasParens)
        {
            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after assert message");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after assert statement");
        pos++;

        debugWriteln("[ASSERT] Final condition: '", condition.strip(), "'");
        debugWriteln("[ASSERT] Message: '", message, "'");
        return new AssertNode(condition.strip(), message);

    case TokenType.CONTINUE:
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after continue");
        pos++;
        return new ContinueNode();

    case TokenType.USE:
        pos++; // Skip 'use'

        if (pos < tokens.length && tokens[pos].type == TokenType.EXTERNAL)
        {
            pos++; // Skip 'external'

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after 'external'");
            pos++; // Skip '('

            enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
                "Expected string literal for header file");
            string headerFile = tokens[pos].value;
            pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after header file");
            pos++; // Skip ')'

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after external import");
            pos++; // Skip ';'

            return new ExternalImportNode(headerFile);
        }

        string moduleName = "";

        while (pos < tokens.length && tokens[pos].type == TokenType.DOT)
        {
            size_t lookAhead = pos + 1;

            if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.DOT)
            {
                lookAhead++;
                if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.SLASH)
                {
                    moduleName ~= "../";
                    pos = lookAhead + 1;
                    continue;
                }
            }
            else if (lookAhead < tokens.length && tokens[lookAhead].type == TokenType.SLASH)
            {
                moduleName ~= "./";
                pos = lookAhead + 1;
                continue;
            }

            break;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
            "Expected module name after 'use'");
        moduleName ~= tokens[pos].value;
        pos++;

        while (pos < tokens.length && (tokens[pos].type == TokenType.DOT || tokens[pos].type == TokenType
                .SLASH))
        {
            if (tokens[pos].type == TokenType.DOT)
            {
                moduleName ~= ".";
            }
            else
            {
                moduleName ~= "/";
            }
            pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected identifier after '.' or '/' in module path");
            moduleName ~= tokens[pos].value;
            pos++;
        }

        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE ||
                tokens[pos].type == TokenType.NEWLINE))
            pos++;

        // Check for import all syntax: use module;
        if (pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON)
        {
            pos++; // Skip ';'
            return new UseNode(moduleName, [], true);
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
            "Expected '(' after module name");
        pos++; // Skip '('

        string[] imports;
        while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
        {
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE ||
                    tokens[pos].type == TokenType.NEWLINE))
                pos++;

            if (pos >= tokens.length || tokens[pos].type == TokenType.RPAREN)
                break;

            if (tokens[pos].type == TokenType.IDENTIFIER)
            {
                imports ~= tokens[pos].value;
                pos++;
            }
            else if (tokens[pos].type == TokenType.COMMA)
            {
                pos++;
            }
            else
            {
                enforce(false, "Unexpected token in use statement");
            }
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
            "Expected ')' after use statement");
        pos++; // Skip ')'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after use statement");
        pos++; // Skip ';'

        return new UseNode(moduleName, imports);

    case TokenType.PLATFORM:
        pos++; // Skip 'platform'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && (tokens[pos].type == TokenType.WINDOWS ||
                tokens[pos].type == TokenType.POSIX),
            "Expected 'windows' or 'posix' after 'platform'");
        string platformName = tokens[pos].value;
        pos++;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after platform name");
        pos++; // Skip '{'

        auto platformNode = new PlatformNode(platformName);

        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
            if (stmt !is null)
                platformNode.children ~= stmt;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after platform block");
        pos++; // Skip '}'

        return platformNode;

    case TokenType.PARALLEL:
        pos++; // Skip 'parallel'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.FOR)
        {
            return parseParallelForHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
        }
        else
        {
            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after 'parallel'");
            pos++; // Skip '{'

            auto parallelNode = new ParallelNode();

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                if (stmt !is null)
                    parallelNode.children ~= stmt;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after parallel block");
            pos++; // Skip '}'

            return parallelNode;
        }

    case TokenType.SINGLE:
        pos++; // Skip 'single'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after 'single'");
        pos++; // Skip '{'

        auto singleNode = new SingleNode();

        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
            if (stmt !is null)
                singleNode.children ~= stmt;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after single block");
        pos++; // Skip '}'

        return singleNode;

    case TokenType.UNSAFE:
        pos++; // Skip 'unsafe'

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after 'unsafe'");
        pos++; // Skip '{'

        auto unsafeNode = new UnsafeNode([]);

        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
            if (stmt !is null)
                unsafeNode.body ~= stmt;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after unsafe block");
        pos++; // Skip '}'

        return unsafeNode;

    case TokenType.LOOP:
        return parseLoopHelper(pos, tokens, currentScope, currentScopeNode, isAxec);

    case TokenType.FOR:
        pos++; // Skip 'for'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        bool isForIn = false;
        size_t tempPos = pos;
        while (tempPos < tokens.length && tokens[tempPos].type == TokenType.WHITESPACE)
            tempPos++;
        if (tempPos < tokens.length && tokens[tempPos].type == TokenType.IDENTIFIER)
        {
            tempPos++;
            while (tempPos < tokens.length && tokens[tempPos].type == TokenType.WHITESPACE)
                tempPos++;
            if (tempPos < tokens.length && tokens[tempPos].type == TokenType.IN)
            {
                isForIn = true;
            }
        }
        if (isForIn)
        {
            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected variable name in for-in loop");
            string itemVar = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IN,
                "Expected 'in' in for-in loop");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected collection name in for-in loop");
            string collection = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
            {
                collection ~= "(";
                pos++; // Skip '('

                int parenDepth = 0;
                while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                {
                    if (tokens[pos].type == TokenType.LPAREN)
                        parenDepth++;
                    else if (tokens[pos].type == TokenType.RPAREN)
                        parenDepth--;

                    if (tokens[pos].type == TokenType.STR)
                        collection ~= "\"" ~ tokens[pos].value ~ "\"";
                    else
                        collection ~= tokens[pos].value;
                    pos++;
                }

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                    "Expected ')' after function arguments in for-in");
                collection ~= ")";
                pos++; // Skip ')'
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after for-in");
            pos++;

            auto forInNode = new ForInNode(itemVar, collection);
            auto prevScope = currentScopeNode;
            currentScopeNode = forInNode;
            currentScope.addVariable(itemVar, false);

            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                if (stmt !is null)
                    forInNode.children ~= stmt;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after for-in body");
            pos++;

            currentScopeNode = prevScope;
            return forInNode;
        }
        else
        {
            // C-style for loop: for init; condition; increment { }
            string init = "";
            string condition = "";
            string increment = "";
            string varName = "";
            string varType = "";
            bool isMutable = false;

            if (pos < tokens.length && tokens[pos].type == TokenType.MUT)
            {
                isMutable = true;
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
            }

            bool hasValKeyword = (pos < tokens.length && tokens[pos].type == TokenType.VAL);
            if (hasValKeyword)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
            }

            // Declaration in header: 'val i = 0', 'mut val i = 0', or 'mut i = 0'
            if (hasValKeyword || (isMutable && pos < tokens.length && tokens[pos].type == TokenType
                    .IDENTIFIER))
            {
                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    hasValKeyword ? "Expected variable name in for init"
                        : "Expected variable name after 'mut' in for init");
                varName = tokens[pos].value;
                pos++;

                if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                {
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        varType = tokens[pos].value;
                        pos++;
                    }
                }

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
                if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                {
                    pos++;
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON &&
                        tokens[pos].type != TokenType.TO)
                    {
                        if (tokens[pos].type != TokenType.WHITESPACE)
                            init ~= tokens[pos].value;
                        pos++;
                    }
                }

                currentScope.addVariable(varName, isMutable);
            }
            else
            {
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON &&
                    tokens[pos].type != TokenType.TO)
                {
                    init ~= tokens[pos].value;
                    pos++;
                }
            }

            // Check for 'to' syntax
            bool isToSyntax = false;
            string toEndValue = "";

            if (pos < tokens.length && tokens[pos].type == TokenType.TO)
            {
                isToSyntax = true;
                pos++; // Skip 'to'

                while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        toEndValue ~= tokens[pos].value;
                    pos++;
                }

                condition = varName ~ "<" ~ toEndValue;
                increment = varName ~ "++";
            }
            else
            {
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after for init");
                pos++;

                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        condition ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after for condition");
                pos++;

                while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        increment ~= tokens[pos].value;
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after for loop header");
            pos++;

            string initStr = "";
            if (varName.length > 0)
            {
                if (varType.length == 0)
                    varType = "int";

                if (isMutable)
                    initStr = "mut val " ~ varName;
                else
                    initStr = "val " ~ varName;

                initStr ~= ": " ~ varType;

                if (init.length > 0)
                    initStr ~= " = " ~ init;
            }
            else
            {
                initStr = init;
            }

            auto forNode = new ForNode(initStr, condition.strip(), increment.strip());
            forNode.varName = varName;
            forNode.varType = varType;
            forNode.isMutable = isMutable;
            forNode.initValue = init.strip();

            auto prevScope = currentScopeNode;
            currentScopeNode = forNode;

            // Parse for body
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                if (stmt !is null)
                    forNode.children ~= stmt;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after for body");
            pos++;

            currentScopeNode = prevScope;
            return forNode;
        }

    case TokenType.IF:
        return parseIfHelper(pos, tokens, currentScope, currentScopeNode, isAxec);

    case TokenType.SWITCH:
        pos++; // Skip 'switch'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        // Parse switch expression (no parentheses required)
        string switchExpr = "";
        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
        {
            if (tokens[pos].type != TokenType.WHITESPACE)
                switchExpr ~= tokens[pos].value;
            pos++;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after switch expression");
        pos++;

        auto switchNode = new SwitchNode(switchExpr.strip());
        auto prevScope = currentScopeNode;
        currentScopeNode = switchNode;

        // Parse switch body (cases)
        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE)
            {
                pos++;
            }
            else if (tokens[pos].type == TokenType.CASE)
            {
                pos++; // Skip 'case'
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                string caseValue = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        caseValue ~= tokens[pos].value;
                    pos++;
                }

                enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                    "Expected '{' after case value");
                pos++;

                auto caseNode = new CaseNode(caseValue.strip());

                // Parse case body
                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                {
                    auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                    if (stmt !is null)
                        caseNode.children ~= stmt;
                }

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                    "Expected '}' after case body");
                pos++;

                switchNode.children ~= caseNode;
            }
            else if (tokens[pos].type == TokenType.DEFAULT)
            {
                pos++; // Skip 'default'
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                    "Expected '{' after default");
                pos++;

                auto defaultNode = new CaseNode("", true);

                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                {
                    auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                    if (stmt !is null)
                        defaultNode.children ~= stmt;
                }

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                    "Expected '}' after default body");
                pos++;

                switchNode.children ~= defaultNode;
            }
            else
            {
                pos++;
            }
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after switch body");
        pos++;

        currentScopeNode = prevScope;
        return switchNode;

    case TokenType.MUT:
        debugWriteln("[MUT case] Starting at pos=", pos);
        pos++;
        debugWriteln("[MUT case] After pos++, pos=", pos, " token=", tokens[pos].type);
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                .NEWLINE))
            pos++;
        debugWriteln("[MUT case] After whitespace skip, pos=", pos, " token=", tokens[pos].type);
        debugWriteln("[MUT case] About to goto VAL case");
        goto case TokenType.VAL;

    case TokenType.VAL:
        {
            debugWriteln("[VAL case] Starting at pos=", pos);
            bool hasValKeyword = (pos < tokens.length && tokens[pos].type == TokenType.VAL);
            size_t checkPos = pos - 1;
            while (checkPos > 0 && (tokens[checkPos].type == TokenType.WHITESPACE || tokens[checkPos].type == TokenType
                    .NEWLINE))
                checkPos--;
            bool isMutable = tokens[checkPos].type == TokenType.MUT;
            debugWriteln("[VAL case] isMutable=", isMutable);
            if (hasValKeyword)
            {
                pos++;
                debugWriteln("[VAL case] After pos++, pos=", pos);
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
            debugWriteln("[VAL case] After whitespace skip, pos=", pos, " token=", tokens[pos]
                    .type);
            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                hasValKeyword ? "Expected identifier after 'val'"
                    : "Expected identifier after 'mut'");
            string varName = tokens[pos].value;
            debugWriteln("[VAL case] varName=", varName);
            pos++;

            string typeName = "";
            string initializer = "";
            int refDepth = 0;

            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                // Handle ref keyword(s)
                while (pos < tokens.length && tokens[pos].type == TokenType.REF)
                {
                    refDepth++;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;
                }

                typeName = parseTypeHelper(pos, tokens);
                debugWriteln("[VAL case] After parseTypeHelper, typeName=", typeName, " pos=", pos);
            }

            debugWriteln("[VAL case] Before checking for =, pos=", pos, " token=", tokens[pos]
                    .type);
            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                // Check for model instantiation: new ModelName(...)
                if (pos < tokens.length && tokens[pos].type == TokenType.NEW)
                {
                    pos++; // Skip 'new'
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected model name after 'new'");
                    string modelName = tokens[pos].value;
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                        "Expected '(' after model name");
                    pos++;

                    string[string] fieldValues;
                    while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                    {
                        if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .NEWLINE)
                        {
                            pos++;
                        }
                        else if (tokens[pos].type == TokenType.IDENTIFIER)
                        {
                            string fieldName = tokens[pos].value;
                            pos++;

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                                "Expected ':' after field name");
                            pos++;

                            string fieldValue = "";
                            int parenDepth = 0;
                            while (pos < tokens.length &&
                                ((tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType
                                    .RPAREN) || parenDepth > 0))
                            {
                                if (tokens[pos].type == TokenType.LPAREN)
                                    parenDepth++;
                                else if (tokens[pos].type == TokenType.RPAREN)
                                    parenDepth--;

                                if (tokens[pos].type == TokenType.STR)
                                    fieldValue ~= "\"" ~ tokens[pos].value ~ "\"";
                                else if (tokens[pos].type == TokenType.CHAR)
                                    fieldValue ~= "'" ~ tokens[pos].value ~ "'";
                                else if (tokens[pos].type != TokenType.WHITESPACE)
                                    fieldValue ~= tokens[pos].value;
                                pos++;
                            }

                            fieldValues[fieldName] = fieldValue.strip();

                            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                                pos++;
                        }
                        else
                        {
                            pos++;
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                        "Expected ')' after model fields");
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after model instantiation");
                    pos++;

                    currentScope.addVariable(varName, isMutable);
                    return new ModelInstantiationNode(modelName, varName, fieldValues, isMutable);
                }
                else
                {
                    debugWriteln("[VAL case] Parsing initializer, starting at pos=", pos);
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        debugWriteln("[VAL case] Initializer loop: pos=", pos, " token=", tokens[pos]
                                .type);

                        if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .NEWLINE)
                        {
                            pos++;
                            continue;
                        }

                        if (initializer.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                            tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType
                            .COMMA && tokens[pos].type != TokenType.LBRACKET && tokens[pos]
                            .type != TokenType.RBRACKET && tokens[pos].type != TokenType.LBRACE &&
                            tokens[pos].type != TokenType.RBRACE)
                        {
                            initializer ~= " ";
                        }
                        if (tokens[pos].type == TokenType.STR)
                            initializer ~= "\"" ~ tokens[pos].value ~ "\"";
                        else if (tokens[pos].type == TokenType.CHAR)
                            initializer ~= "'" ~ tokens[pos].value ~ "'";
                        else
                            initializer ~= tokens[pos].value;
                        pos++;
                    }
                    debugWriteln("[VAL case] After initializer loop, initializer=", initializer);
                }
            }

            debugWriteln("[VAL case] Before final semicolon check, pos=", pos);
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after variable declaration");
            pos++;

            debugWriteln("[VAL case] About to return DeclarationNode");
            currentScope.addVariable(varName, isMutable);
            return new DeclarationNode(varName, isMutable, initializer, typeName, refDepth);
        }

    case TokenType.IDENTIFIER:
        string identName = tokens[pos].value;
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type != TokenType.LPAREN &&
            tokens[pos].type != TokenType.LBRACKET &&
            tokens[pos].type != TokenType.DOT &&
            tokens[pos].type != TokenType.STAR_DOT &&
            !(tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=") &&
            tokens[pos].type != TokenType.INCREMENT &&
            tokens[pos].type != TokenType.DECREMENT)
        {
            size_t look = pos;
            bool hasSemicolon = false;
            while (look < tokens.length)
            {
                if (tokens[look].type == TokenType.SEMICOLON)
                {
                    hasSemicolon = true;
                    break;
                }
                if (tokens[look].type == TokenType.LBRACE || tokens[look].type == TokenType.RBRACE)
                    break;
                look++;
            }

            if (hasSemicolon)
            {
                string functionArgs;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (tokens[pos].type == TokenType.STR)
                    {
                        if (functionArgs.length > 0)
                            functionArgs ~= " ";
                        functionArgs ~= "\"" ~ tokens[pos].value ~ "\"";
                    }
                    else
                    {
                        if (functionArgs.length > 0)
                            functionArgs ~= " ";
                        functionArgs ~= tokens[pos].value;
                    }
                    pos++;
                }

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after function call");
                pos++;

                debugWriteln("[parseStatementHelper] Optional-paren call sugar for '", identName, "' with args '", functionArgs, "'");
                return new FunctionCallNode(identName, functionArgs);
            }
        }

        if (pos < tokens.length && (tokens[pos].type == TokenType.DOT || tokens[pos].type == TokenType.STAR_DOT))
        {
            // Could be: obj.field = value, obj.field[index] = value, OR Model.method(...) or ptr*.field = value
            bool isUnsafeDeref = tokens[pos].type == TokenType.STAR_DOT;
            pos++; // Skip '.' or '*.'
            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected field name or method name after '.' or '*.'");
            string memberName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            // Check if this is a method call: Model.method(...)
            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
            {
                // This is a namespaced function call
                string namespacedFunction = identName ~ "." ~ memberName;

                pos++;
                string[] args;
                string currentArg = "";
                int parenDepth = 0;

                bool lastWasRef = false;
                while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                {
                    if (tokens[pos].type == TokenType.LPAREN)
                    {
                        parenDepth++;
                        currentArg ~= tokens[pos].value;
                        lastWasRef = false;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.RPAREN)
                    {
                        parenDepth--;
                        currentArg ~= tokens[pos].value;
                        lastWasRef = false;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                    {
                        args ~= currentArg.strip();
                        currentArg = "";
                        lastWasRef = false;
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.WHITESPACE)
                    {
                        // Preserve space after 'ref' keyword
                        if (lastWasRef)
                        {
                            currentArg ~= " ";
                            lastWasRef = false;
                        }
                        pos++;
                    }
                    else if (tokens[pos].type == TokenType.STR)
                    {
                        currentArg ~= "\"" ~ tokens[pos].value ~ "\"";
                        lastWasRef = false;
                        pos++;
                    }
                    else
                    {
                        // Check if this token is 'ref'
                        if (tokens[pos].value == "ref")
                        {
                            lastWasRef = true;
                        }
                        else
                        {
                            lastWasRef = false;
                        }
                        currentArg ~= tokens[pos].value;
                        pos++;
                    }
                }

                if (currentArg.strip().length > 0)
                    args ~= currentArg.strip();

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                    "Expected ')' after function arguments");
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after function call");
                pos++;
                return new FunctionCallNode(namespacedFunction, args.join(", "));
            }

            // Allow chained member access: obj.field, obj.field.sub, obj.field.sub.more, etc.
            string fullLeftSide = identName ~ (isUnsafeDeref ? "*." : ".") ~ memberName;

            // Consume additional ".identifier" or "*.identifier" segments, updating memberName to the last segment
            while (pos < tokens.length && (tokens[pos].type == TokenType.DOT || tokens[pos].type == TokenType.STAR_DOT))
            {
                string dotOp = tokens[pos].type == TokenType.STAR_DOT ? "*." : ".";
                pos++; // Skip '.' or '*.'
                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected field name after '.' or '*.'");
                string nextMember = tokens[pos].value;
                pos++;
                fullLeftSide ~= dotOp ~ nextMember;
                memberName = nextMember;
            }

            // Otherwise, check for array access on the (possibly chained) field: obj.field[index]
            while (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
            {
                pos++; // Skip '['
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
                string indexExpr = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                {
                    indexExpr ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                    "Expected ']' after array index");
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
                fullLeftSide ~= "[" ~ indexExpr ~ "]";
            }

            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                // Check if the object is declared (could be a function parameter or local variable)
                // Note: Function parameters are registered in the scope, so this should work
                if (!currentScope.isDeclared(identName))
                {
                    enforce(false, "Undeclared variable: " ~ identName);
                }
                bool isVarMutable = currentScope.isMutable(identName);
                debugWriteln("DEBUG: Member access check for '", identName, "': isMutable=", isVarMutable);
                if (!isVarMutable)
                {
                    enforce(false, "Cannot assign to member '" ~ memberName ~
                            "' of immutable variable '" ~ identName ~ "'");
                }

                pos++;
                string value = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (value.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                        tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType.COMMA)
                    {
                        value ~= " ";
                    }
                    if (tokens[pos].type == TokenType.STR)
                        value ~= "\"" ~ tokens[pos].value ~ "\"";
                    else
                        value ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after field assignment");
                pos++;
                // Use AssignmentNode with the full left side expression
                return new AssignmentNode(fullLeftSide, value.strip());
            }
            else if (pos < tokens.length && tokens[pos].type == TokenType.INCREMENT)
            {
                // Member increment: obj.member++
                if (!currentScope.isDeclared(identName))
                    enforce(false, "Undeclared variable: " ~ identName);

                if (!currentScope.isMutable(identName))
                    enforce(false, "Cannot increment member of immutable variable: " ~ identName);

                pos++; // Skip '++'

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after member increment");
                pos++;

                return new MemberIncrementDecrementNode(identName, memberName, true);
            }
            else if (pos < tokens.length && tokens[pos].type == TokenType.DECREMENT)
            {
                // Member decrement: obj.member--
                if (!currentScope.isDeclared(identName))
                    enforce(false, "Undeclared variable: " ~ identName);

                if (!currentScope.isMutable(identName))
                    enforce(false, "Cannot decrement member of immutable variable: " ~ identName);

                pos++; // Skip '--'

                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after member decrement");
                pos++;

                return new MemberIncrementDecrementNode(identName, memberName, false);
            }
        }
        else if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
        {
            pos++;
            string index = "";
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
            {
                index ~= tokens[pos].value;
                pos++;
            }
            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                "Expected ']' after array index");
            pos++;

            string index2 = "";
            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                {
                    index2 ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                    "Expected ']' after second array index");
                pos++;
            }

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            // Check for member access on array element (e.g., grid[r][c].temperature)
            if (pos < tokens.length && tokens[pos].type == TokenType.DOT)
            {
                pos++; // Skip '.'
                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected field name after '.'");
                string fieldName = tokens[pos].value;
                pos++;

                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                {
                    pos++;
                    string value = "";
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        if (value.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                            tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType
                            .COMMA)
                        {
                            value ~= " ";
                        }
                        if (tokens[pos].type == TokenType.STR)
                            value ~= "\"" ~ tokens[pos].value ~ "\"";
                        else
                            value ~= tokens[pos].value;
                        pos++;
                    }
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after field assignment");
                    pos++;
                    // Build the full member access expression
                    string fullExpr = identName ~ "[" ~ index.strip() ~ "]";
                    if (index2.length > 0)
                        fullExpr ~= "[" ~ index2.strip() ~ "]";
                    fullExpr ~= "." ~ fieldName;
                    return new AssignmentNode(fullExpr, value.strip());
                }
            }
            else if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                pos++;
                string value = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    if (value.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                        tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType.COMMA)
                    {
                        value ~= " ";
                    }
                    if (tokens[pos].type == TokenType.STR)
                        value ~= "\"" ~ tokens[pos].value ~ "\"";
                    else
                        value ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after array assignment");
                pos++;
                return new ArrayAssignmentNode(identName, index.strip(), value.strip(), index2.strip());
            }
        }
        else if (pos < tokens.length && tokens[pos].type == TokenType.INCREMENT)
        {
            // Increment: x++
            if (!currentScope.isDeclared(identName))
            {
                enforce(false, "Undeclared variable: " ~ identName);
            }
            if (!currentScope.isMutable(identName))
            {
                enforce(false, "Cannot increment immutable variable: " ~ identName);
            }
            pos++;
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after increment");
            pos++;
            return new IncrementDecrementNode(identName, true);
        }
        else if (pos < tokens.length && tokens[pos].type == TokenType.DECREMENT)
        {
            // Decrement: x--
            if (!currentScope.isDeclared(identName))
            {
                enforce(false, "Undeclared variable: " ~ identName);
            }
            if (!currentScope.isMutable(identName))
            {
                enforce(false, "Cannot decrement immutable variable: " ~ identName);
            }
            pos++;
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after decrement");
            pos++;
            return new IncrementDecrementNode(identName, false);
        }
        else if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
        {
            // Variable assignment - check if variable is declared
            if (!currentScope.isDeclared(identName))
            {
                enforce(false, "Undeclared variable: " ~ identName);
            }

            pos++;
            string value = "";
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (value.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                    tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType.COMMA)
                {
                    value ~= " ";
                }
                if (tokens[pos].type == TokenType.STR)
                    value ~= "\"" ~ tokens[pos].value ~ "\"";
                else
                    value ~= tokens[pos].value;
                pos++;
            }
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after assignment");
            pos++;
            return new AssignmentNode(identName, value.strip());
        }
        else if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
        {
            // Function call
            pos++;
            string[] args;
            string currentArg = "";
            int parenDepth = 0;

            bool lastWasRef = false;
            while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
            {
                if (tokens[pos].type == TokenType.LPAREN)
                {
                    parenDepth++;
                    currentArg ~= tokens[pos].value;
                    lastWasRef = false;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.RPAREN)
                {
                    parenDepth--;
                    currentArg ~= tokens[pos].value;
                    lastWasRef = false;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                {
                    args ~= currentArg.strip();
                    currentArg = "";
                    lastWasRef = false;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.WHITESPACE)
                {
                    // Preserve space after 'ref' keyword
                    if (lastWasRef)
                    {
                        debugWriteln("[parseStatementHelper] Adding space after 'ref', currentArg: '", currentArg, "'");
                        currentArg ~= " ";
                        lastWasRef = false;
                    }
                    pos++;
                }
                else if (tokens[pos].type == TokenType.STR)
                {
                    currentArg ~= "\"" ~ tokens[pos].value ~ "\"";
                    lastWasRef = false;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.INTERPOLATED_STR)
                {
                    enforce(("std.string" in g_importedModules) !is null,
                        "String interpolation requires 'use std.string;'");

                    string rawContent = tokens[pos].value;
                    enforce(rawContent.canFind("{"),
                        "Interpolated string must contain at least one {} expression. " ~
                            "Use a regular string if no interpolation is needed.");

                    currentArg ~= "__INTERPOLATED__" ~ tokens[pos].value ~ "__INTERPOLATED__";
                    lastWasRef = false;
                    pos++;
                }
                else
                {
                    // Check if this token is 'ref'
                    if (tokens[pos].value == "ref")
                    {
                        debugWriteln("[parseStatementHelper] Found 'ref' keyword");
                        lastWasRef = true;
                    }
                    else
                    {
                        // If the last token was 'ref', add a space before this token
                        if (lastWasRef)
                        {
                            debugWriteln("[parseStatementHelper] Adding space after 'ref' before '", tokens[pos].value, "'");
                            currentArg ~= " ";
                        }
                        lastWasRef = false;
                    }
                    debugWriteln("[parseStatementHelper] Adding token '", tokens[pos].value, "' to currentArg, lastWasRef=", lastWasRef);
                    currentArg ~= tokens[pos].value;
                    pos++;
                }
            }

            if (currentArg.strip().length > 0)
                args ~= currentArg.strip();

            debugWriteln("[parseStatementHelper] Function '", identName, "' collected args: ", args);

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after function arguments");
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                // Assignment to function call result, e.g., deref(ptr) = value
                pos++;
                string value = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    value ~= tokens[pos].value;
                    pos++;
                }
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after assignment");
                pos++;
                return new AssignmentNode(identName ~ "(" ~ args.join(", ") ~ ")", value.strip());
            }
            else
            {
                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                    "Expected ';' after function call");
                pos++;
                debugWriteln("[parseStatementHelper] Returning FunctionCallNode('", identName, "', '", args.join(", "), "')");
                return new FunctionCallNode(identName, args.join(", "));
            }
        }
        return null;

    case TokenType.RETURN:
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        // Check for model instantiation: new ModelName(...)
        if (pos < tokens.length && tokens[pos].type == TokenType.NEW)
        {
            pos++; // Skip 'new'
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected model name after 'new'");
            string modelName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after model name");
            pos++;

            string[string] fieldValues;
            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE)
                {
                    pos++;
                }
                else if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string fieldName = tokens[pos].value;
                    pos++;

                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                        "Expected ':' after field name");
                    pos++;

                    string fieldValue = "";
                    int parenDepth = 0;
                    while (pos < tokens.length &&
                        ((tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType
                            .RPAREN) || parenDepth > 0))
                    {
                        if (tokens[pos].type == TokenType.LPAREN)
                            parenDepth++;
                        else if (tokens[pos].type == TokenType.RPAREN)
                            parenDepth--;

                        if (tokens[pos].type == TokenType.STR)
                            fieldValue ~= "\"" ~ tokens[pos].value ~ "\"";
                        else if (tokens[pos].type != TokenType.WHITESPACE)
                            fieldValue ~= tokens[pos].value;
                        pos++;
                    }

                    fieldValues[fieldName] = fieldValue.strip();

                    if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                        pos++;
                }
                else
                {
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after model fields");
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after return statement");
            pos++;

            // Create a ModelInstantiationNode and wrap it in the return
            auto modelInst = new ModelInstantiationNode(modelName, "", fieldValues, false);
            return new ReturnNode(modelInst);
        }
        else
        {
            string returnExpr;
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (tokens[pos].type == TokenType.STR)
                    returnExpr ~= "\"" ~ tokens[pos].value ~ "\"";
                else
                    returnExpr ~= tokens[pos].value;
                pos++;
            }
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after return statement");
            pos++;
            return new ReturnNode(returnExpr);
        }

    case TokenType.RAW:
        enforce(isAxec, "Raw C blocks are only allowed in .axec files");
        pos++; // Skip 'raw'

        // Skip whitespace/newlines
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                .NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after 'raw'");
        pos++; // Skip '{'

        // Lexer provides raw content as single IDENTIFIER token
        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
            "Expected raw code content");
        string rawCode = tokens[pos].value;
        pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after raw block");
        pos++;

        return new RawCNode(rawCode);

    case TokenType.OPAQUE:
        pos++; // Skip 'opaque'

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after 'opaque'");
        pos++; // Skip '{'

        string[] opaqueTypes;
        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            if (pos >= tokens.length || tokens[pos].type == TokenType.RBRACE)
                break;

            if (tokens[pos].type == TokenType.IDENTIFIER)
            {
                opaqueTypes ~= tokens[pos].value;
                pos++;
            }
            else if (tokens[pos].type == TokenType.COMMA)
            {
                pos++; // Skip comma
            }
            else
            {
                enforce(false, "Expected identifier or ',' in opaque declaration");
            }
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after opaque type list");
        pos++; // Skip '}'

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after opaque declaration");
        pos++; // Skip ';'

        return new OpaqueNode(opaqueTypes);

    case TokenType.EXTERN:
        pos++; // Skip 'extern'

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.DEF,
            "Expected 'def' after 'extern'");
        pos++; // Skip 'def'

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
            "Expected function name after 'extern def'");
        string externFuncName = tokens[pos].value;
        pos++;

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
            "Expected '(' after extern function name");
        pos++; // Skip '('

        string[] externParams;
        while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
        {
            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            if (pos >= tokens.length || tokens[pos].type == TokenType.RPAREN)
                break;

            // Parse parameter: name: type
            string paramStr = "";
            while (pos < tokens.length && tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType.RPAREN)
            {
                if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
                {
                    paramStr ~= tokens[pos].value;
                }
                else
                {
                    paramStr ~= " ";
                }
                pos++;
            }

            if (paramStr.strip().length > 0)
                externParams ~= paramStr.strip();

            if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                pos++; // Skip comma
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
            "Expected ')' after extern parameters");
        pos++; // Skip ')'

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        string externReturnType = "";
        if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
        {
            pos++; // Skip ':'

            // Skip whitespace
            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
                pos++;

            // Parse return type
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
                {
                    externReturnType ~= tokens[pos].value;
                }
                else if (externReturnType.length > 0)
                {
                    externReturnType ~= " ";
                }
                pos++;
            }
            externReturnType = externReturnType.strip();
        }

        // Skip whitespace
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType.NEWLINE))
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after extern declaration");
        pos++; // Skip ';'

        return new ExternNode(externFuncName, externParams, externReturnType);

    default:
        // Safeguard: if we don't recognize the token, we must advance to prevent infinite loops
        debugWriteln("[parseStatementHelper] WARNING: Unhandled token type ", tokens[pos].type, " at pos ", pos);
        enforce(false, "Unexpected token in statement: " ~ tokens[pos].value ~ " (type: " ~ tokens[pos]
                .type.to!string ~ ")\nFull context: " ~ tokens[pos - 5 .. pos + 5].map!(t => t.value)
                .join(""));
        return null;
    }
}

/**
 * Parse an if statement recursively (module-level helper).
 */
private IfNode parseIfHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.stdio : writeln;

    debugWriteln("[parseIfHelper] Entering at pos=", pos);

    pos++; // Skip 'if'
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    string cond = "";
    bool hasParen = false;
    if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
    {
        hasParen = true;
        pos++;
    }

    while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
    {
        if (hasParen && tokens[pos].type == TokenType.RPAREN)
        {
            pos++;
            break;
        }
        if (tokens[pos].type != TokenType.WHITESPACE)
        {
            if (tokens[pos].type == TokenType.STR)
                cond ~= "\"" ~ tokens[pos].value ~ "\" ";
            else if (tokens[pos].type == TokenType.CHAR)
                cond ~= "'" ~ tokens[pos].value ~ "' ";
            else if (tokens[pos].type == TokenType.DOT)
                cond ~= ".";
            else
                cond ~= tokens[pos].value ~ " ";
        }
        pos++;
    }

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;
    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
        "Expected '{' after if condition here: " ~ tokens[pos - 5 .. pos + 5].map!(t => t.value)
            .join(""));
    pos++;

    auto ifNode = new IfNode(cond.strip());
    auto prevScope = currentScopeNode;
    currentScopeNode = ifNode;

    // Parse if body using recursive parseStatementHelper
    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
    {
        auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
        if (stmt !is null)
            ifNode.children ~= stmt;
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
        "Expected '}' after if body");
    pos++;

    // Check for elif clauses - chain them properly
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    IfNode lastNode = ifNode;
    while (pos < tokens.length && tokens[pos].type == TokenType.ELIF)
    {
        debugWriteln("[parseIfHelper] Found elif at pos=", pos);
        pos++; // Skip 'elif'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        string elifCond = "";
        int parenDepth = 0;

        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
        {
            if (tokens[pos].type == TokenType.LPAREN)
            {
                parenDepth++;
                elifCond ~= "(";
                pos++;
            }
            else if (tokens[pos].type == TokenType.RPAREN)
            {
                parenDepth--;
                elifCond ~= ")";
                pos++;
            }
            else if (tokens[pos].type != TokenType.WHITESPACE)
            {
                if (tokens[pos].type == TokenType.STR)
                    elifCond ~= "\"" ~ tokens[pos].value ~ "\" ";
                else if (tokens[pos].type == TokenType.CHAR)
                    elifCond ~= "'" ~ tokens[pos].value ~ "' ";
                else if (tokens[pos].type == TokenType.DOT)
                    elifCond ~= ".";
                else
                    elifCond ~= tokens[pos].value ~ " ";
                pos++;
            }
            else
            {
                pos++;
            }
        }

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after elif condition");
        pos++;

        auto elifNode = new IfNode(elifCond.strip());
        currentScopeNode = elifNode;

        // Parse elif body
        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
            if (stmt !is null)
                elifNode.children ~= stmt;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after elif body");
        pos++;

        // Chain elif: set it as the sole content of the previous node's else body
        lastNode.elseBody = [elifNode];
        lastNode = elifNode;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
    }

    // Check for else clause - attach to the last node in the chain
    if (pos < tokens.length && tokens[pos].type == TokenType.ELSE)
    {
        debugWriteln("[parseIfHelper] Found else at pos=", pos);
        pos++; // Skip 'else'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
            "Expected '{' after else");
        pos++;

        currentScopeNode = lastNode;

        // Parse else body and attach to the last node in the elif chain
        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
        {
            auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
            if (stmt !is null)
                lastNode.elseBody ~= stmt;
        }

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
            "Expected '}' after else body");
        pos++;
    }

    currentScopeNode = prevScope;
    return ifNode;
}

/**
 * Parse a loop statement recursively (module-level helper).
 */
private ParallelForNode parseParallelForHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.stdio : writeln;

    enforce(pos < tokens.length && tokens[pos].type == TokenType.FOR,
        "Expected 'for' in parallel for");
    pos++; // Skip 'for'

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    string init = "";
    string condition = "";
    string increment = "";
    string varName = "";
    string varType = "";
    bool isMutable = false;

    if (pos < tokens.length && tokens[pos].type == TokenType.MUT)
    {
        isMutable = true;
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
    }
    else if (pos < tokens.length && tokens[pos].type == TokenType.VAL)
    {
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
    }

    if (isMutable || (pos > 0 && tokens[pos - 1].type == TokenType.WHITESPACE))
    {
        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
            "Expected variable name in parallel for init");
        varName = tokens[pos].value;
        pos++;

        // Check for type annotation
        if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
            if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
            {
                varType = tokens[pos].value;
                pos++;
            }
        }

        // Parse initializer
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON &&
                tokens[pos].type != TokenType.TO && tokens[pos].type != TokenType.REDUCE)
            {
                if (tokens[pos].type != TokenType.WHITESPACE)
                    init ~= tokens[pos].value;
                pos++;
            }
        }

        currentScope.addVariable(varName, isMutable);
    }

    // Check for 'to' syntax
    bool isToSyntax = false;
    string toEndValue = "";
    string[] reductionClauses = [];

    if (pos < tokens.length && tokens[pos].type == TokenType.TO)
    {
        isToSyntax = true;
        pos++; // Skip 'to'

        // Parse end value until 'reduce' or '{'
        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE &&
            tokens[pos].type != TokenType.REDUCE)
        {
            if (tokens[pos].type != TokenType.WHITESPACE)
                toEndValue ~= tokens[pos].value;
            pos++;
        }

        // Check for reduction clauses
        if (pos < tokens.length && tokens[pos].type == TokenType.REDUCE)
        {
            pos++; // Skip 'reduce'

            // Parse reduction clause(s): reduce(+:sum) or reduce(+:sum, *:product)
            enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                "Expected '(' after 'reduce'");
            pos++; // Skip '('

            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
            {
                string reductionClause = "";
                while (pos < tokens.length && tokens[pos].type != TokenType.COMMA &&
                    tokens[pos].type != TokenType.RPAREN)
                {
                    if (tokens[pos].type != TokenType.WHITESPACE)
                        reductionClause ~= tokens[pos].value;
                    pos++;
                }

                if (reductionClause.length > 0)
                    reductionClauses ~= reductionClause;

                if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                    pos++; // Skip comma
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                "Expected ')' after reduction clauses");
            pos++; // Skip ')'
        }

        // Skip whitespace before '{'
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE ||
                tokens[pos].type == TokenType.NEWLINE))
            pos++;

        // Generate condition and increment
        condition = varName ~ "<" ~ toEndValue;
        increment = varName ~ "++";
    }
    else
    {
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after parallel for init");
        pos++;

        // Parse condition (until semicolon)
        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
        {
            if (tokens[pos].type != TokenType.WHITESPACE)
                condition ~= tokens[pos].value;
            pos++;
        }
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after parallel for condition");
        pos++;

        // Parse increment (until '{')
        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
        {
            if (tokens[pos].type != TokenType.WHITESPACE)
                increment ~= tokens[pos].value;
            pos++;
        }
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
        "Expected '{' after parallel for header");
    pos++;

    // Build initialization string
    string initStr = "";
    if (varName.length > 0)
    {
        // Default to int if no type specified
        if (varType.length == 0)
            varType = "int";

        if (isMutable)
            initStr = varType ~ " " ~ varName;
        else
            initStr = varType ~ " " ~ varName;

        if (init.length > 0)
            initStr ~= " = " ~ init;
    }

    auto parallelForNode = new ParallelForNode(initStr, condition.strip(), increment.strip());
    parallelForNode.reductionClauses = reductionClauses;
    auto prevScope = currentScopeNode;
    currentScopeNode = parallelForNode;

    // Parse parallel for body
    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
    {
        auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
        if (stmt !is null)
            parallelForNode.children ~= stmt;
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
        "Expected '}' after parallel for body");
    pos++;

    currentScopeNode = prevScope;
    return parallelForNode;
}

private LoopNode parseLoopHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.stdio : writeln;

    debugWriteln("[parseLoopHelper] Entering at pos=", pos);

    pos++; // Skip 'loop'
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
        "Expected '{' after loop");
    pos++;

    auto loopNode = new LoopNode();
    auto previousScope = currentScopeNode;
    currentScopeNode = loopNode;

    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
    {
        auto stmt = parseStatementHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
        if (stmt !is null)
            loopNode.children ~= stmt;
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
        "Expected '}' after loop body");
    pos++;

    currentScopeNode = previousScope;
    return loopNode;
}

/**
 * Helper to parse println statement.
 */
private PrintlnNode parsePrintlnHelper(ref size_t pos, Token[] tokens)
{
    pos++;

    string[] messages;
    bool[] isExpressions;

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
    {
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos >= tokens.length || tokens[pos].type == TokenType.SEMICOLON)
            break;

        if (tokens[pos].type == TokenType.STR)
        {
            string msg = tokens[pos].value;
            pos++;
            messages ~= msg;
            isExpressions ~= false;
        }
        else if (tokens[pos].type == TokenType.INTERPOLATED_STR)
        {
            import std.stdio : writeln;

            writeln("DEBUG parsePrintlnHelper: g_importedModules keys: ", g_importedModules.keys);
            auto ptr = ("std.string" in g_importedModules);
            writeln("DEBUG parsePrintlnHelper: ptr is null: ", (ptr is null));
            writeln("DEBUG parsePrintlnHelper: ptr value: ", ptr);
            enforce(ptr !is null,
                "String interpolation requires 'use std.string;'");

            string rawContent = tokens[pos].value;
            writeln("DEBUG parsePrintlnHelper: rawContent = '", rawContent, "'");
            enforce(rawContent.canFind("{"),
                "Interpolated string must contain at least one {} expression. " ~
                    "Use a regular string if no interpolation is needed.");

            string interpContent = "__INTERPOLATED__" ~ tokens[pos].value ~ "__INTERPOLATED__";
            pos++;
            messages ~= interpContent;
            isExpressions ~= true;
        }
        else
        {
            string expr = "";
            while (pos < tokens.length &&
                tokens[pos].type != TokenType.SEMICOLON &&
                tokens[pos].type != TokenType.COMMA)
            {
                if (tokens[pos].type == TokenType.STR)
                    expr ~= "\"" ~ tokens[pos].value ~ "\"";
                else if (tokens[pos].type == TokenType.INTERPOLATED_STR)
                {
                    enforce(("std.string" in g_importedModules) !is null,
                        "String interpolation requires 'use std.string;'");

                    string rawContent = tokens[pos].value;
                    enforce(rawContent.canFind("${"),
                        "Interpolated string must contain at least one ${} expression. " ~
                            "Use a regular string if no interpolation is needed.");

                    expr ~= "__INTERPOLATED__" ~ tokens[pos].value ~ "__INTERPOLATED__";
                }
                else if (tokens[pos].type == TokenType.DOT)
                    expr ~= ".";
                else
                    expr ~= tokens[pos].value;
                pos++;
            }
            if (expr.length > 0)
            {
                messages ~= expr.strip();
                isExpressions ~= true;
            }
        }

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
        "Expected ';' after println");
    pos++;

    if (messages.length == 0)
    {
        return new PrintlnNode("", false);
    }

    return new PrintlnNode(messages, isExpressions);
}

/**
 * Helper to parse print statement.
 */
private PrintNode parsePrintHelper(ref size_t pos, Token[] tokens)
{
    pos++;

    string[] messages;
    bool[] isExpressions;

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
    {
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos >= tokens.length || tokens[pos].type == TokenType.SEMICOLON)
            break;

        if (tokens[pos].type == TokenType.STR)
        {
            string msg = tokens[pos].value;
            pos++;
            messages ~= msg;
            isExpressions ~= false;
        }
        else if (tokens[pos].type == TokenType.INTERPOLATED_STR)
        {
            enforce(("std.string" in g_importedModules) !is null,
                "String interpolation requires 'use std.string;'");

            string rawContent = tokens[pos].value;
            enforce(rawContent.canFind("{"),
                "Interpolated string must contain at least one {} expression. " ~
                    "Use a regular string if no interpolation is needed.");

            string interpContent = "__INTERPOLATED__" ~ tokens[pos].value ~ "__INTERPOLATED__";
            pos++;
            messages ~= interpContent;
            isExpressions ~= true;
        }
        else
        {
            string expr = "";
            while (pos < tokens.length &&
                tokens[pos].type != TokenType.SEMICOLON &&
                tokens[pos].type != TokenType.COMMA)
            {
                if (tokens[pos].type == TokenType.STR)
                    expr ~= "\"" ~ tokens[pos].value ~ "\"";
                else if (tokens[pos].type == TokenType.INTERPOLATED_STR)
                {
                    enforce(("std.string" in g_importedModules) !is null,
                        "String interpolation requires 'use std.string;'");

                    string rawContent = tokens[pos].value;
                    enforce(rawContent.canFind("${"),
                        "Interpolated string must contain at least one ${} expression. " ~
                            "Use a regular string if no interpolation is needed.");

                    expr ~= "__INTERPOLATED__" ~ tokens[pos].value ~ "__INTERPOLATED__";
                }
                else if (tokens[pos].type == TokenType.DOT)
                    expr ~= ".";
                else
                    expr ~= tokens[pos].value;
                pos++;
            }
            if (expr.length > 0)
            {
                messages ~= expr.strip();
                isExpressions ~= true;
            }
        }

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }
    }

    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
        "Expected ';' after print");
    pos++;

    if (messages.length == 0)
    {
        return new PrintNode("", false);
    }

    return new PrintNode(messages, isExpressions);
}

/**
 * Parse array literals in the form <type>[elem1, elem2, ...]
 *
 * Returns the ArrayLiteralNode, or null if not an array literal
 */
private ArrayLiteralNode tryParseArrayLiteral(ref size_t pos, Token[] tokens)
{
    size_t savedPos = pos;

    if (pos >= tokens.length || tokens[pos].type != TokenType.OPERATOR || tokens[pos].value != "<")
        return null;

    pos++; // Skip '<'

    string elementType = "";
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    if (pos >= tokens.length || tokens[pos].type != TokenType.IDENTIFIER)
    {
        pos = savedPos;
        return null;
    }

    elementType = tokens[pos].value;
    pos++;

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    if (pos >= tokens.length || tokens[pos].type != TokenType.OPERATOR || tokens[pos].value != ">")
    {
        pos = savedPos;
        return null;
    }

    pos++; // Skip '>'

    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    if (pos >= tokens.length || tokens[pos].type != TokenType.LBRACKET)
    {
        pos = savedPos;
        return null;
    }

    pos++; // Skip '['

    string[] elements;

    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
    {
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos >= tokens.length || tokens[pos].type == TokenType.RBRACKET)
            break;

        string element = "";

        while (pos < tokens.length && tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType
            .RBRACKET)
        {
            if (tokens[pos].type == TokenType.WHITESPACE)
            {
                pos++;
                continue;
            }

            if (tokens[pos].type == TokenType.STR)
                element ~= "\"" ~ tokens[pos].value ~ "\"";
            else
                element ~= tokens[pos].value;

            pos++;
        }

        if (element.strip().length > 0)
            elements ~= element.strip();

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }
    }

    if (pos >= tokens.length || tokens[pos].type != TokenType.RBRACKET)
    {
        pos = savedPos;
        return null;
    }

    pos++; // Skip ']'

    return new ArrayLiteralNode(elementType, elements);
}

/**
 * Helper to parse type.
 */
private string parseTypeHelper(ref size_t pos, Token[] tokens)
{
    import std.stdio : writeln;

    debugWriteln("[parseTypeHelper] Starting at pos=", pos);
    string typeName = "";
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    debugWriteln("[parseTypeHelper] After whitespace skip, pos=", pos);
    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
    {
        typeName = tokens[pos].value;
        debugWriteln("[parseTypeHelper] Got type name: ", typeName);
        pos++;

        // Validate that the type is not forbidden
        validateTypeNotForbidden(typeName);

        // Handle array syntax: type[] or type[size]
        while (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
        {
            typeName ~= "[";
            pos++;

            // Parse array size if present
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
            {
                typeName ~= tokens[pos].value;
                pos++;
            }

            if (pos < tokens.length && tokens[pos].type == TokenType.RBRACKET)
            {
                typeName ~= "]";
                pos++;
            }
        }

        // Handle pointer syntax: type*
        while (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "*")
        {
            typeName ~= "*";
            pos++;
        }
    }

    if (typeName in g_typeAliases)
    {
        debugWriteln("Resolved alias: ", typeName, " -> ", g_typeAliases[typeName]);
        typeName = g_typeAliases[typeName];
    }

    return typeName;
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
        Token(TokenType.RBRACE, "}"),
        Token(TokenType.MAIN, "main"),
        Token(TokenType.LBRACE, "{"),
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
        Token(TokenType.RBRACE, "}"),
        Token(TokenType.MAIN, "main"),
        Token(TokenType.LBRACE, "{"),
        Token(TokenType.RBRACE, "}")
    ];

    auto funcAst = parse(funcIfTokens);
    assert(funcAst.children[0].nodeType == "Function");
    assert((cast(IfNode) funcAst.children[0].children[0]).condition == "y == 1");
}

static immutable string[] g_forbiddenCTypes = [
    "int", "long", "short", "float", "double",
    "signed", "unsigned", "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t",
    "size_t", "ptrdiff_t", "_Bool", "NULL"
];

/**
 * Validates that a type is not a forbidden C type.
 * Throws an error if the type is forbidden.
 */
void validateTypeNotForbidden(string typeName)
{
    import std.algorithm : canFind;

    if (g_forbiddenCTypes.canFind(typeName))
    {
        throw new Exception("C type '" ~ typeName ~
                "' cannot be used directly. Use the corresponding Axe type instead (e.g., i32, u64, f32, etc.)");
    }
}

private immutable string[] C_KEYS = [
    "vsnprintf", "scanf", "fscanf", "sscanf", "vscanf", "vfscanf", "vsscanf",
    "memcpy", "memmove", "memset", "memccpy", "mempcpy",
    "strcpy", "strncpy", "strcat", "strncat", "strlcpy", "strlcat",
    "strtok", "strtok_r", "stpcpy", "stpncpy", "bcopy", "bzero",
    "perror", "system", "abort"
];

private immutable bool[string] C_KEYWORD_SET = (() {
    bool[string] map;
    foreach (keyword; C_KEYS)
        map[keyword] = true;
    return map;
})();

private void enforceNoCKeys(Token[] tokens)
{
    import std.string : strip, toLower;

    foreach (token; tokens)
    {
        if (token.type != TokenType.IDENTIFIER)
            continue;

        string ident = token.value.strip();
        if (ident.length == 0)
            continue;

        while (ident.length > 0 && (ident[$ - 1] == '*' || ident[$ - 1] == '&'))
            ident = ident[0 .. $ - 1];
        while (ident.length > 0 && (ident[0] == '*' || ident[0] == '&'))
            ident = ident[1 .. $];
        ident = ident.strip();
        if (ident.length == 0)
            continue;

        string lowerIdent = ident.toLower();
        if (lowerIdent in C_KEYWORD_SET)
            enforce(false, ident ~ " is undefined.");
    }
}

string balanceParentheses(string s)
{
    int depth = 0;
    foreach (char c; s)
    {
        if (c == '(')
            depth++;
        else if (c == ')')
            depth--;
    }
    while (depth > 0)
    {
        s ~= ')';
        depth--;
    }
    return s;
}
