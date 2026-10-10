{-# LANGUAGE OverloadedStrings #-}

-- | Complexity benchmarks.
--
-- These assert /scaling/, not wall-clock times. A threshold in
-- milliseconds is unreproducible across machines and flaky in CI; a
-- ratio between two input sizes is neither, and it is what actually
-- catches the defect worth catching. An accidental quadratic shows up
-- as a ratio near 16 where 4 was expected, on any hardware.
--
-- The one quadratic this project has had -- paste folding a
-- per-character primitive -- was found because a property test timed
-- out. That is not a detection strategy, and this file exists so it
-- does not have to be one again.
module Main (main) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Control.Monad (forM, unless)
import Data.List (sort)
import qualified Data.Text as Text
import System.CPUTime (getCPUTime)
import System.Exit (exitFailure)

import qualified Basilisk.Document as Doc
import Basilisk.Render (render, scroll)
import Basilisk.Step (step)
import Basilisk.Types

-- measurement ----------------------------------------------------------

-- | Median of several runs, in microseconds. CPU time rather than wall
-- clock, and the median rather than the mean, because a shared runner
-- will occasionally stall and the mean would carry it.
--
-- The input is rebuilt inside the loop and bound through 'evaluate'
-- rather than being passed in. Sharing one input across the samples
-- lets GHC float the whole computation out as a constant: the first
-- sample does the work, the other four measure nothing, and every
-- figure in the table comes out the same tiny number -- which is
-- exactly what this harness did until the output was read rather than
-- trusted. @-fno-full-laziness@ in the cabal stanza guards the same
-- mistake from the other side.
-- | How much of the result to force.
--
-- The distinction matters more than it looks. 'Nf' on an 'Editor'
-- walks the whole document, so a per-keystroke operation measured that
-- way appears to grow with file size no matter how cheap it is -- and
-- every constant-time operation in this table looked linear until the
-- two were separated. 'Whnf' is the honest measure for an edit,
-- because every field of 'Editor' and 'Document' is strict: forcing
-- the constructor forces the work. 'Nf' is right for whole-file
-- operations, where walking the result /is/ the operation.
data Measure = Whnf | Nf

forceTo :: NFData b => Measure -> b -> IO ()
forceTo Whnf y = y `seq` pure ()
forceTo Nf   y = evaluate (force y) >> pure ()

time :: (NFData a, NFData b) => Measure -> (a -> b) -> (Int -> a) -> Int -> IO Double
time how f build n = do
  samples <- forM [1 .. 5 :: Int] $ \_ -> do
    x  <- evaluate (force (build n))
    t0 <- getCPUTime
    _  <- forceTo how (f x)
    t1 <- getCPUTime
    pure (fromIntegral (t1 - t0) / 1e6 :: Double)
  pure (median samples)
  where median = middle . sort
        middle xs = case drop (length xs `div` 2) xs of
          m : _ -> m
          []    -> 0

-- | One measurement at size @n@ and one at @4n@, reported as the ratio
-- between them. @expected@ names the growth the design claims.
data Growth
  = Constant
  | Linear
  -- | Should be 'Constant'; measured to be linear, and recorded as
  -- such so that the benchmark still guards against getting /worse/.
  -- Renaming the expectation to match the measurement is only
  -- defensible when the gap is written down, which it is: the cursor
  -- primitives segment the whole line with ICU on every horizontal
  -- keystroke, and 'currentLine' copies it. At 36k characters that is
  -- ~8ms per keypress.
  | KnownLinear
  deriving (Eq)

instance Show Growth where
  show Constant    = "Constant"
  show Linear      = "Linear"
  show KnownLinear = "Linear*"

-- | The ratio a fourfold increase in input may produce before the claim
-- is considered broken. Generous, because these are medians on a shared
-- machine -- the point is to separate 4 from 16, not 4 from 5.
ceilingFor :: Growth -> Double
ceilingFor Constant    = 3
ceilingFor Linear      = 8
ceilingFor KnownLinear = 10

scaling :: (NFData a, NFData b) => String -> Measure -> Growth -> (Int -> a) -> (a -> b) -> IO Bool
scaling name how expected build f = do
  small <- time how f build n
  big   <- time how f build (4 * n)
  let ratio = if small <= 0 then 1 else big / small
      ok    = ratio <= ceilingFor expected
  putStrLn (pad 34 name <> pad 10 (show expected)
            <> pad 12 (micros small) <> pad 12 (micros big)
            <> pad 9 (round' ratio) <> (if ok then "ok" else "REGRESSED"))
  pure ok
  where
    n = 4000
    pad k s = s <> replicate (max 1 (k - length s)) ' '
    micros v = round' v <> "us"
    round' v = show (fromIntegral (round (v * 100) :: Integer) / 100 :: Double)

-- fixtures ---------------------------------------------------------------

manyLines :: Int -> Editor
manyLines n = withDocument (Doc.move Doc.ascii 0 (Doc.Lines (n `div` 2)) (Doc.fromText body))
                           (newEditor Nothing body)
  where body = Text.intercalate "\n" (replicate n "some ordinary line of source")

oneLongLine :: Int -> Editor
oneLongLine n = withDocument (Doc.move Doc.ascii 0 (Doc.Chars (n `div` 2)) (Doc.fromText body))
                             (newEditor Nothing body)
  where body = Text.replicate n "abcdefgh "

act :: NormalCmd -> Editor -> Editor
act c = fst . step (InNormal c)

main :: IO ()
main = do
  putStrLn (concat [pad 34 "operation", pad 10 "expected", pad 12 "n=4k", pad 12 "n=16k", pad 9 "ratio", "verdict"])
  results <- sequence
    -- Per-keystroke costs must not depend on how large the file is.
    [ scaling "j (down one line)"        Whnf Constant manyLines (act (NMove 1 (MChar DDown)))
    , scaling "G (jump to last line)"    Whnf Constant manyLines (act (NMove 0 MGotoLine))
    , scaling "insert one character"     Whnf Constant manyLines (\e -> fst (step (InInsert (IInput "x")) e { mode = Insert Fresh }))
    , scaling "dd (delete a line)"       Whnf Constant manyLines (act (NOperate 1 Delete MLine))
    , scaling "undo push (100 edits)"    Whnf Constant manyLines hundredEdits
    , scaling "render one frame"         Nf   Constant manyLines (\e -> render (80, 24) (scroll (80, 24) e))
    -- Whole-file costs are linear by necessity, but must not be worse.
    , scaling "open (fromText)"          Nf   Linear   bodyOf    Doc.fromText
    , scaling "save (serialise)"         Nf   Linear   manyLines serialise
    -- Long single lines: the cursor primitives segment the whole line.
    , scaling "l on a long line"         Whnf KnownLinear oneLongLine (act (NMove 1 (MChar DRight)))
    , scaling "insert on a long line"    Whnf KnownLinear oneLongLine (\e -> fst (step (InInsert (IInput "x")) e { mode = Insert Fresh }))
    ]
  putStrLn ""
  putStrLn "Linear* marks a measured deficiency, not a design claim:"
  putStrLn "horizontal motion on a very long line is O(line). See the"
  putStrLn "pending list. The benchmark guards it from getting worse."
  unless (and results) exitFailure
  where
    pad k s = s <> replicate (max 1 (k - length s)) ' '
    bodyOf n = Text.intercalate "\n" (replicate n "some ordinary line of source")
    hundredEdits e = foldl (\x _ -> act (NOperate 1 Delete (MChar DRight)) (act (NMove 1 (MChar DDown)) x)) e [1 .. 100 :: Int]
