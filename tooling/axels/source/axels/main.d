module axels.main;

import std.stdio;
import std.json;
import std.string;
import std.conv;
import std.exception;
import std.process;
import std.file;
import std.algorithm;

struct LspRequest {
    string jsonrpc;
    string method;
    JSONValue id;
    JSONValue params;
}

struct Diagnostic {
    string message;
    string fileName;
    size_t line;  
    size_t column;
}

__gshared string[string] g_openDocs;
__gshared bool g_debugMode = false;

void debugLog(T...)(T args) {
    if (g_debugMode) {
        stderr.writeln("[DEBUG] ", args);
        stderr.flush();
    }
}

string uriToPath(string uri) {
    enum prefix = "file://";
    if (uri.startsWith(prefix)) {
        string path = uri[prefix.length .. $];
        version(Windows) {
            if (path.length > 0 && path[0] == '/') {
                path = path[1 .. $];
            }
        }
        return path;
    }
    return uri;
}

string wordChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

string extractWordAt(string text, size_t line0, size_t char0) {
    auto lines = text.splitLines();
    if (line0 >= lines.length) {
        return "";
    }
    auto line = lines[line0];
    if (char0 >= line.length) {
        if (line.length == 0) return "";
        char0 = cast(size_t)(line.length - 1);
    }

    size_t start = char0;
    while (start > 0 && wordChars.canFind(line[start - 1])) {
        --start;
    }
    size_t end = char0;
    while (end < line.length && wordChars.canFind(line[end])) {
        ++end;
    }
    return line[start .. end];
}

Diagnostic[] parseDiagnostics(string text) {
    Diagnostic[] result;
    foreach (line; text.splitLines()) {
        auto trimmed = line.strip();
        if (trimmed.length == 0) {
            continue;
        }

        auto first = trimmed.countUntil(':');
        if (first <= 0) {
            continue;
        }
        auto second = trimmed.countUntil(':', first + 1);
        if (second <= 0) {
            continue;
        }
        auto third = trimmed.countUntil(':', second + 1);
        if (third <= 0) {
            continue;
        }

        string fileName = trimmed[0 .. first];
        string lineStr  = trimmed[first + 1 .. second];
        string colStr   = trimmed[second + 1 .. third];
        string msg      = trimmed[third + 1 .. $].strip();

        size_t ln, col;
        try {
            ln  = to!size_t(lineStr.strip());
            col = to!size_t(colStr.strip());
        } catch (Exception) {
            continue;
        }

        Diagnostic d;
        d.fileName = fileName;
        d.line = ln;
        d.column = col;
        d.message = msg;
        result ~= d;
    }
    return result;
}

Diagnostic[] runCompilerOn(string uri, string text) {
    string path = uriToPath(uri);
    debugLog("Running compiler on: ", path);
    
    try {
        std.file.write(path, text);
    } catch (Exception e) {
        debugLog("Failed to write file: ", e.msg);
        return Diagnostic[].init;
    }

    Diagnostic[] diags;
    try {
        auto result = execute(["axc", path]);
        debugLog("Compiler output: ", result.output);
        diags ~= parseDiagnostics(result.output);
        debugLog("Parsed ", diags.length, " diagnostics");
    } catch (Exception e) {
        debugLog("Compiler execution failed: ", e.msg);
    }
    return diags;
}

void sendDiagnostics(string uri, Diagnostic[] diags) {
    debugLog("Sending ", diags.length, " diagnostics for ", uri);
    
    JSONValue root;
    root["jsonrpc"] = "2.0";
    root["method"]  = "textDocument/publishDiagnostics";

    JSONValue params;
    params["uri"] = uri;

    JSONValue[] arr;
    foreach (d; diags) {
        JSONValue jd;
        JSONValue rng;
        JSONValue sPos;
        JSONValue ePos;

        long l  = cast(long)(d.line > 0 ? d.line - 1 : 0);
        long ch = cast(long)(d.column > 0 ? d.column - 1 : 0);

        sPos["line"]      = l;
        sPos["character"] = ch;
        ePos["line"]      = l;
        ePos["character"] = ch + 1;

        rng["start"] = sPos;
        rng["end"]   = ePos;

        jd["range"]   = rng;
        jd["message"] = d.message;
        jd["severity"] = 1L;

        arr ~= jd;
    }

    params["diagnostics"] = JSONValue(arr);
    root["params"] = params;

    writeMessage(root.toString());
}

