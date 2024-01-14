{-# LANGUAGE ImpredicativeTypes #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Compiler.Internal where

import Control.Monad
import qualified Data.List as Li
import Data.Maybe
import Errors
import qualified Lexer as L
import SemanticAnalyzer
import qualified SemanticAnalyzer as S
import qualified SemanticAnalyzer.Expression as SE
import StandardLibrary
import qualified SyntacticAnalyzer as Y
import Util

type CCode = String

data ExpressionBuilder = ExprBuildr
  { ebStatms :: [CCode]
  , ebGStatms :: [CCode]
  , ebStackVars :: [CCode]
  , ebCounter :: Int
  }

data Expression
  = ClosureExpr Closure
  | FunctionRef L.VarIdent
  | CaptureRef Int
  | ParamRef
  | Application Expression Expression
  | IfThenElse Expression Expression Expression
  | Literal Y.Literal
  deriving (Show)

type DeBrujinInd = Int
type MemoryInd = Int

data Closure = Closure
  { clExpression :: Expression
  , clName :: CCode
  , clDepth :: Int
  }
  deriving (Show)

compile :: S.Program -> CCode
compile program =
  includes
    ++ constPredefs
    ++ concatMap ((++ "\n") . predefHelper) (S.progDefs program)
    ++ runtime
    ++ stdDefinitions usedFunctions
    ++ programCode
    ++ if mainfnHelper then mainfn else mainfnEmpty
 where
  usedFunctions =
    foldr
      (\x acc -> getUsedFunctions (mkExpression x) +-+ acc)
      []
      $ S.progDefs program
  programCode = unlines (map genHelper $ S.progDefs program)
  genHelper def@(S.Definition gname _) = genFunction gname $ mkExpression def
  predefHelper (S.Definition gname _) =
    "void* "
      ++ show gname
      ++ "_func(void);"
  mainfnHelper =
    isJust
      $ Li.find
        ( \(S.Definition gname _) ->
            show gname == "main"
        )
        (S.progDefs program)

showExpression :: L.VarIdent -> Expression -> (CCode, CCode)
showExpression gname expr =
  let (ExprBuildr statms gstatms stackVars cnt, expr') =
        runState (showExpressionS gname expr) (ExprBuildr [] [] [] 1)
   in ( unlines
          ( map ("\t" ++) statms
              ++ ["\tvoid* val" ++ show cnt ++ " = " ++ expr' ++ ";"]
              ++ gcStackValRemovals stackVars
              ++ ["\treturn val" ++ show cnt ++ ";"]
          )
      , unlines gstatms
      )

gcStackValRemovals :: [CCode] -> [CCode]
gcStackValRemovals = map (\name -> "\t((gc_type*)" ++ name ++ ")->gc_data.isInStackSpace = 0;")

{- FOURMOLU_DISABLE -}
showExpressionS :: L.VarIdent -> Expression -> State ExpressionBuilder CCode
showExpressionS _ ParamRef = return "param"
showExpressionS _ (Literal (Y.Literal typ lit)) = do
  lid <- incBuilderIndex
  let litName = "l" ++ show lid
  addStatement $ "literal* " ++ litName ++ " = new_literal(sizeof(" ++ cTypeOf typ ++ "));"
  addStackVal litName
  addStatement $ "void* " ++ litName ++ "_data = &" ++ litName ++ "->data;"
  addStatement $ cTypeOf typ ++ "* " ++ litName ++ "_datai = " ++ litName ++ "_data;"
  addStatement $ "*" ++ litName ++ "_datai = " ++ show lit ++ ";"
  return litName
showExpressionS _ (CaptureRef n) = return $ "self->captures[" ++ show (n - 2) ++ "]"
showExpressionS _ (FunctionRef func) = do
  return $ show func ++ "_func()"
showExpressionS gname (ClosureExpr closure) =
    addClosure gname closure
showExpressionS gname (Application expr1 expr2) = do
  expr1' <- showExpressionS gname expr1
  expr2' <- showExpressionS gname expr2
  indx <- incBuilderIndex
  let icl = "icl" ++ show indx
  addStatement $ "closure* " ++ icl ++ " = " ++ expr1' ++ ";"
  addStackVal icl
  return $ icl ++ "->clfunc(" ++ icl ++ ", " ++ expr2' ++ ")"
showExpressionS gname (IfThenElse cond expr1 expr2) = do
  cond' <- showExpressionS gname cond
  indx <- incBuilderIndex
  let ifr = "ifr" ++ show indx
  addStatement $ "void* " ++ ifr ++ ";"
  addStatement $ "if(((literal*)" ++ cond' ++ ")->data[0]){"
  ifvars <- takeStackVars
  expr1' <- showExpressionS gname expr1
  addStatement $ ifr ++ " = " ++ expr1' ++ ";"
  putStackVarsAndRemove ifvars
  addStatement "} else {"
  elsevars <- takeStackVars
  expr2' <- showExpressionS gname expr2
  addStatement $ ifr ++ " = " ++ expr2' ++ ";"
  putStackVarsAndRemove elsevars
  addStatement "}"
  return ifr
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
genFunction :: L.VarIdent -> Expression -> CCode
genFunction name expr =
  gcode ++ "\n" ++
  "void* " ++ show name ++ "_func(void) {\n" ++
        expr' ++
  "}\n"
 where
  (expr', gcode) = showExpression name expr
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
addClosureFunction ::
  L.VarIdent ->
  Expression ->
  State ExpressionBuilder CCode
addClosureFunction gname expr = do
  ind <- incBuilderIndex
  expr' <- separateBuilder $ showExpressionS gname expr
  let fnname = show gname ++ "_clfunc_" ++ show ind
  let fncode =
        "void* " ++ fnname ++ "(closure* self, void* param) {\n" ++
            expr' ++
        "}\n"
  addGlobalStatement fncode
  return fnname
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
addClosure :: L.VarIdent -> Closure -> State ExpressionBuilder CCode
addClosure gname (Closure expr _ depth) = do
  ind <- incBuilderIndex
  let cl = "c" ++ show ind
  addGlobalStatement $ "// depth: " ++ show depth
  clfunc <- addClosureFunction gname expr
  addStatement $
    "closure* " ++ cl ++ " = (closure*)new_closure(" ++ show depth ++ ");"
  addStackVal cl
  addStatement $ cl ++ "->clfunc = " ++ clfunc ++ ";"
  when (depth >= 1) $
      addStatement $ cl ++ "->captures[0] = param;"
  when (depth >= 2) $
    addStatement $ "memcpy(&(" ++ cl ++ "->captures[1]), &(self->captures), sizeof(void*) * " ++ show (depth - 1) ++ ");"
  return $ "c" ++ show ind
{- FOURMOLU_ENABLE -}

incBuilderIndex :: State ExpressionBuilder Int
incBuilderIndex = do
  ExprBuildr statms gstatms stackVars ind <- get
  put $ ExprBuildr statms gstatms stackVars (ind + 1)
  return ind

addStackVal :: CCode -> State ExpressionBuilder ()
addStackVal valName = do
  ExprBuildr statms gstatms stackVars ind <- get
  put $ ExprBuildr statms gstatms (valName : stackVars) ind

takeStackVars :: State ExpressionBuilder [CCode]
takeStackVars = do
  buildr <- get
  put $ buildr{ebStackVars = []}
  return $ ebStackVars buildr

putStackVarsAndRemove :: [CCode] -> State ExpressionBuilder ()
putStackVarsAndRemove vars = do
  vars' <- takeStackVars
  mapM_ (addStatement . drop 1) $ gcStackValRemovals vars'
  builder <- get
  put $ builder{ebStackVars = vars}

addStatement :: CCode -> State ExpressionBuilder ()
addStatement code = do
  ExprBuildr statms gstatms stackVars ind <- get
  put $ ExprBuildr (statms ++ [code]) gstatms stackVars ind

addGlobalStatement :: CCode -> State ExpressionBuilder ()
addGlobalStatement code = do
  ExprBuildr statms gstatms stackVars ind <- get
  put $ ExprBuildr statms (gstatms ++ [code]) stackVars ind

separateBuilder ::
  State ExpressionBuilder CCode ->
  State ExpressionBuilder CCode
separateBuilder builderS = do
  ExprBuildr statms gstatms stackVars cnt <- get
  let (ExprBuildr statms' gstatms' stackVars' cnt', expr') =
        runState builderS (ExprBuildr [] [] [] (cnt + 1))
  put (ExprBuildr statms (gstatms' ++ gstatms) stackVars cnt')
  return
    $ unlines
      ( 
          ["\tgc_invoke();"]
          ++ map ("\t" ++) statms'
          ++ ["\tvoid* val" ++ show cnt ++ " = " ++ expr' ++ ";"]
          ++ gcStackValRemovals stackVars'
          ++ ["\treturn val" ++ show cnt ++ ";"]
      )

getUsedFunctions :: Expression -> [L.VarIdent]
getUsedFunctions (ClosureExpr (Closure clExpr _ _)) = getUsedFunctions clExpr
getUsedFunctions (FunctionRef ident) = [ident]
getUsedFunctions (Application expr1 expr2) =
  getUsedFunctions expr1
    +-+ getUsedFunctions expr2
getUsedFunctions (IfThenElse cond expr1 expr2) =
  getUsedFunctions cond
    +-+ getUsedFunctions expr1
    +-+ getUsedFunctions expr2
getUsedFunctions _ = []

mkExpression :: S.Definition -> Expression
mkExpression def =
  let (expr, _) =
        execState
          (mkExpressionS (S.defName def) 0 (S.teExpr (S.defExpr def)))
          1
   in expr

mkExpressionS ::
  L.VarIdent ->
  Int ->
  SE.Expression ->
  State Int (Expression, [Int])
mkExpressionS _ _ (SE.Ident n) | n == 1 = return (ParamRef, [n])
mkExpressionS _ _ (SE.Ident n) = return (CaptureRef n, [n])
mkExpressionS _ _ (SE.Ref n) = return (FunctionRef n, [])
mkExpressionS _ _ (SE.Lit l) = return (Literal l, [])
mkExpressionS ident depth (SE.Lambda _ expr) = do
  (closure, cptrs) <- mkClosure ident depth expr
  return (ClosureExpr closure, cptrs)
mkExpressionS ident depth (SE.Application expr1 expr2) = do
  (expr1', cptrs1) <- mkExpressionS ident depth expr1
  (expr2', cptrs2) <- mkExpressionS ident depth expr2
  return (Application expr1' expr2', Li.sort (cptrs1 +-+ cptrs2))
mkExpressionS ident depth (SE.IfThenElse cond expr1 expr2) = do
  (cond', cptrsc) <- mkExpressionS ident depth cond
  (expr1', cptrs1) <- mkExpressionS ident depth expr1
  (expr2', cptrs2) <- mkExpressionS ident depth expr2
  return
    ( IfThenElse cond' expr1' expr2'
    , Li.sort
        (cptrs1 +-+ cptrs2 +-+ cptrsc)
    )

mkClosure ::
  L.VarIdent ->
  Int ->
  SE.Expression ->
  State Int (Closure, [Int])
mkClosure ident depth expr = do
  (expr', cptrs) <- mkExpressionS ident (depth + 1) expr
  let cptrs' = filter (> 1) cptrs
  clId <- incState
  let closure =
        Closure
          { clExpression = expr'
          , clName = show ident ++ "_c_" ++ show clId
          , clDepth = depth
          }
  return (closure, map (+ (-1)) cptrs')

incState :: State Int Int
incState = do
  state <- get
  put $ state + 1
  return state

compileFull :: SourceCode -> Either CompilerError CCode
compileFull sc = do
  scy <- leftMap mkCompErrLex $ Y.parseProgram sc
  scs <- S.mkProgramFromSyn scy
  return $ compile scs

{- FOURMOLU_DISABLE -}
includes :: CCode
includes =
    "#include <stdlib.h>\n" ++
    "#include <stdio.h>\n" ++
    "#include <stdint.h>\n" ++
    "#include <string.h>\n" ++
    "\n"
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
runtime :: CCode
runtime =
  "closure* new_closure(uint32_t count) {\n" ++
      "\tclosure* cl = malloc(sizeof(closure) + sizeof(void*) * count);\n" ++
      "\tcl->gc_data.isInStackSpace = 1;\n" ++
      "\tcl->gc_data.captureCount = count;\n" ++
      "\tcl->gc_data.next = gc_object_stack;\n" ++
      "\tgc_object_stack = (gc_type*)cl;\n" ++
      "\treturn cl;\n" ++
  "}\n" ++
  "\n" ++
  "literal* new_literal(size_t size) {\n" ++
      "\tliteral* lit = malloc(sizeof(literal) + size);\n" ++
      "\tlit->gc_data.isInStackSpace = 1;\n" ++
      "\tlit->gc_data.captureCount = 0;\n" ++
      "\tlit->gc_data.next = gc_object_stack;\n" ++
      "\tgc_object_stack = (gc_type*)lit;\n" ++
      "\treturn lit;\n" ++
  "}\n" ++
  "\n" ++
  "void gc_mark(gc_type* startPoint) {\n" ++
      "\tif(startPoint->gc_data.isMarked) { return; }\n" ++
      "\tstartPoint->gc_data.isMarked = 1;\n" ++
      "\tfor(int i = 0; i < startPoint->gc_data.captureCount; i++) {\n" ++
          "\t\tgc_mark(((closure*)startPoint)->captures[i]);\n" ++
      "\t}\n" ++
  "}\n" ++
  "\n" ++
  "void gc_invoke() {\n" ++
      "\tif(gc_object_stack == NULL) { return; }\n" ++
      "\tgc_type* object_ptr = gc_object_stack;\n" ++
      "\twhile(object_ptr != NULL) {\n" ++
          "\t\tobject_ptr->gc_data.isMarked = 0;\n" ++
          "\t\tobject_ptr = object_ptr->gc_data.next;\n" ++
      "\t}\n" ++
      "\n" ++
      "\tobject_ptr = gc_object_stack;\n" ++
      "\twhile(object_ptr != NULL) {\n" ++
          "\t\tif(object_ptr->gc_data.isInStackSpace) {\n" ++
              "\t\t\tgc_mark(object_ptr);\n" ++ 
          "\t\t}\n" ++
          "\t\tobject_ptr = object_ptr->gc_data.next;\n" ++
      "\t}\n" ++
      "\n" ++
      "\tobject_ptr = gc_object_stack;\n" ++
      "\tgc_type* object_ptr_prev = NULL;\n" ++
      "\twhile(object_ptr != NULL) {\n" ++
          "\t\tif(!object_ptr->gc_data.isMarked) {\n" ++
                "\t\t\tgc_type* next = object_ptr->gc_data.next;\n" ++
                "\t\t\tfree(object_ptr);\n" ++
                "\t\t\tobject_ptr = next;\n" ++
                "\t\t\tif(object_ptr_prev == NULL) {\n" ++
                    "\t\t\t\tgc_object_stack = object_ptr;\n" ++
                "\t\t\t} else {\n" ++
                    "\t\t\t\tobject_ptr_prev->gc_data.next = object_ptr;\n" ++
                "\t\t\t}\n" ++
          "\t\t} else {\n" ++
              "\t\t\tobject_ptr_prev = object_ptr;\n" ++
              "\t\t\tobject_ptr = object_ptr->gc_data.next;\n" ++
          "\t\t}\n" ++
      "\t}\n" ++
  "}\n" ++
  "\n"
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
constPredefs :: CCode
constPredefs =
  "typedef __int128 int128_t;\n" ++
  "typedef unsigned __int128 uint128_t;\n" ++
  "typedef struct closure closure;\n" ++
  "typedef struct literal literal;\n" ++
  "typedef struct gc_data gc_data;\n" ++
  "typedef struct gc_type gc_type;\n" ++
  "typedef void* closure_clfunc(closure*, void*);\n" ++
  "\n" ++
  "struct gc_data {\n" ++
      "\tchar isInStackSpace;\n" ++
      "\tchar isMarked;\n" ++
      "\tuint32_t captureCount;\n" ++
      "\tgc_type* next;\n" ++
  "};\n" ++
  "struct gc_type {\n" ++
      "\tgc_data gc_data;\n" ++
  "};\n" ++
  "\n" ++
  "gc_type* gc_object_stack = NULL;\n" ++
  "\n" ++
  "struct closure {\n" ++
      "\tgc_data gc_data;\n" ++
      "\tclosure_clfunc* clfunc;\n" ++
      "\tvoid* captures[];\n" ++
  "};\n" ++
  "struct literal {\n" ++
      "\tgc_data gc_data;\n" ++
      "\tchar data[];\n" ++
  "};\n" ++
  "\n"
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
mainfn :: CCode
mainfn =
  "int main(void) {\n" ++
      "\tliteral* ret = main_func();\n" ++
      "\tchar ret_data = ret->data[0];\n" ++
      "\tret->gc_data.isInStackSpace = 0;\n" ++
      "\tgc_invoke();\n" ++
      "\treturn ret_data;\n" ++
  "}\n"
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
mainfnEmpty :: CCode
mainfnEmpty =
  "int main(void) {\n" ++
      "\treturn 0;\n" ++
  "}\n"
{- FOURMOLU_ENABLE -}

stdDefinitions :: [L.VarIdent] -> CCode
stdDefinitions usedFunctions =
  Li.intercalate "\n" (map genStdDefinitionCode filteredDefs)
 where
  rawDefs =
    map
      ( \lib@(name, _, _) ->
          let (cs, n) =
                genStdRawDefinition lib
           in (name, cs, n)
      )
      standardLibrary
  filteredDefs = filter (\(n, _, _) -> n `elem` usedFunctions) rawDefs

genStdRawDefinition ::
  ( L.VarIdent
  , a
  , (Int -> Writer [Int] CCode) ->
    Writer [Int] [CCode]
  ) ->
  ([CCode], Int)
genStdRawDefinition (_, _, f) = (code, maximum ns)
 where
  ff :: Int -> Writer [Int] CCode
  ff n = Writer ("std_var_" ++ show n, [n])
  (code, ns) = runWriter $ f ff

genStdDefinitionCode :: (L.VarIdent, [CCode], Int) -> CCode
genStdDefinitionCode rawDef =
  let (ExprBuildr _ glStatms _ _, _) =
        runState
          (genStdDefinitionCodeS rawDef)
          (ExprBuildr [] [] [] 1)
   in unlines glStatms

{- FOURMOLU_DISABLE -}
genStdDefinitionCodeS ::
  (L.VarIdent, [CCode], Int) ->
  State ExpressionBuilder ()
genStdDefinitionCodeS rawDef@(name, _, _) = do
  stdExpr <- genStdDefinitionCodeStepS 0 rawDef
  addGlobalStatement $
    "void* " ++ show name ++ "_func(void) {\n" ++
        stdExpr ++ "\n" ++
    "}\n"
{- FOURMOLU_ENABLE -}

{- FOURMOLU_DISABLE -}
genStdDefinitionCodeStepS ::
  Int ->
  (L.VarIdent, [CCode], Int) ->
  State ExpressionBuilder CCode
genStdDefinitionCodeStepS depth rawDef@(name, cs, n)
  | depth >= n = return $
    concatMap (\m -> "\tvoid* std_var_" ++ show m ++ " = " ++ helper m ++ ";\n") [1..n] ++
    concatMap (("\t" ++) . (++ ";\n")) (init cs) ++
    "\treturn " ++ last cs ++ ";"
  | otherwise = do
      nextExpr <- genStdDefinitionCodeStepS (depth + 1) rawDef
      clid <- incBuilderIndex
      let clfunc = show name ++ "_clfunc_" ++ show (depth + 1)
      addGlobalStatement $
        "void* " ++ clfunc ++ "(closure* self, void* param){\n" ++
            nextExpr ++ "\n" ++
        "}\n"
      let cl = "c" ++ show clid
      return $
        "\tclosure* " ++ cl ++ " = new_closure(" ++ show depth ++ ");\n" ++
        "\t" ++ cl ++ "->clfunc = " ++ clfunc ++ ";\n" ++
        (if depth >= 1
        then "\t" ++ cl ++ "->captures[0] = param;\n"
        else "") ++
        (if depth >= 2
        then "\tmemcpy(&(" ++ cl ++ "->captures[1]), &(self->captures), sizeof(void*) * " ++ show (depth - 1) ++ ");\n"
        else "") ++
        "\treturn " ++ cl ++ ";"
      where
      helper m
        | m >= n = "param"
        | otherwise = "self->captures[" ++ show (n - m - 1) ++ "]"
{- FOURMOLU_ENABLE -}
