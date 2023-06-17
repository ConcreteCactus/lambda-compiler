{-# OPTIONS_GHC -Wincomplete-patterns #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

module SyntacticAnalyzer
  ( SynExpression (..),
    SynTypeExpression (..),
    parseExpression,
    parseType,
  )
where

import Control.Applicative
import Errors
import Lexer

data SynExpression
  = Id String
  | Lambda String SynExpression
  | Application SynExpression SynExpression
  deriving (Show, Eq)

data SynTypeExpression
  = TypeId String
  | FunctionType SynTypeExpression SynTypeExpression
  deriving (Show, Eq)

data SynProgramPart = SynDefinition String SynExpression | SynDeclaration String SynTypeExpression deriving (Eq, Show)

type Program = [SynProgramPart]

idParser :: Parser SynExpression
idParser = Id <$> identifier

lambdaParser :: Parser SynExpression
lambdaParser =
  Lambda
    <$> ( lambda
            *> (whiteSpaceO *> identifier <* whiteSpaceO)
            <* (dot <* whiteSpaceO)
        )
    <*> expressionParser

applicationsParser :: Parser SynExpression
applicationsParser = foldl1 Application <$> sepBy1 whiteSpace parseExpressionWithoutApplication

parseExpressionWithoutApplication :: Parser SynExpression
parseExpressionWithoutApplication =
  idParser
    <|> lambdaParser
    <|> (openParen *> expressionParser <* closeParen)

expressionParser :: Parser SynExpression
expressionParser =
  applicationsParser
    <|> idParser
    <|> lambdaParser
    <|> ( whiteSpaceO
            *> ( openParen
                   *> (whiteSpaceO *> expressionParser <* whiteSpaceO)
                   <* closeParen
               )
        )

parseExpression :: String -> Either CompilerError SynExpression
parseExpression s = fst <$> runParser expressionParser s

tIdParser :: Parser SynTypeExpression
tIdParser = TypeId <$> identifier

functionParser :: Parser SynTypeExpression
functionParser = FunctionType <$> typeParserWithoutFunction <*> (whiteSpaceO *> arrow *> whiteSpaceO *> typeParser)

typeParserWithoutFunction :: Parser SynTypeExpression
typeParserWithoutFunction =
  tIdParser
    <|> ( whiteSpaceO
            *> ( openParen
                   *> (whiteSpaceO *> typeParser <* whiteSpaceO)
                   <* closeParen
               )
            <* whiteSpaceO
        )

typeParser :: Parser SynTypeExpression
typeParser =
  functionParser
    <|> tIdParser
    <|> ( whiteSpaceO
            *> ( openParen
                   *> (whiteSpaceO *> typeParser <* whiteSpaceO)
                   <* closeParen
               )
            <* whiteSpaceO
        )

parseType :: String -> Either CompilerError SynTypeExpression
parseType s = fst <$> runParser typeParser s

declarationParser :: Parser SynProgramPart
declarationParser = SynDeclaration <$> identifier <*> (whiteSpaceO *> colon *> whiteSpaceO *> typeParser)

definitionParser :: Parser SynProgramPart
definitionParser = SynDefinition <$> identifier <*> (whiteSpaceO *> colonEquals *> whiteSpaceO *> expressionParser)

programParser :: Parser Program
programParser = sepBy (whiteSpaceO *> endOfLine) (definitionParser <|> declarationParser)

fullProgramParser :: Parser Program
fullProgramParser = (programParser <* whiteSpaceO) <* eof

-- Unit tests

tests :: [Bool]
tests =
  -- Id tests
  [ runParser expressionParser "hello" == Right (Id "hello", ""),
    runParser expressionParser "hello   " == Right (Id "hello", "   "),
    runParser expressionParser "   " == Left (LexicalError UnexpectedEndOfFile),
    -- Lambda tests
    runParser expressionParser "\\a.b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\a. b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\a . b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\ a . b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\ a.b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\a .b" == Right (Lambda "a" (Id "b"), ""),
    runParser expressionParser "\\a.b  " == Right (Lambda "a" (Id "b"), "  "),
    runParser expressionParser "\\a.b  b" == Right (Lambda "a" (Application (Id "b") (Id "b")), ""),
    -- Application tests
    runParser expressionParser "a  b" == Right (Application (Id "a") (Id "b"), ""),
    runParser expressionParser "(\\a.b)  b" == Right (Application (Lambda "a" (Id "b")) (Id "b"), ""),
    runParser expressionParser "a b" == Right (Application (Id "a") (Id "b"), ""),
    runParser expressionParser "a b c" == Right (Application (Application (Id "a") (Id "b")) (Id "c"), ""),
    runParser expressionParser "a b c d" == Right (Application (Application (Application (Id "a") (Id "b")) (Id "c")) (Id "d"), ""),
    runParser expressionParser "(\\a.a) b c" == Right (Application (Application (Lambda "a" (Id "a")) (Id "b")) (Id "c"), ""),
    runParser expressionParser "(\\a.\\b.b) b c" == Right (Application (Application (Lambda "a" (Lambda "b" (Id "b"))) (Id "b")) (Id "c"), ""),
    -- Type parser tests
    runParser typeParser "a" == Right (TypeId "a", ""),
    runParser typeParser "ab" == Right (TypeId "ab", ""),
    runParser typeParser "ab1  " == Right (TypeId "ab1", "  "),
    runParser typeParser "a -> b" == Right (FunctionType (TypeId "a") (TypeId "b"), ""),
    runParser typeParser "a->b" == Right (FunctionType (TypeId "a") (TypeId "b"), ""),
    runParser typeParser "a -> b -> c" == Right (FunctionType (TypeId "a") (FunctionType (TypeId "b") (TypeId "c")), ""),
    runParser typeParser "(a -> b) -> c" == Right (FunctionType (FunctionType (TypeId "a") (TypeId "b")) (TypeId "c"), ""),
    -- Declaration definition
    runParser declarationParser "hello : string" == Right (SynDeclaration "hello" (TypeId "string"), ""),
    runParser declarationParser "helloWorld : string -> string" == Right (SynDeclaration "helloWorld" (FunctionType (TypeId "string") (TypeId "string")), ""),
    runParser definitionParser "world := \\a.\\b.a" == Right (SynDefinition "world" (Lambda "a" (Lambda "b" (Id "a"))), ""),
    -- Whole program parsing
    runParser programParser program1 == Right (program1ShouldBe, ""),
    runParser programParser program2 == Right (program2ShouldBe, "  \n")
  ]

program1 :: String
program1 =
  "hello : string\n"
    ++ "hello := helloString"

program1ShouldBe :: Program
program1ShouldBe =
  [ SynDeclaration "hello" (TypeId "string"),
    SynDefinition "hello" (Id "helloString")
  ]

program2 :: String
program2 =
  "hello : string -> (string -> int) -> char\t   \n \n \n   \n\n\r\n\n  \t \n"
    ++ "hello := \n \t \\a.\\b.\\c.b  \n"

program2ShouldBe :: Program
program2ShouldBe =
  [ SynDeclaration "hello" (FunctionType (TypeId "string") (FunctionType (FunctionType (TypeId "string") (TypeId "int")) (TypeId "char"))),
    SynDefinition "hello" (Lambda "a" (Lambda "b" (Lambda "c" (Id "b"))))
  ]