string readMessage() {
    size_t contentLength;

    while (true) {
        if (stdin.eof) {
            debugLog("stdin EOF reached");
            return null;
        }
        string line = stdin.readln();
        if (line is null) {
            debugLog("readln returned null");
            return null;
        }
        line = line.stripRight("\r\n");
        debugLog("Header line: '", line, "'");
        if (line.length == 0) {
            break;
        }
        auto lower = line.toLower();
        enum prefix = "content-length:";
        if (lower.startsWith(prefix)) {
            auto value = line[prefix.length .. $].strip();
            contentLength = to!size_t(value);
            debugLog("Content-Length: ", contentLength);
        }
    }

    if (contentLength == 0) {
        debugLog("No content length found");
        return null;
    }

    ubyte[] buf;
    buf.length = contentLength;
    size_t readBytes = 0;
    while (readBytes < contentLength) {
        auto chunk = stdin.rawRead(buf[readBytes .. $]);
        auto n = chunk.length;
        if (n == 0) break;
        readBytes += n;
    }

    string result = cast(string) buf[0 .. readBytes];
    debugLog("Received message: ", result);
    return result;
}

void writeMessage(string payload) {
    import std.stdio : stdout;
    
    auto bytes = cast(const(ubyte)[]) payload;
    
    string header = "Content-Length: " ~ to!string(bytes.length) ~ "\r\n\r\n";
    auto headerBytes = cast(const(ubyte)[]) header;
    
    debugLog("Writing header: ", header.strip());
    debugLog("Writing payload (", bytes.length, " bytes)");
    
    stdout.rawWrite(headerBytes);
    stdout.rawWrite(bytes);
    stdout.flush();
    
    debugLog("Write completed and flushed");
}

LspRequest parseRequest(string body) {
    auto j = parseJSON(body);
    LspRequest req;
    if (j.type == JSONType.object) {
        auto obj = j.object;
        if ("jsonrpc" in obj) req.jsonrpc = obj["jsonrpc"].str;
        if ("method" in obj)  req.method  = obj["method"].str;
        if ("id" in obj)      req.id      = obj["id"];
        if ("params" in obj)  req.params  = obj["params"];
    }
    return req;
}

void sendResponse(JSONValue id, JSONValue result) {
    JSONValue root;
    root["jsonrpc"] = "2.0";
    root["id"]      = id;
    root["result"]  = result;
    
    // Convert to string with proper formatting
    string payload = root.toString();
    debugLog("Sending response with id=", id.toString());
    debugLog("Full response: ", payload);
    writeMessage(payload);
}

void sendError(JSONValue id, int code, string message) {
    JSONValue root;
    root["jsonrpc"] = "2.0";
    root["id"]      = id;

    JSONValue err;
    err["code"]    = code;
    err["message"] = message;
    root["error"]  = err;

    writeMessage(root.toString());
}

void handleInitialize(LspRequest req) {
    debugLog("Handling initialize request");
    
    try {
        // Build response manually to ensure correct JSON
        string response = `{"jsonrpc":"2.0","id":` ~ req.id.toString() ~ `,"result":{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"completionProvider":{"triggerCharacters":["."]}}}}`;
        
        debugLog("Sending initialize response");
        debugLog("Response: ", response);
        writeMessage(response);
        debugLog("Initialize response sent successfully");
        stderr.writeln("[INFO] Sent initialize response");
        stderr.flush();
    } catch (Exception e) {
        debugLog("Error in handleInitialize: ", e.msg);
        stderr.writeln("[ERROR] Failed to send initialize response: ", e.msg);
        stderr.flush();
    }
}

void handleInitialized(LspRequest req) {
    debugLog("Client initialized notification received");
    
    // Log that we're ready to receive requests
    stderr.writeln("[INFO] LSP server is now ready to handle requests");
    stderr.flush();
}

void handleShutdown(LspRequest req) {
    debugLog("Shutdown request received");
    JSONValue nilResult;
    sendResponse(req.id, nilResult);
}

void handleExit(LspRequest req) {
    debugLog("Exit notification received");
    import core.stdc.stdlib : exit;
    exit(0);
}

void handleDidOpen(LspRequest req) {
    debugLog("Handling didOpen");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        debugLog("didOpen: params not an object");
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj)) {
        debugLog("didOpen: no textDocument in params");
        return;
    }

    auto td = pObj["textDocument"];
    if (td.type != JSONType.object) {
        debugLog("didOpen: textDocument not an object");
        return;
    }

    auto tdObj = td.object;
    if (!("uri" in tdObj) || !("text" in tdObj)) {
        debugLog("didOpen: missing uri or text");
        return;
    }

    string uri  = tdObj["uri"].str;
    string text = tdObj["text"].str;

    debugLog("didOpen: uri=", uri, ", text length=", text.length);
    g_openDocs[uri] = text;

    auto diags = runCompilerOn(uri, text);
    sendDiagnostics(uri, diags);
}

