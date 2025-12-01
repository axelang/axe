/** 
 * Axe Programming Language Compiler.
 * Author: Navid Momtahen (C) 2025
 * License: GPL-3.0
 * 
 * Handles the rendering process.
 */

module axe.renderer;

import axe.structs;
import axe.gstate;
import axe.imports;
import std.string;
import std.array;
import std.exception;
import std.algorithm;
import std.file;
import std.process;
import std.path;
import std.stdio;
import std.ascii;
import std.string;

static immutable string[string] g_typeMappings = [
    "i8": "int8_t",
    "u8": "uint8_t",
    "i16": "int16_t",
    "u16": "uint16_t",
    "i32": "int32_t",
    "u32": "uint32_t",
    "i64": "int64_t",
    "u64": "uint64_t",
    "isize": "intptr_t",
    "usize": "uintptr_t",
    "f32": "float",
    "f64": "double",
    "bool": "bool",
    "char": "char",
    "rchar": "char*",
    "byte": "uint8_t",
    "ptrdiff": "isize"
];

private int[string] g_refDepths;
private bool[string] g_isMutable;
private string[string] g_arrayWidthVars;
private int[][string] g_functionParamReordering;
private MacroNode[string] g_macros;
private bool[string] g_pointerFields;
private string[string] g_listOfTypes;
private bool[string] g_listElementTypes;
private string[string] g_fieldTypes;
private string[string] g_varType;
private string[string] g_isPointerVar;
private string[string] g_functionPrefixes;
private string[string] g_modelNames;
private bool[string] g_generatedTypedefs;
private bool[string] g_generatedFunctions;
private bool[string] g_enumNames;
private string[string] g_enumValueToEnumName;
private bool g_inTopLevel = false;
private string g_currentModuleName = "";
private bool[string] g_localFunctions;
private string[string] g_globalVarPrefixes;

void setCurrentModuleName(string moduleName)
{
    g_currentModuleName = moduleName.replace(".", "__").replace("/", "__");
}

string canonicalModelCName(string name)
{
    if (name in g_modelNames)
        return g_modelNames[name];

    foreach (baseName, cName; g_modelNames)
    {
        if (cName == name)
            return cName;
    }

    return "";
}

string formatModelFieldType(string fieldType)
{
    import std.string : strip, startsWith;

    string trimmed = fieldType.strip();
    string qualifiers;

    while (trimmed.startsWith("const "))
    {
        qualifiers ~= "const ";
        trimmed = trimmed[6 .. $].strip();
    }

    while (trimmed.startsWith("volatile "))
    {
        qualifiers ~= "volatile ";
        trimmed = trimmed[8 .. $].strip();
    }

    bool hadStructPrefix = false;
    if (trimmed.startsWith("struct "))
    {
        hadStructPrefix = true;
        trimmed = trimmed[7 .. $].strip();
    }

    string pointerSuffix;
    while (trimmed.length > 0 && trimmed[$ - 1] == '*')
    {
        pointerSuffix ~= "*";
        trimmed = trimmed[0 .. $ - 1].strip();
    }

    auto modelName = canonicalModelCName(trimmed);
    if (modelName.length > 0)
    {
        // Check if it's an enum - enums don't need the 'struct' prefix
        if (modelName in g_enumNames)
        {
            trimmed = modelName;
        }
        else
        {
            trimmed = "struct " ~ modelName;
        }
    }
    else if (hadStructPrefix)
    {
        trimmed = "struct " ~ trimmed;
    }

    return qualifiers ~ trimmed ~ pointerSuffix;
}

void collectExternalImports(ASTNode node, ref string[] globalHeaders, ref string[][string] platformHeaders,
    string currentPlatform = null)
{
    import std.algorithm : canFind;

    if (node.nodeType == "ExternalImport")
    {
        auto ext = cast(ExternalImportNode) node;
        if (ext is null)
            return;

        if (currentPlatform is null)
        {
            if (!globalHeaders.canFind(ext.headerFile))
                globalHeaders ~= ext.headerFile;
        }
        else
        {
            auto p = currentPlatform in platformHeaders;
            if (p is null)
            {
                platformHeaders[currentPlatform] = [ext.headerFile];
            }
            else
            {
                if (!(*p).canFind(ext.headerFile))
                    (*p) ~= ext.headerFile;
            }
        }
        return;
    }

    if (node.nodeType == "Platform")
    {
        auto platformNode = cast(PlatformNode) node;
        if (platformNode is null)
            return;

        string platformName = platformNode.platform;
        foreach (child; platformNode.children)
        {
            collectExternalImports(child, globalHeaders, platformHeaders, platformName);
        }
        return;
    }

    foreach (child; node.children)
    {
        collectExternalImports(child, globalHeaders, platformHeaders, currentPlatform);
    }
}

struct ParamInfo
{
    string type;
    string name;
    bool isArray;
    int dimensions;
    bool isDimension;
    string[] dimNames;
}

/** 
 * Function to compute reordered C parameters for functions with variable-length arrays.
 * Returns the reordered parameter strings, reorder map, and parameter info array.
 */
string[] computeReorderedCParams(FunctionNode funcNode, out int[] reorderMap, out ParamInfo[] paramInfos)
{
    import std.stdio : writeln;
    import std.string : split, strip, indexOf, lastIndexOf;
    import std.algorithm : count;
    import std.regex : regex, matchAll;

    foreach (param; funcNode.params)
    {
        debugWriteln("DEBUG: Processing param: '", param, "'");
        auto lastSpace = param.lastIndexOf(' ');
        while (lastSpace > 0)
        {
            int openBrackets = 0;
            for (size_t i = 0; i < lastSpace; i++)
            {
                if (param[i] == '[')
                    openBrackets++;
                if (param[i] == ']')
                    openBrackets--;
            }
            if (openBrackets == 0)
                break;
            lastSpace = param[0 .. lastSpace].lastIndexOf(' ');
        }

        if (lastSpace > 0)
        {
            string paramType = param[0 .. lastSpace].strip();
            string paramName = param[lastSpace + 1 .. $].strip();

            ParamInfo info;
            info.type = paramType;
            info.name = paramName;
            info.isArray = paramType.canFind('[');
            info.dimensions = 0;
            info.isDimension = false;
            info.dimNames = [];

            if (info.isArray)
            {
                info.dimensions = cast(int) paramType.count('[');

                auto dimPattern = regex(r"\[([^\]]+)\]");
                foreach (match; matchAll(paramType, dimPattern))
                {
                    info.dimNames ~= match[1].strip();
                }
            }
            paramInfos ~= info;
        }
    }

    // Second pass: reorder so dimensions come before arrays
    // and convert array syntax to VLA
    string[] dimensionParams;
    string[] otherParams;

    bool[string] referencedDimensions;
    foreach (info; paramInfos)
    {
        if (info.isArray)
        {
            foreach (dimName; info.dimNames)
            {
                referencedDimensions[dimName] = true;
            }
        }
    }

    int[] dimensionIndices;
    int[] otherIndices;

    for (int i = 0; i < paramInfos.length; i++)
    {
        if (!paramInfos[i].isArray && paramInfos[i].name in referencedDimensions)
            dimensionIndices ~= i;
        else
            otherIndices ~= i;
    }

    foreach (info; paramInfos)
    {
        if (info.isArray)
        {
            if (info.type.endsWith("[999]"))
            {
                string listType = mapAxeTypeToCForReturnOrParam(info.type);
                otherParams ~= listType ~ "* " ~ info.name;
            }
            else
            {
                auto bracketPos = info.type.indexOf('[');
                string baseType = info.type[0 .. bracketPos].strip();

                while (baseType.startsWith("ref "))
                {
                    baseType = baseType[4 .. $].strip();
                }
                while (baseType.startsWith("mut "))
                {
                    baseType = baseType[4 .. $].strip();
                }

                baseType = mapAxeTypeToC(baseType);

                if (info.dimNames.length > 0)
                {
                    string dimString = "";
                    foreach (dimName; info.dimNames)
                    {
                        dimString ~= "[" ~ dimName ~ "]";
                    }
                    otherParams ~= baseType ~ " " ~ info.name ~ dimString;
                }
                else
                {
                    otherParams ~= baseType ~ "* " ~ info.name;
                }
            }
        }
        else
        {
            string finalType = mapAxeTypeToC(info.type);
            if (info.name in referencedDimensions)
            {
                dimensionParams ~= finalType ~ " " ~ info.name;
            }
            else
            {
                otherParams ~= finalType ~ " " ~ info.name;
            }
        }
    }
    reorderMap = dimensionIndices ~ otherIndices;
    return dimensionParams ~ otherParams;
}

string mapAxeTypeToCForReturnOrParam(string axeType)
{
    if (axeType.endsWith("[999]"))
    {
        string elementType = axeType[0 .. $ - 5].strip();
        bool isRef = false;
        if (elementType.startsWith("ref "))
        {
            isRef = true;
            elementType = elementType[4 .. $].strip();
        }
        string mappedElementType = mapAxeTypeToC(elementType);
        string structName = "__list_" ~ mappedElementType.replace("*", "_ptr")
            .replace(" ", "_") ~ "_t";
        return isRef ? (structName ~ "*") : structName;
    }
    return mapAxeTypeToC(axeType);
}

string mapAxeTypeToC(string axeType)
{
    if (axeType.startsWith("mut "))
    {
        string baseType = axeType[4 .. $].strip();
        return mapAxeTypeToC(baseType);
    }

    if (axeType.endsWith("[999]"))
    {
        string elementType = axeType[0 .. $ - 5].strip();
        if (elementType.startsWith("ref "))
        {
            elementType = elementType[4 .. $].strip();
            string mappedElementType = mapAxeTypeToC(elementType);
            string structName = "__list_" ~ mappedElementType.replace("*", "_ptr")
                .replace(" ", "_") ~ "_t";
            return structName ~ "*";
        }
        else
        {
            string mappedElementType = mapAxeTypeToC(elementType);
            string structName = "__list_" ~ mappedElementType.replace("*", "_ptr")
                .replace(" ", "_") ~ "_t";
            return structName;
        }
    }

    if (axeType.startsWith("ref "))
    {
        string baseType = axeType[4 .. $].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.startsWith("&mut "))
    {
        string baseType = axeType[5 .. $].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.startsWith("& "))
    {
        string baseType = axeType[2 .. $].strip();
        return "const " ~ mapAxeTypeToC(baseType) ~ "*";
    }
    else if (axeType.endsWith("*"))
    {
        string baseType = axeType[0 .. $ - 1].strip();
        return mapAxeTypeToC(baseType) ~ "*";
    }

    if (axeType in g_typeMappings)
    {
        return g_typeMappings[axeType];
    }

    if (axeType in g_modelNames)
    {
        return g_modelNames[axeType];
    }

    // TODO: Remove.
    if (axeType == "_finddata_t")
    {
        return "struct _finddata_t";
    }

    return axeType;
}

static class RendererConfiguration
{
    static bool releaseBuild = false;
}

/** 
 * C backend renderer.
 *
 * Params:
 *   ast = Abstract syntax tree to render.
 * Returns: 
 *   Generated C code.
 */
