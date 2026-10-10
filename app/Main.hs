{-# LANGUAGE OverloadedStrings #-}

-- | Argument handling, and nothing else. Anything that is not a flag
-- is the file to edit.
module Main (main) where

import Data.Version (showVersion)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import Basilisk.Loop (run)
import Paths_Basilisk (version)

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch args
  | any (`elem` ["-h", "--help"]) args    = usage >>= putStrLn >> exitSuccess
  | any (`elem` ["-v", "--version"]) args = putStrLn ("basilisk " <> showVersion version) >> exitSuccess
  | otherwise = case filter (not . isFlag) args of
      []    -> run Nothing
      [f]   -> run (Just f)
      _ : _ -> do
        hPutStrLn stderr "basilisk: one file at a time; multiple buffers are not implemented"
        exitFailure
  where isFlag a = take 1 a == "-" && a /= "-"

usage :: IO String
usage = do
  me <- getProgName
  pure (unlines
    [ "usage: " <> me <> " [file]"
    , ""
    , "A modal terminal text editor for Haskell, in Haskell."
    , ""
    , "  -h, --help     show this and exit"
    , "  -v, --version  show the version and exit"
    , ""
    , "keys"
    , "  motions    h j k l  w b e  W B  0 ^ $  gg G"
    , "  find-char  f t F T <char>, ; to repeat, , to reverse it"
    , "  other      { } (paragraph)  % (matching bracket)  | (column)"
    , "  search     / then Enter, n to repeat, N to reverse"
    , "  operators  d y c    doubled for a whole line (dd yy cc)"
    , "  edits      x X D C s S  J  p P  u  Ctrl-R  . (repeat last change)"
    , "  insert     i a o O, Escape to leave"
    , "  commands   :w  :w!  :q  :q!  :wq"
    , ""
    , "Counts prefix a command: 3dw, 5j, 2d3w."
    , ""
    , "Quitting with unsaved changes is refused; :q! overrides."
    , "Writing over a file that changed on disk is refused; :w! overrides."
    ])