void handleDidChange(LspRequest req) {
    debugLog("Handling didChange");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        debugLog("didChange: params not an object");
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj)) {
        debugLog("didChange: no textDocument in params");
        return;
    }

    auto td = pObj["textDocument"];
    if (td.type != JSONType.object) {
        debugLog("didChange: textDocument not an object");
        return;
    }

    auto tdObj = td.object;
    if (!("uri" in tdObj)) {
        debugLog("didChange: no uri in textDocument");
        return;
    }

    string uri = tdObj["uri"].str;

    if (!("contentChanges" in pObj)) {
        debugLog("didChange: no contentChanges in params");
        return;
    }

    auto changes = pObj["contentChanges"];
    if (changes.type != JSONType.array || changes.array.length == 0) {
        debugLog("didChange: contentChanges not an array or empty");
        return;
    }

    // For textDocumentSync = 1 (Full), the last change contains the full text
    auto change = changes.array[$ - 1];
    if (change.type != JSONType.object) {
        debugLog("didChange: change not an object");
        return;
    }

    auto chObj = change.object;
    if (!("text" in chObj)) {
        debugLog("didChange: no text in change");
        return;
    }

    string text = chObj["text"].str;
    debugLog("didChange: uri=", uri, ", new text length=", text.length);
    g_openDocs[uri] = text;

    // Run diagnostics on the updated text
    auto diags = runCompilerOn(uri, text);
    sendDiagnostics(uri, diags);
}

void handleDidSave(LspRequest req) {
    debugLog("Handling didSave");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj)) {
        return;
    }

    auto td = pObj["textDocument"];
    if (td.type != JSONType.object) {
        return;
    }

    auto tdObj = td.object;
    if (!("uri" in tdObj)) {
        return;
    }

    string uri = tdObj["uri"].str;
    debugLog("didSave: uri=", uri);
    
    auto it = uri in g_openDocs;
    if (it !is null) {
        auto diags = runCompilerOn(uri, *it);
        sendDiagnostics(uri, diags);
    }
}

void handleDidClose(LspRequest req) {
    debugLog("Handling didClose");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj)) {
        return;
    }

    auto td = pObj["textDocument"];
    if (td.type != JSONType.object) {
        return;
    }

    auto tdObj = td.object;
    if (!("uri" in tdObj)) {
        return;
    }

    string uri = tdObj["uri"].str;
    debugLog("didClose: uri=", uri);

    auto it = uri in g_openDocs;
    if (it !is null) {
        g_openDocs.remove(uri);
    }

    sendDiagnostics(uri, Diagnostic[].init);
}

