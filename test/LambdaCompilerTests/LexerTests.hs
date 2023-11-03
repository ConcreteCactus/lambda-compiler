module LambdaCompilerTests.LexerTests (spec) where

import Control.Monad
import Lexer.Internal
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "block" $ do
    it "can parse the same number of blocks" $ do
      property
        ( \(LexicallySaneCode src' blockCount') ->
            length (runParser (many block) src') == blockCount'
        )

data LexicallySaneCode = Lsc
  { src :: String,
    blockCount :: Int
  }

instance Arbitrary LexicallySaneCode where
  arbitrary = do
    NonNegative blockCount' <- arbitrary
    statements <- replicateM blockCount' $ do
      NonNegative spaceBeforeCount <- arbitrary
      spacingBefore <- replicateM spaceBeforeCount $ do
        ind <- (`mod` 4) . abs <$> arbitrary
        return $ "\n\r \t" !! ind
      let spacingBefore' = spacingBefore ++ "\n"
      NonNegative spaceAfterCount <- arbitrary
      spacingAfter <- replicateM spaceAfterCount $ do
        ind <- (`mod` 4) . abs <$> arbitrary
        return $ "\n\r \t" !! ind
      Positive firstLineLength <- arbitrary
      let firstLine = replicate firstLineLength 'a'
      NonNegative followingLineCount <- arbitrary
      followingLines <- replicateM followingLineCount $ do
        NonNegative spaceCount <- arbitrary
        spaces <- replicateM spaceCount $ do
          ind <- (`mod` 4) . abs <$> arbitrary
          return $ "\n\r\t " !! ind
        let spaces' = spaces ++ " "
        Positive lineLength <- arbitrary
        let line = replicate lineLength 'a'
        return $ spaces' ++ line
      return $
        spacingBefore'
          ++ firstLine
          ++ "\n"
          ++ unlines followingLines
          ++ spacingAfter
    return $ Lsc (concat statements) blockCount'