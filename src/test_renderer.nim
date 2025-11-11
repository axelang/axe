import ast, renderer

# Manually construct AST matching hello.axe
let program = Node(kind: nkProgram, stmts: @[
  Node(kind: nkFuncDecl, name: "main", params: @[], body: @[
    Node(kind: nkCall, fnName: "println", args: @[
      Node(kind: nkStrLit, value: "Hello, world.")
    ]),
    Node(kind: nkLoop, loopBody: @[
      Node(kind: nkCall, fnName: "println", args: @[
        Node(kind: nkStrLit, value: "What is up...")
      ]),
      Node(kind: nkBreak)
    ])
  ])
])

let cCode = render(program)
echo cCode
