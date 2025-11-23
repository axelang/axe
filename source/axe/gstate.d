/** 
 * Axe Programming Language Compiler.
 * Author: Navid Momtahen (C) 2025
 * License: GPL-3.0
 * 
 * Handles the global state.
 */

module axe.gstate;

static class Logger
{
    static bool quietMode = false;
}

/** 
 * Global module prefix for .axec files being compiled directly.
 * Used to prefix function names in both imports and renderer.
 */
__gshared string g_currentModulePrefix = "";

/**
 * Global map of local function names to their prefixed versions.
 * Used by renderer to replace function names in raw C blocks.
 */
__gshared string[string] g_localFunctionMap;

/** 
 * Helper function for conditional debug output.
 *
 * Params:
 *   args = Arguments to be printed if not in quiet mode
 */
void debugWriteln(Args...)(Args args)
{
    debug
    {
        if (!Logger.quietMode)
        {
            import std.stdio : writeln;

            writeln(args);
        }
    }
}