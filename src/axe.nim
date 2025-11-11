import
    os,
    osproc,
    strutils,
    axe/[lexer, parser, renderer]

when isMainModule:
    if paramCount() < 1:
        echo "Usage: axe input.axe"
    else:
        try:
            let
                source = readFile(paramStr(1))
                tokens = lex(source)
                ast = parse(tokens)
                cCode = generateC(ast)
            writeFile("output.c", cCode)
            discard execProcess(
                command = "gcc",
                args = ["output.c", "-o", "output"],
                options = {poStdErrToStdOut}
            )
        except ValueError as e:
            echo "Error: ", e.msg
        except OSError as e:
            echo "LL Error (maybe no C toolchain is installed?): ", e.msg.replace("OS error:", "")
        except Exception as e:
            echo "Unknown Error: ", e.msg
