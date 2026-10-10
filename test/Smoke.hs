{-# LANGUAGE OverloadedStrings #-}

-- | Worked examples, in the vocabulary a vim user would state them in.
-- These depend on the library and therefore on @text-icu@ and @vty@;
-- what they do not depend on is @hspec@ or @QuickCheck@, so they run
-- wherever the editor itself builds.
module Main (main) where

import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty

import Basilisk.Cursor (clusterBounds, displayColumn, renderable, unicode, widthAt)
import Basilisk.Decode (decode, initialKeyState)
import qualified Basilisk.Document as Doc
import Basilisk.Render (clampTop)
import Basilisk.Step (step)
import Basilisk.Types

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check name ok = unless ok (modifyIORef' failures (+ 1) >> putStrLn ("FAILED: " <> name))
  mapM_ (uncurry check) allChecks
  n <- readIORef failures
  putStrLn (show (length allChecks) <> " smoke checks, " <> show n <> " failures.")
  unless (n == 0) (ioError (userError "smoke checks failed"))

allChecks :: [(String, Bool)]
allChecks = documentChecks <> stepChecks <> vocabularyChecks <> tier1Checks <> searchChecks <> safetyChecks <> decodeChecks <> viewportChecks

-- helpers --------------------------------------------------------------

editor :: Text -> Editor
editor = newEditor Nothing

at :: Int -> Editor -> Editor
at n e = withDocument (Doc.move unicode 0 (Doc.Chars n) (document e)) e

-- | Buffer-field fixtures. The split between buffer and session means
-- a test that sets a path or a line ending says so, rather than
-- reaching into one flat record.
onFile :: FilePath -> Editor -> Editor
onFile p = onBuffer (\b -> b { bPath = Just p })

withEol :: Eol -> Bool -> Editor -> Editor
withEol el fe = onBuffer (\b -> b { bEol = el, bFinalEol = fe })

run :: [NormalCmd] -> Editor -> Editor
run cs e0 = foldl (\e c -> fst (step (InNormal c) e)) e0 cs

body :: Editor -> Text
body = Doc.toText . document

keys :: Mode -> [Vty.Key] -> [Action]
keys m = go initialKeyState
  where
    go _ []       = []
    go st (k : ks) = case decode m st (Vty.EvKey k []) of
      (st', Nothing) -> go st' ks
      (st', Just a)  -> a : go st' ks

chars :: String -> [Vty.Key]
chars = map Vty.KChar

-- the document algebra --------------------------------------------------

documentChecks :: [(String, Bool)]
documentChecks =
  [ ("toText . fromText = id, multi-line",
      all (\t -> Doc.toText (Doc.fromText t) == t) ["", "a", "a\nb\nc", "\n\n", "x\n"])
  , ("a document always has at least one line", Doc.lineCount (Doc.fromText "") == 1)
  , ("reach clamps a count to the line", Doc.reach unicode 99 (MChar DRight) (Doc.fromText "ab") == Doc.Chars 2)
  , ("reach MLine is inclusive: dd spans one row", Doc.reach unicode 1 MLine (Doc.fromText "a\nb") == Doc.Lines 0)
  , ("reach MLine is inclusive: 3dd spans three", Doc.reach unicode 3 MLine (Doc.fromText "a\nb") == Doc.Lines 2)
  , ("clampGap is idempotent", let d = Doc.fromText "abc" in Doc.clampGap unicode (Doc.clampGap unicode d) == Doc.clampGap unicode d)
  ] <> unicodeChecks

-- unicode, tabs, and what reaches the terminal ------------------------------

unicodeChecks :: [(String, Bool)]
unicodeChecks =
  [ ("a wide character advances two columns", widthAt 0 '\28450' == 2 && widthAt 0 'a' == 1)
  , ("a combining mark advances none", widthAt 0 '\769' == 0)
  , ("a tab advances to the next stop, from any column",
      and [ (c + widthAt (Doc.Column c) '\t') `mod` Doc.tabStop == 0 | c <- [0 .. 40] ])
  , ("a control character is one column and is never drawn raw",
      widthAt 0 '\ESC' == 1 && renderable "a\ESCb" == "a\65533b")
  , ("a carriage return cannot move the terminal cursor", renderable "a\rb" == "a\65533b")
  , ("a tab is drawn as spaces to the next stop", renderable "a\tb" == "a       b")
  , ("rendering preserves width", all (\t -> displayColumn (renderable t) == displayColumn t)
      ["", "a\tb", "a\ESCb", "\28450x", "e\769"])
  , ("a base plus a combining mark is one cluster", clusterBounds "e\769x" == [0, 2, 3])
  , ("an emoji ZWJ sequence is one cluster", clusterBounds "\128104\8205\128105" == [0, 3])
  , ("two regional indicators are one flag", clusterBounds "\127462\127463" == [0, 2])
  , ("a Hangul syllable is one cluster", clusterBounds "\4352\4449\4523" == [0, 3])
  , ("a prepended concatenation mark binds forward", clusterBounds "\1757a" == [0, 2])
  , ("l steps over a whole cluster, not a codepoint",
      Doc.cursorCol (document (run [NMove 1 (MChar DRight)] (editor "e\769x"))) == Doc.Offset 2)
  , ("x deletes a whole cluster",
      body (run [NOperate 1 Delete (MChar DRight)] (editor "e\769x")) == "x")
  , ("backspace deletes a whole cluster",
      let e = fst (step (InInsert IBackspace) (withDocument (Doc.move unicode 0 (Doc.Chars 2) (Doc.fromText "e\769")) ((editor "e\769") { mode = Insert Fresh })))
      in body e == "")
  , ("w never stops inside a cluster",
      Doc.onBoundary unicode (document (run [NMove 1 MWord] (editor "e\769 x"))))
  , ("j never lands inside a cluster",
      Doc.onBoundary unicode (document (run [NMove 3 (MChar DRight), NMove 1 (MChar DDown)] (editor "abcd\ne\769xy"))))
  , ("a count saturates instead of overflowing",
      all (\a -> all (\n -> n >= 0 && n <= maxCount) (counts a))
          (keys Normal (chars "99999999999999999999j")))
  , ("an absurd paste count is bounded, not an allocation bomb",
      Text.length (body (run [NPaste maxBound True] ((editor "") { register = Just (Clip False "x") }))) <= maxCount)
  ]
  where
    counts (InNormal (NMove n _))      = [n]
    counts (InNormal (NOperate n _ _)) = [n]
    counts _                           = []

-- the pure core ----------------------------------------------------------

stepChecks :: [(String, Bool)]
stepChecks =
  [ ("dw deletes a word and fills the register", body dw == "world" && fmap clipText (register dw) == Just "hello ")
  , ("dw bumps the version exactly once", version dw == 1)
  , ("3dw is one edit, so one undo restores it",
      body threeDw == "four" && body (run [NUndo 1] threeDw) == "one two three four")
  , ("2d3w multiplies the counts", body (run [NOperate 6 Delete MWord] wordy) == "")
  , ("yw leaves the document and version alone, and fills the register",
      body yw == "alpha beta" && version yw == 0 && fmap clipText (register yw) == Just "alpha ")
  , ("d$ cuts the tail", body (run [NOperate 1 Delete MLineEnd] (at 4 (editor "keep this"))) == "keep")
  , ("d0 cuts the head", body (run [NOperate 1 Delete MLineStart] (at 5 (editor "keep this"))) == "this")
  , ("dd removes one line and registers it", body dd == "second\nthird" && fmap clipText (register dd) == Just "first")
  , ("3dd removes three lines", body (run [NOperate 3 Delete MLine] three) == "")
  , ("dj removes the current line and the one below", body (run [NOperate 1 Delete (MChar DDown)] three) == "third")
  , ("dd on the only line leaves one empty line",
      Doc.lineCount (document (run [NOperate 1 Delete MLine] (editor "solo"))) == 1)
  , ("x deletes the character under the cursor", body (run [NOperate 1 Delete (MChar DRight)] (editor "abc")) == "bc")
  , ("l stops at the last character rather than walking off it",
      Doc.cursorCol (document (run [NMove 9 (MChar DRight)] (editor "abc"))) == Doc.Offset 2)
  , ("h stops at column zero", Doc.cursorCol (document (run [NMove 9 (MChar DLeft)] (editor "abc"))) == Doc.Offset 0)
  , ("5j clamps at the last line", Doc.cursorRow (document (run [NMove 5 (MChar DDown)] three)) == 2)
  , ("j past a wide character lands on the right character",
      Doc.cursorCol (document (run [NMove 2 (MChar DRight), NMove 1 (MChar DDown)] (editor "\28450\28450x\nabcde")))
        == Doc.Offset 4)
  , ("P pastes a charwise cut before the cursor", body (run [NPaste 1 False] dw) == "hello world")
  , ("3P pastes three copies", body (run [NPaste 3 False] dw) == "hello hello hello world")
  , ("a linewise cut pastes as whole rows, not joined on",
      body (run [NPaste 1 True] dd) == "second\nfirst\nthird"
        && body (run [NPaste 1 False] dd) == "first\nsecond\nthird")
  , ("yy then p duplicates a line", body (run [NOperate 1 Yank MLine, NPaste 1 True] three) == "first\nfirst\nsecond\nthird")
  , ("3p on a linewise register makes three rows",
      Doc.lineCount (document (run [NPaste 3 True] dd)) == 5)
  , ("p pastes after the cursor", body (run [NPaste 1 True] dw) == "whello orld")
  , ("o opens a line below and enters insert", body (run [NEnterInsert 1 LineBelow] (editor "a")) == "a\n"
      && mode (run [NEnterInsert 1 LineBelow] (editor "a")) == Insert Dirty)
  , ("O opens a line above", body (run [NEnterInsert 1 LineAbove] (editor "a")) == "\na")
  , ("a may sit past the last character, Escape may not",
      Doc.cursorCol (document afterA) == Doc.Offset 1
        && Doc.cursorCol (document (fst (step (InInsert IEscape) afterA))) == Doc.Offset 0)
  , ("a no-op edit grows neither history nor version",
      let e = run [NOperate 1 Delete MWord] (at 5 (editor "hello"))
      in version e == 0 && past (history e) == [])
  , ("save without a path is a status line, not a crash",
      snd (step (InNormal NSave) (editor "x")) == [] && status (fst (step (InNormal NSave) (editor "x"))) == Just "no file name")
  , ("save with a path emits exactly the bytes to write",
      snd (step (InNormal NSave) (withEol LF False (onFile "out.txt" (editor "x")))) == [WriteFile "out.txt" "x" False])
  , ("CRLF survives a round trip",
      snd (step (InNormal NSave) (withEol CRLF True (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\r\nb\r\n" False])
  , (":w and the save command agree",
      snd (step (InPrompt PSubmit) (onFile "o" (editor "x")) { mode = Prompt ExCommand "w" })
        == snd (step (InNormal NSave) (onFile "o" (editor "x"))))
  , ("the trailing newline is a flag, not a line",
      Doc.lineCount (document (editor "a\nb")) == 2
        && snd (step (InNormal NSave) (withEol LF True (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\nb\n" False]
        && snd (step (InNormal NSave) (withEol LF False (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\nb" False])
  , ("an unknown ex-command says so",
      status (fst (step (InPrompt PSubmit) (editor "x") { mode = Prompt ExCommand "zz" })) == Just "unknown command")
  , ("a prompt command with no prompt open is inert", step (InPrompt PBackspace) (editor "x") == (editor "x", []))
  , ("a typing session is one undo entry, not one per character",
      body (run [NUndo 1] session) == "ab" && body session == "abXYZ" && length (past (history session)) == 1)
  , ("a cursor move inside insert mode starts a new entry",
      body (run [NUndo 1] split') == "abX" && length (past (history split')) == 2)
  , ("o then typing then undo removes the line and the text together",
      body (run [NUndo 1] opened) == "ab" && body opened == "ab\nhi")
  , ("undo past the beginning reports rather than crashes",
      status (run [NUndo 3] (editor "x")) == Just "already at oldest change")
  ]
  where
    dw       = run [NOperate 1 Delete MWord] (editor "hello world")
    threeDw  = run [NOperate 3 Delete MWord] (editor "one two three four")
    wordy    = editor "a b c d e f"
    yw       = run [NOperate 1 Yank MWord] (editor "alpha beta")
    three    = editor "first\nsecond\nthird"
    dd       = run [NOperate 1 Delete MLine] three
    afterA   = run [NEnterInsert 1 After] (editor "ab")
    typeIn cs e = foldl (\x c -> fst (step (InInsert c) x)) e cs
    session  = typeIn (map (IInput . Text.singleton) "XYZ")
                      (run [NEnterInsert 1 After] (at 1 (editor "ab")))
    split'   = typeIn [IInput "X", IMove DLeft, IInput "Y"]
                      (run [NEnterInsert 1 After] (at 1 (editor "ab")))
    opened   = typeIn (map (IInput . Text.singleton) "hi") (run [NEnterInsert 1 LineBelow] (editor "ab"))

-- the vocabulary added after the skeleton ------------------------------------

vocabularyChecks :: [(String, Bool)]
vocabularyChecks =
  [ ("b goes back a word", col (run [NMove 2 MWord, NMove 1 MWordBack] (editor "one two three")) == 4)
  , ("2b goes back two", col (run [NMove 2 MWord, NMove 2 MWordBack] (editor "one two three")) == 0)
  , ("e stops on the last letter of a word", col (run [NMove 1 MWordEnd] (editor "one two")) == 2)
  , ("2e reaches the second word end, as e e does",
      col (run [NMove 2 MWordEnd] (editor "one two three"))
        == col (run [NMove 1 MWordEnd, NMove 1 MWordEnd] (editor "one two three")))
  , ("de is inclusive: it deletes the letter e stops on",
      body (run [NOperate 1 Delete MWordEnd] (editor "one two")) == " two")
  , ("^ goes to the first non-blank", col (run [NMove 1 MFirstNonBlank] (at 0 (editor "    indented"))) == 4)
  , ("^ on an all-blank line stops at the end", col (run [NMove 1 MFirstNonBlank] (editor "   ")) == 2)
  , ("G with no count goes to the last line", row (run [NMove 0 MGotoLine] three) == 2)
  , ("2G goes to line two", row (run [NMove 2 MGotoLine] three) == 1)
  , ("9999G clamps at the last line", row (run [NMove 9999 MGotoLine] three) == 2)
  , ("gg goes to the first line", row (run [NMove 5 (MChar DDown), NMove 1 MGotoLine] three) == 0)
  , ("^ is idempotent: pressing it twice lands in the same place both times",
      let once = run [NMove 1 MFirstNonBlank] (editor "    indented")
          twice = run [NMove 1 MFirstNonBlank, NMove 1 MFirstNonBlank] (editor "    indented")
      in col once == col twice)
  , ("c on an empty span still enters insert", mode (run [NOperate 1 Change MWord] (editor "")) == Insert Fresh)
  , ("cw cuts the word and enters insert",
      body cw == " world" && mode cw == Insert Fresh && fmap clipText (register cw) == Just "hello")
  , ("cc empties the line but keeps it",
      body cc == "\nsecond\nthird" && Doc.lineCount (document cc) == 3 && mode cc == Insert Fresh)
  , ("cc on an already empty line changes nothing and marks nothing",
      let e = run [NOperate 1 Change MLine] (editor "") in version e == 0 && not (modified e))
  , ("D deletes to the end of the line", body (run [NMove 4 (MChar DRight), NOperate 1 Delete MLineEnd] (editor "keep this")) == "keep")
  , ("X deletes backwards", body (run [NMove 2 (MChar DRight), NOperate 1 Delete (MChar DLeft)] (editor "abc")) == "ac")
  , ("J joins two lines with a space", body (run [NJoin 1] (editor "one\n   two")) == "one two")
  , ("3J joins three", body (run [NJoin 3] (editor "a\nb\nc\nd")) == "a b c\nd")
  , ("J on the last line is a no-op", let e = run [NJoin 1] (editor "only") in body e == "only" && version e == 0)
  , ("S changes a whole line", body (run [NOperate 1 Change MLine] three) == "\nsecond\nthird")
  ]
  where
    col = Doc.unOffset . Doc.cursorCol . document
    row = Doc.cursorRow . document
    three = editor "first\nsecond\nthird"
    cw = run [NOperate 1 Change MWordEnd] (editor "hello world")
    cc = run [NOperate 1 Change MLine] three

-- ~, gu/gU/g~, r, >/<, ZZ/ZQ ----------------------------------------------

tier1Checks :: [(String, Bool)]
tier1Checks =
  [ ("~ toggles one character and advances past it",
      let e = run [NOperate 1 ToggleCase (MChar DRight)] (editor "hello")
      in body e == "Hello" && col e == 1)
  , ("3~ toggles three characters, advancing past all of them",
      let e = run [NOperate 3 ToggleCase (MChar DRight)] (editor "hello")
      in body e == "HELlo" && col e == 3)
  , ("~ on a non-letter is a true no-op: no version bump, no undo entry",
      let e = run [NOperate 1 ToggleCase (MChar DRight)] (editor "5abc")
      in body e == "5abc" && version e == 0 && not (modified e))
  , ("guw lowercases a word", body (run [NOperate 1 ToLower MWord] (editor "HELLO world")) == "hello world")
  , ("gUw uppercases a word", body (run [NOperate 1 ToUpper MWord] (editor "hello WORLD")) == "HELLO WORLD")
  , ("guu lowercases the whole line, cursor at the first non-blank",
      let e = run [NOperate 1 ToLower MLine] (editor "  HELLO WORLD") in body e == "  hello world" && col e == 2)
  , ("gUU uppercases the whole line", body (run [NOperate 1 ToUpper MLine] (editor "Hello World")) == "HELLO WORLD")
  , ("g~~ toggles the whole line", body (run [NOperate 1 ToggleCase MLine] (editor "Hello World")) == "hELLO wORLD")
  , ("guu on a line with no letters is a no-op",
      let e = run [NOperate 1 ToLower MLine] (editor "123 456") in version e == 0 && not (modified e))
  , (">> indents a line by one level", body (run [NOperate 1 Indent MLine] (editor "foo")) == "    foo")
  , ("3>> indents three lines", body (run [NOperate 3 Indent MLine] (editor "a\nb\nc\nd")) == "    a\n    b\n    c\nd")
  , ("<< dedents an indented line", body (run [NOperate 1 Dedent MLine] (editor "        foo")) == "    foo")
  , ("<< removes only what is there, never going negative",
      let e = run [NOperate 1 Dedent MLine] (editor "  foo") in body e == "foo" && version e == 1)
  , ("<< on an unindented line is a no-op", let e = run [NOperate 1 Dedent MLine] (editor "foo") in version e == 0 && not (modified e))
  , ("> is forced linewise even for a charwise motion",
      body (run [NOperate 1 Indent MWord] (editor "foo bar")) == "    foo bar")
  , ("r replaces one character and leaves the cursor on it",
      let e = run [NReplace 1 'X'] (editor "abc") in body e == "Xbc" && col e == 0)
  , ("3rX replaces three characters with the same one each",
      let e = run [NReplace 3 'X'] (editor "abcdef") in body e == "XXXdef" && col e == 2)
  , ("r on a genuinely empty line is a no-op, not a crash",
      let e = run [NReplace 1 'X'] (editor "") in version e == 0 && not (modified e))
  , ("r clamps its count to what the line actually has",
      body (run [NReplace 99 'X'] (editor "abc")) == "XXX")
  , ("r replacing a character with itself is a true no-op",
      let e = run [NReplace 1 'x'] (editor "x") in version e == 0 && not (modified e))
  , ("3ra on an already-all-a's span is also a no-op",
      let e = run [NReplace 3 'a'] (editor "aaa") in version e == 0 && not (modified e))
  , ("r is repeatable with .", body (run [NReplace 1 'X', NMove 1 (MChar DRight), NRepeat 1] (editor "abc")) == "XXc")
  , ("ZZ saves and quits", snd (step (InNormal NWriteQuit) (onFile "/tmp/zz-smoke.txt" (editor "x"))) /= [])
  , ("ZQ quits without saving, regardless of modified state",
      let e = (run [NOperate 1 Delete (MChar DRight)] (editor "x")) in snd (step (InNormal NQuitDiscard) e) == [RequestQuit])
  , ("3ifoo<Esc> types the text three times", body (typeEsc 3 Before "foo" (editor "")) == "foofoofoo")
  , ("a plain i (count 1) is unaffected", body (typeEsc 1 Before "x" (editor "")) == "x")
  , ("undo after a counted insert removes the whole repetition in one step",
      let e = run [NUndo 1] (typeEsc 3 Before "ab" (editor "")) in body e == "")
  , (". after a counted insert repeats the whole thing again",
      let e = run [NMove 1 (MChar DRight), NRepeat 1] (typeEsc 3 Before "x" (editor ""))
      in body e == "xxxxxx")
  , ("a counted insert with no typed text (bare Escape) inserts nothing extra",
      body (typeEsc 5 Before "" (editor "ab")) == "ab")
  ]
  <> replaceModeChecks
  where
    col = Doc.unOffset . Doc.cursorCol . document
    typeEsc n anchor t e0 = fst (step (InInsert IEscape) typed')
      where
        entered = fst (step (InNormal (NEnterInsert n anchor)) e0)
        typed'  = if Text.null t then entered else fst (step (InInsert (IInput t)) entered)

-- R: replace mode -------------------------------------------------------

replaceModeChecks :: [(String, Bool)]
replaceModeChecks =
  [ ("R overwrites character by character", body (typeEscR "XY" (editor "abcdef")) == "XYcdef")
  , ("R extends past the end of the line", body (typeEscR "XYZ" (editor "ab")) == "XYZ")
  , ("mode is Replace [] immediately after R", mode (fst (step (InNormal NEnterReplace) (editor "abc"))) == Replace [])
  , ("backspace in R restores the overwritten character",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XY"), InInsert IBackspace, InInsert IEscape] (editor "abcdef"))
        == "Xbcdef")
  , ("backspace past an extension deletes it rather than restoring something that was never there",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XYZ"), InInsert IBackspace, InInsert IEscape] (editor "a"))
        == "XY")
  , ("backspace at the very start of an R session is a no-op -- can't back up past where R started",
      body (runActions [InNormal NEnterReplace, InInsert IBackspace] (editor "abc")) == "abc")
  , ("one undo entry removes a whole R session, however many characters it overwrote",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XYZ"), InInsert IEscape, InNormal (NUndo 1)] (editor "abcdef"))
        == "abcdef")
  , ("overwriting a character with itself is a true no-op: no version bump, no undo entry",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "x")] (editor "x") in version e == 0 && not (modified e))
  , ("a real overwrite still bumps the version normally",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "y")] (editor "x") in version e == 1)
  , ("version bumps exactly once for a multi-character IInput, not once per character",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "aa")] (editor "bb") in version e == 1)
  , ("pressing Enter in R mode opens a line rather than embedding a newline in one",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "ab\ncd"), InInsert IEscape] (editor "XY123456")
      in body e == "ab\ncd3456" && all (not . Text.any (== '\n')) (Doc.window 0 10 (document e)))
  ]
  where
    runActions cs e0 = foldl (\e c -> fst (step c e)) e0 cs
    typeEscR t e0 = fst (step (InInsert IEscape) typed')
      where
        entered = fst (step (InNormal NEnterReplace) e0)
        typed'  = if Text.null t then entered else fst (step (InInsert (IInput t)) entered)

-- ; and , repeating f/t/F/T -----------------------------------------------

findCharChecks :: [(String, Bool)]
findCharChecks =
  [ ("f. then ; repeats forward", colOf (step1 ";" (step1 "f." dots)) == 3)
  , ("two ; visits the third occurrence", colOf (step2 ";" ";" (step1 "f." dots)) == 5)
  , (", after f reverses direction", colOf (step1 "," (step2 ";" ";" (step1 "f." dots))) == 3)
  -- vim's well-known gotcha: t stops one short of its target, so a
  -- naive repeat would immediately re-find the same target and never
  -- move. ; must nudge past it instead of getting stuck.
  , ("t. lands one short, already adjacent to the first match",
      colOf (step1 "t." dots) == 0)
  , ("; after t does not get stuck -- it finds the next occurrence",
      colOf (step1 ";" (step1 "t." dots)) == 2)
  , ("a second ; continues advancing, still not stuck",
      colOf (step2 ";" ";" (step1 "t." dots)) == 4)
  , (", after t reverses, searching backward instead",
      colOf (step1 "," (step2 ";" ";" (step1 "t." dots))) == 2)
  , ("; with no previous find reports rather than guessing",
      status (step1 ";" dots) == Just "no previous find")
  -- A counted ';' is the same one-shot "nth occurrence from here"
  -- lookup 'MTo' itself is, not iteration -- the same divergence the
  -- counted-displacement law already excludes 'MTo' for. "a.b.c.d"
  -- has only two further '.'s after the first, so the 3rd does not
  -- exist and a one-shot "3;" stays exactly where it started, even
  -- though three individual presses of ';' would advance twice and
  -- then also stay (landing somewhere else: on the 2nd occurrence).
  , ("a counted ; is one lookup, not iteration, like MTo itself",
      colOf (step1 "3;" (step1 "f." dots)) == colOf (step1 "f." dots))
  , ("but a count within range finds exactly that occurrence",
      colOf (step1 "2;" (step1 "f." dots)) == colOf (step2 ";" ";" (step1 "f." dots)))
  ]
  where
    dots  = editor "a.b.c.d"
    colOf = Doc.unOffset . Doc.cursorCol . document
    step1 ks e = foldl (\e' a -> fst (step a e')) e (keys Normal (chars ks))
    step2 k1 k2 e = step1 k2 (step1 k1 e)

-- search, and the reach shape it needs ---------------------------------------

searchChecks :: [(String, Bool)]
searchChecks =
  [ ("/ jumps to the next match", posOf (find "beta") == (1, 0))
  , ("a search wraps at the end of the document",
      posOf (fst (step (InNormal (NRepeatFind 1 False)) (find "alpha"))) == (0, 0))
  , ("n repeats, N reverses",
      posOf (fst (step (InNormal (NRepeatFind 1 False)) (find "a"))) /= posOf (find "a")
        && posOf (fst (step (InNormal (NRepeatFind 1 True)) (fst (step (InNormal (NRepeatFind 1 False)) (find "a"))))) == posOf (find "a"))
  , ("3n skips two matches",
      posOf (fst (step (InNormal (NRepeatFind 3 False)) (find "a")))
        == posOf (iterate (fst . step (InNormal (NRepeatFind 1 False))) (find "a") !! 3))
  , ("a pattern that is absent does not move the cursor, and says so",
      posOf (find "zzzz") == posOf doc3 && status (find "zzzz") == Just "not found: zzzz")
  , ("n with no previous search reports rather than guessing",
      status (fst (step (InNormal (NRepeatFind 1 False)) doc3)) == Just "no previous search")
  ] <> findCharChecks <>
  -- the Upto shape: a charwise span that crosses rows
  [ ("a charwise span across rows joins the partial first and last rows",
      fmap (Doc.toText . fst) (Doc.operate Delete (Doc.Upto 2 3) (docAt 2 "alpha\nbeta\ngamma"))
        == Just "alma")
  , ("and yields exactly the text between the two positions",
      fmap snd (Doc.operate Delete (Doc.Upto 2 3) (docAt 2 "alpha\nbeta\ngamma"))
        == Just "pha\nbeta\ngam")
  , ("a span to the cursor's own position is a no-op",
      Doc.operate Delete (Doc.Upto 0 0) (docAt 0 "alpha") == Nothing)
  , ("a backwards span cuts the same text as the forwards one",
      fmap snd (Doc.operate Delete (Doc.Upto 0 1) (docAt 3 "alpha"))
        == fmap snd (Doc.operate Delete (Doc.Upto 0 3) (docAt 1 "alpha")))
  ]
  where
    doc3   = editor "alpha\nbeta\ngamma"
    find p = fst (step (InPrompt PSubmit) doc3 { mode = Prompt Search p })
    posOf e = (Doc.cursorRow (document e), Doc.unOffset (Doc.cursorCol (document e)))
    docAt n t = document (at n (editor t))

-- refusing to lose work ------------------------------------------------------

safetyChecks :: [(String, Bool)]
safetyChecks =
  [ (":q on a clean buffer quits", snd (ex "q" clean) == [RequestQuit])
  , (":q on a modified buffer refuses, and says why",
      snd (ex "q" dirty) == [] && status (fst (ex "q" dirty)) == Just "no write since last change (:q! to override)")
  , (":q! on a modified buffer quits", snd (ex "q!" dirty) == [RequestQuit])
  , ("a buffer is clean until edited, and dirty after", not (modified clean) && modified dirty)
  , ("undo alone does not make a buffer clean again", modified (run [NUndo 1] dirty))
  , (":wq writes and quits", snd (ex "wq" (onFile "o" dirty)) == [WriteFile "o" "ba\n" False, RequestQuit])
  , (":wq with no filename does neither", snd (ex "wq" dirty) == [])
  , (":w! sets the override the shell needs", snd (ex "w!" (onFile "o" dirty)) == [WriteFile "o" "ba\n" True])
  , ("Ctrl-C is bound to nothing that can quit", null (decodeCtrl 'c'))
  ]
  where
    clean = editor "ab"
    dirty = fst (step (InInsert (IInput "b")) ((editor "a") { mode = Insert Fresh }))
    ex c e = step (InPrompt PSubmit) e { mode = Prompt ExCommand c }
    decodeCtrl c = maybe [] pure (snd (decode Normal initialKeyState (Vty.EvKey (Vty.KChar c) [Vty.MCtrl])))

-- the key grammar ---------------------------------------------------------

decodeChecks :: [(String, Bool)]
decodeChecks =
  [ ("a bare motion is a move", keys Normal (chars "w") == [InNormal (NMove 1 MWord)])
  , ("an operator waits for its motion", keys Normal (chars "d") == [])
  , ("dw is one action", keys Normal (chars "dw") == [InNormal (NOperate 1 Delete MWord)])
  , ("3dw carries its count", keys Normal (chars "3dw") == [InNormal (NOperate 3 Delete MWord)])
  , ("2d3w multiplies", keys Normal (chars "2d3w") == [InNormal (NOperate 6 Delete MWord)])
  , ("dd is the doubled operator", keys Normal (chars "dd") == [InNormal (NOperate 1 Delete MLine)])
  , ("3dd counts rows", keys Normal (chars "3dd") == [InNormal (NOperate 3 Delete MLine)])
  , ("yy yanks a line", keys Normal (chars "yy") == [InNormal (NOperate 1 Yank MLine)])
  , ("x is delete one character forward", keys Normal (chars "x") == [InNormal (NOperate 1 Delete (MChar DRight))])
  , ("0 with no count pending is a motion", keys Normal (chars "0") == [InNormal (NMove 1 MLineStart)])
  , ("0 after a digit extends the count", keys Normal (chars "10j") == [InNormal (NMove 10 (MChar DDown))])
  , ("counts accumulate across digits", keys Normal (chars "123l") == [InNormal (NMove 123 (MChar DRight))])
  , ("i enters insert", keys Normal (chars "i") == [InNormal (NEnterInsert 1 Before)])
  , ("a colon opens the ex prompt", keys Normal (chars ":") == [InNormal (NEnterPrompt ExCommand)])
  , ("insert mode types text", keys (Insert Fresh) (chars "ab") == [InInsert (IInput "a"), InInsert (IInput "b")])
  , ("the prompt accumulates its own buffer",
      keys (Prompt ExCommand "") (chars "wq") == [InPrompt (PInput "w"), InPrompt (PInput "q")])
  , ("a command key aborts a pending operator rather than dropping it",
      keys Normal (chars "ci") == [])
  , ("~ and 3~ decode as ToggleCase over MChar DRight",
      keys Normal (chars "~") == [InNormal (NOperate 1 ToggleCase (MChar DRight))]
        && keys Normal (chars "3~") == [InNormal (NOperate 3 ToggleCase (MChar DRight))])
  , ("gu, gU and g~ decode as operators composing with a motion",
      keys Normal (chars "guw") == [InNormal (NOperate 1 ToLower MWord)]
        && keys Normal (chars "gUw") == [InNormal (NOperate 1 ToUpper MWord)]
        && keys Normal (chars "g~w") == [InNormal (NOperate 1 ToggleCase MWord)])
  , ("guu, gUU and g~~ double by their bare second letter",
      keys Normal (chars "guu") == [InNormal (NOperate 1 ToLower MLine)]
        && keys Normal (chars "gUU") == [InNormal (NOperate 1 ToUpper MLine)]
        && keys Normal (chars "g~~") == [InNormal (NOperate 1 ToggleCase MLine)])
  , (">> and << decode as Indent/Dedent, doubled like dd",
      keys Normal (chars ">>") == [InNormal (NOperate 1 Indent MLine)]
        && keys Normal (chars "3<<") == [InNormal (NOperate 3 Dedent MLine)])
  , ("r<char> decodes as NReplace, with its count", keys Normal (chars "3rx") == [InNormal (NReplace 3 'x')])
  , ("ZZ and ZQ decode as their own commands",
      keys Normal (chars "ZZ") == [InNormal NWriteQuit] && keys Normal (chars "ZQ") == [InNormal NQuitDiscard])
  , ("g and Z alone, with no second key, produce nothing",
      keys Normal (chars "g") == [] && keys Normal (chars "Z") == [])
  , ("gg still works after the g-prefix gained other uses",
      keys Normal (chars "gg") == [InNormal (NMove 1 MGotoLine)])
  -- Aborting discards the operator and the next key is read fresh, as
  -- vim does after an invalid operator target. So the p in cip is a
  -- paste, not part of a text object -- which is the honest outcome
  -- until text objects exist.
  , ("and the key after an abort is read fresh",
      keys Normal (chars "cip") == [InNormal (NPaste 1 True)])
  , ("the same keys alone still work",
      keys Normal (chars "ip") == [InNormal (NEnterInsert 1 Before), InNormal (NPaste 1 True)])
  , ("an unknown key aborts a pending operator", keys Normal (chars "d") <> keys Normal [Vty.KFun 5] == [])
  , ("a bracketed paste is one action, not one per character",
      length (snd (decode (Insert Fresh) initialKeyState (Vty.EvPaste "hello world") ) `seq`
              [decode (Insert Fresh) initialKeyState (Vty.EvPaste "hello world")]) == 1)
  , ("a bracketed paste in normal mode is a single edit",
      snd (decode Normal initialKeyState (Vty.EvPaste "ab\ncd")) == Just (InNormal (NPasteText "ab\ncd")))
  , ("cw acts as ce, as in vim", keys Normal (chars "cw") == [InNormal (NOperate 1 Change MWordEnd)])
  , ("dw is still dw", keys Normal (chars "dw") == [InNormal (NOperate 1 Delete MWord)])
  , ("cc is the doubled operator", keys Normal (chars "cc") == [InNormal (NOperate 1 Change MLine)])
  , ("D C s S X are operator/motion pairs, not new commands",
      keys Normal (chars "DCsSX") ==
        [ InNormal (NOperate 1 Delete MLineEnd), InNormal (NOperate 1 Change MLineEnd)
        , InNormal (NOperate 1 Change (MChar DRight)), InNormal (NOperate 1 Change MLine)
        , InNormal (NOperate 1 Delete (MChar DLeft)) ])
  , ("b and e decode as motions", keys Normal (chars "2b3e") == [InNormal (NMove 2 MWordBack), InNormal (NMove 3 MWordEnd)])
  , ("gg goes to the first line, G to the last",
      keys Normal (chars "g") == [] && keys Normal (chars "gg") == [InNormal (NMove 1 MGotoLine)]
        && keys Normal (chars "G") == [InNormal (NMove 0 MGotoLine)])
  , ("G carries its count, and none means the last line",
      keys Normal (chars "G") == [InNormal (NMove 0 MGotoLine)]
        && keys Normal (chars "12G") == [InNormal (NMove 12 MGotoLine)])
  , ("p and P differ", keys Normal (chars "pP") == [InNormal (NPaste 1 True), InNormal (NPaste 1 False)])
  , ("dG deletes to the end of the document", keys Normal (chars "dG") == [InNormal (NOperate 0 Delete MGotoLine)])
  , ("n and N decode with counts",
      keys Normal (chars "n3N") == [InNormal (NRepeatFind 1 False), InNormal (NRepeatFind 3 True)])
  , ("; and , decode with counts",
      keys Normal (chars ";3,") == [InNormal (NRepeatTo 1 False), InNormal (NRepeatTo 3 True)])
  , ("a resize disturbs no pending sequence",
      snd (decode Normal initialKeyState (Vty.EvResize 10 10)) == Nothing)
  ]

-- the viewport -------------------------------------------------------------

viewportChecks :: [(String, Bool)]
viewportChecks =
  [ ("the window holds still while the cursor is inside it", clampTop 10 5 3 == 3)
  , ("it scrolls up only to reach the cursor", clampTop 10 2 7 == 2)
  , ("it scrolls down by the least that works", clampTop 10 20 3 == 11)
  , ("every row is reachable", and [inside h r t | h <- [1 .. 8], r <- [0 .. 20], t <- [0 .. 20]])
  ]
  where inside h r t = let t' = clampTop h r t in t' >= 0 && t' <= r && r < t' + h
