{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Basilisk.Document qualified as Doc
import Basilisk.Loop (perform)
import Basilisk.Step (step)
import Basilisk.Types

main :: IO ()
main = do
  withSystemTempDirectory "basilisk-formatter" $ \dir -> do
    let hs = dir </> "Main.hs"
        lhs = dir </> "Literate.lhs"
        latex = dir </> "Latex.lhs"
        markdown = dir </> "notes.md"
        broken = dir </> "Broken.hs"
        editor file source = newEditor (Just file) source
        write file source = perform (editor file source, False) (WriteFile file source False False)
        writeQuit file source = perform (editor file source, False) (WriteFile file source False True)
    Text.writeFile
      (dir </> "formatter.cabal")
      "cabal-version: 3.0\nname: formatter-fixture\nversion: 0.1.0.0\nbuild-type: Simple\nlibrary\n  hs-source-dirs: .\n  exposed-modules: Main\n  default-language: GHC2021\n  default-extensions: RankNTypes\n  build-depends: base\n"
    (formatted, _) <- write hs "module Main where\n\nanswer=42\n\napply :: (forall a. a -> a) -> Int\napply f = f 1"
    check ("Haskell is formatted before it is written: " <> show (status formatted)) (status formatted == Just "written")
    savedHaskell <- Text.readFile hs
    check "the formatted source is the persisted source" ("answer = 42" `Text.isInfixOf` savedHaskell)
    check "Cabal default extensions are used by the formatter" ("apply :: (forall a. a -> a) -> Int" `Text.isInfixOf` savedHaskell)
    check
      "the formatted buffer is clean and undoable"
      ( not (modified formatted)
          && "answer = 42" `Text.isInfixOf` Doc.toText (document formatted)
          && "answer=42" `Text.isInfixOf` Doc.toText (document (fst (step (InNormal (NUndo 1)) formatted)))
      )
    (literate, _) <- write lhs "Literate Haskell.\n> module Literate where\n>\n> value=7"
    literateExists <- doesFileExist lhs
    check ("literate Haskell file exists after save: " <> show (status literate)) literateExists
    savedLiterate <- Text.readFile lhs
    check
      "literate Haskell prose is preserved and code formatted on save"
      ( status literate == Just "written"
          && "Literate Haskell." `Text.isPrefixOf` savedLiterate
          && "value = 7" `Text.isInfixOf` savedLiterate
      )
    (latexFormatted, _) <- write latex "Literate prose.\n\\begin{code}\nmodule Latex where\nvalue=8\n\\end{code}"
    savedLatex <- Text.readFile latex
    check
      "LaTeX literate Haskell is preserved and formatted"
      ( status latexFormatted == Just "written"
          && "Literate prose." `Text.isPrefixOf` savedLatex
          && "\\begin{code}" `Text.isInfixOf` savedLatex
          && "value = 8" `Text.isInfixOf` savedLatex
      )
    (plain, _) <- write markdown "#title\ntext  with   spaces"
    savedMarkdown <- Text.readFile markdown
    check "Markdown is saved without formatting" (status plain == Just "written" && savedMarkdown == "#title\ntext  with   spaces")
    (rejected, quitRequested) <- writeQuit broken "module Broken where\nvalue ="
    exists <- doesFileExist broken
    check
      "invalid Haskell is not written or quit"
      ( not exists
          && not quitRequested
          && maybe False (Text.isPrefixOf "format failed:") (status rejected)
      )
  putStrLn "Haskell save formatter integration checks passed."

check :: String -> Bool -> IO ()
check label condition = unless condition (fail ("FAILED: " <> label))
