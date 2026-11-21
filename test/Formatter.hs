{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Control.Exception (bracket_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import System.Directory (createDirectory, doesFileExist, renameFile)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Posix.Files (accessTimeHiRes, getFileStatus, modificationTimeHiRes, setFileTimesHiRes)

import Basilisk.Document qualified as Doc
import Basilisk.File qualified as File
import Basilisk.Loop (perform, performWith)
import Basilisk.Step (step)
import Basilisk.Types

main :: IO ()
main = do
  withSystemTempDirectory "basilisk-formatter" $ \dir -> do
    let hs = dir </> "Main.hs"
        semanticHs = dir </> "Semantic.hs"
        semanticBeforeDir = dir </> "semantic-before"
        semanticAfterDir = dir </> "semantic-after"
        cppHs = dir </> "Cpp.hs"
        cppBeforeTrueDir = dir </> "cpp-before-true"
        cppBeforeFalseDir = dir </> "cpp-before-false"
        cppAfterTrueDir = dir </> "cpp-after-true"
        cppAfterFalseDir = dir </> "cpp-after-false"
        lhs = dir </> "Literate.lhs"
        latex = dir </> "Latex.lhs"
        birdEdge = dir </> "BirdEdge.lhs"
        latexRegions = dir </> "LatexRegions.lhs"
        emptyLiterate = dir </> "Empty.lhs"
        brokenLiterate = dir </> "BrokenLiterate.lhs"
        brokenLatex = dir </> "BrokenLatex.lhs"
        nestedLatex = dir </> "NestedLatex.lhs"
        malformedLatex = dir </> "MalformedLatex.lhs"
        mixedLiterate = dir </> "MixedEol.lhs"
        markdown = dir </> "notes.md"
        broken = dir </> "Broken.hs"
        syncFailure = dir </> "sync-failure.txt"
        sameTime = dir </> "same-time.txt"
        replacedPath = dir </> "replaced.txt"
        replacement = dir </> "replacement.tmp"
        raced = dir </> "raced.txt"
        twoSpaceDir = dir </> "two-space"
        badConfigDir = dir </> "bad-config"
        xdgDir = dir </> "xdg"
        editor file source = newEditor (Just file) source
        write file source = perform (editor file source, False) (WriteFile file source False False)
        writeQuit file source = perform (editor file source, False) (WriteFile file source False True)
    Text.writeFile (dir </> "fourmolu.yaml") "indentation: 4\n"
    createDirectory xdgDir
    Text.writeFile (xdgDir </> "fourmolu.yaml") "indentation: 6\n"
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
    let semanticSource =
          "module Main where\n\n-- import comment stays with the import\nimport Data.Maybe (fromMaybe)\n\ninfixr 5 <+>\n\ndata Expr = A | B | C | Join Expr Expr deriving Show\n\n-- This operator is intentionally right associative.\n(<+>) :: Expr -> Expr -> Expr\n(<+>) = Join\n\nchain = A <+> B <+> C\n\nmain = print (fromMaybe chain (Just chain))"
    Text.writeFile semanticHs semanticSource
    createDirectory semanticBeforeDir
    (compileBefore, _, compileBeforeError) <-
      readProcessWithExitCode "ghc" ["-v0", "-outputdir", semanticBeforeDir, "-o", semanticBeforeDir </> "semantic", semanticHs] ""
    check ("the semantic fixture compiles before formatting: " <> compileBeforeError) (compileBefore == ExitSuccess)
    (runBefore, semanticOutputBefore, runBeforeError) <-
      readProcessWithExitCode (semanticBeforeDir </> "semantic") [] ""
    check ("the semantic fixture runs before formatting: " <> runBeforeError) (runBefore == ExitSuccess)
    semanticEditor <- File.openFile semanticHs
    (semanticFormatted, _) <-
      perform (semanticEditor, False)
        (WriteFile semanticHs (Doc.toText (document semanticEditor)) False False)
    semanticBytes <- Text.readFile semanticHs
    check
      "formatting preserves a custom fixity declaration and surrounding comments"
      ( status semanticFormatted == Just "written"
          && "-- import comment stays with the import" `Text.isInfixOf` semanticBytes
          && "-- This operator is intentionally right associative." `Text.isInfixOf` semanticBytes
          && "infixr 5 <+>" `Text.isInfixOf` semanticBytes
          && "chain = A <+> B <+> C" `Text.isInfixOf` semanticBytes
      )
    createDirectory semanticAfterDir
    (compileAfter, _, compileAfterError) <-
      readProcessWithExitCode "ghc" ["-v0", "-outputdir", semanticAfterDir, "-o", semanticAfterDir </> "semantic", semanticHs] ""
    check ("the formatted semantic fixture compiles: " <> compileAfterError) (compileAfter == ExitSuccess)
    (runAfter, semanticOutputAfter, runAfterError) <-
      readProcessWithExitCode (semanticAfterDir </> "semantic") [] ""
    check ("the formatted semantic fixture runs: " <> runAfterError) (runAfter == ExitSuccess)
    check "formatting preserves the fixture's evaluated custom-fixity result" (semanticOutputBefore == semanticOutputAfter)
    check "the fixture exercises right associativity" (semanticOutputBefore == "Join A (Join B C)\n")
    let undoBeforeRepeat = fst (step (InNormal (NUndo 1)) semanticFormatted)
    (repeatedFormat, _) <-
      perform
        (semanticFormatted, False)
        (WriteFile semanticHs (Doc.toText (document semanticFormatted)) False False)
    repeatedSemanticBytes <- Text.readFile semanticHs
    let undoAfterRepeat = fst (step (InNormal (NUndo 1)) repeatedFormat)
    check
      "repeated formatting is byte-idempotent and does not add a history change"
      ( status repeatedFormat == Just "written"
          && semanticBytes == repeatedSemanticBytes
          && version semanticFormatted == version repeatedFormat
          && Doc.toText (document undoBeforeRepeat) == Doc.toText (document undoAfterRepeat)
          && not (modified repeatedFormat)
      )
    let cppSource =
          "{-# LANGUAGE CPP #-}\nmodule Main where\n\n#ifdef BASILISK_TRUE\nimport Data.List (intercalate)\n#else\nimport Data.Char (ord)\n#endif\n\nmain = print answer\n\n#ifdef BASILISK_TRUE\nselected :: [String]\nselected = [\"4\", \"2\"]\nanswer = read (intercalate \"\" selected) :: Int\n#else\nselected :: Char\nselected = 'G'\nanswer = ord selected\n#endif"
    Text.writeFile cppHs cppSource
    (cppBeforeTrue, cppOutputBeforeTrue, cppErrorBeforeTrue) <-
      compileAndRun cppBeforeTrueDir cppHs ["-cpp", "-DBASILISK_TRUE"]
    (cppBeforeFalse, cppOutputBeforeFalse, cppErrorBeforeFalse) <-
      compileAndRun cppBeforeFalseDir cppHs ["-cpp"]
    check ("the CPP fixture's true branch compiles before formatting: " <> cppErrorBeforeTrue) (cppBeforeTrue == ExitSuccess)
    check ("the CPP fixture's false branch compiles before formatting: " <> cppErrorBeforeFalse) (cppBeforeFalse == ExitSuccess)
    check "the CPP fixture starts with the expected branch results" (cppOutputBeforeTrue == "42\n" && cppOutputBeforeFalse == "71\n")
    cppEditor <- File.openFile cppHs
    (cppFormatted, _) <-
      perform (cppEditor, False)
        (WriteFile cppHs (Doc.toText (document cppEditor)) False False)
    cppBytes <- Text.readFile cppHs
    (cppAfterTrue, cppOutputAfterTrue, cppErrorAfterTrue) <-
      compileAndRun cppAfterTrueDir cppHs ["-cpp", "-DBASILISK_TRUE"]
    (cppAfterFalse, cppOutputAfterFalse, cppErrorAfterFalse) <-
      compileAndRun cppAfterFalseDir cppHs ["-cpp"]
    check
      "formatting preserves the CPP source and both conditional branches"
      ( status cppFormatted == Just "written"
          && "#ifdef BASILISK_TRUE" `Text.isInfixOf` cppBytes
          && "#else" `Text.isInfixOf` cppBytes
          && "#endif" `Text.isInfixOf` cppBytes
          && "import Data.List (intercalate)" `Text.isInfixOf` cppBytes
          && "import Data.Char (ord)" `Text.isInfixOf` cppBytes
          && "selected :: [String]" `Text.isInfixOf` cppBytes
          && "selected :: Char" `Text.isInfixOf` cppBytes
          && cppAfterTrue == ExitSuccess
          && cppAfterFalse == ExitSuccess
          && cppErrorAfterTrue == ""
          && cppErrorAfterFalse == ""
          && cppOutputAfterTrue == cppOutputBeforeTrue
          && cppOutputAfterFalse == cppOutputBeforeFalse
      )
    createDirectory twoSpaceDir
    Text.writeFile (twoSpaceDir </> "fourmolu.yaml") "indentation: 2\n"
    let configuredSource = "module Configured where\nmain = do\nputStrLn \"one\"\nputStrLn \"two\""
        configuredFile = twoSpaceDir </> "Configured.hs"
    (configured, _) <- write configuredFile configuredSource
    savedConfigured <- Text.readFile configuredFile
    check
      "the nearest project fourmolu.yaml controls formatting"
      ( status configured == Just "written"
          && "  putStrLn \"one\"" `Text.isInfixOf` savedConfigured
          && not ("    putStrLn \"one\"" `Text.isInfixOf` savedConfigured)
      )
    withSystemTempDirectory "basilisk-xdg-config" $ \xdgProject -> do
      previousXdg <- lookupEnv "XDG_CONFIG_HOME"
      let restoreXdg = maybe (unsetEnv "XDG_CONFIG_HOME") (setEnv "XDG_CONFIG_HOME") previousXdg
          xdgFile = xdgProject </> "XdgConfig.hs"
      bracket_ (setEnv "XDG_CONFIG_HOME" xdgDir) restoreXdg $ do
        (xdgFormatted, _) <- write xdgFile "module XdgConfig where\nmain = do\nputStrLn \"one\""
        xdgSaved <- Text.readFile xdgFile
        check
          "the user XDG fourmolu.yaml is used when no project config exists"
          ( status xdgFormatted == Just "written"
              && "      putStrLn \"one\"" `Text.isInfixOf` xdgSaved
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
    Text.writeFile birdEdge "Bird prose.\r\n  indented prose.\r\n-- BASILISK_INTERNAL_LITERATE_0_00000000\r\n\r\n> module BirdEdge where\r\n>\r\n> value=9"
    birdEditor <- File.openFile birdEdge
    (birdWritten, _) <- perform (birdEditor, False) (WriteFile birdEdge (Doc.toText (document birdEditor)) False False)
    savedBirdEdge <- Text.readFile birdEdge
    check
      "Bird files preserve prose, blank code lines, CRLF, and a missing final newline byte-for-byte around formatted code"
      ( status birdWritten == Just "written"
          && savedBirdEdge == "Bird prose.\r\n  indented prose.\r\n-- BASILISK_INTERNAL_LITERATE_0_00000000\r\n\r\n> module BirdEdge where\r\n>\r\n> value = 9"
      )
    check
      "literate formatting is a single undoable buffer change"
      ( not (modified birdWritten)
          && "value = 9" `Text.isInfixOf` Doc.toText (document birdWritten)
          && "value=9" `Text.isInfixOf` Doc.toText (document (fst (step (InNormal (NUndo 1)) birdWritten)))
      )
    ByteString8.writeFile mixedLiterate "Bird prose.\r\n> module MixedEol where\n> value=10\r\n"
    mixedEditor <- File.openFile mixedLiterate
    (mixedWritten, _) <- perform (mixedEditor, False) (WriteFile mixedLiterate (Doc.toText (document mixedEditor)) False False)
    mixedBytes <- ByteString.readFile mixedLiterate
    check
      "mixed line endings on literate input preserve existing terminators and the final-EOL flag"
      ( status mixedWritten == Just "written"
          && mixedBytes == "Bird prose.\r\n> module MixedEol where\n>\r\n> value = 10\r\n"
      )
    Text.writeFile latexRegions "LaTeX prose.\n\\begin{code}\nmodule Regions where\nfirst=1\n\\end{code}\ninter-region prose.\n\\begin{code}\nsecond=2\n\\end{code}\n"
    regionsEditor <- File.openFile latexRegions
    (regionsWritten, _) <- perform (regionsEditor, False) (WriteFile latexRegions (Doc.toText (document regionsEditor)) False False)
    savedRegions <- Text.readFile latexRegions
    check
      "multiple LaTeX code regions retain delimiters and intervening prose in complete output"
      ( status regionsWritten == Just "written"
          && savedRegions == "LaTeX prose.\n\\begin{code}\nmodule Regions where\n\nfirst = 1\n\n\\end{code}\ninter-region prose.\n\\begin{code}\nsecond = 2\n\n\\end{code}\n"
      )
    Text.writeFile emptyLiterate ""
    emptyEditor <- File.openFile emptyLiterate
    (emptyWritten, _) <- perform (emptyEditor, False) (WriteFile emptyLiterate (Doc.toText (document emptyEditor)) False False)
    emptyBytes <- Text.readFile emptyLiterate
    check "an empty literate file remains empty after save" (status emptyWritten == Just "written" && Text.null emptyBytes)
    let brokenLiterateSource = "> module BrokenLiterate where\n> value =\n"
    Text.writeFile brokenLiterate brokenLiterateSource
    brokenLiterateEditor <- File.openFile brokenLiterate
    (badLiterate, badLiterateQuit) <-
      perform (brokenLiterateEditor, False)
        (WriteFile brokenLiterate (Doc.toText (document brokenLiterateEditor)) False True)
    savedBrokenLiterate <- Text.readFile brokenLiterate
    check
      "a parse failure in Bird code preserves the original file and does not quit"
      ( savedBrokenLiterate == brokenLiterateSource
          && not badLiterateQuit
          && Doc.toText (document badLiterate) == Text.dropEnd 1 brokenLiterateSource
          && maybe False (Text.isPrefixOf "format failed:") (status badLiterate)
      )
    let brokenLatexSource = "LaTeX prose.\n\\begin{code}\nmodule BrokenLatex where\nanswer=1"
    Text.writeFile brokenLatex brokenLatexSource
    brokenLatexEditor <- File.openFile brokenLatex
    (badLatex, badLatexQuit) <-
      perform (brokenLatexEditor, False)
        (WriteFile brokenLatex (Doc.toText (document brokenLatexEditor)) False True)
    savedBrokenLatex <- Text.readFile brokenLatex
    check
      "an unterminated LaTeX code environment preserves the original file and does not quit"
      ( savedBrokenLatex == brokenLatexSource
          && not badLatexQuit
          && Doc.toText (document badLatex) == brokenLatexSource
          && maybe False (\message -> "unterminated" `Text.isInfixOf` message) (status badLatex)
      )
    let nestedLatexSource = "\\begin{code}\n\\begin{code}\n\\end{code}\n\\end{code}"
    (nested, nestedQuit) <- writeQuit nestedLatex nestedLatexSource
    nestedExists <- doesFileExist nestedLatex
    check
      "nested LaTeX code environments are rejected without writing or quitting"
      ( not nestedExists
          && not nestedQuit
          && maybe False (\message -> "nested" `Text.isInfixOf` message) (status nested)
      )
    let orphanLatexPath = dir </> "OrphanLatexEnd.lhs"
        orphanLatexSource = "prose\n\\end{code}"
    (orphanLatex, orphanLatexQuit) <- writeQuit orphanLatexPath orphanLatexSource
    orphanLatexExists <- doesFileExist orphanLatexPath
    check
      "an unmatched LaTeX end marker is rejected without writing or quitting"
      ( not orphanLatexExists
          && not orphanLatexQuit
          && maybe False (\message -> "without matching" `Text.isInfixOf` message) (status orphanLatex)
      )
    let malformedLatexSource = "\\begin{code} trailing text\n\\end{code}"
    (malformed, malformedQuit) <- writeQuit malformedLatex malformedLatexSource
    malformedExists <- doesFileExist malformedLatex
    check
      "LaTeX code markers with trailing text are rejected"
      ( not malformedExists
          && not malformedQuit
          && maybe False (\message -> "own unindented line" `Text.isInfixOf` message) (status malformed)
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
          && maybe False
            (\message ->
              "format failed:" `Text.isPrefixOf` message
                && Text.pack broken `Text.isInfixOf` message
                && Text.length message <= 527
            )
            (status rejected)
      )
    createDirectory badConfigDir
    Text.writeFile (badConfigDir </> "fourmolu.yaml") "indentation: not-an-integer\n"
    let badConfigSource = badConfigDir </> "ConfigError.hs"
    (badConfig, quitAfterBadConfig) <- writeQuit badConfigSource "module ConfigError where\nanswer = 42"
    badConfigWasWritten <- doesFileExist badConfigSource
    check
      "an invalid Fourmolu config prevents writing and reports the config path"
      ( not badConfigWasWritten
          && not quitAfterBadConfig
          && maybe False (\message -> "format failed:" `Text.isPrefixOf` message && "fourmolu.yaml" `Text.isInfixOf` message) (status badConfig)
      )
    Text.writeFile sameTime "alpha"
    oldSameTimeStamp <- File.stampOf sameTime
    oldSameTimeStatus <- getFileStatus sameTime
    Text.writeFile sameTime "omega"
    setFileTimesHiRes sameTime (accessTimeHiRes oldSameTimeStatus) (modificationTimeHiRes oldSameTimeStatus)
    newSameTimeStatus <- getFileStatus sameTime
    newSameTimeStamp <- File.stampOf sameTime
    sameTimeResult <- File.writeDocument sameTime "editor" False oldSameTimeStamp
    sameTimeContents <- Text.readFile sameTime
    check
      "same-size edits with the original modification time are refused by the content fingerprint"
      ( modificationTimeHiRes oldSameTimeStatus == modificationTimeHiRes newSameTimeStatus
          && maybe False (\(old, new) -> stampSize old == stampSize new && stampModified old == stampModified new && stampDigest old /= stampDigest new) ((,) <$> oldSameTimeStamp <*> newSameTimeStamp)
          && either (Text.isPrefixOf "file changed on disk") (const False) sameTimeResult
          && sameTimeContents == "omega"
      )
    Text.writeFile replacedPath "alpha"
    oldReplacementStamp <- File.stampOf replacedPath
    Text.writeFile replacement "alpha"
    replacementStatus <- getFileStatus replacement
    setFileTimesHiRes replacement (accessTimeHiRes replacementStatus) (modificationTimeHiRes replacementStatus)
    renameFile replacement replacedPath
    replacementResult <- File.writeDocument replacedPath "editor" False oldReplacementStamp
    replacementContents <- Text.readFile replacedPath
    newReplacementStamp <- File.stampOf replacedPath
    check
      "replacing a file at the same path is detected and preserved"
      ( maybe False (\(old, new) -> stampDevice old == stampDevice new && stampFileId old /= stampFileId new) ((,) <$> oldReplacementStamp <*> newReplacementStamp)
          && either (Text.isPrefixOf "file changed on disk") (const False) replacementResult
          && replacementContents == "alpha"
      )
    Text.writeFile raced "before"
    raceStamp <- File.stampOf raced
    raceResult <-
      File.writeDocumentWith
        (const (pure ()))
        (\_ -> Text.writeFile raced "outside")
        raced
        "inside"
        False
        raceStamp
    raceContents <- Text.readFile raced
    check
      "a change during temporary-file preparation is caught at the final pre-commit check"
      ( either (Text.isPrefixOf "file changed on disk") (const False) raceResult
          && raceContents == "outside"
      )
    (afterSyncFailure, quitAfterSyncFailure) <-
      performWith
        (File.writeDocumentWith (\_ -> ioError (userError "injected sync failure")) (const (pure ())))
        (editor syncFailure "committed content", False)
        (WriteFile syncFailure "committed content" False True)
    committedBytes <- Text.readFile syncFailure
    check
      "post-rename directory-sync failure reports the committed write and cleans the buffer"
      ( committedBytes == "committed content"
          && not (modified afterSyncFailure)
          && stamp afterSyncFailure /= Nothing
          && quitAfterSyncFailure
          && maybe False (Text.isPrefixOf "written; file was written but directory sync failed:") (status afterSyncFailure)
      )
  putStrLn "Haskell save formatter integration checks passed."

check :: String -> Bool -> IO ()
check label condition = unless condition (fail ("FAILED: " <> label))

compileAndRun :: FilePath -> FilePath -> [String] -> IO (ExitCode, String, String)
compileAndRun outputDir source compilerOptions = do
  createDirectory outputDir
  let executable = outputDir </> "fixture"
  (compiled, _, compileError) <-
    readProcessWithExitCode "ghc" (["-v0", "-outputdir", outputDir, "-o", executable] <> compilerOptions <> [source]) ""
  if compiled /= ExitSuccess
    then pure (compiled, "", compileError)
    else do
      (ran, output, runError) <- readProcessWithExitCode executable [] ""
      pure (ran, output, runError)
