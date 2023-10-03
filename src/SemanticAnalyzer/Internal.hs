{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module SemanticAnalyzer.Internal where

import Control.Monad
import Data.Bifunctor
import Data.Foldable
import Errors
import qualified Lexer as L
import SemanticAnalyzer.DependencyList
import SemanticAnalyzer.Expression
import SemanticAnalyzer.Type
import qualified SyntacticAnalyzer as Y
import Util

data UninfDefinition = UninfDefinition
  { udefName :: L.Ident,
    udefExpr :: Expression,
    udefWish :: Maybe NormType
  }
  deriving (Show)

data InfExpr = InfExpr
  { ieExpr :: Expression,
    ieType :: NormType
  }
  deriving (Eq)

instance Show InfExpr where
  show expr = show (ieExpr expr) ++ " : " ++ show (ieType expr)

data TypedExpr = InfTyExpr InfExpr | WishTyExpr Expression NormType
  deriving (Eq)

instance Show TypedExpr where
  show (InfTyExpr infExpr) = show infExpr
  show (WishTyExpr expr typ) = show expr ++ " : " ++ show typ

data Definition = Definition
  { defName :: L.Ident,
    defExpr :: TypedExpr
  }
  deriving (Eq)

instance Show Definition where
  show (Definition name expr) = L.unIdent name ++ " := " ++ show expr

newtype UninfProg = UninfProg [UninfDefinition] deriving (Show)

data ProgInfDeps = ProgInfDeps
  { pidUninfProg :: UninfProg,
    pidDepGraph :: DependencyList L.Ident
  }

newtype Program = Program
  { progDefs :: [Definition]
  }
  deriving (Eq, Show)

type SourceCode = String

teExpr :: TypedExpr -> Expression
teExpr (InfTyExpr infExpr) = ieExpr infExpr
teExpr (WishTyExpr expr _) = expr

teType :: TypedExpr -> NormType
teType (InfTyExpr infExpr) = ieType infExpr
teType (WishTyExpr _ typ) = typ

mkUninfProg :: Y.Program -> Either CompilerError UninfProg
mkUninfProg synProg = execState (mkUninfProgS synProg) (ConvertEnv [] [] [])

mkUninfProgS :: Y.Program -> State ConvertEnv (Either CompilerError UninfProg)
mkUninfProgS synProg = do
  udefsE <- foldEitherM (flip helper) [] synProg
  case udefsE of
    Left e -> return $ Left e
    Right udefs -> do
      errors <- mapM (checkUndefinedReferencesS . udefExpr) udefs
      udefs' <- mapM addWish udefs
      case find
        ( \case
            Just _ -> True
            _ -> False
        )
        errors of
        Just (Just e) -> return $ Left e
        Just Nothing -> error "I've got hit by a lightning bolt."
        Nothing -> return $ Right $ UninfProg udefs'
  where
    foldEitherM ::
      (Monad m) =>
      (a -> b -> m (Either e b)) ->
      b ->
      [a] ->
      m (Either e b)
    foldEitherM _ acc [] = return $ Right acc
    foldEitherM f acc (x : xs) = do
      res <- f x acc
      case res of
        Left err -> return $ Left err
        Right newAcc -> foldEitherM f newAcc xs
    helper ::
      [UninfDefinition] ->
      Y.ProgramPart ->
      State ConvertEnv (Either CompilerError [UninfDefinition])
    helper parts (Y.Declaration name typ) = do
      let conTyp = convertType typ
      addDecl name conTyp
      return $ Right parts
    helper parts (Y.Definition name expr) = do
      semExpr <- convertExpressionS expr
      addGlobal name
      return $ Right $ parts ++ [UninfDefinition name semExpr Nothing]
    checkUndefinedReferencesS ::
      Expression -> State ConvertEnv (Maybe CompilerError)
    checkUndefinedReferencesS (Ident _) = return Nothing
    checkUndefinedReferencesS (Lit _) = return Nothing
    checkUndefinedReferencesS (Ref name) = do
      globM <- findGlobal name
      case globM of
        Nothing ->
          return $ Just $ SemanticError $ SUndefinedVariable (L.unIdent name)
        Just _ -> return Nothing
    checkUndefinedReferencesS (Lambda _ expr) = checkUndefinedReferencesS expr
    checkUndefinedReferencesS (Application expr1 expr2) = do
      c1 <- checkUndefinedReferencesS expr1
      c2 <- checkUndefinedReferencesS expr2
      case (c1, c2) of
        (Just e, _) -> return $ Just e
        (_, Just e) -> return $ Just e
        _ -> return Nothing
    addWish :: UninfDefinition -> State ConvertEnv UninfDefinition
    addWish udef = do
      (ConvertEnv _ _ wishes) <- get
      case lookup (udefName udef) wishes of
        Nothing -> return udef
        Just wish -> return udef {udefWish = Just wish}

mkProgInfDeps :: UninfProg -> Either SemanticError ProgInfDeps
mkProgInfDeps uiprog@(UninfProg uiDefs) = case checkDeps uiprog of
  Just e -> Left e
  Nothing ->
    Right $
      ProgInfDeps uiprog $
        mkDependencyList (map udefName uiDefs) (getDeps uiprog)
  where
    checkDeps :: UninfProg -> Maybe SemanticError
    checkDeps (UninfProg uiDefs') =
      foldr
        ( \udef acc ->
            ( if all (`elem` map udefName uiDefs') (getAllRefs (udefExpr udef))
                then acc
                else Just $ SUndefinedVariable $ L.unIdent $ udefName udef
            )
        )
        Nothing
        uiDefs'
    getDeps :: UninfProg -> L.Ident -> [L.Ident]
    getDeps (UninfProg uiDefs') glob =
      case find ((== glob) . udefName) uiDefs' of
        Nothing -> error "Found an undefined global. This is a bug."
        Just definition -> getAllRefs $ udefExpr definition
    getAllRefs :: Expression -> [L.Ident]
    getAllRefs (Ident _) = []
    getAllRefs (Lit _) = []
    getAllRefs (Ref name) = [name]
    getAllRefs (Lambda _ expr) = getAllRefs expr
    getAllRefs (Application expr1 expr2) =
      getAllRefs expr1 +-+ getAllRefs expr2

mkProgram :: ProgInfDeps -> Either STypeError Program
mkProgram (ProgInfDeps uprog (DependencyList dList)) =
  Program
    <$> foldl
      ( \acc item -> case item of
          DepListSingle a -> helperTree uprog a acc
          DepListCycle as -> helperCycle uprog as acc
      )
      (Right [])
      dList
  where
    helperTree ::
      UninfProg ->
      L.Ident ->
      Either STypeError [Definition] ->
      Either STypeError [Definition]
    helperTree _ _ (Left e) = Left e
    helperTree uprog' a (Right prevDeps) = 
        (: prevDeps)
        <$> ( Definition a
                <$> mkInfExprTree prevDeps (lookupUDefUnsafe uprog' a)
            )
    helperCycle ::
      UninfProg ->
      [L.Ident] ->
      Either STypeError [Definition] ->
      Either STypeError [Definition]
    helperCycle _ _ (Left e) = Left e
    helperCycle uprog' as (Right prevDeps) =
      (++ prevDeps)
        <$> ( zipWith Definition as
                <$> mkTyExprCycle prevDeps (lookupUDefUnsafe uprog' <$> as)
            )
    lookupUDefUnsafe :: UninfProg -> L.Ident -> UninfDefinition
    lookupUDefUnsafe (UninfProg udefs) sname =
      case find (\(UninfDefinition name _ _) -> name == sname) udefs of
        Nothing -> error "A global definition wasn't found."
        Just a -> a

mkInfExprTree :: [Definition] -> UninfDefinition -> Either STypeError TypedExpr
mkInfExprTree defs udef =
  execState (mkTyExprTreeS defs udef) (InferEnv 1 (ReconcileEnv []) [])

mkTyExprTreeS ::
  [Definition] ->
  UninfDefinition ->
  State InferEnv (Either STypeError TypedExpr)
mkTyExprTreeS defs udef = do
  itypE <- infFromExprS defs (udefExpr udef)
  case itypE of
    Left e -> return $ Left e
    Right (ityp, _) -> do
      InferEnv _ _ globs <- get
      case lookup (udefName udef) globs of
        Nothing -> do
          let infExpr = InfExpr (udefExpr udef) $ mkNormType ityp
          return $ addWish udef infExpr
        Just _ -> do
          defTyp <- getTypeOfGlobal (udefName udef)
          mergedDefTypE <- reconcileTypesIS ityp defTyp
          case mergedDefTypE of
            Left e -> return $ Left e
            Right mergedDefTyp -> do
              let infExpr = InfExpr (udefExpr udef) (mkNormType mergedDefTyp)
              return $ addWish udef infExpr
  where
    addWish :: UninfDefinition -> InfExpr -> Either STypeError TypedExpr
    addWish udef' infExpr@(InfExpr _ _) = case udefWish udef' of
      Nothing -> Right $ mkTypedExprInf infExpr
      Just wish -> mkTypedExprWish infExpr wish

mkTyExprCycle ::
  [Definition] -> [UninfDefinition] -> Either STypeError [TypedExpr]
mkTyExprCycle defs udefs =
  execState (mkTyExprCycleS defs udefs) (InferEnv 1 (ReconcileEnv []) [])

mkTyExprCycleS ::
  [Definition] ->
  [UninfDefinition] ->
  State InferEnv (Either STypeError [TypedExpr])
mkTyExprCycleS defs udefs = do
  defTypDictE <- inferTypeExprCycleS defs udefs
  case defTypDictE of
    Left e -> return $ Left e
    Right defTypDict -> do
      helpedTypesE <- sequence <$> mapM helper defTypDict
      case helpedTypesE of
        Left e -> return $ Left e
        Right helpedTypes -> do
          updatedTypes <-
            mapM
              (\(ty, isW) -> (,isW) <$> updateWithSubstitutionsI ty)
              helpedTypes
          return $ zipWithM (curry makeIntoTyExpr) udefs updatedTypes
  where
    helper ::
      (UninfDefinition, Type) ->
      State InferEnv (Either STypeError (Type, Bool))
    helper (udef, infTyp) = do
      infTyp' <- updateWithSubstitutionsI infTyp
      case udefWish udef of
        Nothing -> return $ Right (infTyp', False)
        Just wTyp -> do
          case checkType (mkMutExcTy2 wTyp (mkNormType infTyp')) of
            Left e -> return $ Left e
            Right _ -> do
              wTyp' <- shiftNewIds wTyp
              recTypE <- reconcileTypesIS wTyp' infTyp'
              case recTypE of
                Left e -> error $ "Reconcile after check failed" ++ show e
                Right _ -> return $ Right (wTyp', True)
    makeIntoTyExpr ::
      (UninfDefinition, (Type, Bool)) -> Either STypeError TypedExpr
    makeIntoTyExpr (udef, (typ, isWish)) =
      if isWish
        then Right $ mkTypedExprInf (InfExpr (udefExpr udef) (mkNormType typ))
        else
          mkTypedExprWish
            (InfExpr (udefExpr udef) (mkNormType typ))
            (mkNormType typ)

inferTypeExprCycleS ::
  [Definition] ->
  [UninfDefinition] ->
  State InferEnv (Either STypeError [(UninfDefinition, Type)])
inferTypeExprCycleS _ [] = return $ Right []
inferTypeExprCycleS defs (udef : udefs) = do
  infTypE <- infFromExprS defs (udefExpr udef)
  case infTypE of
    Left e -> return $ Left e
    Right (ityp, _) -> do
      selfTyp <- getTypeOfGlobal (udefName udef)
      selfRecE <- reconcileTypesIS ityp selfTyp
      case selfRecE of
        Left e -> return $ Left e
        Right ityp' -> do
          nextsE <- inferTypeExprCycleS defs udefs
          case nextsE of
            Left e -> return $ Left e
            Right nexts -> do
              ityp'' <- updateWithSubstitutionsI ityp'
              return $ Right $ (udef, ityp'') : nexts

infFromExprS ::
  [Definition] ->
  Expression ->
  State InferEnv (Either STypeError (Type, [Type]))
infFromExprS _ (Lit (Y.IntegerLiteral _)) =
  return $ Right (AtomicType AInt, [])
infFromExprS _ (Ident ident') = do
  (generics, lastGeneric) <- createGenericList ident'
  return $ Right (lastGeneric, generics)
infFromExprS defs (Ref refName) = do
  case lookupRefType defs refName of
    Nothing -> do
      globTyp <- getTypeOfGlobal refName
      return $ Right (globTyp, [])
    Just typ -> do
      shifted <- shiftNewIds typ
      return $ Right (shifted, [])
infFromExprS parts (Lambda _ expr) = do
  inferred <- infFromExprS parts expr
  case inferred of
    Left e -> return $ Left e
    Right (exprType, exprGenerics) -> do
      case exprGenerics of
        [] -> do
          paramId <- getNewId
          return $ Right (FunctionType (GenericType paramId) exprType, [])
        (paramType : otherGenerics) -> do
          return $ Right (FunctionType paramType exprType, otherGenerics)
infFromExprS parts (Application expr1 expr2) = do
  inferred1 <- infFromExprS parts expr1
  inferred2 <- infFromExprS parts expr2
  case (inferred1, inferred2) of
    (Left e, _) -> return $ Left e
    (_, Left e) -> return $ Left e
    (Right (expr1Type, expr1Generics), Right (expr2Type, expr2Generics)) -> do
      newGenericsM <-
        sequence
          <$> forgivingZipWithME reconcileTypesIS expr1Generics expr2Generics
      case newGenericsM of
        Left e -> return $ Left e
        Right newGenerics -> do
          updatedExpr1Type <- updateWithSubstitutionsI expr1Type
          case updatedExpr1Type of
            FunctionType paramType returnType -> do
              updatedExpr2Type <- updateWithSubstitutionsI expr2Type
              updatedParam <- updateWithSubstitutionsI paramType
              reconciledParamM <- 
                reconcileTypesIS updatedParam updatedExpr2Type
              case reconciledParamM of
                Left e -> return $ Left e
                Right _ -> do
                  updatedReturn <- updateWithSubstitutionsI returnType
                  updatedGenerics <- mapM updateWithSubstitutionsI newGenerics
                  return $ Right (updatedReturn, updatedGenerics)
            GenericType genericId -> do
              updatedExpr2Type <- updateWithSubstitutionsI expr2Type
              newReturnId <- getNewId
              addingWorked <-
                addNewSubstitutionI
                  genericId
                  (FunctionType updatedExpr2Type (GenericType newReturnId))
              case addingWorked of
                Left e -> return $ Left e
                Right _ -> do
                  updatedGenerics <- mapM updateWithSubstitutionsI newGenerics
                  return $ Right (GenericType newReturnId, updatedGenerics)
            typ -> return $ Left $ STApplyingToANonFunction $ show typ

lookupRefType :: [Definition] -> L.Ident -> Maybe NormType
lookupRefType parts refName =
  find
    ( \(Definition name _) -> name == refName
    )
    parts
    >>= ( \case
            (Definition _ (WishTyExpr _ wtyp)) -> Just wtyp
            (Definition _ (InfTyExpr infExpr)) -> Just (ieType infExpr)
        )

mkProgramFromSyn :: Y.Program -> Either CompilerError Program
mkProgramFromSyn syn =
  first (SemanticError . STypeError) . mkProgram
    =<< first SemanticError . mkProgInfDeps
    =<< mkUninfProg syn

mkTypedExprInf :: InfExpr -> TypedExpr
mkTypedExprInf = InfTyExpr

mkTypedExprWish :: InfExpr -> NormType -> Either STypeError TypedExpr
mkTypedExprWish infExpr typ =
  WishTyExpr (ieExpr infExpr) typ
    <$ checkType (mkMutExcTy2 typ (ieType infExpr))
