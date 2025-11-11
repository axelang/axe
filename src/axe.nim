import
    os,
    osproc,
    strutils,
    axe/[lexer, parser, renderer]

when defined(windows):
    const extension = ".exe"
else:
    const extension = ""

when isMainModule:
    if paramCount() < 1:
        echo "usage: axe input.axe [-e = emit generated code]"
    else:
        try:
            var name = paramStr(1)
            if ".axe" notin name:
                name = name & ".axe"
            let
                source = readFile(name)
                tokens = lex(source)
                ast = parse(tokens)
                cCode = generateC(ast)

            writeFile(name.replace(".axe", ".c"), cCode)
            discard execProcess(
                command = "gcc",
                args = [name.replace(".axe", ".c"), "-o", name.replace(".axe", extension)],
                options = {poStdErrToStdOut}
            )

            if "-e" notin commandLineParams():
                removeFile(name.replace(".axe", ".c"))

        except ValueError as e:
            echo "Compilation error: ", e.msg
        except OSError as e:
            echo "Linker error (maybe no C toolchain is installed?): ", e.msg.replace("OS error:", "")
        except Exception as e:
            echo "Error: ", e.msg
