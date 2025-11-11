import ast

proc render*(node: Node): string =
  case node.kind
  of nkProgram:
    result = "#include <stdio.h>\n\n"
    for stmt in node.stmts:
      result.add render(stmt)
      result.add "\n"
  
  of nkFuncDecl:
    result = "int " & node.name & "() {\n"
    for stmt in node.body:
      result.add "  " & render(stmt)
    result.add "}\n"
  
  of nkCall:
    if node.fnName == "println":
      result = "printf(\"" & render(node.args[0]) & "\\n\");"
    else:
      result = node.fnName & "("
      for i, arg in node.args:
        if i > 0: result.add ", "
        result.add render(arg)
      result.add ");"
  
  of nkLoop:
    result = "while (1) {\n"
    for stmt in node.loopBody:
      result.add "  " & render(stmt)
    result.add "}"
  
  of nkBreak:
    result = "break;"
  
  of nkStrLit:
    result = node.value
