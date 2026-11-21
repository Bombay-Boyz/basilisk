{-# LANGUAGE OverloadedStrings #-}

-- | Argument handling, and nothing else. Reject unknown options and pass
-- one positional path to the editor.
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
dispatch args = case parseArguments args of
  Left problem -> hPutStrLn stderr ("basilisk: " <> problem) >> exitFailure
  Right ShowHelp -> usage >>= putStrLn >> exitSuccess
  Right ShowVersion -> putStrLn ("basilisk " <> showVersion version) >> exitSuccess
  Right (Edit path) -> run path

data Action = ShowHelp | ShowVersion | Edit (Maybe FilePath)

parseArguments :: [String] -> Either String Action
parseArguments ["-h"] = Right ShowHelp
parseArguments ["--help"] = Right ShowHelp
parseArguments ["-v"] = Right ShowVersion
parseArguments ["--version"] = Right ShowVersion
parseArguments args = do
  paths <- collect False [] args
  case paths of
    [] -> Right (Edit Nothing)
    [path] -> Right (Edit (Just path))
    _ -> Left "one file at a time; multiple buffers are not implemented"
 where
  collect _ paths [] = Right (reverse paths)
  collect True paths remaining = Right (reverse paths <> remaining)
  collect False paths ("--" : remaining) = collect True paths remaining
  collect False paths (arg : remaining)
    | arg `elem` ["-h", "--help", "-v", "--version"] =
        Left (arg <> " must be used by itself")
    | isOption arg = Left ("unknown option: " <> arg)
    | otherwise = collect False (arg : paths) remaining
  isOption arg = take 1 arg == "-" && arg /= "-"

usage :: IO String
usage = do
  me <- getProgName
  pure (unlines
    [ "usage: " <> me <> " [file]"
    , "       " <> me <> " -- [file]"
    , ""
    , "A modal terminal text editor for Haskell, in Haskell."
    , ""
    , "  -h, --help     show this and exit"
    , "  -v, --version  show the version and exit"
    , "  --             end options (for a filename beginning with -)"
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
