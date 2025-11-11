import 
  strutils, 
  sets

type
  TokenKind* = enum
    tkComment, tkIdentifier, tkString, tkKeyword, tkSymbol, tkEof, tkNumber, tkOperator
    
  Token* = object
    kind*: TokenKind
    value*: string
    line*, col*: int

const Keywords = ["main", "void", "loop", "break"].toHashSet()
const Operators = ["+", "-", "*", "/", "%", "=", "==", "!=", "<", ">", "<=", ">="].toHashSet()

proc lex*(source: string): seq[Token] =
  var tokens: seq[Token]
  var i = 0
  var line = 1
  var col = 1
  
  while i < source.len:
    case source[i]
    of ' ', '\t': 
      inc i
      inc col
    of '\n':
      inc i
      inc line
      col = 1
    of '/':
      if i + 1 < source.len and source[i+1] == '/':
        var comment = "//"
        i += 2
        col += 2
        while i < source.len and source[i] != '\n':
          comment.add source[i]
          inc i
          inc col
        tokens.add Token(kind: tkComment, value: comment, line: line, col: col - comment.len)
      elif i + 1 < source.len and source[i+1] == '*':
        var comment = "/*"
        i += 2
        col += 2
        while i < source.len and (source[i] != '*' or source[i+1] != '/'):
          comment.add source[i]
          inc i
          inc col
        if i < source.len and source[i] == '*' and source[i+1] == '/':
          comment.add "*/"
          i += 2
          col += 2
        tokens.add Token(kind: tkComment, value: comment, line: line, col: col - comment.len)
      else:
        tokens.add Token(kind: tkSymbol, value: $source[i], line: line, col: col)
        inc i
        inc col
    of '"':
      var str = ""
      inc i
      inc col
      while i < source.len and source[i] != '"':
        str.add source[i]
        inc i
        inc col
      if i < source.len:
        inc i
        inc col
      tokens.add Token(kind: tkString, value: str, line: line, col: col - str.len - 1)
    of '0'..'9':
      var num = ""
      while i < source.len and source[i].isDigit():
        num.add source[i]
        inc i
        inc col
      tokens.add Token(kind: tkNumber, value: num, line: line, col: col - num.len)
    else:
      if source[i].isAlphaAscii():
        var ident = ""
        let startCol = col
        while i < source.len and (source[i].isAlphaAscii() or source[i] == '_'):
          ident.add source[i]
          inc i
          inc col
        if ident in Keywords:
          tokens.add Token(kind: tkKeyword, value: ident, line: line, col: startCol)
        else:
          tokens.add Token(kind: tkIdentifier, value: ident, line: line, col: startCol)
      elif source[i] in {'+', '-', '*', '/', '%', '=', '<', '>', '!' }:
        var op = $source[i]
        if i + 1 < source.len and source[i+1] in {'=', '<', '>', '!'}:
          op.add source[i+1]
          inc i
          inc col
        if op in Operators:
          tokens.add Token(kind: tkOperator, value: op, line: line, col: col - op.len)
        else:
          tokens.add Token(kind: tkSymbol, value: op, line: line, col: col - op.len)
        inc i
        inc col
      else:
        tokens.add Token(kind: tkSymbol, value: $source[i], line: line, col: col)
        inc i
        inc col
  
  tokens.add Token(kind: tkEof, value: "", line: line, col: col)
  return tokens
