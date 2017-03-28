
{-# LANGUAGE LambdaCase, RecursiveDo #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.FRPNow.GTK
-- Copyright   :  (c) Atze van der Ploeg 2015
-- License     :  BSD-style
-- Maintainer  :  atzeus@gmail.org
-- Stability   :  provisional
-- Portability :  portable
--
-- This module provides interoperability of FRPNow and the GTK system.

module Control.FRPNow.GTK(
  -- * General interface
  ffor, runNowGTK, setAttr, getSignal, getUnitSignal, getSimpleSignal, getClock,
  -- * Utility functions
  IconName, createLabel, createButton, createDynamicButton, createToggleButton,
  createEntry, createProgressBar,createSlider,

  runFileChooserDialog
  ) where

import Graphics.UI.Gtk
import Control.Applicative
import Control.FRPNow
import Data.Maybe
import Data.IORef
import Debug.Trace
import System.Mem.Weak
import System.Glib.GDateTime
import qualified Data.Text as T
import Data.Text (Text)

ffor :: (Functor f) => f a -> (a -> b) -> f b
ffor = flip fmap

-- | Run a Now computation which can interact with GTK. Also starts the GTK system.
-- Call only once, or GTK will freak out.
runNowGTK :: Now () -> IO ()
runNowGTK n = do initGUI
                 doneRef <- newIORef Nothing
                 initNow (schedule doneRef) (n >> return never)
                 mainGUI



schedule :: IORef (Maybe a) -> IO (Maybe a) -> IO ()
schedule ref m = postGUIAsync $
                   m >>= \x ->
                     case x of
                      Just _ -> writeIORef ref x
                      Nothing -> return ()

-- | Set a GTK attribute to a behavior. Each time the behavior changes the
-- attribute is updated.
setAttr :: (WidgetClass w, Eq a) => ReadWriteAttr w b a -> w -> Behavior a -> Now ()
setAttr a w b =
     do i <- sample b
        sync $ set w [a := i]
        (e,cb) <- callback
        sync $ on w unrealize ( cb ())
        let updates = toChanges b `beforeEs` e
        callIOStream setEm updates
  where setEm i = set w [a := i] >> widgetQueueDraw w


-- | Obtain an event stream from a unit GTK signal, i.e. a signal with handler type:
--
-- > IO ()
getUnitSignal :: GObjectClass widget => Signal widget (IO ()) -> widget -> Now (EvStream ())
getUnitSignal s w = getSignal s w (\f -> f ())


-- | Obtain an event stream from a GTK signal giving a single value.
getSimpleSignal :: GObjectClass widget => Signal widget (value -> IO ()) -> widget -> Now (EvStream value)
getSimpleSignal s w = getSignal s w id


-- | General interface to convert an GTK signal to an event stream.
--
-- The signal has type @callback@, for example @(ScrollType -> Double -> IO Bool)@
-- and the eventstream gives elements of type @value@, for instance @(ScrollType,Double)@
-- The conversion function (3rd argument) takes a function to call for producing the value
-- in our example, a function of type @(ScollType,Double) -> IO ()@ and produces
-- a function of the form @callback@, in our example @(ScrollType -> Double -> IO Bool)@.
--
-- In this example we can convert a signal with handler @(ScrollType -> Double -> IO Bool)@
-- to an eventstream giving elements of type @(ScrollType,Double)@ by letting the handler return @False@
-- as follows:
--
-- > scrollToEvStream :: Signal widget (ScrollType -> Double -> IO Bool) -> widget -> Now (EvStream (ScrollType,Double))
-- > scrollToEvStream s w = getSignal s w convert where
-- >   convert call scrolltype double = do call (scrolltype, double)
-- >                                       return False
--
-- The signal is automatically disconnected, when the event stream is garbage collected.
getSignal :: GObjectClass widget => Signal widget callback -> widget -> ((value -> IO ()) -> callback) -> Now (EvStream value)
getSignal s w conv =
   do (res,f) <- callbackStream
      conn <- sync $ on w s (conv f)
      --sync $ addFinalizer res (putStrLn "Run final" >> signalDisconnect conn)
      return res


-- | Get a clock that gives the time since the creation of the clock in seconds, and updates maximally even given number of seconds.
--
-- The clock is automatically destroyed and all resources associated with the clock are freed
-- when the behavior is garbage collected.
getClock :: Double -> Now (Behavior Double)
getClock precision =
  do start <- sync $ gGetCurrentTime
     (res,cb) <- callbackStream
     wres<- sync $ mkWeakPtr res Nothing
     let getDiff = do now <- gGetCurrentTime
                      let seconds = gTimeValSec now - gTimeValSec start
                      let microsec = gTimeValUSec now - gTimeValUSec start
                      return $ (fromIntegral seconds) + (fromIntegral microsec) * 0.000001
     let onTimeOut =
              deRefWeak wres >>= \x ->
                 case x of
                   Just _ -> getDiff >>= cb >> return True
                   Nothing -> return False
     sync $ timeoutAdd  onTimeOut (round (precision * 1000))
     sample $ fromChanges 0 res


--------------------------------------------------------------------------------

runFileChooserDialog :: FileChooserDialog -> Now (Event (Maybe FilePath))
runFileChooserDialog dialog = do
    (retev, cb) <- callback
    sync $ mdo
        conn <- on dialog response $ \resp -> do
            widgetHide dialog
            case resp of
                ResponseAccept -> do
                    mfn <- fileChooserGetFilename dialog
                    cb mfn
                _ -> cb Nothing
            signalDisconnect conn
        widgetShow dialog
    return retev


createLabel :: Behavior Text -> Now Label
createLabel s = do
     l <- sync $ labelNew (Nothing :: Maybe String)
     setAttr labelLabel l s
     return l

type IconName = T.Text

createDynamicButton :: Behavior Text ->  Now (Button,EvStream ())
createDynamicButton s = do
    button <- sync $ buttonNew
    setAttr buttonLabel button s
    stream <- getUnitSignal buttonActivated  button
    return (button,stream)

createButton :: Maybe IconName -> Maybe Text -> Now (Button, EvStream ())
createButton micon mlbl = do
    btn <- sync buttonNew
    iattr <- case micon of
        Just icon -> do
            img <- sync $ imageNewFromIconName icon IconSizeButton
            return [buttonImage := img]
        Nothing -> return []
    let tattr = maybeToList (fmap (buttonLabel :=) mlbl)
    sync $ set btn (iattr ++ tattr)
    pressed <- getUnitSignal buttonActivated btn
    return (btn, pressed)

createToggleButton :: Maybe IconName -> Maybe Text -> Bool -> Now (ToggleButton, Behavior Bool)
createToggleButton micon mlbl initstate = do
    btn <- sync toggleButtonNew
    iattr <- case micon of
        Just icon -> do
            img <- sync $ imageNewFromIconName icon IconSizeButton
            return [buttonImage := img]
        Nothing -> return []
    let tattr = maybeToList (fmap (buttonLabel :=) mlbl)
    sync $ set btn (iattr ++ tattr ++ [toggleButtonActive := initstate])
    updated <- getSignal toggled btn (toggleButtonGetActive btn >>=)
    st <- sample $ fromChanges initstate updated
    return (btn,st)

createEntry :: String -> Now (Entry, Behavior String)
createEntry inittext = do
    entry <- sync $ entryNew
    sync $ set entry [entryText := inittext]
    edits <- getSignal editableChanged entry (entryGetText entry >>=)
    btext <- sample $ fromChanges inittext edits
    return (entry, btext)

createProgressBar :: Behavior Double -> Now ProgressBar
createProgressBar progress = do
    bar <- sync $ progressBarNew
    setAttr progressBarFraction bar progress
    return bar

createSlider ::  Double -> Double -> Double -> Behavior Double -> Now (HScale,EvStream Double)
createSlider min max step b =
  do i <- sample b
     slider <- sync $ hScaleNewWithRange min max step
     setAttr rangeValue slider b
     stream <- getSignal changeValue slider (\f _ d -> f d >> return True)
     return (slider,stream)
