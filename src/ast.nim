type
  NodeKind* = enum
    nkProgram, nkFuncDecl, nkCall, nkLoop, nkBreak, nkStrLit
    
  Node* = ref object
    case kind*: NodeKind
    of nkProgram:
      stmts*: seq[Node]
    of nkFuncDecl:
      name*: string
      params*: seq[string]
      body*: seq[Node]
    of nkCall:
      fnName*: string
      args*: seq[Node]
    of nkLoop:
      loopBody*: seq[Node]
    of nkBreak:
      discard
    of nkStrLit:
      value*: string
