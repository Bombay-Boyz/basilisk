{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The only module that performs IO. It reads an event, asks
-- 'Basilisk.Decode' what it means, asks 'Basilisk.Step' what happens,
-- performs whatever effects come back, and repeats.
--
-- The frame is drawn at the /top/ of the iteration, before the blocking
-- read. That one ordering is what makes the first frame appear before
-- the first keystroke, and what makes a terminal resize repaint: the
-- size is re-read every iteration, so a resize needs no event handling,
-- no 'Resize' action and no special case anywhere.
module Basilisk.Loop (run) where

import Control.Exception (bracket)
import Control.Monad (foldM)
import qualified Graphics.Vty as Vty
import Graphics.Vty.Platform.Unix (mkVty)

import Basilisk.Decode (KeyState, decode, initialKeyState)
import qualified Basilisk.File as File
import Basilisk.Render (render, scroll)
import Basilisk.Step (step)
import Basilisk.Types

-- | 'bracket' guarantees the terminal returns to cooked mode whether the
-- loop returns, throws, or the process is asked to exit, so nothing
-- inside the loop needs exception handling of its own.
run :: Maybe FilePath -> IO ()
run mfp = do
  e0 <- maybe (pure (newEditor Nothing "")) File.openFile mfp
  bracket (mkVty Vty.defaultConfig) Vty.shutdown (\vty -> loop vty initialKeyState e0)

-- | Tail recursive and strict in both pieces of carried state; with
-- 'StrictData' on every field of 'Editor' this leaves no thunk chain
-- across keystrokes and the stack is @O(1)@ for the life of the session.
loop :: Vty.Vty -> KeyState -> Editor -> IO ()
loop vty !ks !e = do
  wh <- Vty.displayBounds (Vty.outputIface vty)
  let shown = scroll wh e
  Vty.update vty (render wh shown)
  ev <- Vty.nextEvent vty
  case decode (mode shown) ks ev of
    (ks', Nothing)  -> loop vty ks' shown
    (ks', Just act) -> do
      let (!next, effects) = step act shown
      (done, quitRequested) <- foldM perform (next, False) effects
      if quitRequested
        then Vty.update vty (render wh (scroll wh done))
        else loop vty ks' done

-- | The one place an 'Effect' becomes IO. Explicit quit effects are
-- honored by the loop; write effects request quit only after success.
-- A successful write is the only place the buffer becomes clean, and it
-- records the stamp the writer observed rather than re-stat'ing and
-- racing with itself. The quit bit is honored only after that success.
perform :: (Editor, Bool) -> Effect -> IO (Editor, Bool)
perform (e, quitRequested) (WriteFile p t force quitOnSuccess) = do
  result <- File.writeDocument p t force (stamp e)
  pure $ case result of
    Left why -> (e { status = Just why }, quitRequested)
    Right mark ->
      ( (onBuffer (\b -> b { bSaved = bVersion b, bStamp = mark }) e)
          { status = Just "written" }
      , quitRequested || quitOnSuccess
      )
perform (e, _) RequestQuit = pure (e, True)
