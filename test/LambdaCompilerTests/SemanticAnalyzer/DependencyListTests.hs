module LambdaCompilerTests.SemanticAnalyzer.DependencyListTests (spec) where

import Data.Array
import Data.List (intercalate)
import SemanticAnalyzer.DependencyList.Internal
import Test.Hspec
import Test.QuickCheck
import Util

spec :: Spec
spec = do
    describe "DependencyList" $ do
        it "contains elements exactly once" $
            property (\(ArbList (DependencyList as) _ _) -> hasNoDups $ arrayify as)
        it "contains relsize number of elements" $
            property
                ( \(ArbList (DependencyList as) size _) ->
                    length (arrayify as) == size
                )
        it "'s elements don't depend on ones coming after them" $
            property
                ( \(ArbList (DependencyList as) _ depf) ->
                    let dependsOn = dependsFn depf
                     in fst $
                            foldr
                                ( \item (good, arr) ->
                                    if good && not (any (item `dependsOn`) arr)
                                        then (True, item : arr)
                                        else (False, arr)
                                )
                                (True, [])
                                as
                )
        describe "DependencyMatrix" $ do
            it "can build a dependency matrix on a graph with no cycles" $ do
                dmMatrix (mkDependencyMatrix ['A' .. 'E'] testConns1)
                    `shouldBe` array
                        ((1, 1), (5, 5))
                        [ ((i, j), returnArr !! (i - 1) !! (j - 1) == 1)
                        | i <- [1 .. 5]
                        , j <- [1 .. 5]
                        ]
            it "can build a dependency matrix on a graph with one cycle" $ do
                mkDependencyMatrix "ABCDE" testConns2
                    `shouldBe` DependencyMatrix 
                        [DepListCycle "EDCAB"]
                        (array ((1, 1), (1, 1)) [((1, 1), True)])
            it "can find a proper ordering on a grap with one cycle" $ do
                createOrdering (mkDependencyMatrix "ABCDE" testConns3)
                    `shouldBe` DependencyList 
                        [DepListCycle "EBC"
                        , DepListSingle 'D'
                        , DepListSingle 'A'
                        ]
                

testConns1 :: Char -> Char -> Bool
testConns1 'A' 'D' = True
testConns1 'D' 'B' = True
testConns1 'B' 'C' = True
testConns1 'C' 'E' = True
testConns1 _ _ = False

testConns2 :: Char -> Char -> Bool
testConns2 'A' 'D' = True
testConns2 'D' 'B' = True
testConns2 'B' 'C' = True
testConns2 'C' 'E' = True
testConns2 'E' 'A' = True
testConns2 _ _ = False

testConns3 :: Char -> Char -> Bool
testConns3 'A' 'D' = True
testConns3 'D' 'B' = True
testConns3 'B' 'C' = True
testConns3 'C' 'E' = True
testConns3 'E' 'B' = True
testConns3 _ _ = False

{- FOURMOLU_DISABLE -}
returnArr :: [[Int]]
returnArr =
    [ [1, 1, 1, 1, 1]
    , [0, 1, 1, 0, 1]
    , [0, 0, 1, 0, 1]
    , [0, 1, 1, 1, 1]
    , [0, 0, 0, 0, 1]
    ]
{- FOURMOLU_ENABLE -}

data ArbList = ArbList (DependencyList Int) Int (Int -> [Int])

instance Show ArbList where
    show (ArbList dpList size depf) =
        show dpList
            ++ " > "
            ++ show size
            ++ "\n"
            ++ showdepf depf size

showdepf :: (Int -> [Int]) -> Int -> String
showdepf depf size =
    intercalate "\n" $
        map (\a -> show a ++ ": " ++ show (depf a)) [1 .. size]

instance Arbitrary ArbList where
    arbitrary = do
        relsize <- (+ 10) . (`mod` 100) . abs <$> arbitrary
        relsizesq <- (`mod` (relsize * relsize)) . (+ relsize) . abs <$> arbitrary
        outside <- (`mod` 10) <$> arbitrary
        let conform = (+ 1) . (`mod` (relsize + outside - 1))
        rel <- take relsizesq . map (fstMap conform . sndMap conform) <$> arbitrary
        let depf a' =
                foldr
                    (\(a, b) acc -> if a == a' then b : acc else if b == a' then a : acc else acc)
                    []
                    rel
        return $ ArbList (mkDependencyList [1 .. relsize] depf) relsize depf

arrayify :: [DependencyListItem a] -> [a]
arrayify [] = []
arrayify ((DepListSingle a) : as) = a : arrayify as
arrayify ((DepListCycle as) : bs) = as ++ arrayify bs

hasNoDups :: (Eq a) => [a] -> Bool
hasNoDups [] = True
hasNoDups (a : as)
    | a `elem` as = False
    | otherwise = hasNoDups as
