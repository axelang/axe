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
 *   isAxec = Whether the source file is .axec
 * Returns: 
 *   ASTNode = Abstract syntax tree representing the parsed tokens
 */
ASTNode parse(Token[] tokens, bool isAxec = false)
{
    import std.stdio;
    import std.exception : enforce;
    import std.conv;
    import std.string;
    import std.algorithm;
    import axe.structs : Scope;

    writeln("Starting parse with tokens:");
    foreach (i, token; tokens)
    {
        writeln(i, ": ", token.type, " ('", token.value, "')");
    }

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

        while (pos < tokens.length && tokens[pos].type == TokenType.REF)
        {
            pos++;
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
        }

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
                writeln("DEBUG parseArrayType: After first ], pos=", pos, " token=", tokens[pos].type, " value='", tokens[pos]
                        .value, "'");
            else
                writeln("DEBUG parseArrayType: After first ], pos=", pos, " END OF TOKENS");

            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
            {
                writeln("DEBUG parseArrayType: Found second [");
                hasSecondDimension = true;
                pos++; // Skip '['

                if (pos < tokens.length)
                    writeln("DEBUG parseArrayType: After second [, token=", tokens[pos].type, " value='", tokens[pos]
                            .value, "'");

                while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                {
                    writeln("DEBUG parseArrayType: Adding to size2: '", tokens[pos].value, "'");
                    size2 ~= tokens[pos].value;
                    pos++;
                }

                writeln("DEBUG parseArrayType: size2='", size2, "' hasSecondDimension=", hasSecondDimension);

                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                    "Expected ']' after second array size");
                pos++; // Skip ']'
            }
        }

        return ArrayTypeInfo(elementType, size, size2, hasSecondDimension);
    }

    /** 
     * Parses println argument (string literal or expression)
     * 
     * Returns: 
     *   PrintlnNode = Node with message and isExpression flag
     */
    PrintlnNode parsePrintln()
    {
        pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.STR)
        {
            string msg = tokens[pos].value;
            pos++;
            return new PrintlnNode(msg, false);
        }
        else
        {
            string expr = "";
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (tokens[pos].type == TokenType.STR)
                    expr ~= "\"" ~ tokens[pos].value ~ "\"";
                else if (tokens[pos].type == TokenType.DOT)
                    expr ~= ".";
                else
                    expr ~= tokens[pos].value;
                pos++;
            }
            return new PrintlnNode(expr.strip(), true);
        }
    }

    /** 
     * Parses print argument (string literal or expression)
     * 
     * Returns: 
     *   PrintNode = Node with message and isExpression flag
     */
    PrintNode parsePrint()
    {
        pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.STR)
        {
            string msg = tokens[pos].value;
            pos++;
            return new PrintNode(msg, false);
        }
        else
        {
            string expr = "";
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (tokens[pos].type == TokenType.STR)
                    expr ~= "\"" ~ tokens[pos].value ~ "\"";
                else if (tokens[pos].type == TokenType.DOT)
                    expr ~= ".";
                else
                    expr ~= tokens[pos].value;
                pos++;
            }
            return new PrintNode(expr.strip(), true);
        }
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
                else if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string paramName = tokens[pos].value;
                    pos++;
                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++;

                        // Check for ref keyword before type
                        string refPrefix = "";
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;
                        if (pos < tokens.length && tokens[pos].type == TokenType.REF)
                        {
                            refPrefix = "ref ";
                            pos++;
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;
                        }

                        // Check if this is an array type
                        size_t savedPos = pos;
                        string baseType = parseType();

                        if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                        {
                            // Array parameter - parse full array type
                            pos = savedPos;
                            auto arrayInfo = parseArrayType();
                            writeln("DEBUG parseArgs: elementType='", arrayInfo.elementType, "' size='", arrayInfo.size, "' size2='", arrayInfo
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

                            writeln("DEBUG parseArgs: fullType='", fullType, "' paramName='", paramName, "'");
                            args ~= fullType ~ " " ~ paramName;
                        }
                        else
                        {
                            args ~= refPrefix ~ baseType ~ " " ~ paramName;
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
        writeln("Current token at pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

        switch (tokens[pos].type)
        {
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
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                if (tokens[pos].type == TokenType.IDENTIFIER)
                {
                    string fieldName = tokens[pos].value;
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                        "Expected ':' after field name");
                    pos++; // Skip ':'

                    string fieldType = parseType();
                    orderedFields ~= ModelNode.Field(fieldName, fieldType);
                }
                else
                {
                    pos++; // Skip whitespace/newlines
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after model body");
            pos++; // Skip '}'

            auto modelNode = new ModelNode(modelName, null);
            modelNode.fields = orderedFields;
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

            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected module name after 'use'");
            string moduleName = tokens[pos].value;
            pos++;

            // Handle module paths like "stdlib/arena" (tokenized as stdlib, /, arena)
            while (pos < tokens.length && tokens[pos].type == TokenType.SLASH)
            {
                moduleName ~= "/";
                pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected identifier after '/' in module path");
                moduleName ~= tokens[pos].value;
                pos++;
            }

            while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE))
                pos++;

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

            ast.children ~= new UseNode(moduleName, imports);
            continue;

        case TokenType.MAIN:
            // Fall through to IDENTIFIER case which handles main
            goto case TokenType.IDENTIFIER;

        case TokenType.MAIN_OLD_DELETE_ME_LATER:
            // This old MAIN case has been replaced by the one below that uses parseStatementHelper
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

                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACKET)
                            {
                                index2 ~= tokens[pos].value;
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                "Expected ']' after second array index");
                            pos++; // Skip ']'
                        }

                        // Skip whitespace
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        // Check if this is array element assignment
                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                        {
                            pos++; // Skip '='

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
                    // Check for member access (dot notation)
                    else if (pos < tokens.length && tokens[pos].type == TokenType.DOT)
                    {
                        pos++; // Skip '.'

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                            "Expected member name after '.'");
                        string memberName = tokens[pos].value;
                        pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                        {
                            if (!currentScope.isDeclared(identName))
                                enforce(false, "Undeclared variable: " ~ identName);

                            if (!currentScope.isMutable(identName))
                                enforce(false, "Cannot assign to member '" ~ memberName ~
                                        "' of immutable variable '" ~ identName ~ "'");

                            pos++; // Skip '='

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
                                "Expected ';' after member assignment");
                            pos++;

                            mainNode.children ~= new MemberAccessNode(identName, memberName, value.strip());
                        }
                        else
                        {
                            // Member read - this would be part of an expression
                            // For now, we'll handle it in println or other contexts
                            enforce(false, "Member read not yet supported in this context");
                        }
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.INCREMENT)
                    {
                        if (!currentScope.isDeclared(identName))
                            enforce(false, "Undeclared variable: " ~ identName);
                        if (!currentScope.isMutable(identName))
                            enforce(false, "Cannot increment immutable variable: " ~ identName);
                        pos++; // Skip '++'

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after increment");
                        pos++;

                        mainNode.children ~= new IncrementDecrementNode(identName, true);
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.DECREMENT)
                    {
                        if (!currentScope.isDeclared(identName))
                            enforce(false, "Undeclared variable: " ~ identName);
                        if (!currentScope.isMutable(identName))
                            enforce(false, "Cannot decrement immutable variable: " ~ identName);
                        pos++; // Skip '--'

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                            "Expected ';' after decrement");
                        pos++;

                        mainNode.children ~= new IncrementDecrementNode(identName, false);
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                    {
                        if (!currentScope.isDeclared(identName))
                            enforce(false, "Undeclared variable: " ~ identName);
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
                        string args = "";
                        pos++;

                        int parenDepth = 0;
                        while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                        {
                            if (tokens[pos].type == TokenType.LPAREN)
                            {
                                parenDepth++;
                                args ~= tokens[pos].value;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.RPAREN)
                            {
                                parenDepth--;
                                args ~= tokens[pos].value;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.WHITESPACE)
                            {
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.COMMA)
                            {
                                args ~= ", ";
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.STR)
                            {
                                args ~= "\"" ~ tokens[pos].value ~ "\"";
                                pos++;
                            }
                            else
                            {
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
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after 'loop'");
                    pos++;

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
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after 'break'");
                            pos++;
                            loopNode.children ~= new BreakNode();
                            break;

                        case TokenType.CONTINUE:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after 'continue'");
                            pos++;
                            loopNode.children ~= new ContinueNode();
                            break;

                        case TokenType.MUT:
                        case TokenType.VAL:
                            bool loopIsMutable = tokens[pos].type == TokenType.MUT;
                            pos++;

                            if (loopIsMutable)
                            {
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
                                    "Expected 'val' after 'mut'");
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                                "Expected variable name");
                            string loopVarName = tokens[pos].value;
                            pos++;

                            // Check for type annotation
                            string loopVarType = "";
                            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                            {
                                pos++; // Skip ':'
                                loopVarType = parseType();
                            }

                            string loopInitializer = "";
                            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR
                                && tokens[pos].value == "=")
                            {
                                pos++;

                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    if (tokens[pos].type == TokenType.STR)
                                        loopInitializer ~= "\"" ~ tokens[pos].value ~ "\"";
                                    else
                                        loopInitializer ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after variable declaration");
                            pos++;

                            currentScope.addVariable(loopVarName, loopIsMutable);
                            loopNode.children ~= new DeclarationNode(loopVarName, loopIsMutable, loopInitializer,
                                loopVarType);
                            break;

                        case TokenType.IDENTIFIER:
                            string loopIdentName = tokens[pos].value;
                            pos++;

                            if (pos < tokens.length && tokens[pos].type == TokenType.INCREMENT)
                            {
                                if (!currentScope.isDeclared(loopIdentName))
                                    enforce(false, "Undeclared variable: " ~ loopIdentName);
                                if (!currentScope.isMutable(loopIdentName))
                                    enforce(false, "Cannot increment immutable variable: " ~ loopIdentName);
                                pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after increment");
                                pos++;

                                loopNode.children ~= new IncrementDecrementNode(loopIdentName, true);
                            }
                            else if (pos < tokens.length && tokens[pos].type == TokenType.DECREMENT)
                            {
                                if (!currentScope.isDeclared(loopIdentName))
                                    enforce(false, "Undeclared variable: " ~ loopIdentName);
                                if (!currentScope.isMutable(loopIdentName))
                                    enforce(false, "Cannot decrement immutable variable: " ~ loopIdentName);
                                pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after decrement");
                                pos++;

                                loopNode.children ~= new IncrementDecrementNode(loopIdentName, false);
                            }
                            else
                            {
                                enforce(false, "Unexpected token after identifier in loop body: " ~ tokens[pos]
                                        .value);
                            }
                            break;

                        case TokenType.IF:
                            // Handle if statements in loops
                            pos++;

                            string loopCondition;
                            bool hasParens = false;

                            // Check if condition has parentheses
                            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                            {
                                hasParens = true;
                                pos++; // Skip '('

                                while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                                {
                                    loopCondition ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after if condition");
                                pos++; // Skip ')'
                            }
                            else
                            {
                                // Parse condition without parentheses until '{'
                                while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                                {
                                    loopCondition ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after if condition");
                            pos++;

                            auto loopIfNode = new IfNode(loopCondition);
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                if (tokens[pos].type == TokenType.BREAK)
                                {
                                    pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after 'break'");
                                    pos++;
                                    loopIfNode.children ~= new BreakNode();
                                }
                                else if (tokens[pos].type == TokenType.CONTINUE)
                                {
                                    pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after 'continue'");
                                    pos++;
                                    loopIfNode.children ~= new ContinueNode();
                                }
                                else
                                {
                                    enforce(false, "Unexpected token in if body within loop");
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after if body");
                            pos++;

                            loopNode.children ~= loopIfNode;
                            break;

                        default:
                            enforce(false, "Unexpected token in loop body: " ~ tokens[pos].value);
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;

                    mainNode.children ~= loopNode;
                    break;

                case TokenType.FOR:
                    pos++; // Skip 'for'

                    size_t savedPos = pos;
                    bool isForIn = false;
                    string forInVarName = "";
                    string forInArrayName = "";

                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        forInVarName = tokens[pos].value;
                        pos++;

                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        if (pos < tokens.length && tokens[pos].type == TokenType.IN)
                        {
                            pos++; // Skip 'in'

                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                            {
                                forInArrayName = tokens[pos].value;
                                pos++;
                                isForIn = true;
                            }
                        }
                    }

                    if (isForIn)
                    {
                        // Parse for-in loop
                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after for-in header");
                        pos++; // Skip '{'

                        auto forInNode = new ForInNode(forInVarName, forInArrayName);

                        // Register the loop variable in scope
                        currentScope.addVariable(forInVarName, false);

                        // Parse for-in loop body
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            switch (tokens[pos].type)
                            {
                            case TokenType.PRINTLN:
                                forInNode.children ~= parsePrintln();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++;
                                break;

                            case TokenType.PRINT:
                                forInNode.children ~= parsePrint();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after print");
                                pos++;
                                break;

                            case TokenType.BREAK:
                                pos++;
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after 'break'");
                                pos++;
                                forInNode.children ~= new BreakNode();
                                break;

                            case TokenType.CONTINUE:
                                pos++;
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after 'continue'");
                                pos++;
                                forInNode.children ~= new ContinueNode();
                                break;

                            default:
                                enforce(false, "Unexpected token in for-in loop body: " ~ to!string(
                                        tokens[pos].type));
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after for-in loop body");
                        pos++; // Skip '}'

                        mainNode.children ~= forInNode;
                        break;
                    }

                    // Reset position for classic for loop parsing
                    pos = savedPos;

                    // Parse initialization (mut val i = 0 or val i = 0)
                    bool forIsMutable = false;
                    string forVarName = "";
                    string forVarType = "";
                    string forInitValue = "";

                    if (pos < tokens.length && tokens[pos].type == TokenType.MUT)
                    {
                        forIsMutable = true;
                        pos++; // Skip 'mut'
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
                        "Expected 'val' in for loop initialization");
                    pos++; // Skip 'val'

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected variable name in for loop");
                    forVarName = tokens[pos].value;
                    pos++;

                    // Check for type annotation
                    if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                    {
                        pos++; // Skip ':'
                        forVarType = parseType();
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=",
                        "Expected '=' in for loop initialization");
                    pos++; // Skip '='

                    // Parse init value until semicolon
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        forInitValue ~= tokens[pos].value;
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after for loop initialization");
                    pos++; // Skip ';'

                    // Parse condition (i < 10)
                    string forCondition = "";
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        forCondition ~= tokens[pos].value;
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after for loop condition");
                    pos++; // Skip ';'

                    // Parse increment (i++)
                    string forIncrement = "";
                    while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                    {
                        forIncrement ~= tokens[pos].value;
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after for loop header");
                    pos++; // Skip '{'

                    auto forNode = new ForNode("", forCondition.strip(), forIncrement.strip());
                    forNode.isMutable = forIsMutable;
                    forNode.varName = forVarName;
                    forNode.varType = forVarType.length > 0 ? forVarType : "int";
                    forNode.initValue = forInitValue.strip();

                    // Register the loop variable in scope
                    currentScope.addVariable(forVarName, forIsMutable);

                    // Parse for loop body
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.PRINTLN:
                            forNode.children ~= parsePrintln();
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;

                        case TokenType.PRINT:
                            forNode.children ~= parsePrint();
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after print");
                            pos++;
                            break;

                        case TokenType.BREAK:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after 'break'");
                            pos++;
                            forNode.children ~= new BreakNode();
                            break;

                        case TokenType.CONTINUE:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after 'continue'");
                            pos++;
                            forNode.children ~= new ContinueNode();
                            break;

                        case TokenType.IDENTIFIER:
                            string forLoopIdentName = tokens[pos].value;
                            pos++;

                            // Skip whitespace
                            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                                pos++;

                            // Check if this is array indexing
                            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                            {
                                pos++; // Skip '['

                                string forLoopIndex = "";
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .RBRACKET)
                                {
                                    forLoopIndex ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                    "Expected ']' after array index");
                                pos++; // Skip ']'

                                // Skip whitespace
                                while (pos < tokens.length && tokens[pos].type == TokenType
                                    .WHITESPACE)
                                    pos++;

                                // Check if this is array element assignment
                                if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos]
                                    .value
                                    == "=")
                                {
                                    pos++; // Skip '='

                                    string forLoopValue = "";
                                    while (pos < tokens.length && tokens[pos].type != TokenType
                                        .SEMICOLON)
                                    {
                                        if (tokens[pos].type == TokenType.STR)
                                            forLoopValue ~= "\"" ~ tokens[pos].value ~ "\"";
                                        else
                                            forLoopValue ~= tokens[pos].value;
                                        pos++;
                                    }

                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after array assignment");
                                    pos++;

                                    forNode.children ~= new ArrayAssignmentNode(forLoopIdentName, forLoopIndex.strip(),
                                        forLoopValue.strip());
                                }
                                else
                                {
                                    enforce(false, "Array indexing without assignment not yet supported in for loop");
                                }
                            }
                            else if (pos < tokens.length && tokens[pos].type == TokenType.INCREMENT)
                            {
                                if (!currentScope.isDeclared(forLoopIdentName))
                                    enforce(false, "Undeclared variable: " ~ forLoopIdentName);
                                if (!currentScope.isMutable(forLoopIdentName))
                                    enforce(false, "Cannot increment immutable variable: " ~ forLoopIdentName);
                                pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after increment");
                                pos++;

                                forNode.children ~= new IncrementDecrementNode(forLoopIdentName, true);
                            }
                            else if (pos < tokens.length && tokens[pos].type == TokenType.DECREMENT)
                            {
                                if (!currentScope.isDeclared(forLoopIdentName))
                                    enforce(false, "Undeclared variable: " ~ forLoopIdentName);
                                if (!currentScope.isMutable(forLoopIdentName))
                                    enforce(false, "Cannot decrement immutable variable: " ~ forLoopIdentName);
                                pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after decrement");
                                pos++;

                                forNode.children ~= new IncrementDecrementNode(forLoopIdentName, false);
                            }
                            else
                            {
                                enforce(false, "Unexpected token after identifier in for loop body");
                            }
                            break;

                        case TokenType.IF:
                            // Handle if statements in for loops
                            pos++;

                            string forIfCondition;

                            // Check if condition has parentheses
                            if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                            {
                                pos++; // Skip '('

                                while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                                {
                                    forIfCondition ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after if condition");
                                pos++; // Skip ')'
                            }
                            else
                            {
                                // Parse condition without parentheses until '{'
                                while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                                {
                                    forIfCondition ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after if condition");
                            pos++;

                            auto forIfNode = new IfNode(forIfCondition);
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                if (tokens[pos].type == TokenType.BREAK)
                                {
                                    pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after 'break'");
                                    pos++;
                                    forIfNode.children ~= new BreakNode();
                                }
                                else if (tokens[pos].type == TokenType.CONTINUE)
                                {
                                    pos++;
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after 'continue'");
                                    pos++;
                                    forIfNode.children ~= new ContinueNode();
                                }
                                else if (tokens[pos].type == TokenType.PRINTLN)
                                {
                                    forIfNode.children ~= parsePrintln();
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after println");
                                    pos++;
                                }
                                else
                                {
                                    enforce(false, "Unexpected token in if body within for loop");
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after if body");
                            pos++;

                            forNode.children ~= forIfNode;
                            break;

                        default:
                            enforce(false, "Unexpected token in for loop body: " ~ tokens[pos]
                                    .value);
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after for loop body");
                    pos++;

                    mainNode.children ~= forNode;
                    break;

                case TokenType.IF:
                    pos++;

                    string condition;

                    // Check if condition has parentheses
                    if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        pos++; // Skip '('

                        while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                        {
                            condition ~= tokens[pos].value;
                            pos++;
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                            "Expected ')' after if condition");
                        pos++; // Skip ')'
                    }
                    else
                    {
                        // Parse condition without parentheses until '{'
                        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                        {
                            condition ~= tokens[pos].value;
                            pos++;
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after if condition");
                    pos++;

                    auto ifNode = new IfNode(condition);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        switch (tokens[pos].type)
                        {
                        case TokenType.PRINTLN:
                            ifNode.children ~= parsePrintln();
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after println");
                            pos++;
                            break;

                        case TokenType.PRINT:
                            ifNode.children ~= parsePrint();
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after print");
                            pos++;
                            break;

                        default:
                            enforce(false, "Unexpected token in if body");
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after if body");
                    pos++;

                    // Check for elif and else
                    while (pos < tokens.length && tokens[pos].type == TokenType.ELIF)
                    {
                        pos++; // Skip 'elif'

                        string elifCondition;

                        // Check if condition has parentheses
                        if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                        {
                            pos++; // Skip '('

                            while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                            {
                                elifCondition ~= tokens[pos].value;
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                "Expected ')' after elif condition");
                            pos++; // Skip ')'
                        }
                        else
                        {
                            // Parse condition without parentheses until '{'
                            while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                            {
                                elifCondition ~= tokens[pos].value;
                                pos++;
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after elif condition");
                        pos++;

                        auto elifNode = new IfNode(elifCondition);
                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            switch (tokens[pos].type)
                            {
                            case TokenType.PRINTLN:
                                elifNode.children ~= parsePrintln();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++;
                                break;

                            case TokenType.PRINT:
                                elifNode.children ~= parsePrint();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after print");
                                pos++;
                                break;

                            default:
                                enforce(false, "Unexpected token in elif body");
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after elif body");
                        pos++;

                        ifNode.elifBranches ~= elifNode;
                    }

                    // Check for else
                    if (pos < tokens.length && tokens[pos].type == TokenType.ELSE)
                    {
                        pos++; // Skip 'else'

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                            "Expected '{' after else");
                        pos++;

                        while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                        {
                            switch (tokens[pos].type)
                            {
                            case TokenType.PRINTLN:
                                ifNode.elseBody ~= parsePrintln();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after println");
                                pos++;
                                break;

                            case TokenType.PRINT:
                                ifNode.elseBody ~= parsePrint();
                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after print");
                                pos++;
                                break;

                            default:
                                enforce(false, "Unexpected token in else body");
                            }
                        }

                        enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                            "Expected '}' after else body");
                        pos++;
                    }

                    mainNode.children ~= ifNode;
                    break;

                case TokenType.SWITCH:
                    pos++; // Skip 'switch'

                    // Parse the switch expression
                    string switchExpr = "";
                    while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                    {
                        switchExpr ~= tokens[pos].value;
                        pos++;
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after switch expression");
                    pos++; // Skip '{'

                    auto switchNode = new SwitchNode(switchExpr.strip());

                    // Parse case statements
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        if (tokens[pos].type == TokenType.CASE)
                        {
                            pos++; // Skip 'case'

                            string caseValue = "";
                            while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
                            {
                                caseValue ~= tokens[pos].value;
                                pos++;
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after case value");
                            pos++; // Skip '{'

                            auto caseNode = new CaseNode(caseValue.strip(), false);

                            // Parse case body
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                switch (tokens[pos].type)
                                {
                                case TokenType.PRINTLN:
                                    caseNode.children ~= parsePrintln();
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after println");
                                    pos++;
                                    break;

                                case TokenType.PRINT:
                                    caseNode.children ~= parsePrint();
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after print");
                                    pos++;
                                    break;

                                default:
                                    enforce(false, "Unexpected token in case body: " ~ tokens[pos]
                                            .value);
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after case body");
                            pos++; // Skip '}'

                            switchNode.children ~= caseNode;
                        }
                        else if (tokens[pos].type == TokenType.DEFAULT)
                        {
                            pos++; // Skip 'default'

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                                "Expected '{' after default");
                            pos++; // Skip '{'

                            auto defaultNode = new CaseNode("", true);

                            // Parse default body
                            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                            {
                                switch (tokens[pos].type)
                                {
                                case TokenType.PRINTLN:
                                    defaultNode.children ~= parsePrintln();
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after println");
                                    pos++;
                                    break;

                                case TokenType.PRINT:
                                    defaultNode.children ~= parsePrint();
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after print");
                                    pos++;
                                    break;

                                default:
                                    enforce(false, "Unexpected token in default body: " ~ tokens[pos]
                                            .value);
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                                "Expected '}' after default body");
                            pos++; // Skip '}'

                            switchNode.children ~= defaultNode;
                        }
                        else
                        {
                            // Unexpected token in switch body
                            enforce(false, "Unexpected token in switch body at pos " ~ pos.to!string ~
                                    ": " ~ tokens[pos].type.to!string ~ " ('" ~ tokens[pos].value ~ "')");
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after switch body");
                    pos++; // Skip '}'

                    mainNode.children ~= switchNode;
                    break;

                case TokenType.MUT:
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
                        "Expected 'val' after 'mut'");
                    goto case TokenType.VAL;

                case TokenType.VAL:
                    bool isMutable = tokens[pos - 1].type == TokenType.MUT;
                    pos++;

                    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
                    {
                        string varName = tokens[pos].value;
                        pos++;

                        // Check for type annotation
                        string typeName = "";
                        bool isArray = false;
                        string arraySize = "";
                        string arraySize2 = "";
                        int refDepth = 0;

                        if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                        {
                            pos++; // Skip ':'

                            // Check for ref modifiers
                            refDepth = parseRefDepth();

                            // Check if this is an array type
                            size_t savedPos = pos;
                            string baseType = parseType();

                            if (pos < tokens.length && tokens[pos].type == TokenType.LBRACKET)
                            {
                                isArray = true;
                                pos = savedPos;
                                auto arrayInfo = parseArrayType();
                                typeName = arrayInfo.elementType;
                                arraySize = arrayInfo.size;
                                arraySize2 = arrayInfo.size2;
                            }
                            else
                            {
                                typeName = baseType;
                            }
                        }

                        string initializer = "";
                        if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                        {
                            pos++;

                            // Check if this is a model instantiation
                            if (pos < tokens.length && tokens[pos].type == TokenType.NEW)
                            {
                                pos++; // Skip 'new'

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                                    "Expected model name after 'new'");
                                string modelName = tokens[pos].value;
                                pos++;

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
                                    "Expected '(' after model name");
                                pos++; // Skip '('

                                string[string] fieldValues;
                                while (pos < tokens.length && tokens[pos].type != TokenType.RPAREN)
                                {
                                    if (tokens[pos].type == TokenType.IDENTIFIER)
                                    {
                                        string fieldName = tokens[pos].value;
                                        pos++;

                                        enforce(pos < tokens.length && tokens[pos].type == TokenType.COLON,
                                            "Expected ':' after field name in model instantiation");
                                        pos++; // Skip ':'

                                        string fieldValue = "";
                                        while (pos < tokens.length && tokens[pos].type != TokenType.COMMA
                                            && tokens[pos].type != TokenType.RPAREN)
                                        {
                                            if (tokens[pos].type == TokenType.STR)
                                                fieldValue ~= "\"" ~ tokens[pos].value ~ "\"";
                                            else
                                                fieldValue ~= tokens[pos].value;
                                            pos++;
                                        }

                                        fieldValues[fieldName] = fieldValue.strip();

                                        if (pos < tokens.length && tokens[pos].type == TokenType
                                            .COMMA)
                                            pos++; // Skip ','
                                    }
                                    else
                                    {
                                        pos++; // Skip whitespace/newlines
                                    }
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
                                    "Expected ')' after model instantiation");
                                pos++; // Skip ')'

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after model instantiation");
                                pos++;

                                currentScope.addVariable(varName, isMutable);
                                mainNode.children ~= new ModelInstantiationNode(
                                    modelName, varName, fieldValues, isMutable);
                            }
                            else if (isArray && pos < tokens.length && tokens[pos].type == TokenType
                                .LBRACKET)
                            {
                                // Array literal initialization [1, 2, 3]
                                pos++; // Skip '['

                                string[] arrayElements;
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .RBRACKET)
                                {
                                    string element = "";
                                    while (pos < tokens.length && tokens[pos].type != TokenType.COMMA
                                        && tokens[pos].type != TokenType.RBRACKET)
                                    {
                                        if (tokens[pos].type == TokenType.STR)
                                            element ~= "\"" ~ tokens[pos].value ~ "\"";
                                        else
                                            element ~= tokens[pos].value;
                                        pos++;
                                    }

                                    if (element.strip().length > 0)
                                        arrayElements ~= element.strip();

                                    if (pos < tokens.length && tokens[pos].type == TokenType.COMMA)
                                        pos++; // Skip ','
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACKET,
                                    "Expected ']' after array literal");
                                pos++; // Skip ']'

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after array declaration");
                                pos++;

                                // If no size specified, use array literal length
                                if (arraySize.length == 0)
                                    arraySize = to!string(arrayElements.length);

                                currentScope.addVariable(varName, isMutable);
                                mainNode.children ~= new ArrayDeclarationNode(varName, isMutable, typeName, arraySize,
                                    arrayElements, arraySize2);
                            }
                            else
                            {
                                // Regular variable initialization
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    if (tokens[pos].type == TokenType.STR)
                                        initializer ~= "\"" ~ tokens[pos].value ~ "\"";
                                    else
                                        initializer ~= tokens[pos].value;
                                    pos++;
                                }

                                enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                    "Expected ';' after val declaration");
                                pos++;

                                currentScope.addVariable(varName, isMutable);

                                if (isArray)
                                    mainNode.children ~= new ArrayDeclarationNode(varName, isMutable,
                                        typeName, arraySize, [], arraySize2);
                                else
                                    mainNode.children ~= new DeclarationNode(varName, isMutable, initializer, typeName, refDepth);
                            }
                        }
                        else
                        {
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after val declaration");
                            pos++;

                            currentScope.addVariable(varName, isMutable);

                            if (isArray)
                                mainNode.children ~= new ArrayDeclarationNode(varName, isMutable, typeName, arraySize, [
                                    ], arraySize2);
                            else
                                mainNode.children ~= new DeclarationNode(varName, isMutable, initializer, typeName, refDepth);
                        }
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
                    pos++; // Skip '}'

                    mainNode.children ~= new RawCNode(rawCode);
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
                            while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                            {
                                if (tokens[pos].type == TokenType.LPAREN)
                                {
                                    parenDepth++;
                                    args ~= tokens[pos].value;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.RPAREN)
                                {
                                    parenDepth--;
                                    args ~= tokens[pos].value;
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.WHITESPACE)
                                {
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.COMMA)
                                {
                                    args ~= ", ";
                                    pos++;
                                }
                                else if (tokens[pos].type == TokenType.STR)
                                {
                                    args ~= "\"" ~ tokens[pos].value ~ "\"";
                                    pos++;
                                }
                                else
                                {
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

                writeln("Exited main block at pos ", pos);
                writeln("Current token: ", pos < tokens.length ? to!string(
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

            // Parse macro body (currently only supports raw blocks)
            while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
            {
                if (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                    .NEWLINE)
                {
                    pos++;
                    continue;
                }

                if (tokens[pos].type == TokenType.RAW)
                {
                    enforce(isAxec, "Raw C blocks are only allowed in .axec files");
                    pos++; // Skip 'raw'

                    while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                            .NEWLINE))
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after 'raw'");
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected raw code content");
                    string rawCode = tokens[pos].value;
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after raw block");
                    pos++;

                    macroNode.children ~= new RawCNode(rawCode);
                }
                else
                {
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                "Expected '}' after macro body");
            pos++;

            ast.children ~= macroNode;
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
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after function declaration");
            pos++;

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

                case TokenType.PRINTLN, TokenType.PRINT:
                    auto stmt = parseSimpleStatement();
                    if (stmt !is null)
                        funcNode.children ~= stmt;
                    break;

                case TokenType.IF:
                    // Use parseIfHelper to handle if/elif/else chains
                    auto ifNode = parseIfHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                    funcNode.children ~= ifNode;
                    break;

                case TokenType.IDENTIFIER:
                    string identName = tokens[pos].value;
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    // Check for member access (dot notation)
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
                            // Check if the object is mutable
                            if (!currentScope.isDeclared(identName))
                            {
                                enforce(false, "Undeclared variable: " ~ identName);
                            }
                            if (!currentScope.isMutable(identName))
                            {
                                enforce(false, "Cannot assign to member of immutable variable: " ~ identName);
                            }

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
                            funcNode.children ~= new AssignmentNode(identName ~ "." ~ fieldName, value.strip());
                        }
                        else
                        {
                            enforce(false, "Expected '=' after member access");
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
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
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

                        funcNode.children ~= new AssignmentNode(identName, expr);
                    }
                    else if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
                    {
                        // Function call
                        pos++;
                        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                            pos++;

                        string functionArgs;
                        int parenDepth = 0;
                        while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                        {
                            if (tokens[pos].type == TokenType.LPAREN)
                            {
                                parenDepth++;
                                functionArgs ~= tokens[pos].value;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.RPAREN)
                            {
                                parenDepth--;
                                functionArgs ~= tokens[pos].value;
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.WHITESPACE)
                            {
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.COMMA)
                            {
                                functionArgs ~= ", ";
                                pos++;
                            }
                            else if (tokens[pos].type == TokenType.STR)
                            {
                                functionArgs ~= "\"" ~ tokens[pos].value ~ "\"";
                                pos++;
                            }
                            else
                            {
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
                    funcNode.children ~= parseLoopHelper(pos, tokens, currentScope, currentScopeNode, isAxec);
                    break;

                case TokenType.LOOP_OLD_REMOVE_ME:
                    pos++;
                    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                        pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                        "Expected '{' after loop");
                    pos++;

                    ASTNode loopNode = new LoopNode();
                    currentScopeNode = loopNode;
                    writeln("Entering loop body at pos ", pos);
                    while (pos < tokens.length && tokens[pos].type != TokenType.RBRACE)
                    {
                        writeln("Loop body pos ", pos, ": ", tokens[pos].type, " ('", tokens[pos].value, "')");

                        switch (tokens[pos].type)
                        {
                        case TokenType.WHITESPACE, TokenType.NEWLINE:
                            pos++;
                            break;

                        case TokenType.PRINTLN, TokenType.PRINT:
                            auto stmt = parseSimpleStatement();
                            if (stmt !is null)
                                loopNode.children ~= stmt;
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
                                    (tokens[pos].value == "==" || tokens[pos].value == ">" || tokens[pos].value == "<"
                                        || tokens[pos].value == ">=" || tokens[pos].value == "<=" || tokens[pos]
                                        .value ==
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
                            currentScopeNode = ifNode;
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
                                case TokenType.RETURN:
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;
                                    string returnExpr = "";
                                    while (pos < tokens.length && tokens[pos].type != TokenType
                                        .SEMICOLON)
                                    {
                                        returnExpr ~= tokens[pos].value;
                                        pos++;
                                    }
                                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                        "Expected ';' after return statement");
                                    pos++;
                                    ifNode.children ~= new ReturnNode(returnExpr);
                                    break;
                                case TokenType.WHITESPACE, TokenType.NEWLINE:
                                    pos++;
                                    break;
                                case TokenType.PRINTLN, TokenType.PRINT:
                                    auto stmt = parseSimpleStatement();
                                    if (stmt !is null)
                                        ifNode.children ~= stmt;
                                    break;
                                case TokenType.IDENTIFIER:
                                    string varName = tokens[pos].value;
                                    if (!currentScope.isDeclared(varName))
                                    {
                                        enforce(false, "Undeclared variable: " ~ varName);
                                    }
                                    pos++;
                                    while (pos < tokens.length && tokens[pos].type == TokenType
                                        .WHITESPACE)
                                        pos++;

                                    // Check if this is an assignment
                                    if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR
                                        && tokens[pos].value == "=")
                                    {
                                        pos++;
                                        while (pos < tokens.length && tokens[pos].type == TokenType
                                            .WHITESPACE)
                                            pos++;

                                        string expr = "";
                                        while (pos < tokens.length && tokens[pos].type != TokenType
                                            .SEMICOLON)
                                        {
                                            expr ~= tokens[pos].value;
                                            pos++;
                                        }

                                        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                            "Expected ';' after assignment");
                                        pos++;

                                        ifNode.children ~= new AssignmentNode(varName, expr);
                                    }
                                    else
                                    {
                                        enforce(false, "Expected '=' after identifier in if block");
                                    }
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
                            currentScopeNode = loopNode;
                            loopNode.children ~= ifNode;
                            break;

                        case TokenType.IDENTIFIER:
                            string varName = tokens[pos].value;
                            if (!currentScope.isDeclared(varName))
                            {
                                enforce(false, "Undeclared variable: " ~ varName);
                            }
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

                                string expr = "";
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    expr ~= tokens[pos].value;
                                    pos++;
                                }

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
                                int parenDepth = 0;
                                while (pos < tokens.length && (tokens[pos].type != TokenType.RPAREN || parenDepth > 0))
                                {
                                    if (tokens[pos].type == TokenType.LPAREN)
                                    {
                                        parenDepth++;
                                        args ~= tokens[pos].value;
                                        pos++;
                                    }
                                    else if (tokens[pos].type == TokenType.RPAREN)
                                    {
                                        parenDepth--;
                                        args ~= tokens[pos].value;
                                        pos++;
                                    }
                                    else if (tokens[pos].type == TokenType.WHITESPACE)
                                    {
                                        pos++;
                                    }
                                    else if (tokens[pos].type == TokenType.COMMA)
                                    {
                                        args ~= ", ";
                                        pos++;
                                    }
                                    else if (tokens[pos].type == TokenType.STR)
                                    {
                                        args ~= "\"" ~ tokens[pos].value ~ "\"";
                                        pos++;
                                    }
                                    else
                                    {
                                        args ~= tokens[pos].value;
                                        pos++;
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

                        case TokenType.MUT:
                            pos++;
                            enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
                                "Expected 'val' after 'mut'");
                            goto case TokenType.VAL;

                        case TokenType.VAL:
                            bool loopIsMutable = tokens[pos - 1].type == TokenType.MUT;
                            pos++;

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                                "Expected identifier after 'val'");
                            string loopVarName = tokens[pos].value;
                            pos++;

                            string loopTypeName = "";
                            string loopInitializer = "";

                            if (pos < tokens.length && tokens[pos].type == TokenType.COLON)
                            {
                                pos++;
                                loopTypeName = parseType();
                            }

                            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                            {
                                pos++;
                                while (pos < tokens.length && tokens[pos].type != TokenType
                                    .SEMICOLON)
                                {
                                    if (tokens[pos].type == TokenType.STR)
                                        loopInitializer ~= "\"" ~ tokens[pos].value ~ "\"";
                                    else
                                        loopInitializer ~= tokens[pos].value;
                                    pos++;
                                }
                            }

                            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                                "Expected ';' after variable declaration");
                            pos++;

                            currentScope.addVariable(loopVarName, loopIsMutable);
                            loopNode.children ~= new DeclarationNode(loopVarName, loopIsMutable, loopInitializer, loopTypeName);
                            break;

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
                            enforce(false, "Unexpected token in loop body at " ~ to!string(
                                    pos) ~ ": "
                                    ~ to!string(
                                        tokens[pos].type) ~ " ('" ~ tokens[pos].value ~ "')");
                        }
                    }

                    writeln("Exited loop body at pos ", pos);
                    writeln("Current token: ", pos < tokens.length ? to!string(tokens[pos].type) : "EOF", " ('",
                        pos < tokens.length ? tokens[pos].value : "", "')");
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.RBRACE,
                        "Expected '}' after loop body");
                    pos++;
                    currentScopeNode = funcNode;
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

                case TokenType.MUT:
                    pos++;
                    enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
                        "Expected 'val' after 'mut'");
                    goto case TokenType.VAL;

                case TokenType.VAL:
                    bool isMutable = tokens[pos - 1].type == TokenType.MUT;
                    pos++;

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                        "Expected identifier after 'val'");
                    string varName = tokens[pos].value;
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

                        typeName = parseType();
                    }

                    if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
                    {
                        pos++;
                        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                        {
                            if (tokens[pos].type == TokenType.STR)
                                initializer ~= "\"" ~ tokens[pos].value ~ "\"";
                            else
                                initializer ~= tokens[pos].value;
                            pos++;
                        }
                    }

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after variable declaration");
                    pos++;

                    currentScope.addVariable(varName, isMutable);
                    funcNode.children ~= new DeclarationNode(varName, isMutable, initializer, typeName, refDepth);
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

/**
 * Parse a single statement recursively (module-level helper).
 * Returns null for whitespace/newlines.
 */
private ASTNode parseStatementHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.array : join;
    import std.stdio : writeln;

    writeln("[parseStatementHelper] pos=", pos, " token=", tokens[pos].type, " value='", tokens[pos].value, "'");

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

        enforce(pos < tokens.length && tokens[pos].type == TokenType.LPAREN,
            "Expected '(' after 'assert'");
        pos++;

        // Parse condition (everything until comma)
        string condition = "";
        int parenDepth = 0;
        while (pos < tokens.length)
        {
            if (tokens[pos].type == TokenType.LPAREN)
                parenDepth++;
            else if (tokens[pos].type == TokenType.RPAREN)
            {
                if (parenDepth == 0)
                    break;
                parenDepth--;
            }
            else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                break;

            if (tokens[pos].type != TokenType.WHITESPACE && tokens[pos].type != TokenType.NEWLINE)
            {
                // Preserve quotes for string literals
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

        // Parse message (should be a string)
        enforce(pos < tokens.length && tokens[pos].type == TokenType.STR,
            "Expected string message after comma in assert");
        string message = tokens[pos].value;
        pos++;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.RPAREN,
            "Expected ')' after assert message");
        pos++;

        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after assert statement");
        pos++;

        writeln("[ASSERT] Final condition: '", condition.strip(), "'");
        writeln("[ASSERT] Message: '", message, "'");
        return new AssertNode(condition.strip(), message);

    case TokenType.CONTINUE:
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after continue");
        pos++;
        return new ContinueNode();

    case TokenType.LOOP:
        return parseLoopHelper(pos, tokens, currentScope, currentScopeNode, isAxec);

    case TokenType.FOR:
        pos++; // Skip 'for'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        // Check if this is a for-in loop or C-style for loop
        // Look ahead to see if there's an 'in' keyword
        size_t lookAhead = pos;
        bool isForIn = false;
        while (lookAhead < tokens.length && tokens[lookAhead].type != TokenType.LBRACE && tokens[lookAhead].type != TokenType
            .SEMICOLON)
        {
            if (tokens[lookAhead].type == TokenType.IN)
            {
                isForIn = true;
                break;
            }
            lookAhead++;
        }

        if (isForIn)
        {
            // for-in loop: for item in collection { }
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

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after for-in");
            pos++;

            auto forInNode = new ForInNode(itemVar, collection);
            auto prevScope = currentScopeNode;
            currentScopeNode = forInNode;
            currentScope.addVariable(itemVar, false); // Loop variable is immutable

            // Parse for-in body
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

            // Parse init - handle variable declaration
            if (pos < tokens.length && tokens[pos].type == TokenType.MUT)
            {
                isMutable = true;
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;
            }

            if (pos < tokens.length && tokens[pos].type == TokenType.VAL)
            {
                pos++;
                while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                    pos++;

                enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                    "Expected variable name in for init");
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
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
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
                // No variable declaration, just an expression
                while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                {
                    init ~= tokens[pos].value;
                    pos++;
                }
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after for init");
            pos++;

            // Parse condition (until semicolon)
            while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
            {
                if (tokens[pos].type != TokenType.WHITESPACE)
                    condition ~= tokens[pos].value;
                pos++;
            }
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after for condition");
            pos++;

            // Parse increment (until '{')
            while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
            {
                if (tokens[pos].type != TokenType.WHITESPACE)
                    increment ~= tokens[pos].value;
                pos++;
            }

            enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
                "Expected '{' after for increment");
            pos++;

            // Build initialization string
            string initStr = "";
            if (varName.length > 0)
            {
                // Default to int if no type specified
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

                auto defaultNode = new CaseNode("default");

                // Parse default body
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
        writeln("[MUT case] Starting at pos=", pos);
        pos++;
        writeln("[MUT case] After pos++, pos=", pos, " token=", tokens[pos].type);
        while (pos < tokens.length && (tokens[pos].type == TokenType.WHITESPACE || tokens[pos].type == TokenType
                .NEWLINE))
            pos++;
        writeln("[MUT case] After whitespace skip, pos=", pos, " token=", tokens[pos].type);
        enforce(pos < tokens.length && tokens[pos].type == TokenType.VAL,
            "Expected 'val' after 'mut'");
        writeln("[MUT case] About to goto VAL case");
        goto case TokenType.VAL;

    case TokenType.VAL:
        {
            writeln("[VAL case] Starting at pos=", pos);
            // Check if previous non-whitespace token was MUT
            size_t checkPos = pos - 1;
            while (checkPos > 0 && (tokens[checkPos].type == TokenType.WHITESPACE || tokens[checkPos].type == TokenType
                    .NEWLINE))
                checkPos--;
            bool isMutable = tokens[checkPos].type == TokenType.MUT;
            writeln("[VAL case] isMutable=", isMutable);

            pos++;
            writeln("[VAL case] After pos++, pos=", pos);
            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;
            writeln("[VAL case] After whitespace skip, pos=", pos, " token=", tokens[pos].type);
            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected identifier after 'val'");
            string varName = tokens[pos].value;
            writeln("[VAL case] varName=", varName);
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
                writeln("[VAL case] After parseTypeHelper, typeName=", typeName, " pos=", pos);
            }

            writeln("[VAL case] Before checking for =, pos=", pos, " token=", tokens[pos].type);
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
                            while (pos < tokens.length && tokens[pos].type != TokenType.COMMA && tokens[pos].type != TokenType
                                .RPAREN)
                            {
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

                    enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                        "Expected ';' after model instantiation");
                    pos++;

                    currentScope.addVariable(varName, isMutable);
                    return new ModelInstantiationNode(modelName, varName, fieldValues, isMutable);
                }
                else
                {
                    // Regular initialization
                    writeln("[VAL case] Parsing initializer, starting at pos=", pos);
                    while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
                    {
                        writeln("[VAL case] Initializer loop: pos=", pos, " token=", tokens[pos]
                                .type);
                        if (initializer.length > 0 && tokens[pos].type != TokenType.LPAREN &&
                            tokens[pos].type != TokenType.RPAREN && tokens[pos].type != TokenType
                            .COMMA)
                        {
                            // Add space before token (except for parens and commas)
                            initializer ~= " ";
                        }
                        if (tokens[pos].type == TokenType.STR)
                            initializer ~= "\"" ~ tokens[pos].value ~ "\"";
                        else
                            initializer ~= tokens[pos].value;
                        pos++;
                    }
                    writeln("[VAL case] After initializer loop, initializer=", initializer);
                }
            }

            writeln("[VAL case] Before final semicolon check, pos=", pos);
            enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
                "Expected ';' after variable declaration");
            pos++;

            writeln("[VAL case] About to return DeclarationNode");
            currentScope.addVariable(varName, isMutable);
            return new DeclarationNode(varName, isMutable, initializer, typeName, refDepth);
        }

    case TokenType.IDENTIFIER:
        string identName = tokens[pos].value;
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        if (pos < tokens.length && tokens[pos].type == TokenType.DOT)
        {
            // Field access: obj.field = value
            pos++; // Skip '.'
            enforce(pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER,
                "Expected field name after '.'");
            string fieldName = tokens[pos].value;
            pos++;

            while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
                pos++;

            if (pos < tokens.length && tokens[pos].type == TokenType.OPERATOR && tokens[pos].value == "=")
            {
                // Check if the object is mutable
                if (!currentScope.isDeclared(identName))
                {
                    enforce(false, "Undeclared variable: " ~ identName);
                }
                if (!currentScope.isMutable(identName))
                {
                    enforce(false, "Cannot assign to member of immutable variable: " ~ identName);
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
                // Use AssignmentNode with dot notation for field assignment
                return new AssignmentNode(identName ~ "." ~ fieldName, value.strip());
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
                    currentArg ~= tokens[pos].value;
                    pos++;
                }
                else if (tokens[pos].type == TokenType.COMMA && parenDepth == 0)
                {
                    args ~= currentArg.strip();
                    currentArg = "";
                    pos++;
                }
                else if (tokens[pos].type == TokenType.WHITESPACE)
                {
                    pos++;
                }
                else if (tokens[pos].type == TokenType.STR)
                {
                    currentArg ~= "\"" ~ tokens[pos].value ~ "\"";
                    pos++;
                }
                else
                {
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
                return new FunctionCallNode(identName, args.join(", "));
            }
        }
        return null;

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
        return new ReturnNode(returnExpr);

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

    default:
        // Safeguard: if we don't recognize the token, we must advance to prevent infinite loops
        writeln("[parseStatementHelper] WARNING: Unhandled token type ", tokens[pos].type, " at pos ", pos);
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

    writeln("[parseIfHelper] Entering at pos=", pos);

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
            cond ~= tokens[pos].value ~ " ";
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
        writeln("[parseIfHelper] Found elif at pos=", pos);
        pos++; // Skip 'elif'
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;

        string elifCond = "";
        bool elifHasParen = false;
        if (pos < tokens.length && tokens[pos].type == TokenType.LPAREN)
        {
            elifHasParen = true;
            pos++;
        }

        while (pos < tokens.length && tokens[pos].type != TokenType.LBRACE)
        {
            if (elifHasParen && tokens[pos].type == TokenType.RPAREN)
            {
                pos++;
                break;
            }
            if (tokens[pos].type != TokenType.WHITESPACE)
                elifCond ~= tokens[pos].value ~ " ";
            pos++;
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
        writeln("[parseIfHelper] Found else at pos=", pos);
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
private LoopNode parseLoopHelper(ref size_t pos, Token[] tokens, ref Scope currentScope, ref ASTNode currentScopeNode, bool isAxec)
{
    import std.stdio : writeln;

    writeln("[parseLoopHelper] Entering at pos=", pos);

    pos++; // Skip 'loop'
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    enforce(pos < tokens.length && tokens[pos].type == TokenType.LBRACE,
        "Expected '{' after loop");
    pos++;

    auto loopNode = new LoopNode();
    auto previousScope = currentScopeNode;
    currentScopeNode = loopNode;

    // Parse loop body using recursive parseStatementHelper
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

    if (pos < tokens.length && tokens[pos].type == TokenType.STR)
    {
        string msg = tokens[pos].value;
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after println");
        pos++;
        return new PrintlnNode(msg, false);
    }
    else
    {
        string expr = "";
        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
        {
            if (tokens[pos].type == TokenType.STR)
                expr ~= "\"" ~ tokens[pos].value ~ "\"";
            else if (tokens[pos].type == TokenType.DOT)
                expr ~= ".";
            else
                expr ~= tokens[pos].value;
            pos++;
        }
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after println");
        pos++;
        return new PrintlnNode(expr.strip(), true);
    }
}

/**
 * Helper to parse print statement.
 */
private PrintNode parsePrintHelper(ref size_t pos, Token[] tokens)
{
    pos++;

    if (pos < tokens.length && tokens[pos].type == TokenType.STR)
    {
        string msg = tokens[pos].value;
        pos++;
        while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
            pos++;
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after print");
        pos++;
        return new PrintNode(msg, false);
    }
    else
    {
        string expr = "";
        while (pos < tokens.length && tokens[pos].type != TokenType.SEMICOLON)
        {
            if (tokens[pos].type == TokenType.STR)
                expr ~= "\"" ~ tokens[pos].value ~ "\"";
            else if (tokens[pos].type == TokenType.DOT)
                expr ~= ".";
            else
                expr ~= tokens[pos].value;
            pos++;
        }
        enforce(pos < tokens.length && tokens[pos].type == TokenType.SEMICOLON,
            "Expected ';' after print");
        pos++;
        return new PrintNode(expr.strip(), true);
    }
}

/**
 * Helper to parse type.
 */
private string parseTypeHelper(ref size_t pos, Token[] tokens)
{
    import std.stdio : writeln;

    writeln("[parseTypeHelper] Starting at pos=", pos);
    string typeName = "";
    while (pos < tokens.length && tokens[pos].type == TokenType.WHITESPACE)
        pos++;

    writeln("[parseTypeHelper] After whitespace skip, pos=", pos);
    if (pos < tokens.length && tokens[pos].type == TokenType.IDENTIFIER)
    {
        typeName = tokens[pos].value;
        writeln("[parseTypeHelper] Got type name: ", typeName);
        pos++;

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
