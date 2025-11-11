import
    structs,
    strformat,
    strutils

proc lex*(source: string): seq[Token] =
    ## Lexical analysis and tokenization
    ## Includes whitespace skipping, basic tokenization, and string handling

    var tokens: seq[Token]
    var pos = 0

    while pos < source.len:
        case source[pos]
        of '*':
            # Handle pointer types by combining with previous identifier
            if tokens.len > 0 and tokens[^1].typ == Identifier:
                tokens[^1].value.add("*")
                inc(pos)
            else:
                raise newException(ValueError, "Unexpected '*'")
        of ' ', '\t', '\r':
            tokens.add(Token(typ: Whitespace, value: $source[pos]))
            inc(pos)
        of '\n':
            tokens.add(Token(typ: Newline, value: "\n"))
            inc(pos)
        of '{':
            tokens.add(Token(typ: LBrace, value: "{"))
            inc(pos)
        of '}':
            tokens.add(Token(typ: RBrace, value: "}"))
            inc(pos)
        of ';':
            tokens.add(Token(typ: Semicolon, value: ";"))
            inc(pos)
        of ':':
            tokens.add(Token(typ: Colon, value: ":"))
            inc(pos)
        of '"':
            let ending = source.find('"', pos + 1)
            if ending == -1:
                raise newException(ValueError, "Unterminated string")
            tokens.add(Token(typ: String, value: source[(pos+1)..(ending-1)]))
            pos = ending + 1
        of '(', ')', ',':
            tokens.add(Token(typ: case source[pos]
                of '(': LParen
                of ')': RParen
                of ',': Comma
                else: Colon, value: $source[pos]))
            inc(pos)
        of '[':
            tokens.add(Token(typ: LBracket, value: "["))
            inc(pos)
        of ']':
            tokens.add(Token(typ: RBracket, value: "]"))
            inc(pos)
        of '.':
            tokens.add(Token(typ: Dot, value: "."))
            inc(pos)
        else:
            if pos + 4 <= source.len and source[pos ..< pos+4] == "main":
                tokens.add(Token(typ: Main, value: "main"))
                pos += 4
            elif pos + 7 <= source.len and source[pos ..< pos+7] == "println":
                tokens.add(Token(typ: Println, value: "println"))
                pos += 7
            elif pos + 4 <= source.len and source[pos ..< pos+4] == "loop":
                tokens.add(Token(typ: Loop, value: "loop"))
                pos += 4
            elif pos + 5 <= source.len and source[pos ..< pos+5] == "break":
                tokens.add(Token(typ: Break, value: "break"))
                pos += 5
            elif pos + 3 <= source.len and source[pos ..< pos+3] == "def":
                tokens.add(Token(typ: Def, value: "def"))
                pos += 3
            elif source[pos].isAlphaAscii():
                let start = pos
                while pos < source.len and (source[pos].isAlphaNumeric() or
                        source[pos] == '_'):
                    inc(pos)
                tokens.add(Token(typ: Identifier, value: source[start..<pos]))
            else:
                let charAtPos = if pos < source.len: source[pos] else: '.'
                raise newException(
                    ValueError,
                    &"Unexpected character at position {pos}: '{charAtPos}'"
                )
    return tokens
