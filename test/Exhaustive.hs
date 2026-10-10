{-# LANGUAGE OverloadedStrings #-}

-- | A from-scratch sweep of every (mode, command, document) shape the
-- editor can be in, forcing each result to normal form. It proves
-- nothing about behaviour; it proves that nothing anywhere throws, and
-- it needs no test framework to say so.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM)

import qualified Basilisk.Document as Doc
import Basilisk.Step (step)
import Basilisk.Types

documents :: [Doc.Document]
documents = map Doc.fromText
  [ "", "x", "hello world", "a\nb\nc", "\n\n", "first\nsecond\nthird"
  , "one two three\nfour", "\28450\23383 wide\nplain", "  leading", "trailing  "
  -- every class that has broken a terminal editor
  , "e\769x\769", "\128104\8205\128105 family", "\127462\127463 flag"
  , "\ta\tb", "esc\ESChere", "nul\NULhere", "cr\rhere", "\8205leading joiner" ]

modes :: [Mode]
modes = [ Normal, Insert Fresh, Insert Dirty
        , Replace [], Replace [Nothing], Replace [Just "a"], Replace [Just "\n", Just "x", Nothing]
        , Prompt ExCommand "", Prompt ExCommand "q", Prompt ExCommand "w", Prompt Search "x" ]

motions :: [Motion]
motions = [ MChar DUp, MChar DDown, MChar DLeft, MChar DRight, MWord, MWordBack, MWordEnd
          , MLine, MLineStart, MFirstNonBlank, MLineEnd, MGotoLine
          , MTo False False 'e', MTo True True 'a', MBigWord False, MBigWord True
          , MParagraph False, MParagraph True, MMatch, MColumn ]

actions :: [Action]
actions =
  [ InNormal c | c <- concat
      [ [NMove n m | n <- [0, 1, 7], m <- motions]
      , [NOperate n o m | n <- [1, 7], o <- [Delete, Yank, Change, ToLower, ToUpper, ToggleCase, Indent, Dedent], m <- motions]
      , [NEnterInsert n a | n <- [1, 3], a <- [Before, After, LineBelow, LineAbove]]
      , [NEnterPrompt k | k <- [ExCommand, Search]]
      , [NMove n m | n <- [maxBound, minBound], m <- [MChar DRight, MWord, MLine]]
      , [NOperate maxBound o m | o <- [Delete, ToggleCase, Indent, Dedent], m <- motions]
      , [NReplace n c | n <- [0, 1, 3, maxBound, minBound], c <- ['x', '\769']]
      , [NPaste 0 True, NPaste 2 False, NPasteText "", NPasteText "p\nq", NPasteText "\769"
        , NUndo 0, NUndo 3, NUndo maxBound, NUndo minBound, NRedo 3, NRedo minBound, NRepeat 1, NRepeat 3
        , NRepeatFind 1 False, NRepeatFind 1 True, NRepeatFind maxBound False
        , NRepeatTo 1 False, NRepeatTo 1 True, NRepeatTo maxBound False, NRepeatTo minBound True
        , NSave, NWriteQuit, NQuitDiscard, NEnterReplace] ] ]
  ++ [InInsert c | c <- [IInput "", IInput "z", IInput "\n", IInput "\769", IInput "\t", IInput "a\nb"
                        , IInput "ab\ncd", IInput "x"
                        , IBackspace, IMove DUp, IMove DDown, IMove DLeft, IMove DRight, IEscape]]
  ++ [InPrompt c | c <- [PInput "", PInput "w", PBackspace, PSubmit, PEscape]]

main :: IO ()
main = do
  let editors = [ withDocument d ((newEditor p "") { mode = m, register = r })
                | d <- documents, m <- modes, p <- [Nothing, Just "o.txt"], r <- [Nothing, Just (Clip False "reg"), Just (Clip True "reg\ntext")] ]
  outcomes <- forM editors (\e -> forM actions (once e))
  putStrLn (show (sum (map length outcomes)) <> " (mode, command, document) combinations exercised, 0 exceptions.")
  where
    once e a = do
      r <- try (evaluate (force (step a e))) :: IO (Either SomeException (Editor, [Effect]))
      either (\ex -> ioError (userError (show a <> ": " <> show ex))) (const (pure ())) r
