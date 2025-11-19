module axe.gstate;

static class GlobalState
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
        if (!GlobalState.quietMode)
        {
            import std.stdio : writeln;

            writeln(args);
        }
    }
}