void handleHover(LspRequest req) {
    debugLog("Handling hover request");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        debugLog("hover: params not an object");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj) || !("position" in pObj)) {
        debugLog("hover: missing textDocument or position");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    auto td = pObj["textDocument"].object;
    string uri = td["uri"].str;

    auto pos = pObj["position"].object;
    size_t line0   = cast(size_t) pos["line"].integer;
    size_t char0   = cast(size_t) pos["character"].integer;

    debugLog("hover: uri=", uri, ", line=", line0, ", char=", char0);

    auto it = uri in g_openDocs;
    if (it is null) {
        debugLog("hover: document not found in g_openDocs");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    string text = *it;
    string word = extractWordAt(text, line0, char0);
    debugLog("hover: extracted word='", word, "'");
    
    if (word.length == 0) {
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    JSONValue contents;
    contents["kind"]  = "plaintext";
    contents["value"] = "Symbol: " ~ word ~ "\n\n(Hover information for Axe language)";

    JSONValue result;
    result["contents"] = contents;

    sendResponse(req.id, result);
    debugLog("hover: response sent");
}

void handleCompletion(LspRequest req) {
    debugLog("Handling completion request");
    
    auto params = req.params;
    if (params.type != JSONType.object) {
        debugLog("completion: params not an object");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    auto pObj = params.object;
    if (!("textDocument" in pObj) || !("position" in pObj)) {
        debugLog("completion: missing textDocument or position");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    auto td = pObj["textDocument"].object;
    string uri = td["uri"].str;

    auto pos = pObj["position"].object;
    size_t line0   = cast(size_t) pos["line"].integer;
    size_t char0   = cast(size_t) pos["character"].integer;

    debugLog("completion: uri=", uri, ", line=", line0, ", char=", char0);

    auto it = uri in g_openDocs;
    if (it is null) {
        debugLog("completion: document not found");
        JSONValue empty;
        sendResponse(req.id, empty);
        return;
    }

    string text = *it;
    string prefix = extractWordAt(text, line0, char0);
    debugLog("completion: prefix='", prefix, "'");

    string[] keywords = [
        "def", "pub", "mut", "val", "loop", "for", "in", "if", "else",
        "elif", "switch", "case", "break", "continue", "model", "enum",
        "use", "test", "assert", "unsafe", "parallel", "single", "platform"
    ];

    JSONValue[] items;
    bool[string] seen;

    foreach (k; keywords) {
        if (prefix.length == 0 || k.startsWith(prefix)) {
            if (k !in seen) {
                JSONValue item;
                item["label"] = k;
                item["kind"]  = 14L; // Keyword
                item["detail"] = "keyword";
                items ~= item;
                seen[k] = true;
            }
        }
    }

    foreach (ln; text.splitLines()) {
        string current;
        foreach (ch; ln) {
            if (wordChars.canFind(ch)) {
                current ~= ch;
            } else {
                if (current.length > 0 && (prefix.length == 0 || current.startsWith(prefix))) {
                    if (current !in seen) {
                        JSONValue item;
                        item["label"] = current;
                        item["kind"]  = 6L; // Variable
                        items ~= item;
                        seen[current] = true;
                    }
                }
                current = "";
            }
        }
        if (current.length > 0 && (prefix.length == 0 || current.startsWith(prefix))) {
            if (current !in seen) {
                JSONValue item;
                item["label"] = current;
                item["kind"]  = 6L;
                items ~= item;
                seen[current] = true;
            }
        }
    }

    debugLog("completion: returning ", items.length, " items");

    JSONValue result;
    result["isIncomplete"] = false;
    result["items"]        = JSONValue(items);

    sendResponse(req.id, result);
}

void dispatch(LspRequest req) {
    debugLog("Dispatching method: ", req.method);
    
    switch (req.method) {
    case "initialize":
        handleInitialize(req);
        break;
    case "initialized":
        handleInitialized(req);
        break;
    case "shutdown":
        handleShutdown(req);
        break;
    case "exit":
        handleExit(req);
        break;
    case "textDocument/didOpen":
        handleDidOpen(req);
        break;
    case "textDocument/didChange":
        handleDidChange(req);
        break;
    case "textDocument/didSave":
        handleDidSave(req);
        break;
    case "textDocument/didClose":
        handleDidClose(req);
        break;
    case "textDocument/hover":
        handleHover(req);
        break;
    case "textDocument/completion":
        handleCompletion(req);
        break;
    default:
        debugLog("Unknown method: ", req.method);
        if (req.id.type != JSONType.null_) {
            sendError(req.id, -32_601, "Method not found");
        }
        break;
    }
}

int main() {
    import std.process : environment;
    import std.stdio : stdin, stdout, stderr;
    
    version(Windows) {
        import core.stdc.stdio : _setmode, _O_BINARY;
        import core.stdc.stdio : fileno;
        _setmode(fileno(stdin.getFP()), _O_BINARY);
        _setmode(fileno(stdout.getFP()), _O_BINARY);
    }
    
    if (environment.get("AXELS_DEBUG", "") == "1") {
        g_debugMode = true;
        debugLog("=== Axe Language Server Starting (Debug Mode) ===");
    }
    
    debugLog("Entering main loop");
    
    int messageCount = 0;
    while (true) {
        messageCount++;
        debugLog("Waiting for message #", messageCount, "...");
        stderr.flush();
        
        auto body = readMessage();
        if (body is null) {
            debugLog("Received null message, exiting");
            break;
        }
        
        debugLog("Processing message #", messageCount);
        
        try {
            auto req = parseRequest(body);
            if (req.method.length == 0) {
                debugLog("Empty method in request");
                continue;
            }
            dispatch(req);
        } catch (Exception e) {
            debugLog("Exception in main loop: ", e.msg);
            stderr.writeln("[ERROR] ", e);
            stderr.flush();
        }
        
        debugLog("Finished processing message #", messageCount);
        stderr.flush();
    }
    
    debugLog("Main loop exited");
    return 0;
}
