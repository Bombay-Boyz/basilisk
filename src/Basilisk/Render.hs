{-# LANGUAGE OverloadedStrings #-}

-- | Editor to frame. Pure: every input, including the terminal size,
-- arrives as an argument.
--
-- Scrolling is hysteresis -- vim scrolls only once the cursor tries to
-- leave the window, so the next scroll position depends on the previous
-- one. That is state no zipper can derive, and 'top' is therefore as
-- irreducible as 'desiredColumn'. 'scroll' is the one function that
-- updates it, and the loop calls it once per frame, so a resize needs no
-- action of its own.
module Basilisk.Render
  ( render
  , scroll
  , clampTop
  ) where

import qualified Data.Text as Text
import qualified Graphics.Vty as Vty

import Basilisk.Cursor (displayColumn, renderable)
import qualified Basilisk.Document as Doc
import Basilisk.Types

-- | @clampTop h r t@ is the least adjustment of @t@ that puts row @r@
-- inside a window of @h@ rows.
--
-- Claim: for @h >= 1@ and @r >= 0@ and @t >= 0@, the result @t'@
-- satisfies @0 <= t' <= r < t' + h@.
-- Proof: three exhaustive cases. If @r < t@ then @t' = r@, so
-- @t' <= r < t' + h@ since @h >= 1@, and @t' = r >= 0@. If
-- @r >= t + h@ then @t' = r - h + 1 <= r@ and @r < t' + h = r + 1@, and
-- @t' >= t + 1 > 0@. Otherwise @t <= r < t + h@ already and @t' = t@.
clampTop :: Int -> Int -> Int -> Int
clampTop h r t
  | r < t      = r
  | r >= t + h = r - h + 1
  | otherwise  = t

-- | A terminal can report a degenerate size -- a zero-column window
-- mid-resize, or a pty with no window size set at all. This is the one
-- place that has to know: every measurement below is taken from a
-- window of at least one cell, so no downstream computation can produce
-- a negative width, a negative cursor position, or an empty frame.
usable :: (Int, Int) -> (Int, Int)
usable (w, h) = (max 1 w, max 1 h)

-- | The window is every row but the last, which the status line owns,
-- and never fewer than one.
body :: (Int, Int) -> Int
body = max 1 . subtract 1 . snd . usable

scroll :: (Int, Int) -> Editor -> Editor
scroll wh e = e { top = clampTop (body wh) (Doc.cursorRow (document e)) (top e) }

-- | Draws the window 'scroll' chose, then the status line, then places
-- the terminal cursor. Assumes 'scroll' has already run for this frame;
-- that is the loop's one obligation and the reason 'top' is read here
-- rather than recomputed.
render :: (Int, Int) -> Editor -> Vty.Picture
render wh0 e = (Vty.picForImage (Vty.vertCat (rows <> [bar]))) { Vty.picCursor = cur }
  where
    (w, h) = usable wh0
    rows   = map (Vty.text' Vty.defAttr . renderable) (Doc.window (top e) (body wh0) (document e))
    bar    = Vty.text' (Vty.defAttr `Vty.withStyle` Vty.reverseVideo)
                       (Text.justifyLeft w ' ' (Text.take w (renderable (statusLine e))))
    clamp lo hi = max lo . min hi
    -- A display with no cells has nowhere to put a cursor, and asking
    -- vty (6.6) to place one there is a segfault in the terminal layer,
    -- not an exception this code could catch. 'usable' keeps every
    -- measurement above well defined; this keeps the one value that is
    -- handed back to the terminal honest about a window that cannot
    -- show it.
    cur
      | uncurry (*) wh0 <= 0 = Vty.NoCursor
      | otherwise = Vty.Cursor
          (clamp 0 (w - 1) (Doc.unColumn (displayColumn (Doc.beforeCursor (document e)))))
          (clamp 0 (h - 1) (Doc.cursorRow (document e) - top e))

-- | One line, and the only channel the editor has to say anything: an
-- open prompt if there is one, otherwise the last status message,
-- otherwise the file name.
statusLine :: Editor -> Text.Text
statusLine e = case mode e of
  Prompt k b -> Text.cons (sigil k) b
  Normal     -> idle
  Insert _   -> "-- INSERT --"
  Replace _  -> "-- REPLACE --"
  where
    sigil ExCommand = ':'
    sigil Search    = '/'
    idle = maybe (name <> flag) id (status e)
    name = maybe "[No Name]" Text.pack (path e)
    flag = (if readOnly e then " [RO]" else "") <> (if modified e then " [+]" else "")
