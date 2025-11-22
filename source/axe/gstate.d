/** 
 * Axe Programming Language Compiler.
 * Author: Navid Momtahen (C) 2025
 * License: GPL-3.0
 * 
 * Handles the global state for logging and debug output.
 */

module axe.gstate;

static class Logger
{
    static bool quietMode = false;
}

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