string generateC(ASTNode ast)
{
    string cCode;
    string[string] __typeMapCache;
    string cachedMapAxeTypeToC(string t)
    {
        if (auto v = t in __typeMapCache)
            return *v;
        auto r = mapAxeTypeToC(t);
        __typeMapCache[t] = r;
        return r;
    }

    string[string] variables;
    string currentFunction = "";
    string[] functionParams;
    int loopLevel = 0;

    switch (ast.nodeType)
    {
    case "Program":
        g_refDepths.clear();
        g_isMutable.clear();
        g_macros.clear();
        g_pointerFields.clear();
        g_fieldTypes.clear();
        g_isPointerVar.clear();
        g_varType.clear();
        g_functionPrefixes.clear();
        g_modelNames.clear();
        g_generatedTypedefs.clear();
        g_generatedFunctions.clear();
        g_enumNames.clear();
        g_enumValueToEnumName.clear();
        g_localFunctions.clear();
        g_globalVarPrefixes.clear();

        // Important: g_currentModuleName is set by setCurrentModuleName called from builds.d
        string[] globalExternalHeaders;
        string[][string] platformExternalHeaders;
        collectExternalImports(ast, globalExternalHeaders, platformExternalHeaders);

        // First pass: collect all overload names so we don't treat them as functions
        bool[string] overloadNames;

        foreach (child; ast.children)
        {
            if (child.nodeType == "Overload")
            {
                auto overloadNode = cast(OverloadNode) child;
                overloadNames[overloadNode.name] = true;
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Macro")
            {
                auto macroNode = cast(MacroNode) child;
                g_macros[macroNode.name] = macroNode;
                debugWriteln("DEBUG: Pre-stored macro '", macroNode.name, "' with ", macroNode.params.length, " parameters");
            }
            if (child.nodeType == "Use")
            {
                auto useNode = cast(UseNode) child;
                string modulePrefix = useNode.moduleName.replace(".", "__").replace("-", "_");
                debugWriteln("DEBUG: Processing Use node for module '", useNode.moduleName, "' with prefix '", modulePrefix, "'");
                foreach (importName; useNode.imports)
                {
                    if (importName.length > 0 && !(importName[0] >= 'A' && importName[0] <= 'Z'))
                    {
                        if (importName !in overloadNames)
                        {
                            string prefixedName = modulePrefix ~ "__" ~ importName;
                            debugWriteln("DEBUG: Adding g_functionPrefixes['", importName, "'] = '", prefixedName, "'");
                            g_functionPrefixes[importName] = prefixedName;
                            g_modelNames[importName] = prefixedName;
                            g_enumNames[modulePrefix ~ "__" ~ importName] = true;
                        }
                    }
                }
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                // Store the model name mapping
                // Extract base name from prefixed name (e.g., "std_arena_Arena" -> "Arena")
                string baseName = modelNode.name;
                if (modelNode.name.canFind("_") && modelNode.name.startsWith("std_"))
                {
                    auto lastUnderscore = modelNode.name.lastIndexOf("__");
                    if (lastUnderscore >= 0)
                    {
                        baseName = modelNode.name[lastUnderscore + 2 .. $];
                        g_modelNames[baseName] = modelNode.name;
                    }
                }
                else
                {
                    if (modelNode.name.canFind("_"))
                    {
                        auto lastUnderscore = modelNode.name.lastIndexOf("__");
                        if (lastUnderscore >= 0)
                        {
                            baseName = modelNode.name[lastUnderscore + 2 .. $];
                            g_modelNames[baseName] = modelNode.name;
                        }
                    }

                    // For std files, prefix with module name
                    // TODO: Remove this.
                    if (modelNode.name == "error")
                        g_modelNames[modelNode.name] = "std_errors_" ~ modelNode.name;
                    else
                        g_modelNames[modelNode.name] = modelNode.name;
                }

                foreach (field; modelNode.fields)
                {
                    if (field.type == modelNode.name)
                        g_pointerFields[modelNode.name ~ "." ~ field.name] = true;
                    if (field.type.startsWith("ref "))
                        g_pointerFields[modelNode.name ~ "." ~ field.name] = true;
                    if (field.type.endsWith("[999]"))
                        g_pointerFields[modelNode.name ~ "." ~ field.name] = true;
                    g_fieldTypes[modelNode.name ~ "." ~ field.name] = field.type;
                }
            }
            else if (child.nodeType == "Enum")
            {
                auto enumNode = cast(EnumNode) child;
                string baseName = enumNode.name;
                if (enumNode.name.canFind("_") && enumNode.name.startsWith("std_"))
                {
                    auto lastUnderscore = enumNode.name.lastIndexOf("__");
                    if (lastUnderscore >= 0)
                    {
                        baseName = enumNode.name[lastUnderscore + 2 .. $];
                        g_modelNames[baseName] = enumNode.name;
                    }
                }
                else
                {
                    g_modelNames[enumNode.name] = enumNode.name;
                }
            }
        }

        // Discover public global variables and build a mapping from their
        // logical names to the underlying C symbols (gvar__*). This lets
        // importing modules refer to them via short names or ::name sugar.
        foreach (child; ast.children)
        {
            if (child.nodeType == "Declaration")
            {
                auto declNode = cast(DeclarationNode) child;
                if (declNode !is null && declNode.isPublic)
                {
                    string logicalName = declNode.name;
                    string cName = "gvar__" ~ logicalName;
                    if (logicalName.length > 0 && logicalName !in g_globalVarPrefixes)
                    {
                        g_globalVarPrefixes[logicalName] = cName;
                        debugWriteln("DEBUG: Registered public global '", logicalName,
                            "' -> '", cName, "'");
                    }
                }
            }
            else if (child.nodeType == "ArrayDeclaration")
            {
                auto arrayDecl = cast(ArrayDeclarationNode) child;
                if (arrayDecl !is null && arrayDecl.isPublic)
                {
                    string logicalName = arrayDecl.name;
                    string cName = "gvar__" ~ logicalName;
                    if (logicalName.length > 0 && logicalName !in g_globalVarPrefixes)
                    {
                        g_globalVarPrefixes[logicalName] = cName;
                        debugWriteln("DEBUG: Registered public global array '", logicalName,
                            "' -> '", cName, "'");
                    }
                }
            }
        }

        cCode ~= "#define nil ((void*)0)\n";
        cCode ~= "#include <stdio.h>\n";
        cCode ~= "#include <stdbool.h>\n";
        cCode ~= "#include <stdlib.h>\n";
        cCode ~= "#include <string.h>\n";
        cCode ~= "#include <stdint.h>\n";
        cCode ~= "\n";

        version (Windows)
        {
            cCode ~= `#ifndef NOMINMAX
                      #define NOMINMAX
                      #endif
                      #define NOGDI
                      #define WIN32_LEAN_AND_MEAN`;
            cCode ~= "\n#include <windows.h>\n";
        }

        cCode ~= "#ifndef _WIN32\n";
        cCode ~= "#include <sys/stat.h>\n";
        cCode ~= "#include <sys/types.h>\n";
        cCode ~= "#include <sys/time.h>\n";
        cCode ~= "#else\n";
        cCode ~= "#include <sys/stat.h>\n";
        cCode ~= "#include <sys/types.h>\n";
        cCode ~= "#include <io.h>\n";
        cCode ~= "#include <direct.h>\n";
        cCode ~= "#endif\n";

        foreach (header; globalExternalHeaders)
        {
            cCode ~= "#include <" ~ header ~ ">\n";
        }

        if (hasImportedModule("std/net") || hasImportedModule("net.axec"))
        {
            cCode ~= "#include <curl/curl.h>\n";
        }

        if (hasImportedModule("std/json") || hasImportedModule("json.axec"))
        {
            cCode ~= "#include <yyjson.h>\n";
        }

        foreach (platformName, headers; platformExternalHeaders)
        {
            if (platformName == "windows")
                cCode ~= "#ifdef _WIN32\n";
            else if (platformName == "posix")
                cCode ~= "#ifndef _WIN32\n";
            else
                continue;

            foreach (header; headers)
            {
                cCode ~= "#include <" ~ header ~ ">\n";
            }

            cCode ~= "#endif\n";
        }

        cCode ~= "\n";
        cCode ~= "int __axe_argc = 0;\n";
        cCode ~= "char** __axe_argv = NULL;\n\n\n";

        // Hoist overload macro definitions as early as possible so all
        // subsequent code (including imported std modules) can use them.
        foreach (child; ast.children)
        {
            if (child.nodeType == "Overload")
            {
                cCode ~= generateC(child) ~ "\n";
            }
        }

        bool hasPrintOverload = false;
        bool hasPrintlnOverload = false;
        foreach (child; ast.children)
        {
            if (child.nodeType == "Overload")
            {
                auto ov = cast(OverloadNode) child;
                if (ov.name == "print")
                {
                    hasPrintOverload = true;
                    debugWriteln("DEBUG: Found Overload node for 'print'");
                }
                else if (ov.name == "println")
                {
                    hasPrintlnOverload = true;
                    debugWriteln("DEBUG: Found Overload node for 'println'");
                }
            }
        }

        import std.string : startsWith, endsWith;

        debugWriteln("DEBUG: hasPrintOverload=", hasPrintOverload, ", 'print' in g_functionPrefixes=", (
                "print" in g_functionPrefixes) !is null);
        debugWriteln("DEBUG: hasPrintlnOverload=", hasPrintlnOverload, ", 'println' in g_functionPrefixes=", (
                "println" in g_functionPrefixes) !is null);

        if (!hasPrintOverload && ("print" in g_functionPrefixes))
        {
            string macroName = g_functionPrefixes["print"]; // e.g. std_io_print
            debugWriteln("DEBUG: Generating fallback macro for print: ", macroName);
            if (macroName.startsWith("std_io_") && macroName.endsWith("print"))
            {
                string prefix = macroName[0 .. $ - "print".length]; // std_io_
                cCode ~= "#define " ~ macroName ~ "(x) _Generic((x), \\\n";
                cCode ~= "    std__string__string: " ~ prefix ~ "print_str, \\\n";
                cCode ~= "    char*: " ~ prefix ~ "print_chrptr, \\\n";
                cCode ~= "    int32_t: " ~ prefix ~ "print_i32, \\\n";
                cCode ~= "    char: " ~ prefix ~ "print_char \\\n";
                cCode ~= "    )(x)\n";
            }
        }

        if (!hasPrintlnOverload && ("println" in g_functionPrefixes))
        {
            string macroName = g_functionPrefixes["println"]; // e.g. std_io_println
            debugWriteln("DEBUG: Generating fallback macro for println: ", macroName);
            if (macroName.startsWith("std_io_") && macroName.endsWith("println"))
            {
                string prefix = macroName[0 .. $ - "println".length]; // std_io_
                cCode ~= "#define " ~ macroName ~ "(x) _Generic((x), \\\n";
                cCode ~= "    std__string__string: " ~ prefix ~ "print_str, \\\n";
                cCode ~= "    char*: " ~ prefix ~ "println_chrptr, \\\n";
                cCode ~= "    int32_t: " ~ prefix ~ "println_i32, \\\n";
                cCode ~= "    char: " ~ prefix ~ "println_char \\\n";
                cCode ~= "    )(x)\n";
            }
        }

        cCode ~= "#define len_ptr(x) ((x)->len)\n"; // For pointer to list
        cCode ~= "#define len_v(x) ((&(x))->len)\n"; // For list value
        cCode ~= "#define len(x) len_v(x)\n"; // Default to value semantics

        foreach (child; ast.children)
        {
            if (child.nodeType == "Enum")
            {
                auto enumNode = cast(EnumNode) child;
                g_enumNames[enumNode.name] = true;

                string baseName = enumNode.name;
                if (enumNode.name.canFind("_"))
                {
                    auto lastUnderscore = enumNode.name.lastIndexOf("__");
                    if (lastUnderscore >= 0)
                    {
                        baseName = enumNode.name[lastUnderscore + 2 .. $];
                        g_modelNames[baseName] = enumNode.name;
                    }
                }

                cCode ~= generateC(child) ~ "\n";
            }
        }

        g_listElementTypes.clear();

        /// Recursively scan for list types in all declarations
        void scanForListTypes(ASTNode node)
        {
            if (node.nodeType == "Declaration")
            {
                auto declNode = cast(DeclarationNode) node;
                if (declNode.typeName.length > 0 && declNode.typeName.canFind("[999]"))
                {
                    auto bracketPos = declNode.typeName.indexOf("[999]");
                    if (bracketPos > 0)
                    {
                        string elementType = declNode.typeName[0 .. bracketPos];
                        string mappedElementType = cachedMapAxeTypeToC(elementType);
                        g_listElementTypes[mappedElementType] = true;
                        debugWriteln("DEBUG: Scanned list type in declaration: ", mappedElementType);
                    }
                }
            }

            foreach (childNode; node.children)
            {
                scanForListTypes(childNode);
            }
        }

        foreach (child; ast.children)
        {
            scanForListTypes(child);
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                string returnType = funcNode.returnType;

                import std.string : indexOf, lastIndexOf;

                auto bracketPos = returnType.indexOf("[999]");
                if (bracketPos > 0)
                {
                    string elementType = returnType[0 .. bracketPos].strip();
                    if (elementType.startsWith("ref "))
                    {
                        elementType = elementType[4 .. $].strip();
                    }
                    string cElementType = cachedMapAxeTypeToC(elementType);
                    g_listElementTypes[cElementType] = true;
                }
            }
            else if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (field; modelNode.fields)
                {
                    import std.string : indexOf;

                    auto bracketPos = field.type.indexOf("[999]");
                    if (bracketPos > 0)
                    {
                        string elementType = field.type[0 .. bracketPos].strip();
                        if (elementType.startsWith("ref "))
                        {
                            elementType = elementType[4 .. $].strip();
                        }
                        string cElementType = cachedMapAxeTypeToC(elementType);
                        g_listElementTypes[cElementType] = true;
                    }

                    if (field.isUnion)
                    {
                        foreach (inner; field.nestedFields)
                        {
                            auto innerBracketPos = inner.type.indexOf("[999]");
                            if (innerBracketPos > 0)
                            {
                                string innerElementType = inner.type[0 .. innerBracketPos].strip();
                                if (innerElementType.startsWith("ref "))
                                {
                                    innerElementType = innerElementType[4 .. $].strip();
                                }
                                string innerCElementType = cachedMapAxeTypeToC(innerElementType);
                                g_listElementTypes[innerCElementType] = true;
                            }

                            if (inner.type == "model" && inner.isUnion)
                            {
                                foreach (nestedField; inner.nestedFields)
                                {
                                    auto nestedBracketPos = nestedField.type.indexOf("[999]");
                                    if (nestedBracketPos > 0)
                                    {
                                        string nestedElementType = nestedField.type[0 .. nestedBracketPos].strip();
                                        if (nestedElementType.startsWith("ref "))
                                        {
                                            nestedElementType = nestedElementType[4 .. $].strip();
                                        }
                                        string nestedCElementType = cachedMapAxeTypeToC(
                                            nestedElementType);
                                        g_listElementTypes[nestedCElementType] = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        {
            import std.string : indexOf, startsWith, strip;

            ModelNode[string] modelMap;
            string[] modelNames;

            foreach (child; ast.children)
            {
                if (child.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) child;
                    string cName = canonicalModelCName(modelNode.name);
                    if (cName.length == 0)
                        cName = modelNode.name;

                    modelMap[cName] = modelNode;
                    modelNames ~= cName;
                }
            }

            string getBaseAxeType(string typeName)
            {
                string t = typeName.strip();
                while (t.startsWith("mut "))
                    t = t[4 .. $].strip();
                while (t.startsWith("ref "))
                    t = t[4 .. $].strip();
                while (t.startsWith("&mut "))
                    t = t[5 .. $].strip();
                while (t.startsWith("& "))
                    t = t[2 .. $].strip();

                auto bracketPos = t.indexOf('[');
                if (bracketPos >= 0)
                    t = t[0 .. bracketPos].strip();
                while (t.length > 0 && t[$ - 1] == '*')
                    t = t[0 .. $ - 1].strip();

                return t;
            }

            string[][string] deps;
            foreach (cName, modelNode; modelMap)
            {
                foreach (field; modelNode.fields)
                {
                    string baseAxeType = getBaseAxeType(field.type);
                    if (baseAxeType.length == 0)
                        continue;

                    string mapped = cachedMapAxeTypeToC(baseAxeType);

                    if (mapped in modelMap && mapped != cName)
                    {
                        auto ref depList = deps.require(cName, cast(string[])[]);

                        bool exists = false;
                        foreach (depName; depList)
                        {
                            if (depName == mapped)
                            {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists)
                            depList ~= mapped;
                    }
                }
            }

            enum VisitState
            {
                unvisited,
                visiting,
                visited
            }

            VisitState[string] state;
            string[] orderedModels;

            void visit(string name)
            {
                VisitState currentState = VisitState.unvisited;
                if (auto ps = name in state)
                    currentState = *ps;

                if (currentState == VisitState.visited)
                    return;
                if (currentState == VisitState.visiting)
                {
                    // Cycle detected; emit in current order to avoid infinite recursion
                    return;
                }

                state[name] = VisitState.visiting;

                string[] directDeps;
                if (auto pd = name in deps)
                    directDeps = *pd;

                foreach (dep; directDeps)
                {
                    if (dep in modelMap)
                        visit(dep);
                }

                state[name] = VisitState.visited;
                orderedModels ~= name;
            }

            foreach (name; modelNames)
            {
                visit(name);
            }

            // Generate forward declarations for all models first
            foreach (name; orderedModels)
            {
                if (name !in g_generatedTypedefs)
                {
                    cCode ~= "struct " ~ name ~ ";\n";
                }
            }

            // Also generate typedefs for forward declarations
            foreach (name; orderedModels)
            {
                if (name !in g_generatedTypedefs)
                {
                    cCode ~= "typedef struct " ~ name ~ " " ~ name ~ ";\n";
                }
            }

            // Generate forward declarations for list types (so models can use pointers to them)
            foreach (elementType; g_listElementTypes.byKey())
            {
                cCode ~= "typedef struct __list_" ~ elementType ~ "_t __list_" ~ elementType ~ "_t;\n";
            }

            // Generate the actual model definitions
            foreach (name; orderedModels)
            {
                auto modelNode = modelMap[name];
                cCode ~= generateC(modelNode) ~ "\n";
            }

            // Generate list typedefs AFTER all models are fully defined
            // (arrays need complete types, not just forward declarations)
            foreach (elementType; g_listElementTypes.byKey())
            {
                cCode ~= "typedef struct __list_" ~ elementType ~ "_t {\n";
                cCode ~= "    " ~ elementType ~ "* data;\n";
                cCode ~= "    int len;\n";
                cCode ~= "    int capacity;\n";
                cCode ~= "} __list_" ~ elementType ~ "_t;\n\n";

                // List initialization function
                cCode ~= "static inline __list_" ~ elementType ~ "_t __list_" ~ elementType ~ "_init(void) {\n";
                cCode ~= "    __list_" ~ elementType ~ "_t list;\n";
                cCode ~= "    list.data = NULL;\n";
                cCode ~= "    list.len = 0;\n";
                cCode ~= "    list.capacity = 0;\n";
                cCode ~= "    return list;\n";
                cCode ~= "}\n\n";

                // List push function with automatic growth
                cCode ~= "static inline void __list_" ~ elementType ~ "_push(__list_" ~ elementType ~ "_t* list, " ~ elementType ~ " item) {\n";
                cCode ~= "    if (list->len >= list->capacity) {\n";
                cCode ~= "        int new_capacity = list->capacity == 0 ? 8 : list->capacity * 2;\n";
                cCode ~= "        " ~ elementType ~ "* new_data = (" ~ elementType ~ "*)realloc(list->data, new_capacity * sizeof(" ~ elementType ~ "));\n";
                cCode ~= "        if (new_data == NULL) { fprintf(stderr, \"Out of memory\\n\"); exit(1); }\n";
                cCode ~= "        list->data = new_data;\n";
                cCode ~= "        list->capacity = new_capacity;\n";
                cCode ~= "    }\n";
                cCode ~= "    list->data[list->len++] = item;\n";
                cCode ~= "}\n\n";
            }

            auto dtCName = canonicalModelCName("DateTime");
            if (dtCName == "DateTime")
            {
                cCode ~= "typedef struct DateTime std_time_DateTime;\n";
            }
        }

        string[string] functionModulePrefixes;

        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                if (funcNode.name.canFind("_"))
                {
                    auto lastUnderscore = funcNode.name.lastIndexOf("__");
                    if (lastUnderscore > 0)
                    {
                        string potentialPrefix = funcNode.name[0 .. lastUnderscore];
                        string baseName = funcNode.name[lastUnderscore + 2 .. $];
                        functionModulePrefixes[baseName] = potentialPrefix;

                        foreach (enumName; g_enumNames.byKey())
                        {
                            if (enumName.startsWith(potentialPrefix ~ "_"))
                            {
                                break;
                            }
                        }
                    }
                }
            }
        }

        foreach (child; ast.children)
        {
            if (child.nodeType == "Function")
            {
                auto funcNode = cast(FunctionNode) child;
                if (funcNode.name != "main")
                {
                    string prefixedFuncName = funcNode.name;

                    if (funcNode.name.canFind("_"))
                    {
                        auto lastUnderscore = funcNode.name.lastIndexOf("__");
                        if (lastUnderscore >= 0)
                        {
                            string baseName = funcNode.name[lastUnderscore + 2 .. $];
                            debugWriteln("DEBUG: Found function '", funcNode.name, "' with baseName '", baseName, "'");
                            // Support both single-underscore std_ prefixes (older style) and
                            // double-underscore std__module prefixes used for .axec modules,
                            // so that imported std functions like std__string_str get
                            // registered and can be called via their unprefixed names.
                            if (funcNode.name.startsWith("std_") || funcNode.name.startsWith("std__") || funcNode
                                .name.startsWith("lexer_"))
                            {
                                // Don't overwrite existing mappings from imports processing
                                if (baseName !in g_functionPrefixes)
                                {
                                    debugWriteln("DEBUG: Adding to g_functionPrefixes['", baseName, "'] = '", funcNode
                                            .name, "'");
                                    g_functionPrefixes[baseName] = funcNode.name;
                                }
                                else
                                {
                                    debugWriteln("DEBUG: Not overwriting existing g_functionPrefixes['", baseName, "'] = '", g_functionPrefixes[baseName], "' with '", funcNode
                                            .name, "'");
                                }
                            }
                        }
                        prefixedFuncName = funcNode.name;
                    }

                    string processedReturnType = mapAxeTypeToCForReturnOrParam(funcNode.returnType);
                    cCode ~= processedReturnType ~ " " ~ prefixedFuncName ~ "(";
                    if (funcNode.params.length > 0)
                    {
                        int[] reorderMap;
                        ParamInfo[] paramInfos;
                        string[] processedParams = computeReorderedCParams(funcNode, reorderMap, paramInfos);
                        cCode ~= processedParams.join(", ");
                        g_functionParamReordering[prefixedFuncName] = reorderMap;

                        foreach (info; paramInfos)
                        {
                            g_varType[info.name] = info.type;
                            if (info.type.canFind("*"))
                                g_refDepths[info.name] = 1;
                        }
                    }
                    cCode ~= ");\n";
                }
            }
            else if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    auto methodFunc = cast(FunctionNode) method;
                    if (methodFunc !is null)
                    {
                        string processedReturnType = mapAxeTypeToCForReturnOrParam(
                            methodFunc.returnType);
                        cCode ~= processedReturnType ~ " " ~ methodFunc.name ~ "(";
                        if (methodFunc.params.length > 0)
                        {
                            int[] reorderMap;
                            ParamInfo[] paramInfos;
                            string[] processedParams = computeReorderedCParams(methodFunc, reorderMap, paramInfos);
                            cCode ~= processedParams.join(", ");
                            g_functionParamReordering[methodFunc.name] = reorderMap;
                        }
                        cCode ~= ");\n";
                    }
                }
            }
        }
        cCode ~= "\n";

        foreach (child; ast.children)
        {
            if (child.nodeType == "Model")
            {
                auto modelNode = cast(ModelNode) child;
                foreach (method; modelNode.methods)
                {
                    cCode ~= generateC(method) ~ "\n";
                }
            }
        }

        cCode ~= "\n";

        g_inTopLevel = true;
        foreach (child; ast.children)
        {
            if (child.nodeType != "Model" && child.nodeType != "ExternalImport" && child.nodeType != "Enum" && child
                .nodeType != "Use" && child.nodeType != "Macro" && child.nodeType != "Overload")
            {
                debugWriteln("DEBUG: Processing top-level node of type '", child.nodeType, "'");
                bool prevTop = g_inTopLevel;
                g_inTopLevel = true;
                cCode ~= generateC(child) ~ "\n";
                g_inTopLevel = prevTop;
            }
        }
        break;

    case "Main":
        loopLevel++;
        bool savedTopMain = g_inTopLevel;
        g_inTopLevel = false;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        cCode ~= "    return 0;\n";
        loopLevel--;
        g_inTopLevel = savedTopMain;
        cCode ~= "}\n";
        break;

    case "Function":
        auto funcNode = cast(FunctionNode) ast;
        string funcName = funcNode.name;
        string originalFuncName = funcName;

        if (funcName != "main" && funcName in g_functionPrefixes)
        {
            funcName = g_functionPrefixes[funcName];
        }
        else if (funcName != "main" && g_currentModuleName.length > 0)
        {
            import std.string : indexOf;

            if (originalFuncName.indexOf("__") == -1)
            {
                funcName = g_currentModuleName ~ "__" ~ funcName;
            }
        }

        string[] params = funcNode.params;
        string prevFunction = currentFunction;
        currentFunction = funcName;
        bool savedTopFunc = g_inTopLevel;
        g_inTopLevel = false;
        functionParams = params;

        debugWriteln("DEBUG: Processing function '", funcName, "' with ", params.length, " parameters");

        if (funcName in g_generatedFunctions)
        {
            debugWriteln("DEBUG: Function '", funcName, "' already generated, skipping");
            return "";
        }

        g_generatedFunctions[funcName] = true;

        // Track that this function is local to this module (not imported)
        // Only track functions that don't have module prefixes (no "__" in name)
        // Imported functions like "std__errors__panic" should not be tracked as local

        import std.string : indexOf;

        if (originalFuncName.indexOf("__") == -1)
        {
            g_localFunctions[originalFuncName] = true;
            debugWriteln("DEBUG: Tracked local function '", originalFuncName, "'");
        }

        import std.string : lastIndexOf;

        auto lastUnderscore = funcName.lastIndexOf("__");
        if (lastUnderscore >= 0)
        {
            string baseName = funcName[lastUnderscore + 2 .. $];
            if (baseName.length > 0 && baseName !in g_functionPrefixes)
            {
                g_functionPrefixes[baseName] = funcName;
            }
        }

        g_isPointerVar.clear();
        g_varType.clear();

        if (funcNode.name == "main")
        {
            if (!RendererConfiguration.releaseBuild)
            {
                cCode ~= generateStackTraceHandlers();
            }
            cCode ~= "int main(int argc, char** argv) {\n";
            cCode ~= "__axe_argc = argc;\n";
            cCode ~= "__axe_argv = argv;\n";
            if (!RendererConfiguration.releaseBuild)
            {
                cCode ~= generateStackTraceSetup();
            }
            version (Windows)
            {
                cCode ~= "SetConsoleOutputCP(CP_UTF8);\n";
            }
        }
        else
        {
            string processedReturnType = mapAxeTypeToCForReturnOrParam(funcNode.returnType);
            cCode ~= processedReturnType ~ " " ~ funcName ~ "(";
            debugWriteln("DEBUG: Function '", funcName, "' params: ", params);
            if (params.length > 0)
            {
                debugWriteln("DEBUG: Calling computeReorderedCParams for '", funcName, "'");
                int[] reorderMap;
                ParamInfo[] paramInfos;
                string[] processedParams = computeReorderedCParams(funcNode, reorderMap, paramInfos);
                debugWriteln("DEBUG: paramInfos count: ", paramInfos.length);
                cCode ~= processedParams.join(", ");
                g_functionParamReordering[funcName] = reorderMap;

                foreach (info; paramInfos)
                {
                    g_varType[info.name] = info.type;
                    string mappedType = cachedMapAxeTypeToC(info.type);
                    if (info.type.canFind("*") || mappedType.canFind("*"))
                    {
                        g_refDepths[info.name] = 1;
                        g_isPointerVar[info.name] = "true";
                        debugWriteln("DEBUG: Set g_isPointerVar['", info.name, "'] = true (type: ", info.type, " -> ", mappedType, ")");
                    }
                }
            }
            cCode ~= ") {\n";
        }

        foreach (child; ast.children)
            cCode ~= generateC(child);

        if (funcNode.name == "main")
            cCode ~= "return 0;\n";

        currentFunction = prevFunction;
        g_inTopLevel = savedTopFunc;
        cCode ~= "}\n";
        break;

    case "FunctionCall":
        auto callNode = cast(FunctionCallNode) ast;
        string callName = callNode.functionName;

        debugWriteln("DEBUG: Processing FunctionCall '", callName, "', g_functionPrefixes.keys: ", g_functionPrefixes
                .keys);

        import std.string : startsWith, indexOf, strip;

        if (callName == "append")
        {
            if (callNode.args.length >= 2)
            {
                string varName = callNode.args[0].strip();
                string value = callNode.args[1].strip();

                if (varName in g_listOfTypes)
                {
                    string processedValue = processExpression(value);
                    string elementType = g_listOfTypes[varName];
                    cCode ~= "__list_" ~ elementType ~ "_push(&" ~ varName ~ ", " ~ processedValue ~ ");\n";
                    debugWriteln("DEBUG: Generated append code for '", varName, "'");
                    break;
                }
            }
        }

        if (callName.startsWith("C."))
        {
            callName = callName[2 .. $];
        }

        if (callName.canFind("."))
        {
            auto parts = callName.split(".");
            string modelName = parts[0].strip();
            string methodName = parts[1].strip();

            if (modelName in g_modelNames)
            {
                // Use the canonical C model name so that calls match the
                // generated C prototypes for model methods. For example,
                // `error.print_self` in std/errors.axec should become
                // `std_errors_error_print_self`, not `error_print_self`.
                string modelCName = canonicalModelCName(modelName);
                if (modelCName.length == 0)
                    modelCName = modelName;

                callName = modelCName ~ "_" ~ methodName;
            }
            else
            {
                callName = callName.replace(".", "__");
            }
        }
        else if (callName in g_functionPrefixes)
        {
            debugWriteln("DEBUG: Found callName '", callName, "' in g_functionPrefixes, mapping to '", g_functionPrefixes[callName], "'");
            callName = g_functionPrefixes[callName];
        }
        else if (callName in g_localFunctions && g_currentModuleName.length > 0)
        {
            callName = g_currentModuleName ~ "__" ~ callName;
            debugWriteln("DEBUG: Prefixing local function '", callName, "' with module name");
        }
        else
        {
            import std.string : indexOf;

            auto underscorePos = callName.indexOf("__");
            if (underscorePos > 0)
            {
                string modelName = callName[0 .. underscorePos];
                string methodName = callName[underscorePos + 2 .. $];

                if (modelName in g_modelNames && methodName.length > 0)
                {
                    string modelCName = canonicalModelCName(modelName);
                    if (modelCName.length == 0)
                        modelCName = modelName;

                    callName = modelCName ~ "_" ~ methodName;
                }
            }
        }

        if (callName in g_macros)
        {
            debugWriteln("DEBUG: Expanding macro '", callName, "'");
            auto macroNode = g_macros[callName];

            import std.string : split, strip;

            string[] callArgs;
            if (callNode.args.length > 0)
            {
                foreach (arg; callNode.args)
                    callArgs ~= arg.strip();
            }

            string[string] paramMap;
            for (size_t i = 0; i < macroNode.params.length && i < callArgs.length;
                i++)
            {
                // For macro arguments, use them as-is without processing
                // This is important for untyped parameters used in raw C blocks
                // They should be literal string substitutions, not processed expressions
                string processedArg = callArgs[i].strip();
                paramMap[macroNode.params[i]] = processedArg;
                debugWriteln("  DEBUG: Mapping '", macroNode.params[i], "' -> '", processedArg, "'");
            }

            string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
            foreach (child; macroNode.children)
            {
                if (child.nodeType == "RawC")
                {
                    auto rawNode = cast(RawCNode) child;
                    string expandedCode = rawNode.code;

                    debugWriteln("  DEBUG: RawC code before substitution: '", expandedCode, "'");
                    debugWriteln("  DEBUG: Parameter map: ", paramMap);

                    foreach (paramName, paramValue; paramMap)
                    {
                        import std.string : replace;

                        string prefixedValue = paramValue;
                        if (paramValue in g_functionPrefixes)
                        {
                            prefixedValue = g_functionPrefixes[paramValue];
                            debugWriteln("  DEBUG: Type '", paramValue, "' needs function prefix: '", prefixedValue, "'");
                        }
                        else if (paramValue in g_modelNames)
                        {
                            prefixedValue = g_modelNames[paramValue];
                            debugWriteln("  DEBUG: Type '", paramValue, "' needs model prefix: '", prefixedValue, "'");
                        }

                        string pattern = "{{" ~ paramName ~ "}}";
                        if (expandedCode.canFind(pattern))
                        {
                            debugWriteln("  DEBUG: Found pattern '", pattern, "' in code");
                            debugWriteln("  DEBUG: Replacing '", pattern, "' with '", prefixedValue, "'");
                            string beforeReplace = expandedCode;
                            expandedCode = expandedCode.replace(pattern, prefixedValue);
                            if (beforeReplace == expandedCode)
                            {
                                debugWriteln("  DEBUG: WARNING - replacement didn't change code!");
                            }
                        }
                        else if (expandedCode == paramName)
                        {
                            debugWriteln("  DEBUG: Exact match (legacy) - replacing '", paramName, "' with '", prefixedValue, "'");
                            expandedCode = prefixedValue;
                        }
                    }

                    debugWriteln("  DEBUG: RawC code after substitution: '", expandedCode, "'");

                    cCode ~= indent ~ expandedCode ~ "\n";
                }
                else if (child.nodeType == "Model")
                {
                    auto modelNode = cast(ModelNode) child;
                    import std.string : replace;
                    import std.stdio : writeln;

                    foreach (paramName, paramValue; paramMap)
                    {
                        modelNode.name = modelNode.name.replace(paramName, paramValue);
                    }

                    foreach (ref field; modelNode.fields)
                    {
                        foreach (paramName, paramValue; paramMap)
                        {
                            field.type = field.type.replace(paramName, paramValue);
                        }
                    }

                    cCode ~= generateC(child);
                }
                else
                {
                    cCode ~= generateC(child);
                }
            }
            break;
        }

        // WORKAROUND: Fix args that were incorrectly split at commas inside string literals
        // If we have args like: '"text' and 'more text"', rejoin them
        string[] fixedArgs;
        for (size_t i = 0; i < callNode.args.length; i++)
        {
            string arg = callNode.args[i];

            // Check if this arg starts with a quote but doesn't end with one
            if (arg.strip().startsWith('"') && !arg.strip().endsWith('"'))
            {
                // Look ahead for the closing quote in subsequent args
                string combined = arg;
                size_t j = i + 1;
                while (j < callNode.args.length)
                {
                    combined ~= ", " ~ callNode.args[j];
                    if (callNode.args[j].strip().endsWith('"'))
                    {
                        // Found the closing quote
                        fixedArgs ~= combined;
                        i = j; // Skip the args we just combined
                        break;
                    }
                    j++;
                }
                // If we didn't find a closing quote, just add the arg as-is
                if (j >= callNode.args.length)
                {
                    fixedArgs ~= arg;
                }
            }
            else
            {
                fixedArgs ~= arg;
            }
        }

        string[] processedArgs;

        foreach (arg; fixedArgs)
        {
            string trimmedArg = arg.strip();

            if (trimmedArg.startsWith("ref "))
            {
                string inner = trimmedArg[4 .. $].strip();
                string processedInner = processExpression(inner, "function_call");
                processedArgs ~= "&" ~ processedInner;
                continue;
            }

            processedArgs ~= processExpression(arg, "function_call");
        }

        if (callName in g_functionParamReordering)
        {
            int[] reorderMap = g_functionParamReordering[callName];
            string[] reorderedArgs;
            reorderedArgs.length = processedArgs.length;

            for (int i = 0; i < reorderMap.length && i < processedArgs.length; i++)
            {
                reorderedArgs[i] = processedArgs[reorderMap[i]];
            }
            processedArgs = reorderedArgs;
        }

        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        // If this is a C escape (internal C__ prefix), strip it so the
        // generated C calls the raw symbol name (e.g., closedir,
        // WSACleanup, malloc).
        string emittedName = callName;
        if (emittedName.startsWith("C__"))
        {
            emittedName = emittedName[3 .. $];
        }

        cCode ~= indent ~ emittedName ~ "(" ~ processedArgs.join(", ") ~ ");\n";
        break;

    case "Assignment":
        auto assignNode = cast(AssignmentNode) ast;

        import std.stdio : writeln;
        import std.string : indexOf;

        debugWriteln("DEBUG Assignment: variable='", assignNode.variable, "'");
        string dest = processExpression(assignNode.variable.strip());
        debugWriteln("DEBUG Assignment: variable='", assignNode.variable, "' dest='", dest, "'");
        string expr = assignNode.expression.strip();

        string baseVarName = dest;
        auto bracketPos = dest.indexOf('[');
        if (bracketPos > 0)
        {
            baseVarName = dest[0 .. bracketPos];
        }

        if (baseVarName !in variables && !functionParams.canFind(baseVarName) && currentFunction != "")
        {
            variables[baseVarName] = "int";
            cCode ~= "int " ~ dest;

            if (expr.length > 0)
            {
                string processedExpr = processExpression(expr, "assignment");
                cCode ~= " = " ~ processedExpr;
            }
            cCode ~= ";\n";
        }
        else
        {
            if (baseVarName in g_isMutable && !g_isMutable[baseVarName])
                throw new Exception(
                    "Cannot assign to immutable variable '" ~ baseVarName ~ "' (declared with 'val')");

            string processedExpr = processExpression(expr, "assignment");

            cCode ~= dest ~ " = " ~ processedExpr ~ ";\n";
        }
        break;

    case "ArrayDeclaration":
        auto arrayNode = cast(ArrayDeclarationNode) ast;
        debugWriteln("DEBUG ArrayDeclaration: elementType='", arrayNode.elementType, "' name='", arrayNode.name, "'");
        string mappedElementType = cachedMapAxeTypeToC(arrayNode.elementType);
        debugWriteln("DEBUG ArrayDeclaration: mappedElementType='", mappedElementType, "'");
        string arrayType = arrayNode.isMutable ? mappedElementType : "const " ~ mappedElementType;

        if (arrayNode.size2.length > 0)
        {
            cCode ~= arrayType ~ " " ~ arrayNode.name ~ "[" ~ arrayNode.size ~ "][" ~ arrayNode.size2 ~ "]";
        }
        else
        {
            cCode ~= arrayType ~ " " ~ arrayNode.name ~ "[" ~ arrayNode.size ~ "]";
        }
        if (arrayNode.initializer.length > 0)
        {
            cCode ~= " = {" ~ arrayNode.initializer.join(", ") ~ "}";
        }

        cCode ~= ";\n";
        break;

    case "ArrayAccess":
        auto accessNode = cast(ArrayAccessNode) ast;
        if (accessNode.index2.length > 0)
        {
            cCode ~= accessNode.arrayName ~ "[" ~ processExpression(
                accessNode.index) ~ "][" ~ processExpression(accessNode.index2) ~ "]";
        }
        else
        {
            cCode ~= accessNode.arrayName ~ "[" ~ processExpression(accessNode.index) ~ "]";
        }
        break;

    case "ArrayAssignment":
        auto arrayAssignNode = cast(ArrayAssignmentNode) ast;
        string processedArrayName = processExpression(arrayAssignNode.arrayName);
        string processedIndex = processExpression(arrayAssignNode.index);
        string processedValue = processExpression(arrayAssignNode.value);
        if (arrayAssignNode.index2.length > 0)
        {
            string processedIndex2 = processExpression(arrayAssignNode.index2);
            cCode ~= processedArrayName ~ "[" ~ processedIndex ~ "][" ~ processedIndex2 ~ "] = " ~ processedValue ~ ";\n";
        }
        else
        {
            cCode ~= processedArrayName ~ "[" ~ processedIndex ~ "] = " ~ processedValue ~ ";\n";
        }
        break;

    case "Declaration":
        auto declNode = cast(DeclarationNode) ast;

        g_isMutable[declNode.name] = declNode.isMutable;
        if (declNode.refDepth > 0)
        {
            g_refDepths[declNode.name] = declNode.refDepth;
        }

        string arrayPart = "";
        string baseType;

        import std.string : indexOf, count;
        import std.algorithm : canFind;
        import std.conv : to;

        bool isListOfType = false;
        string listStructName = "";
        if (declNode.typeName.length > 0 && declNode.typeName.canFind("[999]"))
        {
            auto bracketPos999 = declNode.typeName.indexOf("[999]");
            if (bracketPos999 > 0)
            {
                string elementType = declNode.typeName[0 .. bracketPos999];
                string mappedElementType = cachedMapAxeTypeToC(elementType);
                g_listOfTypes[declNode.name] = mappedElementType;
                g_listElementTypes[mappedElementType] = true;
                listStructName = "__list_" ~ mappedElementType.replace("*", "_ptr").replace(" ", "_") ~ "_t";
                isListOfType = true;
                debugWriteln("DEBUG renderer: Detected list variable '", declNode.name,
                    "' with element type '", elementType, "' -> '", mappedElementType, "'");
                debugWriteln("DEBUG renderer: Registered list element type: '", mappedElementType, "'");
            }
        }

        if (declNode.typeName.length > 0)
        {
            auto bracketPos = declNode.typeName.indexOf('[');
            if (bracketPos >= 0)
            {
                arrayPart = declNode.typeName[bracketPos .. $];
                string rawBaseType = declNode.typeName[0 .. bracketPos].strip();
                baseType = cachedMapAxeTypeToC(rawBaseType);
            }
            else
            {
                baseType = cachedMapAxeTypeToC(declNode.typeName);
            }
        }
        else
        {
            baseType = "int";
        }

        if (isListOfType)
        {
            baseType = listStructName;
            arrayPart = "";
        }

        for (int i = 0; i < declNode.refDepth; i++)
            baseType ~= "*";

        g_varType[declNode.name] = baseType; // track by logical name
        g_isPointerVar[declNode.name] = declNode.refDepth > 0 ? "true" : "false";
        if (declNode.refDepth > 0)
            debugWriteln("DEBUG set g_isPointerVar['", declNode.name, "'] = true");

        string type = declNode.isMutable ? baseType : "const " ~ baseType;

        // Choose the emitted C variable name. For public top-level vars,
        // use the gvar__ prefix so they behave like proper globals.
        string emittedName = declNode.name;
        if (g_inTopLevel && declNode.isPublic)
        {
            if (declNode.name in g_globalVarPrefixes)
                emittedName = g_globalVarPrefixes[declNode.name];
            else
                emittedName = "gvar__" ~ declNode.name;
        }

        string decl = type ~ " " ~ emittedName ~ arrayPart;

        if (declNode.initializer.length == 0 && declNode.typeName.length > 0)
        {
            dchar first = declNode.typeName[0];
            if (first >= 'A' && first <= 'Z' && !declNode.typeName.endsWith("[999]"))
            {
                decl ~= " = {}";
            }
        }

        if (declNode.initializer.length > 0)
        {
            string processedExpr = processExpression(declNode.initializer, "assignment");

            string var = "";
            if (processedExpr.startsWith("*"))
            {
                var = processedExpr[1 .. $];
            }
            else if (processedExpr.startsWith("(*") && processedExpr.endsWith(")"))
            {
                var = processedExpr[2 .. $ - 1];
            }
            if (var != "")
            {
                if (var in g_varType && g_varType[var] == "int64_t")
                {
                    string T = type;
                    if (T.endsWith("*"))
                        T = T[0 .. $ - 1];
                    if (type.endsWith("*"))
                        processedExpr = "(" ~ T ~ "*)" ~ var;
                    else
                        processedExpr = "*(" ~ T ~ "*)" ~ var;
                }
            }

            // For non-top-level declarations of char* with string literal initializers,
            // emit a buffer plus strcpy. At true top-level (global scope), we instead
            // want a direct literal initializer, so we only take this path when
            // g_inTopLevel is false.
            if (baseType == "char*" && processedExpr.length > 0 && processedExpr[0] == '"' && !g_inTopLevel)
            {
                import std.string : replace;

                size_t bufferSize = cast(int) processedExpr.length - 2 + 1;

                type = declNode.isMutable ? "char" : "const char";
                decl = type ~ " " ~ emittedName ~ "[" ~ bufferSize.to!string ~ "]";
                cCode ~= decl ~ ";\n";
                cCode ~= "strcpy(" ~ emittedName ~ ", " ~ processedExpr ~ ");\n";
                break;
            }

            if (arrayPart.length > 0 && processedExpr.length > 0)
            {
                import std.string : replace, split, indexOf;

                if (processedExpr[0] == '(' && processedExpr.canFind("){"))
                {
                    size_t braceStart = processedExpr.indexOf("){") + 1;
                    size_t braceEnd = processedExpr.lastIndexOf("}");
                    if (braceStart < braceEnd)
                    {
                        string contents = processedExpr[braceStart + 1 .. braceEnd];
                        if (arrayPart == "[]")
                        {
                            auto elements = contents.split(",");
                            arrayPart = "[" ~ elements.length.to!string ~ "]";
                            decl = type ~ " " ~ declNode.name ~ arrayPart;
                        }
                        processedExpr = "{" ~ contents ~ "}";
                    }
                }
                else if (processedExpr[0] == '[')
                {
                    if (arrayPart == "[]")
                    {
                        auto elements = processedExpr[1 .. $ - 1].split(",");
                        arrayPart = "[" ~ elements.length.to!string ~ "]";
                        decl = type ~ " " ~ declNode.name ~ arrayPart;
                    }

                    // Only replace [ and ] for simple array literals, not for stupid ass compound literals like [type]{...}
                    // Check if this looks like a compound literal (has both ] and { in sequence)
                    if (!processedExpr.canFind("]{") && !processedExpr.canFind("] {"))
                    {
                        processedExpr = processedExpr.replace("[", "{").replace("]", "}");
                    }
                }
            }

            decl ~= " = " ~ processedExpr;
            cCode ~= decl ~ ";\n";
        }
        else
        {
            if (isListOfType)
            {
                if (g_inTopLevel)
                {
                    cCode ~= decl ~ " = {0};\n";
                    debugWriteln("DEBUG renderer: Zero-initialized top-level list variable '", declNode.name, "'");
                }
                else
                {
                    string elementType = g_listOfTypes[declNode.name];
                    cCode ~= decl ~ " = __list_" ~ elementType ~ "_init();\n";
                    debugWriteln("DEBUG renderer: Initialized list struct '", declNode.name,
                        "' with init function");
                }
            }
            else
            {
                // Initialize structs to zero to avoid uninitialized memory issues,
                // especially with unions where reading one variant after writing another can cause segfaults
                cCode ~= decl ~ " = {0};\n";
            }
        }

        break;

    case "Println":
        auto printlnNode = cast(PrintlnNode) ast;
        {
            bool hasInterpolated = false;
            foreach (i, msg; printlnNode.messages)
            {
                if (printlnNode.isExpressions[i] && msg.startsWith("__INTERPOLATED__"))
                {
                    hasInterpolated = true;
                    break;
                }
            }

            if (hasInterpolated && printlnNode.messages.length == 1)
            {
                string processedExpr = processExpression(printlnNode.messages[0], "println");
                cCode ~= "printf(\"%s\\n\", " ~ processedExpr ~ ");\n";
            }
            else
            {
                string formatString = "";
                string[] exprArgs;

                for (size_t i = 0; i < printlnNode.messages.length; i++)
                {
                    if (printlnNode.isExpressions[i])
                    {
                        if (printlnNode.messages[i].startsWith("__INTERPOLATED__"))
                        {
                            formatString ~= "%s";
                            string processedExpr = processExpression(printlnNode.messages[i], "println");
                            exprArgs ~= processedExpr;
                        }
                        else
                        {
                            string formatSpec = getFormatSpecifier(printlnNode.messages[i]);
                            formatString ~= formatSpec;
                            string processedExpr = processExpression(printlnNode.messages[i], "println");
                            exprArgs ~= processedExpr;
                        }
                    }
                    else
                    {
                        formatString ~= printlnNode.messages[i];
                    }
                }

                formatString ~= "\\n";

                if (exprArgs.length > 0)
                {
                    cCode ~= "printf(\"" ~ formatString ~ "\", " ~ exprArgs.join(", ") ~ ");\n";
                }
                else
                {
                    cCode ~= "printf(\"" ~ formatString ~ "\");\n";
                }
            }
        }
        break;

    case "Print":
        auto printNode = cast(PrintNode) ast;
        {
            string formatString = "";
            string[] exprArgs;

            for (size_t i = 0; i < printNode.messages.length; i++)
            {
                if (printNode.isExpressions[i])
                {
                    string formatSpec = getFormatSpecifier(printNode.messages[i]);
                    formatString ~= formatSpec;
                    string processedExpr = processExpression(printNode.messages[i], "println");
                    exprArgs ~= processedExpr;
                }
                else
                {
                    formatString ~= printNode.messages[i];
                }
            }

            if (exprArgs.length > 0)
            {
                cCode ~= "printf(\"" ~ formatString ~ "\", " ~ exprArgs.join(", ") ~ ");\n";
            }
            else
            {
                cCode ~= "printf(\"" ~ formatString ~ "\");\n";
            }
        }
        break;

    case "If":
        auto ifNode = cast(IfNode) ast;
        cCode ~= "if (" ~ processCondition(ifNode.condition) ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}";

        IfNode currentNode = ifNode;
        while (currentNode.elseBody.length == 1 && currentNode.elseBody[0].nodeType == "If")
        {
            auto elifNode = cast(IfNode) currentNode.elseBody[0];
            cCode ~= " else if (" ~ processCondition(elifNode.condition) ~ ") {\n";
            loopLevel++;

            foreach (child; elifNode.children)
            {
                cCode ~= generateC(child);
            }

            loopLevel--;
            cCode ~= "}";
            currentNode = elifNode;
        }

        if (currentNode.elseBody.length > 0)
        {
            cCode ~= " else {\n";
            loopLevel++;

            foreach (elseChild; currentNode.elseBody)
            {
                cCode ~= generateC(elseChild);
            }

            loopLevel--;
            cCode ~= "}";
        }

        cCode ~= "\n";
        break;

    case "Loop":
        cCode ~= "while (1) {\n";

        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Platform":
        auto platformNode = cast(PlatformNode) ast;

        if (platformNode.platform == "windows")
            cCode ~= "#ifdef _WIN32\n";
        else if (platformNode.platform == "posix")
            cCode ~= "#ifndef _WIN32\n";

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        cCode ~= "#endif\n";
        break;

    case "ParallelFor":
        auto parallelForNode = cast(ParallelForNode) ast;

        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        string ompPragma = "#pragma omp parallel for";

        if (parallelForNode.reductionClauses.length > 0)
        {
            ompPragma ~= " reduction(";
            foreach (i, clause; parallelForNode.reductionClauses)
            {
                if (i > 0)
                    ompPragma ~= ", ";
                ompPragma ~= clause;
            }
            ompPragma ~= ")";
        }

        cCode ~= indent ~ ompPragma ~ "\n";
        cCode ~= indent ~ "for (" ~ parallelForNode.initialization ~ "; "
            ~ processCondition(
                parallelForNode.condition) ~ "; "
            ~ parallelForNode.increment ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= indent ~ "}\n";
        break;

    case "For":
        auto forNode = cast(ForNode) ast;
        string forInit;
        if (forNode.varName.length > 0)
        {
            string forType = forNode.isMutable ? forNode.varType : "const " ~ forNode.varType;
            forInit = forType ~ " " ~ forNode.varName ~ " = " ~ processExpression(forNode.initValue);
        }
        else
        {
            forInit = processExpression(forNode.initValue);
        }

        string forCond = processCondition(forNode.condition);
        string forIncr = forNode.increment;

        if (forNode.isParallel)
        {
            string ompPragma = "#pragma omp parallel for";

            if (forNode.reductionClauses.length > 0)
            {
                ompPragma ~= " reduction(";
                foreach (i, clause; forNode.reductionClauses)
                {
                    if (i > 0)
                        ompPragma ~= ", ";
                    ompPragma ~= clause;
                }
                ompPragma ~= ")";
            }

            cCode ~= ompPragma ~ "\n";
        }

        cCode ~= "for (" ~ forInit ~ "; " ~ forCond ~ "; " ~ forIncr ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Parallel":
        cCode ~= "#pragma omp parallel\n{\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "ParallelLocal":
        auto parallelLocalNode = cast(ParallelLocalNode) ast;

        foreach (i, varName; parallelLocalNode.privateVars)
        {
            string typeStr = parallelLocalNode.privateTypes[i];
            string cType = cachedMapAxeTypeToC(typeStr);

            cCode ~= cType ~ " " ~ varName ~ ";\n";
        }

        cCode ~= "#pragma omp parallel private(";
        foreach (i, varName; parallelLocalNode.privateVars)
        {
            if (i > 0)
                cCode ~= ", ";
            cCode ~= varName;
        }
        cCode ~= ")\n{\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Single":
        cCode ~= "#pragma omp single\n{\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "ForIn":
        auto forInNode = cast(ForInNode) ast;

        // Generate: for (int32_t i = 0; i < xs->len; i++) {
        //              {{type}} varName = xs->data[i];
        //              ... body ...
        //          }
        // This supports lists with .len field and .data array
        string indexVar = "_i_" ~ forInNode.varName;
        string processedArrayName = processExpression(forInNode.arrayName);
        processedArrayName = applyFunctionPrefixes(processedArrayName);

        bool isPointer = (forInNode.arrayName in g_isPointerVar &&
                g_isPointerVar[forInNode.arrayName] == "true");
        string accessor = isPointer ? "->" : ".";

        bool needsTempVar = processedArrayName.canFind("(");
        string collectionVar = processedArrayName;
        string collectionAccessor = accessor;

        if (needsTempVar)
        {
            string tempVarName = "_temp_collection_" ~ forInNode.varName;
            collectionVar = processedArrayName;
            collectionAccessor = "->";
        }

        string loopHeader = "for (int32_t " ~ indexVar ~ " = 0; " ~ indexVar ~ " < " ~
            collectionVar ~ collectionAccessor ~ "len; " ~ indexVar ~ "++) {\n";
        cCode ~= loopHeader;
        loopLevel++;

        string indent = "    ".replicate(loopLevel);
        string varDecl = indent ~ "typeof(" ~ collectionVar ~ collectionAccessor ~ "data[0]) " ~
            forInNode.varName ~ " = " ~ collectionVar ~ collectionAccessor ~
            "data[" ~ indexVar ~ "];\n";
        cCode ~= varDecl;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Break":
        cCode ~= "break;\n";
        break;

    case "Continue":
        cCode ~= "continue;\n";
        break;

    case "RawC":
        auto rawNode = cast(RawCNode) ast;
        string rawCode = rawNode.code;

        // IMPORTANT: 
        //
        // ONLY replace local functions from the current module (g_localFunctionMap)
        // Do NOT replace imported functions or system functions
        // This handles cases like local callback functions that need to be prefixed
        // while leaving system API functions (malloc, strlen, accept, etc.) unchanged

        foreach (unprefixed, prefixed; g_localFunctionMap)
        {
            import std.regex : regex, replaceAll;

            // Match function names ONLY in these contexts:
            // 1. Function calls: funcname( - immediately followed by opening paren
            // 2. Function pointers as arguments: , funcname) or , funcname, - preceded by comma
            //
            // Do NOT match:
            // - Variable names in declarations
            // - Type names in casts like (typename)
            // - Struct field names like s.fieldname
            //
            // Pattern: Either preceded by comma and followed by comma/semicolon/close-paren OR followed by (.

            auto pattern = regex(
                `(?:(?<=,)\s*\b` ~ unprefixed ~ `\b\s*(?=[,;)])|\b` ~ unprefixed ~ `\b(?=\s*\())`);
            rawCode = replaceAll(rawCode, pattern, prefixed);
        }

        cCode ~= rawCode ~ "\n";
        break;

    case "Return":
        auto returnNode = cast(ReturnNode) ast;
        if (returnNode.expressionNode !is null)
        {
            string processedExpr = generateC(returnNode.expressionNode);
            if (processedExpr.endsWith("\n"))
                processedExpr = processedExpr[0 .. $ - 1];
            cCode ~= "return " ~ processedExpr ~ ";\n";
        }
        else if (returnNode.expression.length > 0)
        {
            string processedExpr = processExpression(returnNode.expression);
            cCode ~= "return " ~ processedExpr ~ ";\n";
        }
        else
        {
            cCode ~= "return;\n";
        }
        break;

    case "Enum":
        auto enumNode = cast(EnumNode) ast;

        if (enumNode.name in g_generatedTypedefs)
            return "";

        g_generatedTypedefs[enumNode.name] = true;

        cCode ~= "typedef enum {\n";
        foreach (i, value; enumNode.values)
        {
            g_enumValueToEnumName[value] = enumNode.name;
            cCode ~= "    " ~ enumNode.name ~ "_" ~ value;
            if (i < cast(int) enumNode.values.length - 1)
                cCode ~= ",";
            cCode ~= "\n";
        }
        cCode ~= "} " ~ enumNode.name ~ ";\n";
        break;

    case "Test":
        auto testNode = cast(TestNode) ast;

        if (!RendererConfiguration.releaseBuild)
        {
            writeln("Test block: Not a release build, adding stack trace handlers.");
            cCode ~= generateStackTraceHandlers();
        }
        cCode ~= "int main(int argc, char** argv) {\n";
        cCode ~= "    __axe_argc = argc;\n";
        cCode ~= "    __axe_argv = argv;\n";
        if (!RendererConfiguration.releaseBuild)
        {
            cCode ~= generateStackTraceSetup();
        }
        version (Windows)
        {
            cCode ~= "SetConsoleOutputCP(65001);\n";
        }
        cCode ~= "    int passed = 0;\n";
        cCode ~= "    int failed = 0;\n\n";

        foreach (child; testNode.children)
        {
            if (child.nodeType == "Assert")
            {
                auto assertNode = cast(AssertNode) child;
                string condition = processExpression(assertNode.condition);

                cCode ~= "    if (" ~ condition ~ ") {\n";
                cCode ~= "        printf(\"\\033[32m✓ PASS:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
                cCode ~= "        passed++;\n";
                cCode ~= "    } else {\n";
                cCode ~= "        printf(\"\\033[31m✗ FAIL:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
                cCode ~= "        failed++;\n";
                cCode ~= "    }\n\n";
            }
            else
            {
                string stmt = generateC(child);
                if (stmt.length > 0)
                {
                    cCode ~= "    " ~ stmt.replace("\n", "\n    ");
                    if (!stmt.endsWith("\n"))
                        cCode ~= "\n";
                }
            }
        }

        cCode ~= "    printf(\"\\n\");\n";
        cCode ~= "    if (failed == 0) {\n";
        cCode ~= "        printf(\"\\033[32mAll tests passed. (%d/%d)\\033[0m\\n\", passed, passed + failed);\n";
        cCode ~= "    } else {\n";
        cCode ~= "        printf(\"\\033[31m%d test(s) failed, %d passed\\033[0m\\n\", failed, passed);\n";
        cCode ~= "    }\n";
        cCode ~= "    return failed > 0 ? 1 : 0;\n";
        cCode ~= "}\n";
        break;

    case "Macro":
        // Store macro for later expansion, don't generate code now
        auto macroNode = cast(MacroNode) ast;
        g_macros[macroNode.name] = macroNode;
        debugWriteln("DEBUG: Stored macro '", macroNode.name, "' with ", macroNode.params.length, " parameters");
        break;

    case "Overload":
        auto overloadNode = cast(OverloadNode) ast;
        {
            string paramName = overloadNode.paramName.length ? overloadNode.paramName : "x";
            string callExpr = overloadNode.callExpr.length ? overloadNode.callExpr : paramName;

            // Overload macro names should NOT be prefixed - they should remain as simple
            // names like "print" or "println" so user code can call them naturally.
            // Only the TARGET FUNCTIONS inside the macro should be prefixed.
            string macroName = overloadNode.name;

            cCode ~= "#define " ~ macroName ~ "(" ~ paramName ~ ") _Generic((" ~ callExpr ~ "), \\\n";

            // If any target function in this overload resolves to a prefixed
            // name (e.g. std_io_print_str for print_str), reuse that prefix
            // for other targets that don't otherwise resolve. This keeps all
            // dispatched functions consistently in the same C namespace.
            string overloadPrefix;

            foreach (i, typeName; overloadNode.typeNames)
            {
                string mappedType = cachedMapAxeTypeToC(typeName);
                string baseName = overloadNode.targetFunctions[i];
                string cTargetName = baseName;

                import std.string : split, strip, indexOf, replace, endsWith;

                if (cTargetName.canFind("."))
                {
                    auto parts = cTargetName.split(".");
                    string modelName = parts[0].strip();
                    string methodName = parts[1].strip();

                    if (modelName in g_modelNames)
                    {
                        string modelCName = canonicalModelCName(modelName);
                        if (modelCName.length == 0)
                            modelCName = modelName;
                        cTargetName = modelCName ~ "_" ~ methodName;
                    }
                    else
                    {
                        cTargetName = cTargetName.replace(".", "__");
                    }
                }
                else if (cTargetName in g_functionPrefixes)
                {
                    cTargetName = g_functionPrefixes[cTargetName];
                }
                else
                {
                    auto underscorePos = cTargetName.indexOf("__");
                    if (underscorePos > 0)
                    {
                        string modelName = cTargetName[0 .. underscorePos];
                        string methodName = cTargetName[underscorePos + 2 .. $];

                        if (modelName in g_modelNames && methodName.length > 0)
                        {
                            string modelCName = canonicalModelCName(modelName);
                            if (modelCName.length == 0)
                                modelCName = modelName;
                            cTargetName = modelCName ~ "_" ~ methodName;
                        }
                    }
                }

                // If we haven't discovered a prefix yet and this resolution
                // changed the name by adding a leading prefix (and kept the
                // original suffix), infer it now. 
                // 
                // Example:
                //   baseName = "print_str"
                //   cTargetName = "std_io_print_str"  -> overloadPrefix = "std_io_".
                if (overloadPrefix.length == 0 && cTargetName != baseName && cTargetName.endsWith(
                        baseName))
                {
                    overloadPrefix = cTargetName[0 .. $ - baseName.length];
                }

                // If we have an inferred prefix but this particular target
                // didn't resolve (e.g. println_chrptr), apply the same prefix
                // so it dispatches to the correctly-prefixed function in
                // the same module (std_io_println_chrptr).
                if (overloadPrefix.length > 0 && cTargetName == baseName)
                {
                    cTargetName = overloadPrefix ~ baseName;
                }

                cCode ~= "    " ~ mappedType ~ ": " ~ cTargetName;
                if (i + 1 < overloadNode.typeNames.length)
                    cCode ~= ", \\\n";
                else
                    cCode ~= " \\\n";
            }

            cCode ~= "    )(" ~ callExpr ~ ")\n";
        }
        break;

    case "Model":
        auto modelNode = cast(ModelNode) ast;
        string modelName = canonicalModelCName(modelNode.name);
        if (modelName.length == 0)
            modelName = modelNode.name;

        if (modelName in g_generatedTypedefs)
            return "";

        g_generatedTypedefs[modelName] = true;

        // Forward declaration and typedef already generated in the main loop
        // Now just define the struct body
        cCode ~= "struct " ~ modelName ~ " {\n";

        bool hasSelfReference = false;
        foreach (field; modelNode.fields)
        {
            string fieldType = field.type;
            auto bracketPos = fieldType.indexOf('[');
            if (bracketPos >= 0)
            {
                fieldType = fieldType[0 .. bracketPos].strip();
            }

            if (fieldType == modelNode.name)
            {
                hasSelfReference = true;
                break;
            }
        }

        foreach (field; modelNode.fields)
        {
            // Union fields are rendered as a nested union block inside the struct
            if (field.isUnion)
            {
                cCode ~= "    union {\n";

                foreach (inner; field.nestedFields)
                {
                    // Check if this is an anonymous model definition
                    if (inner.type == "model" && inner.isUnion)
                    {
                        // Render as anonymous struct inside union
                        cCode ~= "        struct {\n";

                        foreach (nestedField; inner.nestedFields)
                        {
                            string nestedType;
                            string nestedArrayPart = "";

                            import std.string : indexOf;

                            if (nestedField.type.endsWith("[999]"))
                            {
                                nestedType = mapAxeTypeToCForReturnOrParam(nestedField.type) ~ "*";
                            }
                            else
                            {
                                auto nestedBracketPos = nestedField.type.indexOf('[');
                                if (nestedBracketPos >= 0)
                                {
                                    nestedArrayPart = nestedField.type[nestedBracketPos .. $];
                                    string nestedRawBaseType = nestedField.type[0 .. nestedBracketPos].strip();
                                    nestedType = cachedMapAxeTypeToC(nestedRawBaseType);
                                }
                                else
                                {
                                    nestedType = cachedMapAxeTypeToC(nestedField.type);
                                }
                            }

                            // Handle ref types - convert "ref T" to "T*"
                            if (nestedType.startsWith("ref "))
                            {
                                nestedType = nestedType[4 .. $].strip() ~ "*";
                            }

                            nestedType = formatModelFieldType(nestedType);

                            // Self-referential nested fields
                            if (nestedField.type == modelNode.name)
                            {
                                nestedType = "struct " ~ nestedField.type ~ "*";
                            }

                            cCode ~= "            " ~ nestedType ~ " " ~ nestedField.name ~ nestedArrayPart ~ ";\n";
                        }

                        cCode ~= "        } " ~ inner.name ~ ";\n";
                    }
                    else
                    {
                        // Regular union field here.

                        string innerType;
                        string innerArrayPart = "";

                        import std.string : indexOf;

                        if (inner.type.endsWith("[999]"))
                        {
                            innerType = mapAxeTypeToCForReturnOrParam(inner.type) ~ "*";
                        }
                        else
                        {
                            auto innerBracketPos = inner.type.indexOf('[');
                            if (innerBracketPos >= 0)
                            {
                                innerArrayPart = inner.type[innerBracketPos .. $];
                                string innerRawBaseType = inner.type[0 .. innerBracketPos].strip();
                                innerType = cachedMapAxeTypeToC(innerRawBaseType);
                            }
                            else
                            {
                                innerType = cachedMapAxeTypeToC(inner.type);
                            }
                        }

                        // Handle ref types - convert "ref T" to "T*"
                        if (innerType.startsWith("ref "))
                        {
                            innerType = innerType[4 .. $].strip() ~ "*";
                        }

                        innerType = formatModelFieldType(innerType);

                        // Self-referential inner fields use the forward-declared struct as well
                        if (inner.type == modelNode.name)
                        {
                            innerType = "struct " ~ inner.type ~ "*";
                        }

                        cCode ~= "        " ~ innerType ~ " " ~ inner.name ~ innerArrayPart ~ ";\n";
                    }
                }

                cCode ~= "    } " ~ field.name ~ ";\n";
                continue;
            }

            string fieldType;
            string arrayPart = "";

            import std.string : indexOf;

            // Check if this is a list type (ends with [999])
            if (field.type.endsWith("[999]"))
            {
                // This is a list type - use a pointer to the list struct
                // (list typedefs come after model definitions, so we need forward compat)
                // Don't include the [999] array part for list types
                fieldType = mapAxeTypeToCForReturnOrParam(field.type);

                // If not already a pointer (ref list returns with *), add pointer
                if (!fieldType.endsWith("*"))
                {
                    fieldType ~= "*";
                }
            }
            else
            {
                auto bracketPos = field.type.indexOf('[');
                if (bracketPos >= 0)
                {
                    arrayPart = field.type[bracketPos .. $];
                    string rawBaseType = field.type[0 .. bracketPos].strip();
                    fieldType = cachedMapAxeTypeToC(rawBaseType);
                }
                else
                {
                    fieldType = cachedMapAxeTypeToC(field.type);
                }
            }

            debugWriteln("DEBUG model field: name='", field.name, "' type='", field.type, "' mapped='", fieldType, "' arrayPart='", arrayPart, "'");

            if (fieldType.startsWith("ref "))
                fieldType = fieldType[4 .. $].strip() ~ "*";

            fieldType = formatModelFieldType(fieldType);

            if (field.type == modelNode.name)
                fieldType = "struct " ~ field.type ~ "*";

            cCode ~= "    " ~ fieldType ~ " " ~ field.name ~ arrayPart ~ ";\n";
        }
        cCode ~= "};\n\n";
        break;

    case "ModelInstantiation":
        auto instNode = cast(ModelInstantiationNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        string cModelName = canonicalModelCName(instNode.modelName);

        if (cModelName.length == 0)
            cModelName = instNode.modelName;

        if (instNode.variableName.length == 0)
        {
            cCode ~= "(struct " ~ cModelName ~ "){";
        }
        else
        {
            string constQualifier = instNode.isMutable ? "" : "const ";
            cCode ~= indent ~ constQualifier ~ cModelName ~ " " ~ instNode.variableName ~ " = {";
        }

        bool first = true;
        foreach (fieldName, fieldValue; instNode.fieldValues)
        {
            if (!first)
                cCode ~= ", ";
            cCode ~= "." ~ fieldName ~ " = " ~ processExpression(fieldValue);
            first = false;
        }

        if (instNode.variableName.length == 0)
        {
            cCode ~= "}";
        }
        else
        {
            cCode ~= "};\n";
        }
        break;

    case "MemberAccess":
        auto memberNode = cast(MemberAccessNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        string accessOp = ".";

        bool objectIsPointer = false;
        if (memberNode.objectName.canFind("->"))
        {
            objectIsPointer = true;
        }
        else if (memberNode.objectName in g_isPointerVar && g_isPointerVar[memberNode.objectName] == "true")
        {
            objectIsPointer = true;
        }
        else if (memberNode.objectName in g_varType)
        {
            string objType = g_varType[memberNode.objectName];
            if (objType.startsWith("ref ") || objType.endsWith("*"))
            {
                objectIsPointer = true;
            }
        }

        // Check if it's a pointer field (for subsequent chain accesses)
        string baseModelName = g_varType.get(memberNode.objectName, "");
        if (baseModelName.startsWith("ref "))
            baseModelName = baseModelName[4 .. $].strip();
        if (baseModelName.startsWith("mut "))
            baseModelName = baseModelName[4 .. $].strip();
        while (baseModelName.length > 0 && baseModelName[$ - 1] == '*')
            baseModelName = baseModelName[0 .. $ - 1].strip();

        if (baseModelName ~ "." ~ memberNode.memberName in g_pointerFields)
        {
            objectIsPointer = true;
        }

        if (objectIsPointer)
        {
            accessOp = "->";
        }

        if (memberNode.value.length > 0)
        {
            cCode ~= indent ~ memberNode.objectName ~ accessOp ~ memberNode.memberName;
            cCode ~= " = " ~ memberNode.value ~ ";\n";
        }
        else
        {
            cCode ~= memberNode.objectName ~ accessOp ~ memberNode.memberName;
        }
        break;

    case "Switch":
        auto switchNode = cast(SwitchNode) ast;
        cCode ~= "switch (" ~ processExpression(switchNode.expression) ~ ") {\n";
        loopLevel++;

        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        loopLevel--;
        cCode ~= "}\n";
        break;

    case "Case":
        auto caseNode = cast(CaseNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        if (caseNode.isDefault)
        {
            cCode ~= indent ~ "default:\n";
        }
        else
        {
            cCode ~= indent ~ "case " ~ processExpression(caseNode.value) ~ ":\n";
        }

        loopLevel++;
        foreach (child; ast.children)
        {
            cCode ~= generateC(child);
        }

        string breakIndent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        cCode ~= breakIndent ~ "break;\n";
        loopLevel--;
        break;

    case "IncrementDecrement":
        auto incDecNode = cast(IncrementDecrementNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";

        if (incDecNode.isIncrement)
            cCode ~= indent ~ incDecNode.variable ~ "++;\n";
        else
            cCode ~= indent ~ incDecNode.variable ~ "--;\n";
        break;

    case "MemberIncrementDecrement":
        auto memberIncDecNode = cast(MemberIncrementDecrementNode) ast;
        string indent = loopLevel > 0 ? "    ".replicate(loopLevel) : "";
        string accessor = ".";

        if (memberIncDecNode.objectName in g_isPointerVar &&
            g_isPointerVar[memberIncDecNode.objectName] == "true")
        {
            accessor = "->";
        }

        if (memberIncDecNode.isIncrement)
            cCode ~= indent ~ memberIncDecNode.objectName ~ accessor ~ memberIncDecNode.memberName ~ "++;\n";
        else
            cCode ~= indent ~ memberIncDecNode.objectName ~ accessor ~ memberIncDecNode.memberName ~ "--;\n";
        break;

    case "ExternalImport":
        auto extImportNode = cast(ExternalImportNode) ast;
        cCode ~= "#include <" ~ extImportNode.headerFile ~ ">\n";
        break;

    case "Opaque":
        auto opaqueNode = cast(OpaqueNode) ast;
        foreach (typeName; opaqueNode.typeNames)
        {
            cCode ~= "typedef struct " ~ typeName ~ " " ~ typeName ~ ";\n";
        }
        break;

    case "Extern":
        auto externNode = cast(ExternNode) ast;

        g_generatedFunctions[externNode.functionName] = true;

        // Don't generate the actual extern declaration - these are already declared
        // in system headers. We just need to track that they exist.
        // If we wanted to generate declarations for truly external functions,
        // we'd uncomment the code below:

        /*        
        string returnType = externNode.returnType.length > 0 ? 
            cachedMapAxeTypeToC(externNode.returnType) : "void";
        
        string[] cParams;
        foreach (param; externNode.params)
        {
            // Parse "name: type" format
            auto colonPos = param.indexOf(':');
            if (colonPos > 0)
            {
                string paramName = param[0 .. colonPos].strip();
                string paramType = param[colonPos + 1 .. $].strip();
                string cType = cachedMapAxeTypeToC(paramType);
                cParams ~= cType ~ " " ~ paramName;
            }
        }
        
        cCode ~= "extern " ~ returnType ~ " " ~ externNode.functionName ~ 
                 "(" ~ cParams.join(", ") ~ ");\n";
        */
        break;

    case "Unsafe":
        auto unsafeNode = cast(UnsafeNode) ast;
        // Simply render the body of the unsafe block
        // The *. syntax has already been converted to -> in processExpression
        foreach (child; unsafeNode.body)
        {
            cCode ~= generateC(child);
        }
        break;

    case "Assert":
        auto assertNode = cast(AssertNode) ast;
        string condition = processExpression(assertNode.condition);
        cCode ~= "if (" ~ condition ~ ") {\n";
        cCode ~= "    printf(\"\\033[32m✓ PASS:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
        cCode ~= "} else {\n";
        cCode ~= "    printf(\"\\033[31m✗ FAIL:\\033[0m " ~ assertNode.message ~ "\\n\");\n";
        cCode ~= "    exit(1);\n";
        cCode ~= "}\n";
        break;

    default:
        enforce(false, "Unsupported node type for C generation: " ~ ast.nodeType);
    }

    // Final cleanup: Fix invalid double-initializer pattern produced by the
    // interaction between implicit struct init and list macros.

    import std.string : replace;

    cCode = cCode.replace(" = {} = {0}", " = {0}");

    return cCode;
}

/**
 * Helper function to get format specifier from Axe type
 */
string getTypeFormatSpecifier(string varType)
{
    varType = varType.strip();

    while (varType.startsWith("ref "))
        varType = varType[4 .. $].strip();

    switch (varType)
    {
    case "i8":
    case "i16":
    case "i32":
    case "int":
        return "%d";
    case "u8":
    case "u16":
    case "u32":
    case "uint":
    case "byte":
        return "%u";
    case "i64":
    case "long":
        return "%lld";
    case "u64":
    case "ulong":
    case "usize":
    case "size":
        return "%llu";
    case "f32":
    case "float":
        return "%f";
    case "f64":
    case "double":
        return "%lf";
    case "char":
        return "%c";
    case "bool":
        return "%d";
    case "string":
        return "%s";
    case "char*":
        return "%s";
    case "ref char":
        return "%s";
    default:
        if (varType.endsWith("*"))
            return "%p";
        return "%d";
    }
}

/**
 * Helper function to convert expressions to strings based on their types
 */
string convertToString(string expr, string varType)
{
    varType = varType.strip();

    while (varType.startsWith("ref "))
        varType = varType[4 .. $].strip();

    if (varType == "string" || varType.endsWith("_string") || varType == "std__string__string")
    {
        return expr;
    }

    if (varType == "char*")
    {
        return expr;
    }

    import std.conv : to;
    import std.random : uniform;

    string tempVar = "_axe_str_" ~ uniform(0, 999_999).to!string;
    string formatSpec = getTypeFormatSpecifier(varType);

    string exprToFormat = expr;
    if (varType == "string")
        exprToFormat = expr ~ ".data";

    return "({char " ~ tempVar ~ "[64]; snprintf(" ~ tempVar ~
        ", 64, \"" ~ formatSpec ~ "\", " ~ exprToFormat ~ "); " ~
        "std__string__string_create(" ~ tempVar ~ "); })";
}

/**
 * Helper function to process interpolated strings
 * Generates inline C code that returns char* for use in println
 * or wraps in struct for use with std/string functions
 */
string processInterpolatedString(string interpContent, bool returnStruct = false)
{
    import std.string : indexOf;
    import std.array : Appender;
    import std.conv : to;
    import std.random : uniform;

    string[] parts;
    string[] expressions;

    size_t pos = 0;
    string currentPart = "";

    while (pos < interpContent.length)
    {
        if (interpContent[pos] == '{' && (pos == 0 || interpContent[pos - 1] != '\\'))
        {
            if (pos > 0 && currentPart.length > 0 && interpContent[pos - 1] == '$')
                currentPart = currentPart[0 .. $ - 1];

            parts ~= currentPart;
            currentPart = "";

            size_t braceStart = pos + 1;
            int braceDepth = 1;
            size_t braceEnd = braceStart;

            while (braceEnd < interpContent.length && braceDepth > 0)
            {
                if (interpContent[braceEnd] == '{')
                    braceDepth++;
                else if (interpContent[braceEnd] == '}')
                    braceDepth--;
                braceEnd++;
            }

            if (braceDepth != 0)
            {
                import std.exception : enforce;

                enforce(false, "Unmatched braces in interpolated string");
            }

            string expr = interpContent[braceStart .. braceEnd - 1].strip();
            expressions ~= expr;

            pos = braceEnd;
        }
        else
        {
            currentPart ~= interpContent[pos];
            pos++;
        }
    }

    parts ~= currentPart;

    if (expressions.length == 0)
    {
        return "\"" ~ interpContent ~ "\"";
    }

    string resultVar = "_axe_interp_" ~ uniform(0, 999_999).to!string;
    string code = "({";

    code ~= "size_t " ~ resultVar ~ "_len = " ~ parts[0].length.to!string;
    foreach (i, expr; expressions)
    {
        string varType = lookupExpressionType(expr);
        string processedExprForLen = processExpression(expr);

        if (i + 1 < parts.length)
            code ~= " + " ~ parts[i + 1].length.to!string;

        if (varType == "string" || varType.endsWith("_string") || varType == "std__string__string")
            code ~= " + (" ~ processedExprForLen ~ ").len";
        else
            code ~= " + 32";
    }
    code ~= "; ";

    code ~= "char* " ~ resultVar ~ " = (char*)malloc(" ~ resultVar ~ "_len + 1); ";
    code ~= "char* " ~ resultVar ~ "_p = " ~ resultVar ~ "; ";

    foreach (i, part; parts)
    {
        if (part.length > 0)
        {
            string escapedPart = part.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", "\\t");
            code ~= "memcpy(" ~ resultVar ~ "_p, \"" ~ escapedPart ~ "\", " ~ part.length.to!string ~ "); ";
            code ~= resultVar ~ "_p += " ~ part.length.to!string ~ "; ";
        }

        if (i < expressions.length)
        {
            string expr = expressions[i];
            string varType = lookupExpressionType(expr);
            string processedExpr = processExpression(expr);

            if (varType == "string" || varType.endsWith("_string") || varType == "std__string__string")
            {
                code ~= "{ struct std__string__string _s = " ~ processedExpr ~ "; ";
                code ~= "memcpy(" ~ resultVar ~ "_p, _s.data, _s.len); ";
                code ~= resultVar ~ "_p += _s.len; } ";
            }
            else
            {
                string formatSpec = getTypeFormatSpecifier(varType);
                string exprToFormat = processedExpr;

                code ~= "{ int _len = snprintf(" ~ resultVar ~ "_p, 32, \"" ~ formatSpec ~ "\", " ~ exprToFormat ~ "); ";
                code ~= resultVar ~ "_p += _len; } ";
            }
        }
    }

    code ~= "*" ~ resultVar ~ "_p = '\\0'; ";

    if (returnStruct)
    {
        string structVar = "_axe_str_struct_" ~ uniform(0, 999_999).to!string;
        code ~= "struct std__string__string " ~ structVar ~ " = {0}; ";
        code ~= structVar ~ ".data = " ~ resultVar ~ "; ";
        code ~= structVar ~ ".len = " ~ resultVar ~ "_p - " ~ resultVar ~ "; ";
        code ~= structVar ~ ".cap = " ~ resultVar ~ "_len + 1; ";
        code ~= structVar ~ "; })";
    }
    else
    {
        code ~= resultVar ~ "; })";
    }

    return code;
}

/**
 * Function to lookup the type of an expression
 */
string lookupExpressionType(string expr)
{
    expr = expr.strip();

    if (expr in g_varType)
    {
        return g_varType[expr];
    }

    if (expr.startsWith("\"") && expr.endsWith("\""))
        return "string";

    if (expr.startsWith("'") && expr.endsWith("'"))
        return "char";

    if (expr.length > 0 && (expr[0] >= '0' && expr[0] <= '9'))
    {
        if (expr.canFind("."))
            return "f64";
        return "i32";
    }

    return "i32";
}

/**
 * Replace keywords with C operators outside of string literals.
 * Respects word boundaries to avoid replacing keywords inside identifiers.
 */
private string replaceKeywordOutsideStrings(string input, string keyword, string replacement)
{
    string result = "";
    bool inString = false;
    bool inCharLiteral = false;
    size_t i = 0;

    while (i < input.length)
    {
        // Track double-quoted strings
        if (input[i] == '"' && !inCharLiteral)
        {
            // Check if it's escaped (but not a double-escape)
            bool isEscaped = false;
            if (i > 0 && input[i - 1] == '\\')
            {
                // Count consecutive backslashes before this quote
                size_t backslashCount = 0;
                size_t j = i - 1;
                while (j > 0 && input[j] == '\\')
                {
                    backslashCount++;
                    if (j == 0)
                        break;
                    j--;
                }
                // If odd number of backslashes, the quote is escaped
                isEscaped = (backslashCount % 2 == 1);
            }
            if (!isEscaped)
            {
                inString = !inString;
            }
            result ~= input[i];
            i++;
        }
        // Track single-quoted char literals
        else if (input[i] == '\'' && !inString)
        {
            // Check if it's escaped (but not a double-escape)
            bool isEscaped = false;
            if (i > 0 && input[i - 1] == '\\')
            {
                // Count consecutive backslashes before this quote
                size_t backslashCount = 0;
                size_t j = i - 1;
                while (j > 0 && input[j] == '\\')
                {
                    backslashCount++;
                    if (j == 0)
                        break;
                    j--;
                }
                // If odd number of backslashes, the quote is escaped
                isEscaped = (backslashCount % 2 == 1);
            }
            if (!isEscaped)
            {
                inCharLiteral = !inCharLiteral;
            }
            result ~= input[i];
            i++;
        }
        else if (!inString && !inCharLiteral)
        {
            bool matches = false;
            size_t matchLen = 0;

            if (i > 0 && i + keyword.length + 1 < input.length &&
                input[i - 1] == ' ' && input[i .. i + keyword.length] == keyword &&
                input[i + keyword.length] == ' ')
            {
                result ~= replacement;
                i += keyword.length;
                matches = true;
            }
            else if (i + keyword.length <= input.length && input[i .. i + keyword.length] == keyword)
            {
                import std.ascii : isAlphaNum, isDigit;

                bool beforeOk = (i == 0 || (!isAlphaNum(input[i - 1]) && input[i - 1] != '_'));
                bool afterOk = (i + keyword.length >= input.length ||
                        (!isAlphaNum(input[i + keyword.length]) && input[i + keyword.length] != '_'));

                // Special case: For logical operators (and/or/xor/not), if preceded by
                // a character that clearly ends an expression (like ', ), ], digit, operator),
                // allow the match even if followed by alphanumeric. This handles cases like
                // '0'andch where the parser squashed operators without spaces.
                bool isLogicalOp = (keyword == "and" || keyword == "or" ||
                        keyword == "xor" || keyword == "not");
                bool afterOperatorOrLiteral = (i > 0 && (input[i - 1] == '\'' ||
                        input[i - 1] == ')' ||
                        input[i - 1] == ']' ||
                        isDigit(input[i - 1])));

                // Match if: (beforeOk AND afterOk) OR (logical operator after expression)
                if ((beforeOk && afterOk) || (isLogicalOp && beforeOk && afterOperatorOrLiteral))
                {
                    if (i > 0 && input[i - 1] != ' ')
                        result ~= " ";
                    result ~= replacement;
                    if (i + keyword.length < input.length && input[i + keyword.length] != ' ')
                        result ~= " ";
                    i += keyword.length;
                    matches = true;
                }
            }

            if (!matches)
            {
                result ~= input[i];
                i++;
            }
        }
        else
        {
            result ~= input[i];
            i++;
        }
    }

    return result;
}

/**
 * Convert Axe type syntax to C type for cast expressions
 */
string processTypeForCast(string axeType)
{
    axeType = axeType.strip();

    // Handle ref prefix
    bool isRef = false;
    if (axeType.startsWith("ref "))
    {
        isRef = true;
        axeType = axeType[4 .. $].strip();
    }

    // Handle list(T) syntax
    if (axeType.startsWith("list(") && axeType.endsWith(")"))
    {
        string elementType = axeType[5 .. $ - 1].strip();
        string cElementType = mapAxeTypeToC(elementType);
        string listTypeName = "__list_" ~ cElementType.replace("*", "_ptr")
            .replace(" ", "_") ~ "_t";
        return isRef ? listTypeName ~ "*" : listTypeName;
    }

    // Map basic types
    string cType = mapAxeTypeToC(axeType);
    return isRef ? cType ~ "*" : cType;
}

/**
 * Function to process arithmetic expressions
 */
string processExpression(string expr, string context = "")
{
    expr = expr.strip();

    import std.string : replace;
    import std.algorithm : canFind;
    import std.regex : replaceAll, regex, matchAll;

    // Syntactic sugar: ::name always refers to a global variable, even if
    // there is a local with the same name. Rewrite ::name (with optional
    // whitespace between the colons) to the fully-qualified C symbol
    // before any other processing.
    auto globalMatches = matchAll(expr, regex(r":\s*:\s*([A-Za-z_][A-Za-z0-9_]*)"));
    foreach (m; globalMatches)
    {
        string fullMatch = m[0];
        string name = m[1];

        string mapped;
        if (name in g_globalVarPrefixes)
        {
            mapped = g_globalVarPrefixes[name];
        }
        else
        {
            mapped = "gvar__" ~ name;
        }

        debugWriteln("DEBUG: Mapping ::", name, " -> ", mapped);
        expr = expr.replace(fullMatch, mapped);
    }

    // If this is a simple identifier and it corresponds to an imported
    // global (tracked in g_globalVarPrefixes), rewrite it to the
    // fully-qualified gvar__* symbol. Do not override locals/params
    // tracked in g_varType. Note that ::name sugar above is handled
    // first and always takes precedence for explicit global access.
    if (expr.length > 0 &&
        !expr.canFind(" ") &&
        !expr.canFind("(") && !expr.canFind(")") &&
        !expr.canFind(".") && !expr.canFind("->") &&
        !expr.canFind("[") && !expr.canFind("]"))
    {
        if (expr !in g_varType && expr in g_globalVarPrefixes)
        {
            string mapped = g_globalVarPrefixes[expr];
            debugWriteln("DEBUG: Mapping global identifier '", expr, "' -> '", mapped, "'");
            expr = mapped;
        }
    }

    expr = expr.replaceAll(regex(r"\bC\s*\.\s*"), "");

    // Handle cast[Type](value) syntax -> (Type)(value)
    auto castMatches = matchAll(expr, regex(r"\bcast\s*\[\s*([^\]]+)\s*\]\s*\(\s*([^)]+)\s*\)"));
    foreach (match; castMatches)
    {
        string fullMatch = match[0];
        string castType = match[1].strip();
        string castValue = match[2].strip();

        // Process the type to handle 'ref list(string)' -> '__list_std__string__string_t*'
        string cType = processTypeForCast(castType);

        string replacement = "(" ~ cType ~ ")(" ~ castValue ~ ")";
        expr = expr.replace(fullMatch, replacement);
    }

    auto lenMatches = matchAll(expr, regex(r"\blen\s*\(\s*([^)]+)\s*\)"));
    foreach (match; lenMatches)
    {
        string fullMatch = match[0];
        string lenArg = match[1].strip();
        bool isPointer = false;

        if (lenArg.canFind("->"))
        {
            isPointer = true;
        }
        else if (lenArg.canFind("."))
        {
            auto lastDot = lenArg.lastIndexOf('.');
            if (lastDot >= 0)
            {
                string fieldName = lenArg[lastDot + 1 .. $].strip();
                auto bracketPos = fieldName.indexOf('[');
                if (bracketPos >= 0)
                    fieldName = fieldName[0 .. bracketPos];
                fieldName = fieldName.strip();

                foreach (modelName; g_modelNames.byValue)
                {
                    string fullFieldKey = modelName ~ "." ~ fieldName;
                    if (fullFieldKey in g_pointerFields && g_pointerFields[fullFieldKey])
                    {
                        isPointer = true;
                        break;
                    }
                }
            }
        }
        else
        {
            string baseVar = lenArg;
            auto bracketPos = baseVar.indexOf('[');
            if (bracketPos >= 0)
                baseVar = baseVar[0 .. bracketPos];
            baseVar = baseVar.strip();

            if (baseVar in g_isPointerVar && g_isPointerVar[baseVar] == "true")
            {
                isPointer = true;
            }
        }

        string replacement = isPointer ? ("len_ptr(" ~ lenArg ~ ")") : ("len_v(" ~ lenArg ~ ")");
        expr = expr.replace(fullMatch, replacement);
    }

    {
        bool insideString = false;
        bool insideChar = false;
        size_t idx = 0;
        while (idx < expr.length)
        {
            if (expr[idx] == '"' && (idx == 0 || expr[idx - 1] != '\\'))
                insideString = !insideString;
            else if (expr[idx] == '\'' && (idx == 0 || expr[idx - 1] != '\\'))
                insideChar = !insideChar;

            if (!insideString && !insideChar && idx + 4 <= expr.length && expr[idx .. idx + 4] == "list")
            {
                if (idx > 0)
                {
                    char prevChar = expr[idx - 1];
                    if ((prevChar >= 'a' && prevChar <= 'z') ||
                        (prevChar >= 'A' && prevChar <= 'Z') ||
                        (prevChar >= '0' && prevChar <= '9') ||
                        prevChar == '_')
                    {
                        idx++;
                        continue;
                    }
                }

                size_t j = idx + 4;
                while (j < expr.length && (expr[j] == ' ' || expr[j] == '\t'))
                    j++;
                if (j < expr.length && expr[j] == '(')
                {
                    size_t parenDepth = 1;
                    size_t k = j + 1;
                    while (k < expr.length && parenDepth > 0)
                    {
                        if (expr[k] == '(')
                            parenDepth++;
                        else if (expr[k] == ')')
                            parenDepth--;
                        k++;
                    }
                    if (parenDepth == 0)
                    {
                        string fullMatch = expr[idx .. k];
                        string innerContent = expr[j + 1 .. k - 1].strip();
                        string cElementType = mapAxeTypeToC(innerContent);
                        string listTypeName = "__list_" ~ cElementType.replace("*", "_ptr")
                            .replace(" ", "_") ~ "_t";
                        expr = expr[0 .. idx] ~ listTypeName ~ expr[k .. $];
                        idx += listTypeName.length;
                        continue;
                    }
                }
            }
            idx++;
        }
    }

    foreach (typeName, prefixedName; g_modelNames)
    {
        if (typeName != prefixedName)
        {
            expr = replaceKeywordOutsideStrings(expr, typeName, prefixedName);
        }
    }

    // len() is now handled by the C macro #define len(x) ((x).len)
    // No need for special processing here
    //
    // EARLY EXIT: If the entire expression is a string literal, return it as-is without any processing
    // Handle both " and ' as starting quotes (sometimes quotes get corrupted in parsing)

    if (expr.length >= 2 && (expr[0] == '"' || expr[0] == '\''))
    {
        // Check if it's actually a complete string literal (not multiple strings)
        // Look for either " or ' as the ending quote

        bool inEscape = false;
        size_t endQuotePos = 0;

        for (size_t i = 1; i < expr.length; i++)
        {
            if (inEscape)
            {
                inEscape = false;
            }
            else if (expr[i] == '\\')
            {
                inEscape = true;
            }
            else if (expr[i] == '"' || expr[i] == '\'')
            {
                endQuotePos = i;
                break;
            }
        }

        if (endQuotePos > 0 && endQuotePos + 1 == expr.length)
        {
            if (expr[0] != '"' && expr[endQuotePos] == '"')
            {
                return '"' ~ expr[1 .. $];
            }
            return expr;
        }
    }

    import std.regex : regex, matchFirst;
    import std.array : replace;
    import std.regex : replaceAll;
    import std.string : replace;

    if (expr.length == 1)
    {
        import std.ascii : isAlphaNum;

        char c = expr[0];
        if (!isAlphaNum(c) && c != '_' && c != '"' && c != '\'')
        {
            return "'" ~ expr ~ "'";
        }
    }

    {
        import std.ascii : isDigit;

        string normalized;
        bool inString = false;

        for (size_t i = 0; i < expr.length;)
        {
            char c = expr[i];
            if (c == '"' && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
                normalized ~= c;
                i++;
            }
            else if (!inString && isDigit(c))
            {
                size_t start = i;
                size_t intEnd = i;
                while (intEnd < expr.length && isDigit(expr[intEnd]))
                    intEnd++;

                size_t j = intEnd;
                while (j < expr.length && (expr[j] == ' ' || expr[j] == '\t'))
                    j++;

                if (j < expr.length && expr[j] == '.')
                {
                    j++;
                    while (j < expr.length && (expr[j] == ' ' || expr[j] == '\t'))
                        j++;

                    if (j < expr.length && isDigit(expr[j]))
                    {
                        size_t fracStart = j;
                        size_t fracEnd = j;
                        while (fracEnd < expr.length && isDigit(expr[fracEnd]))
                            fracEnd++;

                        normalized ~= expr[start .. intEnd];
                        normalized ~= ".";
                        normalized ~= expr[fracStart .. fracEnd];

                        i = fracEnd;
                        continue;
                    }
                }

                normalized ~= c;
                i++;
            }
            else
            {
                normalized ~= c;
                i++;
            }
        }

        expr = normalized;
    }

    // Strip outer parentheses if they wrap the entire expression
    import std.string : strip;

    string strippedExpr = expr.strip();
    if (strippedExpr.startsWith("(") && strippedExpr.endsWith(")"))
    {
        // Check if these are matching outer parens
        int depth = 0;
        bool isOuterParen = true;
        for (size_t i = 0; i < strippedExpr.length; i++)
        {
            if (strippedExpr[i] == '(')
                depth++;
            else if (strippedExpr[i] == ')')
                depth--;
            if (depth == 0 && i < strippedExpr.length - 1)
            {
                isOuterParen = false;
                break;
            }
        }
        if (isOuterParen)
        {
            strippedExpr = strippedExpr[1 .. $ - 1].strip();
        }
    }

    if (strippedExpr.startsWith("__INTERPOLATED__") && strippedExpr.endsWith("__INTERPOLATED__"))
    {
        string interpContent = strippedExpr[16 .. $ - 16];
        return processInterpolatedString(interpContent, false);
    }

    expr = replaceKeywordOutsideStrings(expr, "mod", "%");
    expr = replaceKeywordOutsideStrings(expr, "and", "&&");
    expr = replaceKeywordOutsideStrings(expr, "or", "||");
    expr = replaceKeywordOutsideStrings(expr, "xor", "^");
    expr = replaceKeywordOutsideStrings(expr, "not", "!");

    import std.string : indexOf, lastIndexOf;

    ptrdiff_t funcNameEnd = expr.indexOf("(");
    if (funcNameEnd > 0)
    {
        string funcName = expr[0 .. funcNameEnd].strip();

        import std.string : startsWith, strip;

        if (funcName.length >= 2 && funcName[0] == 'C')
        {
            string afterC = funcName[1 .. $].strip();
            if (afterC.length > 0 && (afterC[0] == '.' || afterC[0] == '_'))
            {
                auto dotPos = funcName.indexOf('.');
                auto underscorePos = funcName.indexOf("__");

                if (dotPos != -1)
                {
                    funcName = funcName[dotPos + 1 .. $].strip();
                }
                else if (underscorePos != -1)
                {
                    funcName = funcName[underscorePos + 2 .. $].strip();
                }
            }
        }

        ptrdiff_t argEnd = funcNameEnd + 1;
        int depth = 1;
        bool inQuote = false;
        while (argEnd < expr.length && depth > 0)
        {
            if (expr[argEnd] == '"' && (argEnd == 0 || expr[argEnd - 1] != '\\'))
                inQuote = !inQuote;
            else if (!inQuote && expr[argEnd] == '(')
                depth++;
            else if (!inQuote && expr[argEnd] == ')')
                depth--;
            argEnd++;
        }
        argEnd--;

        if (argEnd > funcNameEnd && argEnd < expr.length && expr[argEnd] == ')')
        {
            import std.stdio : writeln;

            string argsString = expr[funcNameEnd + 1 .. argEnd].strip();
            string suffix = (argEnd + 1 < expr.length) ? expr[argEnd + 1 .. $] : "";
            if (argsString.length > 0)
            {
                string[] argList;
                string currentArg = "";
                int parenDepth = 0;
                bool inQuoteArg = false;
                bool inInterpolated = false;

                for (size_t i = 0; i < argsString.length; i++)
                {
                    char c = argsString[i];

                    if (i + 16 <= argsString.length && argsString[i .. i + 16] == "__INTERPOLATED__")
                    {
                        inInterpolated = !inInterpolated;
                        currentArg ~= "__INTERPOLATED__";
                        i += 15;
                        continue;
                    }

                    if (c == '"' && (i == 0 || argsString[i - 1] != '\\'))
                        inQuoteArg = !inQuoteArg;
                    else if (!inQuoteArg && c == '(')
                        parenDepth++;
                    else if (!inQuoteArg && c == ')')
                        parenDepth--;
                    else if (!inQuoteArg && parenDepth == 0 && !inInterpolated && c == ',')
                    {
                        if (currentArg.length > 0)
                            argList ~= processExpression(currentArg.strip(), "function_call");
                        currentArg = "";
                        continue;
                    }
                    currentArg ~= c;
                }
                if (currentArg.length > 0)
                    argList ~= processExpression(currentArg.strip(), "function_call");

                expr = funcName ~ "(" ~ argList.join(", ") ~ ")" ~ suffix;
            }
        }
    }

    static immutable string[string] typeCastMap = [
        "i8": "int8_t",
        "u8": "uint8_t",
        "i16": "int16_t",
        "u16": "uint16_t",
        "i32": "int32_t",
        "u32": "uint32_t",
        "i64": "int64_t",
        "u64": "uint64_t",
        "isize": "intptr_t",
        "usize": "uintptr_t",
        "f32": "float",
        "f64": "double",
        "bool": "bool",
        "char": "char",
        "byte": "uint8_t",
        "ptrdiff": "intptr_t"
    ];

    // IMPORTANT: Do type replacements outside of string literals only
    foreach (axeType, cType; typeCastMap)
    {
        string result = "";
        bool inString = false;
        bool inCharLiteral = false;
        size_t i = 0;

        while (i < expr.length)
        {
            if (expr[i] == '"' && !inCharLiteral && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
                result ~= expr[i];
                i++;
            }
            else if (expr[i] == '\'' && !inString && (i == 0 || expr[i - 1] != '\\'))
            {
                inCharLiteral = !inCharLiteral;
                result ~= expr[i];
                i++;
            }
            else if (!inString && !inCharLiteral && i < expr.length && expr[i] == '(')
            {
                size_t j = i + 1;
                while (j < expr.length && (expr[j] == ' ' || expr[j] == '\t'))
                    j++;

                if (j + axeType.length <= expr.length && expr[j .. j + axeType.length] == axeType)
                {
                    size_t k = j + axeType.length;
                    while (k < expr.length && (expr[k] == ' ' || expr[k] == '\t'))
                        k++;

                    if (k < expr.length && expr[k] == ')')
                    {
                        result ~= "(" ~ cType ~ ")";
                        i = k + 1;
                        continue;
                    }
                }
                result ~= expr[i];
                i++;
            }
            else
            {
                result ~= expr[i];
                i++;
            }
        }
        expr = result;
    }

    {
        import std.regex : matchAll;

        auto refCastPattern = regex(r"\(\s*ref\s*(\w+)\s*\)");
        auto matches = matchAll(expr, refCastPattern);
        foreach (match; matches)
        {
            string fullMatch = match[0];
            string baseType = match[1];
            string cBaseType = baseType in typeCastMap ? typeCastMap[baseType] : baseType;

            expr = expr.replace(fullMatch, "(" ~ cBaseType ~ "*)");
        }
    }

    if (expr.canFind("[") && expr.canFind("{"))
    {
        size_t bracketStart = expr.indexOf("[");
        if (bracketStart == 0 || (bracketStart > 0 && expr[bracketStart - 1] != '.'))
        {
            size_t bracketEnd = expr.indexOf("]", bracketStart);
            if (bracketEnd != -1 && bracketEnd + 1 < expr.length)
            {
                size_t bracePos = bracketEnd + 1;
                while (bracePos < expr.length && (expr[bracePos] == ' ' || expr[bracePos] == '\t'))
                    bracePos++;

                if (bracePos < expr.length && expr[bracePos] == '{')
                {
                    string elementType = expr[bracketStart + 1 .. bracketEnd].strip();
                    bool isType = true;
                    foreach (c; elementType)
                    {
                        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                                (c >= '0' && c <= '9') || c == '_' || c == '*'))
                        {
                            isType = false;
                            break;
                        }
                    }

                    if (isType && elementType.length > 0)
                    {
                        size_t braceStart = bracePos;
                        size_t braceEnd = expr.indexOf("}", braceStart);
                        if (braceEnd != -1)
                        {
                            string arrayContent = expr[braceStart + 1 .. braceEnd];

                            string cType = mapAxeTypeToC(elementType);
                            string result = expr[0 .. bracketStart] ~ "(" ~ cType ~
                                "[]){" ~ arrayContent ~ "}";

                            if (braceEnd + 1 < expr.length)
                                result ~= expr[braceEnd + 1 .. $];

                            return result;
                        }
                    }
                }
            }
        }
    }

    debugWriteln("DEBUG processExpression: Checking for macros in expr: '", expr, "'");
    debugWriteln("DEBUG processExpression: Available macros: ", g_macros.keys);

    foreach (macroName, macroNode; g_macros)
    {
        import std.string : indexOf, split, strip;
        import std.regex : regex, matchFirst;

        auto macroPattern = regex(macroName ~ r"\s*\(");
        auto match = matchFirst(expr, macroPattern);

        if (match)
        {
            debugWriteln("DEBUG processExpression: Found macro call '", macroName, "' in expression");
        }

        while (match)
        {
            auto startIdx = match.pre.length;
            size_t parenStart = startIdx + macroName.length;
            while (parenStart < expr.length && (expr[parenStart] == ' ' || expr[parenStart] == '\t'))
                parenStart++;
            parenStart++;

            int depth = 1;
            size_t parenEnd = parenStart;
            while (parenEnd < expr.length && depth > 0)
            {
                if (expr[parenEnd] == '(')
                    depth++;
                else if (expr[parenEnd] == ')')
                    depth--;
                if (depth > 0)
                    parenEnd++;
            }

            string argsStr = expr[parenStart .. parenEnd];
            string[] callArgs;
            int argDepth = 0;
            size_t argStart = 0;
            for (size_t i = 0; i < argsStr.length; i++)
            {
                if (argsStr[i] == '(')
                    argDepth++;
                else if (argsStr[i] == ')')
                    argDepth--;
                else if (argsStr[i] == ',' && argDepth == 0)
                {
                    callArgs ~= argsStr[argStart .. i].strip();
                    argStart = i + 1;
                }
            }
            if (argStart < argsStr.length)
                callArgs ~= argsStr[argStart .. $].strip();

            string[string] paramMap;
            for (size_t i = 0; i < macroNode.params.length && i < callArgs.length;
                i++)
            {
                // For macro arguments, use them as-is without processing
                // This is important for untyped parameters used in raw C blocks
                // They should be literal string substitutions, not processed expressions
                paramMap[macroNode.params[i]] = callArgs[i].strip();
            }

            string expandedCode = "";
            foreach (child; macroNode.children)
            {
                if (child.nodeType == "RawC")
                {
                    auto rawNode = cast(RawCNode) child;
                    expandedCode = rawNode.code;

                    foreach (paramName, paramValue; paramMap)
                    {
                        expandedCode = expandedCode.replace(paramName, paramValue);
                    }
                }
            }

            expr = expr[0 .. startIdx] ~ "(" ~ expandedCode ~ ")" ~ expr[parenEnd + 1 .. $];

            match = matchFirst(expr, macroPattern);
        }
    }

    import std.regex : regex, replaceAll;

    while (expr.canFind("ref_of"))
    {
        auto startIdx = expr.indexOf("ref_of");
        if (startIdx == -1)
            break;

        size_t pos = startIdx + 6;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1; // After "("

        int depth = 1;
        size_t parenEnd = parenStart;
        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        debugWriteln("DEBUG ref_of: varName = '", varName, "', parenEnd = ", parenEnd, ", expr.length = ", expr
                .length);
        debugWriteln("DEBUG ref_of: suffix = '", expr[parenEnd + 1 .. $], "'");
        if (varName.canFind("[") || varName.canFind("."))
        {
            expr = expr[0 .. startIdx] ~ "&(" ~ varName ~ ")" ~ expr[parenEnd + 1 .. $];
            debugWriteln("DEBUG ref_of: wrapped expression = '", expr, "'");
        }
        else
        {
            expr = expr[0 .. startIdx] ~ "&" ~ varName ~ expr[parenEnd + 1 .. $];
        }
    }

    while (expr.canFind("addr_of"))
    {
        auto startIdx = expr.indexOf("addr_of");
        if (startIdx == -1)
            break;

        size_t pos = startIdx + 7;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1; // After "("

        int depth = 1;
        size_t parenEnd = parenStart;
        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "&" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    while (expr.canFind("addr_int"))
    {
        auto startIdx = expr.indexOf("addr_int");
        if (startIdx == -1)
            break;

        size_t pos = startIdx + 8;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1; // After "("

        int depth = 1;
        size_t parenEnd = parenStart;
        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "(int64_t)&" ~ varName ~ expr[parenEnd + 1 .. $];
    }

    while (expr.canFind("deref"))
    {
        auto startIdx = expr.indexOf("deref");
        if (startIdx == -1)
            break;

        size_t pos = startIdx + 5;
        while (pos < expr.length && (expr[pos] == ' ' || expr[pos] == '\t'))
            pos++;

        if (pos >= expr.length || expr[pos] != '(')
            break;

        auto parenStart = pos + 1;
        int depth = 1;
        size_t parenEnd = parenStart;

        while (parenEnd < expr.length && depth > 0)
        {
            if (expr[parenEnd] == '(')
                depth++;
            else if (expr[parenEnd] == ')')
                depth--;
            if (depth > 0)
                parenEnd++;
        }

        string varName = expr[parenStart .. parenEnd].strip();
        expr = expr[0 .. startIdx] ~ "(*" ~ varName ~ ")" ~ expr[parenEnd + 1 .. $];
    }

    {
        // Replace "ref varname" with "&varname" OUTSIDE OF THE DAMN STRING LITERALS
        string result = "";
        bool inString = false;
        bool inCharLiteral = false;
        size_t i = 0;

        while (i < expr.length)
        {
            if (expr[i] == '"' && !inCharLiteral && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
                result ~= expr[i];
                i++;
            }
            else if (expr[i] == '\'' && !inString && (i == 0 || expr[i - 1] != '\\'))
            {
                inCharLiteral = !inCharLiteral;
                result ~= expr[i];
                i++;
            }
            else if (!inString && !inCharLiteral && i + 4 <= expr.length && expr[i .. i + 3] == "ref" && expr[i + 3] == ' ')
            {
                bool isWordBoundary = (i == 0 || !((expr[i - 1] >= 'a' && expr[i - 1] <= 'z') ||
                        (expr[i - 1] >= 'A' && expr[i - 1] <= 'Z') ||
                        (expr[i - 1] >= '0' && expr[i - 1] <= '9') ||
                        expr[i - 1] == '_'));

                if (isWordBoundary)
                {
                    i += 4;
                    result ~= "&";
                    continue;
                }
                result ~= expr[i];
                i++;
            }
            else
            {
                result ~= expr[i];
                i++;
            }
        }
        expr = result;
    }

    if (expr.canFind("["))
    {
        bool inString = false;
        int parenDepth = 0;
        size_t bracketPos = expr.length;
        for (size_t i = 0; i < expr.length; i++)
        {
            if (expr[i] == '"' && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
            }
            else if (!inString && expr[i] == '(')
            {
                parenDepth++;
            }
            else if (!inString && expr[i] == ')')
            {
                parenDepth--;
            }
            else if (!inString && parenDepth == 0 && expr[i] == '[')
            {
                bracketPos = i;
                break;
            }
        }

        if (bracketPos < expr.length)
        {
            string base = expr[0 .. bracketPos].strip();
            size_t endPos = bracketPos + 1;
            int depth = 1;
            bool inIndexString = false;
            while (endPos < expr.length && depth > 0)
            {
                if (expr[endPos] == '"' && (endPos == 0 || expr[endPos - 1] != '\\'))
                {
                    inIndexString = !inIndexString;
                }
                else if (!inIndexString && expr[endPos] == '[')
                {
                    depth++;
                }
                else if (!inIndexString && expr[endPos] == ']')
                {
                    depth--;
                }
                endPos++;
            }

            if (depth > 0)
                return expr;

            string index = expr[bracketPos + 1 .. endPos - 1].strip();
            string rest = expr[endPos .. $].strip();
            string processedBase = processExpression(base);
            string processedIndex = processExpression(index);
            string processedRest = rest.length > 0 ? processExpression(rest) : "";
            return processedBase ~ "[" ~ processedIndex ~ "]" ~ processedRest;
        }
    }

    if (expr.canFind("*."))
    {
        string result = "";
        bool inString = false;
        for (size_t i = 0; i < expr.length; i++)
        {
            if (expr[i] == '"' && (i == 0 || expr[i - 1] != '\\'))
            {
                inString = !inString;
                result ~= expr[i];
            }
            else if (!inString && i + 1 < expr.length && expr[i] == '*' && expr[i + 1] == '.')
            {
                result ~= "->";
                i++;
            }
            else
            {
                result ~= expr[i];
            }
        }
        expr = result;
    }

    if (expr.startsWith("C."))
    {
        expr = expr[2 .. $];
    }

    /** 
     * Parse an identifier from the string starting at index i
     * Params:
     *   s = string to parse
     *   i = reference to the current index in the string; will be updated to the position after the parsed identifier
     * Returns: the parsed identifier as a string
     */
    string parseIdentifier(string s, ref size_t i)
    {
        size_t start = i;
        while (i < s.length && (s[i] >= 'a' && s[i] <= 'z' || s[i] >= 'A' && s[i] <= 'Z' ||
                s[i] >= '0' && s[i] <= '9' || s[i] == '_'))
            i++;
        return s[start .. i];
    }

    /** 
     * Skip some whitespace characters in the string starting at index i
     * Params:
     *   s = string to parse
     *   i = reference to the current index in the string; will be updated to the position after the skipped whitespace
     */
    void skipWhitespace(string s, ref size_t i)
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
            i++;
    }

    string exprResult = "";
    size_t pos = 0;
    bool inStringLiteral = false;

    while (pos < expr.length)
    {
        if (expr[pos] == '"' && (pos == 0 || expr[pos - 1] != '\\'))
        {
            inStringLiteral = !inStringLiteral;
            exprResult ~= expr[pos];
            pos++;
            continue;
        }

        if (inStringLiteral)
        {
            exprResult ~= expr[pos];
            pos++;
            continue;
        }

        // Check if we're at the start of an identifier
        if (expr[pos] >= 'a' && expr[pos] <= 'z' || expr[pos] >= 'A' && expr[pos] <= 'Z' || expr[pos] == '_')
        {
            size_t startPos = pos;
            string ident = parseIdentifier(expr, pos);

            // Look ahead to see if this is part of a member access chain or static method call
            size_t lookahead = pos;
            skipWhitespace(expr, lookahead);

            if (lookahead < expr.length && expr[lookahead] == '.')
            {
                // This is the start of a chain - collect the entire chain
                string chain = ident;
                bool isPointer = g_isPointerVar.get(ident, "false") == "true";
                string currentType = g_varType.get(ident, "");

                if (currentType.length > 0)
                {
                    if (currentType[$ - 1] == '*' || currentType.startsWith("ref "))
                        isPointer = true;
                }

                string baseModelName = currentType;
                if (baseModelName.startsWith("ref "))
                    baseModelName = baseModelName[4 .. $].strip();
                if (baseModelName.startsWith("mut "))
                    baseModelName = baseModelName[4 .. $].strip();
                while (baseModelName.length > 0 && baseModelName[$ - 1] == '*')
                    baseModelName = baseModelName[0 .. $ - 1].strip();

                // Check if this is a static method call (Model.method(...))
                // The identifier could be either the short name (Arena) or already-prefixed (std__arena__Arena)
                bool isStaticMethod = false;
                string prefixedModelName = "";

                if (ident in g_modelNames)
                {
                    prefixedModelName = g_modelNames[ident];
                }
                else if (ident.canFind("__"))
                {
                    prefixedModelName = ident;
                }

                if (prefixedModelName.length > 0)
                {
                    size_t temp = lookahead + 1; // Skip the dot
                    skipWhitespace(expr, temp); // Skip any whitespace after the dot
                    string methodName = parseIdentifier(expr, temp);

                    if (methodName.length > 0)
                    {
                        skipWhitespace(expr, temp);

                        bool isEnum = (prefixedModelName in g_enumNames) !is null;
                        bool hasOpenParen = temp < expr.length && expr[temp] == '(';

                        if (hasOpenParen || isEnum)
                        {
                            exprResult ~= prefixedModelName ~ "_" ~ methodName;
                            pos = temp;
                            continue;
                        }
                    }
                }

                pos = lookahead;
                while (pos < expr.length && expr[pos] == '.')
                {
                    pos++; // Skip dot
                    skipWhitespace(expr, pos); // Skip any whitespace after the dot
                    string fieldName = parseIdentifier(expr, pos);

                    string arraySuffix = "";
                    if (pos < expr.length && expr[pos] == '[')
                    {
                        size_t bracketStart = pos;
                        pos++;
                        int depth = 1;
                        while (pos < expr.length && depth > 0)
                        {
                            if (expr[pos] == '[')
                                depth++;
                            else if (expr[pos] == ']')
                                depth--;
                            pos++;
                        }
                        arraySuffix = expr[bracketStart .. pos];
                    }

                    string op = isPointer ? "->" : ".";
                    chain ~= op ~ fieldName ~ arraySuffix;

                    string fieldKey = baseModelName ~ "." ~ fieldName;
                    if (fieldKey in g_pointerFields)
                    {
                        isPointer = true;
                        if (fieldKey in g_fieldTypes)
                        {
                            string fieldType = g_fieldTypes[fieldKey];
                            if (fieldType.startsWith("ref "))
                                fieldType = fieldType[4 .. $].strip();
                            if (fieldType.startsWith("mut "))
                                fieldType = fieldType[4 .. $].strip();
                            while (fieldType.length > 0 && fieldType[$ - 1] == '*')
                                fieldType = fieldType[0 .. $ - 1].strip();
                            baseModelName = fieldType;
                        }
                    }
                    else
                    {
                        isPointer = false;
                        if (fieldKey in g_fieldTypes)
                        {
                            string fieldType = g_fieldTypes[fieldKey];
                            if (fieldType.startsWith("ref "))
                                fieldType = fieldType[4 .. $].strip();
                            if (fieldType.startsWith("mut "))
                                fieldType = fieldType[4 .. $].strip();
                            while (fieldType.length > 0 && fieldType[$ - 1] == '*')
                                fieldType = fieldType[0 .. $ - 1].strip();
                            baseModelName = fieldType;
                        }
                    }

                    skipWhitespace(expr, pos);
                    if (pos >= expr.length || expr[pos] != '.')
                        break;
                }

                exprResult ~= chain;
            }
            else
            {
                exprResult ~= ident;
            }
        }
        else
        {
            exprResult ~= expr[pos];
            pos++;
        }
    }

    expr = exprResult;
    expr = applyFunctionPrefixes(expr);

    if (expr.canFind("(") && expr.endsWith(")"))
    {
        size_t parenPos = expr.indexOf("(");
        if (parenPos > 0)
        {
            string funcName = expr[0 .. parenPos].strip();
            string args = expr[parenPos .. $];

            string actualFuncName = funcName;
            if (funcName.startsWith("!"))
            {
                actualFuncName = funcName[1 .. $].strip();
            }

            debugWriteln("DEBUG processExpression: Found potential function call '", actualFuncName, "' with args '", args, "'");
            debugWriteln("DEBUG processExpression: Checking g_functionPrefixes for '", actualFuncName, "'");

            if (actualFuncName in g_functionPrefixes)
            {
                string prefixedFuncName = g_functionPrefixes[actualFuncName];
                debugWriteln("DEBUG processExpression: Found mapping '", actualFuncName, "' -> '", prefixedFuncName, "'");

                if (funcName.startsWith("!"))
                {
                    return "!" ~ prefixedFuncName ~ args;
                }
                else
                {
                    return prefixedFuncName ~ args;
                }
            }
            else
            {
                debugWriteln("DEBUG processExpression: No mapping found for '", actualFuncName, "'");
            }
        }

        return expr;
    }

    // Check for operators, but try very hard not to split on dots (member access) or operators inside strings
    // Note: Longer operators must come first to avoid incorrect matching (e.g., >> before >)
    foreach (op; [
            "<<", ">>", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/",
            "%", "<", ">"
        ])
    {
        if (expr.canFind(op) && op != "")
        {
            string[] parts;
            string current = "";
            bool inString = false;
            int parenDepth = 0;

            for (size_t i = 0; i < expr.length; i++)
            {
                if (expr[i] == '"' && (i == 0 || expr[i - 1] != '\\'))
                {
                    inString = !inString;
                    current ~= expr[i];
                }
                else if (!inString && expr[i] == '(')
                {
                    parenDepth++;
                    current ~= expr[i];
                }
                else if (!inString && expr[i] == ')')
                {
                    parenDepth--;
                    current ~= expr[i];
                }
                else if (!inString && parenDepth == 0 && i + op.length <= expr.length &&
                    expr[i .. i + op.length] == op &&
                    (i == 0 || expr[i - 1] != op[0]))
                {
                    // Don't split on - if it's part of ->
                    if (op == "-" && i + 1 < expr.length && expr[i + 1] == '>')
                    {
                        current ~= expr[i];
                        continue;
                    }
                    // Don't split on > if it's part of ->
                    if (op == ">" && i > 0 && expr[i - 1] == '-')
                    {
                        current ~= expr[i];
                        continue;
                    }

                    parts ~= current;
                    current = "";
                    i += cast(int) op.length - 1;
                }
                else
                {
                    current ~= expr[i];
                }
            }
            parts ~= current;

            if (parts.length == 2)
            {
                if (parts[0].strip().length == 0)
                    continue;
                return "(" ~ processExpression(parts[0]) ~ op ~ processExpression(parts[1]) ~ ")";
            }
            else if (parts.length > 2)
            {
                if (parts[0].strip().length == 0)
                    continue;
                string result = processExpression(parts[0]);
                for (int i = 1; i < parts.length; i++)
                {
                    result = "(" ~ result ~ op ~ processExpression(parts[i]) ~ ")";
                }
                return result;
            }
        }
    }

    if (expr in g_refDepths && g_refDepths[expr] > 0)
    {
        if (context == "println")
        {
            string result = expr;
            for (int i = 0; i < g_refDepths[expr]; i++)
            {
                result = "*" ~ result;
            }
            return result;
        }
    }

    // TODO: Remove and replace with something better.
    //
    // Hack: conditions that compare against bare { or } came from STR tokens in the parser
    // without quotes. Emit them as C character literals so generated code is valid.
    if (expr == "{")
        return "'{'";
    if (expr == "}")
        return "'}'";

    // Handle bare char literals that need to be wrapped in single quotes for C
    // These come from the parser without quotes (e.g., ',' becomes just , in AST)
    // However, we only wrap punctuation - NOT letters or digits, as those might be variable names
    if (expr.length == 1)
    {
        char c = expr[0];
        bool isLetter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        bool isDigit = (c >= '0' && c <= '9');
        bool isOperator = (c == '+' || c == '-' || c == '*' || c == '/' || c == '%' ||
                c == '=' || c == '<' || c == '>' || c == '&' || c == '|' ||
                c == '!' || c == '~' || c == '^');
        bool isUnderscore = (c == '_');

        // Only wrap punctuation characters (not letters, digits, operators, or underscore)
        // Letters will be handled properly by the parser wrapping CHAR tokens
        if (!isLetter && !isDigit && !isOperator && !isUnderscore && c >= 32 && c < 127)
        {
            if (c == '\'')
                return "'\\\''"; // Single quote needs escaping
            else if (c == '\\')
                return "'\\\\'"; // Backslash needs escaping
            else if (c == '"')
                return "'\"'"; // Double quote in single quotes
            else
                return "'" ~ expr ~ "'";
        }
    }

    if (expr.length == 2 && expr[0] == '\\')
    {
        return "'" ~ expr ~ "'";
    }

    // Check if this is a standalone enum value that needs prefixing
    if (expr in g_enumValueToEnumName)
    {
        string enumName = g_enumValueToEnumName[expr];
        return enumName ~ "_" ~ expr;
    }

    debugWriteln("DEBUG processExpression FINAL: returning '", expr, "'");
    return expr;
}

string applyFunctionPrefixes(string expr)
{
    import std.regex : regex, replaceAll;

    foreach (funcName, prefixedName; g_functionPrefixes)
    {
        expr = expr.replaceAll(regex(r"\b" ~ funcName ~ r"\s*\("), prefixedName ~ "(");
    }

    if (g_currentModuleName.length > 0)
    {
        foreach (funcName, _; g_localFunctions)
        {
            string prefixedName = g_currentModuleName ~ "__" ~ funcName;
            expr = expr.replaceAll(regex(r"\b" ~ funcName ~ r"\s*\("), prefixedName ~ "(");
        }
    }
    return expr;
}

import std.array;

/**
 * Determines the printf format specifier for an expression.
 * Returns "%s" for strings, "%d" for integers (default).
 */
private string getFormatSpecifier(string expr)
{
    import std.string : strip;

    string trimmed = expr.strip();

    while (trimmed.startsWith("(") && trimmed.endsWith(")"))
    {
        trimmed = trimmed[1 .. $ - 1].strip();
    }

    if (trimmed.startsWith("\"") && trimmed.endsWith("\""))
    {
        return "%s";
    }

    if (expr.canFind(".data"))
    {
        return "%s";
    }

    string varName = trimmed;

    if (varName.canFind("."))
    {
        varName = varName[0 .. varName.indexOf(".")];
    }
    else if (varName.canFind("->"))
    {
        varName = varName[0 .. varName.indexOf("->")];
    }

    if (varName in g_varType)
    {
        string varType = g_varType[varName];
        if (varType.canFind("*") || varType.canFind("char"))
        {
            return "%s";
        }
    }

    return "%d";
}

private string processCondition(string condition)
{
    import std.array : replace;
    import std.string : indexOf;

    // Use replaceKeywordOutsideStrings for proper word-boundary checking
    condition = replaceKeywordOutsideStrings(condition, "mod", "%");
    condition = replaceKeywordOutsideStrings(condition, "and", "&&");
    condition = replaceKeywordOutsideStrings(condition, "band", "&");
    condition = replaceKeywordOutsideStrings(condition, "bor", "|");
    condition = replaceKeywordOutsideStrings(condition, "shl", "<<");
    condition = replaceKeywordOutsideStrings(condition, "shr", ">>");
    condition = replaceKeywordOutsideStrings(condition, "not", "!");
    condition = replaceKeywordOutsideStrings(condition, "or", "||");
    condition = replaceKeywordOutsideStrings(condition, "xor", "^");

    // Handle logical operators (&&, ||) first - they have lowest precedence
    foreach (op; ["&&", "||"])
    {
        auto idx = condition.indexOf(op);
        if (idx >= 0)
        {
            string left = condition[0 .. idx].strip();
            string right = condition[idx + op.length .. $].strip();
            string result = "(" ~ processCondition(left) ~ " " ~ op ~ " " ~ processCondition(
                right) ~ ")";
            result = applyFunctionPrefixes(result);
            return result;
        }
    }

    // Then handle comparison operators - check longer operators first to avoid partial matches
    foreach (op; ["==", "!=", ">=", "<=", ">", "<"])
    {
        auto idx = condition.indexOf(op);
        if (idx >= 0)
        {
            string left = condition[0 .. idx].strip();
            string right = condition[idx + op.length .. $].strip();
            string result = "(" ~ processExpression(left) ~ op ~ processExpression(right) ~ ")";
            result = applyFunctionPrefixes(result);
            return result;
        }
    }

    string result = processExpression(condition);
    result = applyFunctionPrefixes(result);
    return result;
}

string generateStackTraceHandlers()
{
    string code = "";
    version (Windows)
    {
        code ~= "#include <dbghelp.h>\n";
    }
    else version (Posix)
    {
        code ~= "#include <execinfo.h>\n";
        code ~= "#include <signal.h>\n";
        code ~= "#include <unistd.h>\n";
    }
    code ~= "\n";
    version (Windows)
    {
        code ~= "static void axe_win_print_backtrace(void) {\n";
        code ~= "    HANDLE process = GetCurrentProcess();\n";
        code ~= "    SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME | SYMOPT_LOAD_LINES);\n";
        code ~= "    SymInitialize(process, NULL, TRUE);\n";
        code ~= "\n";
        code ~= "    void* stack[64];\n";
        code ~= "    USHORT frames = CaptureStackBackTrace(0, 64, stack, NULL);\n";
        code ~= "    fprintf(stderr, \"Backtrace (%u frames):\\n\", (unsigned)frames);\n";
        code ~= "\n";
        code ~= "    SYMBOL_INFO* symbol = (SYMBOL_INFO*)malloc(sizeof(SYMBOL_INFO) + 256);\n";
        code ~= "    if (!symbol) return;\n";
        code ~= "    memset(symbol, 0, sizeof(SYMBOL_INFO) + 256);\n";
        code ~= "    symbol->MaxNameLen = 255;\n";
        code ~= "    symbol->SizeOfStruct = sizeof(SYMBOL_INFO);\n";
        code ~= "\n";
        code ~= "    for (USHORT i = 0; i < frames; i++) {\n";
        code ~= "        DWORD64 address = (DWORD64)(stack[i]);\n";
        code ~= "        if (SymFromAddr(process, address, 0, symbol)) {\n";
        code ~= "            fprintf(stderr, \"  #%02u 0x%llx %s\\n\", (unsigned)i, (unsigned long long)address, symbol->Name);\n";
        code ~= "        } else {\n";
        code ~= "            fprintf(stderr, \"  #%02u 0x%llx <unknown>\\n\", (unsigned)i, (unsigned long long)address);\n";
        code ~= "        }\n";
        code ~= "    }\n";
        code ~= "    free(symbol);\n";
        code ~= "}\n";
        code ~= "\n";
        code ~= "static LONG WINAPI axe_unhandled_exception_filter(EXCEPTION_POINTERS* info) {\n";
        code ~= "    (void)info;\n";
        code ~= "    fprintf(stderr, \"Fatal: Unhandled exception.\\n\");\n";
        code ~= "    axe_win_print_backtrace();\n";
        code ~= "    fflush(stderr);\n";
        code ~= "    ExitProcess(1);\n";
        code ~= "    return EXCEPTION_EXECUTE_HANDLER;\n";
        code ~= "}\n";
    }
    else version (Posix)
    {
        code ~= "static void axe_segv_handler(int sig) {\n";
        code ~= "    const char* name = (sig == SIGSEGV ? \"SIGSEGV\" : (sig == SIGABRT ? \"SIGABRT\" : \"SIGNAL\"));\n";
        code ~= "    fprintf(stderr, \"Fatal: %s received.\\n\", name);\n";
        code ~= "    void* frames[64];\n";
        code ~= "    int n = backtrace(frames, 64);\n";
        code ~= "    if (n > 0) {\n";
        code ~= "        fprintf(stderr, \"Backtrace (%d frames):\\n\", n);\n";
        code ~= "        backtrace_symbols_fd(frames, n, fileno(stderr));\n";
        code ~= "    }\n";
        code ~= "    fflush(stderr);\n";
        code ~= "    _exit(139);\n";
        code ~= "}\n";
    }
    code ~= "\n";
    return code;
}

string generateStackTraceSetup()
{
    string code;
    version (Windows)
    {
        code ~= "    SetUnhandledExceptionFilter(axe_unhandled_exception_filter);\n";
    }
    else version (Posix)
    {
        code ~= "    signal(SIGSEGV, axe_segv_handler);\n";
        code ~= "    signal(SIGABRT, axe_segv_handler);\n";
    }
    return code;
}

unittest
{
    import axe.parser;
    import axe.lexer;
    import std.stdio;
    import std.string;

    {
        auto tokens = lex("def main() { put \"hello\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int main(int argc, char** argv)"));
        assert(cCode.canFind("printf(\"hello\")"));
    }

    {
        auto tokens = lex("def foo { put \"hello\"; } def main() { foo(); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("foo()"));
    }

    {
        auto tokens = lex("def main() { foo(1, 2); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("foo(1, 2)"));
    }

    {
        auto tokens = lex("def main() { loop { break; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("while (1) {"));
        assert(cCode.canFind("break;"));
    }

    {
        auto tokens = lex("def main() { if (x > 5) { put \"greater\"; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);

        assert(cCode.canFind("(x>5 )"));
        assert(cCode.canFind(`printf("greater");`));
    }

    {
        auto tokens = lex("def main() { val x = 5 + 3; val y = x - 2; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("const int x = (5+3)"));
        assert(cCode.canFind("const int y = (x-2)"));
    }

    {
        auto tokens = lex(
            "def foo { put \"in foo\"; } def main() { foo(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);
        assert(cCode.canFind("void foo()"));
        assert(cCode.canFind(`printf("in foo");`));
        assert(cCode.canFind("foo();"));
    }

    {
        auto tokens = lex(
            "def add(a: i32, b: i32): i32 { return a + b; } def main() { val x: i32 = add(1, 2); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int32_t add(int32_t a, int32_t b)"));
        assert(cCode.canFind("return (a+b);"));
        assert(cCode.canFind("const int32_t x = add(1, 2);"));
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex("def main() { y = y + 1; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Undeclared variable: y"));
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught undeclared variable error");
        }
    }

    {
        auto tokens = lex("def main() { put \"start\"; loop { put \"in loop\"; break; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Loop test output:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Loop should start with while (1) {");
        assert(cCode.canFind("printf(\"in loop\");"), "Loop should contain println");
        assert(cCode.canFind("break;"), "Loop should contain break");

        import std.algorithm : count;
        import std.string : indexOf;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced in loop code");

        auto loopStart = cCode.indexOf("while (1)");
        auto returnPos = cCode.indexOf("return 0;");
        assert(loopStart < returnPos, "return should come after loop");
    }

    {
        auto tokens = lex("def main() { mut val x = 5; x = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable reassignment test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 5;"), "Should declare x");
        assert(cCode.canFind("x = 10;"), "Should reassign x");
    }

    {
        auto tokens = lex(
            "def testfunc() { mut val x = 0; loop { put \"test\"; x = x + 1; if x == 5 { break; } } } def main() { testfunc(); }"
        );
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Complex loop test:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("printf(\"test\");"), "Should have put in loop");
        assert(cCode.canFind("x = (x+1);"), "Should have assignment in loop");
        assert(cCode.canFind("if ((x==5))"), "Should have if statement");

        import std.algorithm : count;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced");
    }

    {
        auto tokens = lex(
            "def greet(name: ref char, t: i32) { put \"hello\"; } def main() { greet(\"world\", 1); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function call with string literal test:");
        writeln(cCode);

        assert(cCode.canFind("void greet(char* name, int32_t t)"), "Should declare greet function");
        assert(cCode.canFind("greet(\"world\", 1);"), "String literal should have quotes in function call");
        assert(!cCode.canFind("greet(world, 1);"), "String literal should not lose quotes");
    }

    {
        auto tokens = lex("// This is a comment\ndef main() { put \"test\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Comment filtering test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"test\");"), "Should have put statement");
        assert(!cCode.canFind("//"), "Comments should be filtered out");
        assert(!cCode.canFind("This is a comment"), "Comment text should not appear in output");
    }

    {
        auto tokens = lex("def main() { raw { printf(\"raw C\"); } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Raw C block test (.axec):");
        writeln(cCode);

        assert(cCode.canFind("printf(\"raw C\");"), "Should have raw C code");
        assert(!cCode.canFind("raw {"), "Raw keyword should not appear in output");
    }

    {
        auto tokens = lex("def main() { put \"before\"; raw { int x = 5; } put \"after\"; }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Mixed raw C and Axe code test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"before\");"), "Should have first put");
        assert(cCode.canFind("int x = 5;"), "Should have raw C code");
        assert(cCode.canFind("printf(\"after\");"), "Should have second put");
    }

    {
        import std.exception : assertThrown;

        auto tokens = lex("def main() { raw { test(); } }");

        writeln("Raw C block rejection test (.axe):");
        assertThrown(parse(tokens, false), "Should reject raw blocks in .axe files");
        writeln("Correctly rejected raw block in .axe file");
    }

    {
        auto tokens = lex("model Cat { name: ref char, age: i32 } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model definition test:");
        writeln(cCode);

        assert(cCode.canFind("struct Cat {"), "Should have struct definition");
        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int32_t age;"), "Should have age field");
        assert(cCode.canFind("typedef struct Cat Cat;"), "Should have Cat typedef");
    }

    {
        auto tokens = lex(
            "model Cat { name: ref char, health: i32 } " ~
                "def main() { val cat = new Cat(name: \"Garfield\", health: 100); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model instantiation test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat Cat;"), "Should have struct definition");
        assert(cCode.canFind("const Cat cat = {"), "Should have const struct initialization");
        assert(cCode.canFind(".name = \"Garfield\""), "Should initialize name field");
        assert(cCode.canFind(".health = 100"), "Should initialize health field");
    }

    {
        auto tokens = lex(
            "overload println(x: generic) { i32 => println_i32; }(x); " ~
                "def println_i32(x: i32) { put \"int\"; } " ~
                "def main() { println(42); }");

        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Overload macro hoist test:");
        writeln(cCode);

        assert(cCode.canFind("#define println("), "Overload should generate println macro");
        assert(cCode.canFind("int32_t: println_i32"),
            "Overload should map i32 to println_i32 in _Generic");

        auto macroPos = cCode.indexOf("#define println(");
        auto callPos = cCode.indexOf("println(42);");
        assert(macroPos != -1 && callPos != -1 && macroPos < callPos,
            "Overload macro should be hoisted before call site");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } def main() { mut val cat = new Cat(health: 100); cat.health = 90; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Mutable model and member assignment test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have mutable struct (no const)");
        assert(!cCode.canFind("const Cat cat"), "Should not have const for mut val");
        assert(cCode.canFind("cat.health = 90;"), "Should have member assignment");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } def main() { val ptr: i64 = 123; mut val n: ref Cat = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deref on long test:");
        writeln(cCode);

        assert(cCode.canFind("Cat* n = (Cat*)ptr;"), "Should cast long to pointer type when deref in declaration");
    }

    {
        auto tokens = lex("model SomeModel { value: i32, def some_function() { println \"Hello from model method\"; } } def main() { mut val obj: SomeModel = SomeModel.create(); obj.some_function(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model with function test:");
        writeln(cCode);

        assert(cCode.canFind("struct SomeModel"), "Should generate struct for model");
        assert(cCode.canFind("void SomeModel_some_function("), "Should generate function declaration for model method");
        assert(cCode.canFind("obj__some_function();"), "Should generate function call in main");
    }

    {
        auto tokens = lex(
            "def test_func(grid: i32[height][width], width: i32, height: i32) { } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable-length array parameter reordering test:");
        writeln(cCode);

        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width]);"),
            "Forward declaration should have dimension parameters before array parameter");

        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width])"),
            "Function definition should have dimension parameters before array parameter");
    }

    {
        auto tokens = lex(
            "model String { data: ref char, len: usize } " ~
                "def str_cmp(a: String, b: String): i32 { " ~
                "    mut val len: usize = 0; " ~
                "    if a.len < b.len { len = a.len; } else { len = b.len; } " ~
                "    for mut val i = 0; i < len; i++ { " ~
                "        if a.data[i] < b.data[i] { return -1; } " ~
                "    } " ~
                "    return 0; " ~
                "} " ~
                "def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function parameter and variable scope test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t str_cmp(String a, String b)"),
            "Should have function declaration with parameters");

        assert(cCode.canFind("uintptr_t len = 0;") || cCode.canFind("uintptr_t len=0;"),
            "Should have len variable declaration");

        assert((cCode.canFind("if ((a.len<b.len)") || cCode.canFind("if ((a.len < b.len)") ||
                cCode.canFind("if (a.len < b.len")),
            "Should use function parameter 'a' in if condition");

        assert((cCode.canFind("i < len") || cCode.canFind("i<len")),
            "Should use declared variable 'len' in for loop condition");

        assert((cCode.canFind("a.data[i]") || cCode.canFind("a.data[ i ]")),
            "Should use function parameter 'a' in for loop body");
    }

    {
        auto tokens = lex("def main() { put \"hello\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int main(int argc, char** argv)"));
        assert(cCode.canFind("printf(\"hello\")"));
    }

    {
        auto tokens = lex("def foo { put \"hello\"; } def main() { foo(); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("foo()"));
    }

    {
        auto tokens = lex("def main() { foo(1, 2); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("foo(1, 2)"));
    }

    {
        auto tokens = lex("def main() { loop { break; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);
        assert(cCode.canFind("while (1) {"));
        assert(cCode.canFind("break;"));
    }

    {
        auto tokens = lex("def main() { if (x > 5) { put \"greater\"; } }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);

        assert(cCode.canFind("(x>5 )"));
        assert(cCode.canFind(`printf("greater");`));
    }

    {
        auto tokens = lex("def main() { val x = 5 + 3; val y = x - 2; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("const int x = (5+3)"));
        assert(cCode.canFind("const int y = (x-2)"));
    }

    {
        auto tokens = lex(
            "def foo { put \"in foo\"; } def main() { foo(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);
        assert(cCode.canFind("void foo()"));
        assert(cCode.canFind(`printf("in foo");`));
        assert(cCode.canFind("foo();"));
    }

    {
        auto tokens = lex(
            "def add(a: i32, b: i32): i32 { return a + b; } def main() { val x: i32 = add(1, 2); }");
        auto ast = parse(tokens);

        auto cCode = generateC(ast);

        writeln(cCode);
        assert(cCode.canFind("int32_t add(int32_t a, int32_t b)"));
        assert(cCode.canFind("return (a+b);"));
        assert(cCode.canFind("const int32_t x = add(1, 2);"));
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex("def main() { y = y + 1; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Undeclared variable: y"));
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught undeclared variable error");
        }
    }

    {
        auto tokens = lex("def main() { put \"start\"; loop { put \"in loop\"; break; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Loop test output:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Loop should start with while (1) {");
        assert(cCode.canFind("printf(\"in loop\");"), "Loop should contain println");
        assert(cCode.canFind("break;"), "Loop should contain break");

        import std.algorithm : count;
        import std.string : indexOf;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced in loop code");

        auto loopStart = cCode.indexOf("while (1)");
        auto returnPos = cCode.indexOf("return 0;");
        assert(loopStart < returnPos, "return should come after loop");
    }

    {
        auto tokens = lex("def main() { mut val x = 5; x = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable reassignment test:");
        writeln(cCode);

        assert(cCode.canFind("int x = 5;"), "Should declare x");
        assert(cCode.canFind("x = 10;"), "Should reassign x");
    }

    {
        auto tokens = lex(
            "def testfunc() { mut val x = 0; loop { put \"test\"; x = x + 1; if x == 5 { break; } } } def main() { testfunc(); }"
        );
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Complex loop test:");
        writeln(cCode);

        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("printf(\"test\");"), "Should have put in loop");
        assert(cCode.canFind("x = (x+1);"), "Should have assignment in loop");
        assert(cCode.canFind("if ((x==5))"), "Should have if statement");

        import std.algorithm : count;

        auto openBraces = cCode.count('{');
        auto closeBraces = cCode.count('}');
        assert(openBraces == closeBraces, "Braces should be balanced");
    }

    {
        auto tokens = lex(
            "def greet(name: ref char, t: i32) { put \"hello\"; } def main() { greet(\"world\", 1); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Function call with string literal test:");
        writeln(cCode);

        assert(cCode.canFind("void greet(char* name, int32_t t)"), "Should declare greet function");
        assert(cCode.canFind("greet(\"world\", 1);"), "String literal should have quotes in function call");
        assert(!cCode.canFind("greet(world, 1);"), "String literal should not lose quotes");
    }

    {
        auto tokens = lex("// This is a comment\ndef main() { put \"test\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Comment filtering test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"test\");"), "Should have put statement");
        assert(!cCode.canFind("//"), "Comments should be filtered out");
        assert(!cCode.canFind("This is a comment"), "Comment text should not appear in output");
    }

    {
        auto tokens = lex("def main() { raw { printf(\"raw C\"); } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Raw C block test (.axec):");
        writeln(cCode);

        assert(cCode.canFind("printf(\"raw C\");"), "Should have raw C code");
        assert(!cCode.canFind("raw {"), "Raw keyword should not appear in output");
    }

    {
        auto tokens = lex("def main() { put \"before\"; raw { int x = 5; } put \"after\"; }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Mixed raw C and Axe code test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"before\");"), "Should have first put");
        assert(cCode.canFind("int x = 5;"), "Should have raw C code");
        assert(cCode.canFind("printf(\"after\");"), "Should have second put");
    }

    {
        import std.exception : assertThrown;

        auto tokens = lex("def main() { raw { test(); } }");

        writeln("Raw C block rejection test (.axe):");
        assertThrown(parse(tokens, false), "Should reject raw blocks in .axe files");
        writeln("Correctly rejected raw block in .axe file");
    }

    {
        auto tokens = lex("model Cat { name: ref char, age: i32 } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model definition test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat"), "Should have struct definition");
        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int32_t age;"), "Should have age field");
        assert(cCode.canFind("typedef struct Cat Cat;"), "Should have Cat typedef");
    }

    {
        auto tokens = lex(
            "model Cat { name: ref char, health: i32 } " ~
                "def main() { val cat = new Cat(name: \"Garfield\", health: 100); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model instantiation test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct Cat"), "Should have struct definition");
        assert(cCode.canFind("const Cat cat = {"), "Should have const struct initialization");
        assert(cCode.canFind(".name = \"Garfield\""), "Should initialize name field");
        assert(cCode.canFind(".health = 100"), "Should initialize health field");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } def main() { mut val cat = new Cat(health: 100); cat.health = 90; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Mutable model and member assignment test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have mutable struct (no const)");
        assert(!cCode.canFind("const Cat cat"), "Should not have const for mut val");
        assert(cCode.canFind("cat.health = 90;"), "Should have member assignment");
    }

    {
        auto tokens = lex(
            "model Cat { health: i32 } def main() { mut val cat = new Cat(health: 100); put cat.health; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Member access in put test:");
        writeln(cCode);

        assert(cCode.canFind("Cat cat = {"), "Should have struct initialization");
        assert(cCode.canFind("printf(\"%d\", cat.health);"), "Should print member access");
    }

    {
        auto tokens = lex("model Person { name: ref char, age: i32, height: i32 } def main()"
                ~ " { val p = new Person(name: \"Alice\", age: 30, height: 170); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multi-field model test:");
        writeln(cCode);

        assert(cCode.canFind("char* name;"), "Should have name field");
        assert(cCode.canFind("int32_t age;"), "Should have age field");
        assert(cCode.canFind("int32_t height;"), "Should have height field");
        assert(cCode.canFind(".name = \"Alice\""), "Should initialize name");
        assert(cCode.canFind(".age = 30"), "Should initialize age");
        assert(cCode.canFind(".height = 170"), "Should initialize height");
    }

    {
        bool caught = false;
        try
        {
            auto tokens = lex(
                "model Cat { health: i32 } def main() { val cat = new Cat(health: 100); cat.health = 90; }");
            auto ast = parse(tokens);
            generateC(ast);
        }
        catch (Exception e)
        {
            writeln("ERROR: ", e.msg);
            assert(e.msg.canFind("Cannot assign to member") || e.msg.canFind("immutable"),
                "Should prevent assignment to immutable struct member");
            caught = true;
        }
        if (!caught)
        {
            assert(0, "Should have caught immutable member assignment error");
        }
    }

    {
        auto tokens = lex(
            "model Point { x: i32, y: i32 } model Line { start: ref Point, end: ref Point } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested model types test:");
        writeln(cCode);

        assert(cCode.canFind("struct Point;"), "Should define Point struct");
        assert(cCode.canFind("typedef struct Line Line;"), "Should define Line struct");
        assert(cCode.canFind("Point* start;"), "Should have Point* field in Line");
        assert(cCode.canFind("Point* end;"), "Should have Point* field in Line");
    }

    {
        auto tokens = lex("def main() { val x: i32 = 1; switch x { case 1 { put \"one\"; } " ~
                "case 2 { put \"two\"; } default { put \"other\"; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Switch/case statement test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t x = 1;"), "Should declare x with type annotation");
        assert(cCode.canFind("switch (x) {"), "Should have switch statement");
        assert(cCode.canFind("case 1:"), "Should have case 1");
        assert(cCode.canFind("printf(\"one\");"), "Should have println in case 1");
        assert(cCode.canFind("case 2:"), "Should have case 2");
        assert(cCode.canFind("printf(\"two\");"), "Should have println in case 2");
        assert(cCode.canFind("default:"), "Should have default case");
        assert(cCode.canFind("printf(\"other\");"), "Should have println in default");
        assert(cCode.canFind("break;"), "Should have break statements");
    }

    {
        auto tokens = lex("def main() { val x: ref char = \"hello\"; mut val y: i32 = 42; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Type annotation test:");
        writeln(cCode);

        assert(cCode.canFind("const char x[6];"), "Should convert char* with string literal to char[] with exact size");
        assert(cCode.canFind("strcpy(x, \"hello\");"), "Should use strcpy for string literal initialization");
        assert(cCode.canFind("int32_t y = 42;"), "Should use int type annotation for mutable");
        assert(!cCode.canFind("const int y"), "Mutable variable should not be const");
    }

    {
        auto tokens = lex("def main() { val a: i32 = 5; val b: i32 = 10; val c: i32 = a + b; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Multiple type annotations test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t a = 5;"), "Should declare a with int type");
        assert(cCode.canFind("const int32_t b = 10;"), "Should declare b with int type");
        assert(cCode.canFind("const int32_t c = (a+b);"), "Should declare c with int type");
    }

    {
        auto tokens = lex("def main() { mut val x: i32 = 0; x++; x--; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment/decrement operators test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 0;"), "Should declare mutable x");
        assert(cCode.canFind("x++;"), "Should have increment operator");
        assert(cCode.canFind("x--;"), "Should have decrement operator");
    }

    {
        auto tokens = lex(
            "def main() { mut val counter: i32 = 0; loop { counter++; if counter == 5 { break; } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment in loop test (if without parens):");
        writeln(cCode);

        assert(cCode.canFind("int32_t counter = 0;"), "Should declare counter");
        assert(cCode.canFind("while (1) {"), "Should have loop");
        assert(cCode.canFind("counter++;"), "Should increment in loop");
        assert(cCode.canFind("if ((counter==5))"), "Should have condition");
    }

    {
        auto tokens = lex("def main() { val x: i32 = 10; val y: ref i32 = ref_of(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Reference type test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 10;"), "Should have x declaration");
        assert(cCode.canFind("int32_t* y = &x;"), "Should have y as pointer with address-of");
    }

    {
        auto tokens = lex("def main() { val x: i32 = 10; val addr: i64 = addr_int(x); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("addr_int test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t x = 10;"), "Should have x declaration");
        assert(cCode.canFind("int64_t addr = (int64_t)&x;"), "Should convert address to long");
    }

    {
        auto tokens = lex(
            "enum State { RUNNING, STOPPED } def main() { val s: State = State.RUNNING; put s; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Enum test:");
        writeln(cCode);

        assert(cCode.canFind("typedef enum {"), "Should have typedef enum declaration");
        assert(cCode.canFind("} State;"), "Should have State typedef");
        assert(cCode.canFind("RUNNING"), "Should have enum value RUNNING");
        assert(cCode.canFind("STOPPED"), "Should have enum value STOPPED");
        assert(cCode.canFind("State s = State_RUNNING;"), "Should use enum value without prefix");
    }

    {
        auto tokens = lex("def main() { if 5 mod 3 == 2 { put \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Modulo operator test:");
        writeln(cCode);

        assert(cCode.canFind("5%3"), "Should translate 'mod' to '%'");
        assert(!cCode.canFind("mod"), "Should not have 'mod' keyword in output");
    }

    {
        auto tokens = lex("def main() { if 1 == 1 and 2 == 2 { put \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Logical AND operator test:");
        writeln(cCode);

        assert(cCode.canFind("&&"), "Should translate 'and' to '&&'");
    }

    {
        auto tokens = lex("val msg: rchar = \"hello\"; def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Top-level char* global initialization test:");
        writeln(cCode);

        assert(cCode.canFind("const char* msg = \"hello\";"),
            "Top-level char* should use direct string literal initializer");
        assert(!cCode.canFind("const char msg["),
            "Top-level char* should not be converted to char[]");
        assert(!cCode.canFind("strcpy(msg, \"hello\""),
            "Top-level char* should not use strcpy for initialization");
    }

    {
        auto tokens = lex("def main() { if 1 mod 3 == 0 and 2 mod 5 == 0 { put \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Complex condition with mod and and test:");
        writeln(cCode);

        assert(cCode.canFind("1%3"), "Should translate first 'mod' to '%'");
        assert(cCode.canFind("2%5"), "Should translate second 'mod' to '%'");
        assert(cCode.canFind("&&"), "Should translate 'and' to '&&'");
        assert(!cCode.canFind("mod"), "Should not have 'mod' keyword in output");
        assert(cCode.canFind("1%3==0") || cCode.canFind("(1 % 3 == 0)") ||
                cCode.canFind("(1%3)==0"), "Should have proper first comparison");
        assert(cCode.canFind("2%5==0") || cCode.canFind("(2 % 5 == 0)") ||
                cCode.canFind("(2%5)==0"), "Should have proper second comparison");
    }

    {
        auto tokens = lex(
            "def get_value(x: i32): i32 { return x; } def wrapper(y: i32): i32 { return get_value(y); } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t get_value(int32_t x)"), "Should have get_value function");
        assert(cCode.canFind("int32_t wrapper(int32_t y)"), "Should have wrapper function");
        assert(cCode.canFind("return get_value(y)"), "Should have nested function call");
    }

    {
        auto tokens = lex(
            "def destroy(ptr: i64) { } def main() { val x: i32 = 5; destroy(thing_of(x)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested function call in main test:");
        writeln(cCode);

        assert(cCode.canFind("void destroy(int64_t ptr)"), "Should have destroy function");
        assert(cCode.canFind("destroy(thing_of(x))"), "Should have nested function call with ref_of(x)");
    }

    {
        auto tokens = lex(
            "def inner(a: i32): i32 { return a; } def middle(b: i32): i32 { return inner(b); } def outer(c: i32): i32 { return middle(inner(c)); } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deeply nested function call test:");
        writeln(cCode);

        assert(cCode.canFind("return middle(inner(c))"), "Should handle deeply nested calls: middle(inner(c))");
    }

    // Macro system tests
    {
        auto tokens = lex(
            "macro add(a: i32, b: i32) { raw { a + b } } def main() { val x: i32 = add(5, 3); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Basic macro test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t x = (5+3);") || cCode.canFind(
                "const int32_t x = ( 5 + 3 );"),
            "Should expand macro add(5, 3) to (5+3)");
        assert(!cCode.canFind("add(5, 3)"), "Should not have macro call in output");
    }

    {
        auto tokens = lex(
            "macro square(x: i32) { raw { x * x } } def main() { val result: i32 = square(4); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with repeated parameter test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t result = ( 4 * 4 );") || cCode.canFind(
                "const int32_t result = (4 * 4);"),
            "Should expand square(4) to (4*4)");
    }

    {
        auto tokens = lex(
            "macro max(a: i32, b: i32) { raw { (a > b) ? a : b } } def main() { val m: i32 = max(10, 20); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with ternary operator test:");
        writeln(cCode);

        assert(cCode.canFind("(10>20)?10:20") || cCode.canFind("(10 > 20) ? 10 : 20"),
            "Should expand max(10, 20) to ternary expression");
    }

    {
        auto tokens = lex(
            "macro add(a: i32, b: i32) { raw { a + b } } def calc(x: i32, y: i32): i32 { return add(x, y); } def main() { }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in function body test:");
        writeln(cCode);

        assert(cCode.canFind("return ( x + y );") || cCode.canFind("return (x + y);"),
            "Should expand macro in function return statement");
    }

    {
        auto tokens = lex(
            "macro inc(x: i32) { raw { x + 1 } } def main() { val a: i32 = 5; val b: i32 = inc(a); }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro with variable argument test:");
        writeln(cCode);

        assert(cCode.canFind("const int32_t b = ( a + 1 );") || cCode.canFind(
                "const int32_t b = (a + 1);"),
            "Should expand inc(a) with variable argument");
    }

    {
        auto tokens = lex(
            "macro triple(x: i32) { raw { x * 3 } } def main() { if triple(2) == 6 { println \"yes\"; } }");
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);

        writeln("Macro in condition test:");
        writeln(cCode);

        assert(cCode.canFind("if") && (cCode.canFind("( 2 * 3 )==6") || cCode.canFind(
                "(2 * 3) == 6")),
            "Should expand macro in if condition");
    }

    {
        auto tokens = lex(
            "def main() { mut val ptr: ref i32 = NULL; val value: i32 = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref test:");
        writeln(cCode);

        assert(cCode.canFind("*ptr"), "Should replace deref(ptr) with *ptr");
        assert(cCode.canFind("int32_t* ptr = NULL;"), "Should declare pointer variable");
        assert(cCode.canFind("const int32_t value = (*ptr);"), "Should assign dereferenced value");
    }

    {
        auto tokens = lex(
            "def main() { mut val ptr: ref ref i32 = NULL; val value: i32 = deref(deref(ptr)); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Nested deref test:");
        writeln(cCode);

        assert(cCode.canFind("*(*ptr)"), "Should handle nested deref(deref(ptr)) as **ptr");
        assert(cCode.canFind("int32_t** ptr = NULL;"), "Should declare double pointer");
        assert(cCode.canFind("const int32_t value = (*(*ptr));"), "Should assign double dereferenced value");
    }

    {
        auto tokens = lex(
            "def main() { mut val ptr: ref i32 = NULL; if deref(ptr) == 5 { println \"equal\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref in condition test:");
        writeln(cCode);

        assert(cCode.canFind("if (((*ptr)==5))"), "Should handle deref in if condition");
    }

    {
        auto tokens = lex("def main() { mut val ptr: ref i32 = NULL; deref(ptr) = 10; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("deref assignment test:");
        writeln(cCode);

        assert(cCode.canFind("(*ptr) = 10;"), "Should handle deref on left side of assignment");
    }

    {
        auto tokens = lex(
            "model Test { field: i32 } def main() { mut val obj: Test = Test.create(); obj.field = 5; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Non-pointer member access test:");
        writeln(cCode);

        assert(cCode.canFind("obj.field = 5;"), "Should use . for non-pointer object");
    }

    {
        auto tokens = lex(
            "model Test { field: i32 } def main() { mut val ptr: ref Test = cast[ref Test](nil); ptr.field = 5; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Pointer variable member access test:");
        writeln(cCode);

        assert(cCode.canFind("ptr->field = 5;"), "Should use -> for pointer variable");
    }

    {
        auto tokens = lex("model Node { value: i32, next: Node } def main() { val head: Node = Node.create(); if head.next.value == 5 { println \"yes\"; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Pointer field access in if condition test:");
        writeln(cCode);

        assert(cCode.canFind("if ((head.next->value==5))"), "Should use -> for pointer field access in if condition");
    }

    {
        auto tokens = lex(
            "model Test { value: i32 } def main() { val ptr: i64 = 123; mut val n: ref Test = deref(ptr); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Deref on long test:");
        writeln(cCode);

        assert(cCode.canFind("Test* n = (Test*)ptr;"), "Should cast long to pointer type when deref in declaration");
    }

    {
        auto tokens = lex("model SomeModel { value: i32, def some_function() { println \"Hello from model method\"; } } def main() { mut val obj: SomeModel = nil; obj.some_function(); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Model with function test:");
        writeln(cCode);

        assert(cCode.canFind("struct SomeModel"), "Should generate struct for model");
        assert(cCode.canFind("void SomeModel_some_function("), "Should generate function declaration for model method");
        assert(cCode.canFind("obj__some_function();"), "Should generate function call in main");
    }

    {
        auto tokens = lex(
            "def test_func(grid: i32[height][width], width: i32, height: i32) { } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Variable-length array parameter reordering test:");
        writeln(cCode);

        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width]);"),
            "Forward declaration should have dimension parameters before array parameter");

        assert(cCode.canFind("void test_func(int32_t width, int32_t height, int32_t grid[height][width])"),
            "Function definition should have dimension parameters before array parameter");
    }

    {
        auto tokens = lex("model Test { data: i32[10][20]; } def main() { }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("2D array test:");
        writeln(cCode);

        assert(cCode.canFind("int32_t data[10][20];"), "2D array should be rendered as int32_t data[10][20];");
    }

    {
        auto tokens = lex(
            "model Node { value: i32; next: ref Node; } " ~
                "def main() { mut val head: ref Node = nil; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Self-referential model hoist test:");
        writeln(cCode);

        assert(cCode.canFind("struct Node;"), "Model should emit forward declaration before typedef");
        assert(cCode.canFind("typedef struct Node"), "Model should emit typedef for struct Node");
        assert(cCode.canFind("struct Node* next;"),
            "Self-referential fields should use 'struct Node*' to avoid undeclared identifier errors");
    }

    {
        auto tokens = lex(
            "def use_grid(grid: ref i32[], width: i32) { } " ~
                "def main() { use_grid(nil, 0); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Ref array parameter test:");
        writeln(cCode);

        assert(cCode.canFind("void use_grid(int32_t* grid, int32_t width);"),
            "ref i32[] parameters should compile to single pointer");
        assert(cCode.canFind("void use_grid(int32_t* grid, int32_t width)"),
            "Function definition should also use single pointer");
    }

    {
        auto tokens = lex(`
        model Counter {
            value: i32,
        }

        def main() {
            mut val counter: Counter = new Counter(value: 0);
            counter.value = 5;
            counter.value++;
            println counter.value;
            counter.value--;
            println counter.value;
        }`);
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Increment/decrement on struct member test:");
        writeln(cCode);

        assert(cCode.canFind("counter.value++;"), "Should increment struct member correctly");
        assert(cCode.canFind("counter.value--;"), "Should decrement struct member correctly");
    }

    {
        auto tokens = lex(`
        model error {
            msg: string;

            def create(msg: rchar): error {
                return new error(msg: string.create(msg));
            }

            def print_self(err: error) {
                print_str(err.msg);
            }
        }

        def panic(err: error) {
            print "\nRuntimeError: ";
            error.print_self(err);
            
            raw {
                exit(1);
            }
        }

        def __test_error(): error {
            return new error(msg: string.create("Some bad thing happened"));
        }

        test {
            println_str(__test_error().msg);
            panic(error.create("Uh oh"));
        }`);
        auto ast = parse(tokens, true);
        auto cCode = generateC(ast);
        writeln("Model method calls test:");
        writeln(cCode);
        assert(cCode.canFind("void error_print_self(std_errors_error err)"),
            "Should generate method function with correct signature");
    }

    {
        auto tokens = lex("use hi (hello); test {}");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Use statement at end of program test:");
        writeln(cCode);

        assert(!cCode.canFind("void use("), "Should not treat Use as a function");
        assert(!cCode.canFind("struct use"), "Should not treat Use as a model");
    }

    {
        auto tokens = lex("def main() { for mut i = 0 to 10 { println i; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For-to syntax test:");
        writeln(cCode);

        assert(cCode.canFind("for (int i = 0; (i<10); i++)"),
            "Should desugar 'for mut i = 0 to 10' to C for loop");
    }

    {
        auto tokens = lex("def main() { for mut i = 5 to 15 { println i; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For-to syntax with non-zero start test:");
        writeln(cCode);

        assert(cCode.canFind("for (int i = 5; (i<15); i++)"),
            "Should handle non-zero start value in for-to loop");
    }

    {
        auto tokens = lex(
            "def main() { mut val sum: i32 = 0; parallel for mut i = 0 to 100 { sum = sum + i; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel for without reduction test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel for"),
            "Should generate OpenMP pragma for parallel for");
        assert(cCode.canFind("for (int i = 0; (i<100); i++)"),
            "Should generate correct for loop in parallel for");
    }

    {
        auto tokens = lex(
            "def main() { mut val sum: i32 = 0; parallel for mut i = 0 to 100 reduce(+:sum) { sum = sum + i; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel for with reduction clause test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel for reduction(+:sum)"),
            "Should generate OpenMP pragma with reduction clause");
        assert(cCode.canFind("for (int i = 0; (i<100); i++)"),
            "Should generate correct for loop in parallel for with reduction");
    }

    {
        auto tokens = lex("def main() { mut val sum: i32 = 0; mut val prod: i32 = 1; parallel for mut i = 1 to 10 reduce(+:sum, *:prod) { sum = sum + i; prod = prod * i; } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel for with multiple reduction clauses test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel for reduction(+:sum, *:prod)"),
            "Should generate OpenMP pragma with multiple reduction clauses");
    }

    {
        auto tokens = lex("model StringList { len: i32, data: string } def get_list(): ref StringList { } def main() { for item in get_list() { } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For-in with function call test:");
        writeln(cCode);

        assert(cCode.canFind("stdlib_os_get_list()->len") || cCode.canFind("get_list()->len"),
            "Should handle function call in for-in collection");
        assert(cCode.canFind("for (int32_t _i_item = 0;"),
            "Should generate index variable for for-in loop");
    }

    {
        auto tokens = lex(
            "model StringList { len: i32, data: string } def main() { val items: StringList = StringList.create(); for item in items { } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("For-in with simple identifier test:");
        writeln(cCode);

        assert(cCode.canFind("items.len") || cCode.canFind("items->len"),
            "Should handle simple identifier in for-in collection");
        assert(cCode.canFind("for (int32_t _i_item = 0;"),
            "Should generate index variable for for-in loop");
    }

    {
        auto tokens = lex(
            "def task_a() { println \"A\"; } def task_b() { println \"B\"; } " ~
                "def main() { parallel { task_a(); task_b(); } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel block test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel"),
            "Should generate OpenMP parallel pragma");
        assert(cCode.canFind("task_a()"),
            "Should include task_a function call");
        assert(cCode.canFind("task_b()"),
            "Should include task_b function call");
    }

    {
        auto tokens = lex(
            "def some_task() { println \"hello\"; } " ~
                "def some_other_task() { println \"world\"; } " ~
                "def main() { parallel { single { some_task(); some_other_task(); } } }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel with single block test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel"),
            "Should generate OpenMP parallel pragma");
        assert(cCode.canFind("#pragma omp single"),
            "Should generate OpenMP single pragma");
        assert(cCode.canFind("some_task()"),
            "Should include some_task function call");
        assert(cCode.canFind("some_other_task()"),
            "Should include some_other_task function call");
    }

    {
        auto tokens = lex("def main() { put (\"Hello, world\"); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("String literal in parentheses format specifier test:");
        writeln(cCode);

        assert(cCode.canFind("printf(\"%s\", (\"Hello, world\"));"),
            "Should use %s format specifier for string literals even in parentheses, not %d");
        assert(!cCode.canFind("printf(\"%d\", (\"Hello, world\"));"),
            "Should NOT use %d format specifier for string literals in parentheses");
    }

    {
        auto tokens = lex(
            "opaque { MyType, AnotherType }; " ~
                "extern def my_func(x: i32): i32; " ~
                "extern def process(data: ref MyType): bool; " ~
                "def main() { val result: i32 = my_func(42); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Opaque types and extern functions test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct MyType MyType;"),
            "Should generate typedef for MyType");
        assert(cCode.canFind("typedef struct AnotherType AnotherType;"),
            "Should generate typedef for AnotherType");
        assert(cCode.canFind("my_func(42)"),
            "Should allow calling extern function my_func");
        assert(!cCode.canFind("extern int32_t my_func"),
            "Should NOT generate extern declaration (assumes it exists in C headers)");
    }

    {
        auto tokens = lex(
            "opaque { SomeStruct }; " ~
                "extern def get_value(ptr: usize): i32; " ~
                "def main() { " ~
                "    mut ptr: usize = 0; " ~
                "    unsafe { " ~
                "        mut x: i32 = ptr*.value; " ~
                "        ptr*.count = 42; " ~
                "    } " ~
                "}");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Unsafe block with *. pointer member access test:");
        writeln(cCode);

        assert(cCode.canFind("typedef struct SomeStruct SomeStruct;"),
            "Should generate typedef for opaque SomeStruct");
        assert(cCode.canFind("ptr -> value") || cCode.canFind("->value"),
            "Should convert *. to -> for pointer member access");
        assert(cCode.canFind("(ptr->count) = 42") || cCode.canFind("->count = 42"),
            "Should convert *. to -> for pointer member assignment");
        assert(!cCode.canFind("*."),
            "*. syntax should be converted to -> in generated C code");
    }

    {
        auto tokens = lex("def main() { val x: f64 = 2 . 0* 3 . 0; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Float literal spacing normalization (simple expression) test:");
        writeln(cCode);

        assert(!cCode.canFind("2 . 0"), "Float literal should not contain spaces around decimal point (2 . 0)");
        assert(!cCode.canFind("3 . 0"), "Float literal should not contain spaces around decimal point (3 . 0)");
        assert(cCode.canFind("2.0"), "Float literal 2.0 should be rendered without spaces around decimal point");
        assert(cCode.canFind("3.0"), "Float literal 3.0 should be rendered without spaces around decimal point");
    }

    {
        auto tokens = lex("def main() { mut val n: f64 = 1 . 0; mut val term: f64 = 1 . 0; term = ((term*(( 2 . 0* n + 1 . 0) *( 2 . 0* n + 1 . 0)))); }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Float literal spacing normalization (complex expression) test:");
        writeln(cCode);

        assert(!cCode.canFind("2 . 0"), "Complex expression should not contain spaced float literal 2 . 0");
        assert(!cCode.canFind("1 . 0"), "Complex expression should not contain spaced float literal 1 . 0");
        assert(cCode.canFind("2.0"), "Complex expression should contain normalized 2.0");
        assert(cCode.canFind("1.0"), "Complex expression should contain normalized 1.0");
    }

    {
        auto tokens = lex("def main() { put \"value is 2 . 0\"; }");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Float-like text inside string literal should be preserved test:");
        writeln(cCode);

        assert(cCode.canFind("value is 2 . 0"),
            "String literal contents 'value is 2 . 0' should be preserved without normalization");
        assert(!cCode.canFind("value is 2.0"),
            "Float normalization should not alter contents of string literals");
    }

    {
        auto tokens = lex("def main() { mut lst: list(i32); append(lst, 10); append(lst, 20);}");
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("list type test:");
        writeln(cCode);

        assert(cCode.canFind("__list_int32_t_t lst = __list_int32_t_init();"), "Should declare list(i32) as int32_t array");
    }

    {
        auto tokens = lex(`def main() {
            val x: rchar = "hello";
            val y = ($"Hello, {x} world");
        }`);
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("String interpolation test:");
        writeln(cCode);
        assert(cCode.canFind(`const char x[6];
strcpy(x, "hello");`),
            "Should create char array with correct size for interpolated string");
    }

    {
        auto tokens = lex(`
def worker(arena: ref Arena, value: i32): i32 {
    mut p: ref i32 = (ref i32)Arena.alloc(arena, sizeof(i32));
    deref(p) = value * value;
    return deref(p);
}

def main() {
    println "Running parallel computation...";

    parallel local(mut arena: Arena) {
        arena = Arena.create(1024);
        val tid: i32 = Parallel.thread_id();
        val result: i32 = worker(ref_of(arena), tid);
        println $"Thread {tid} computed {result}";
        Arena.destroy(ref_of(arena));
    }

    println "Done.";
}
`);
        auto ast = parse(tokens);
        auto cCode = generateC(ast);

        writeln("Parallel local with arena allocation test:");
        writeln(cCode);

        assert(cCode.canFind("#pragma omp parallel private(arena)"),
            "Should generate OpenMP parallel pragma for parallel local block");
        assert(cCode.canFind("Arena__destroy(&arena);"),
            "Should destroy Arena at end of parallel local block");
    }
}
