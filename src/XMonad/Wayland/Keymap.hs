-- | Keysyms use the XKB numeric representation; modifiers use River's bitmask.
-- Commands are literal argv. Opt into a shell explicitly for pipelines.
module XMonad.Wayland.Keymap
  ( key, modeKey, keySym, super, shift, control, alt
  , keyReturn, keyEscape, keyTab, keyLeft, keyDown, keyUp, keyRight, keyPrint
  , defaultKeyBindings, validateKeyBindings, validateConfig, bindingAt, pickerBindings
  ) where

import Data.Bits ((.&.))
import Data.List (nub)
import qualified Data.Set as Set
import Data.Word (Word32)
import XMonad.Wayland.Types

key :: Word32 -> Word32 -> Action -> KeyBinding
key = modeKey NormalMode

modeKey :: BindingMode -> Word32 -> Word32 -> Action -> KeyBinding
modeKey mode symbol modifiers action = KeyBinding symbol modifiers mode action

-- Latin-1 is represented directly in XKB; other Unicode symbols use its marker.
keySym :: Char -> Word32
keySym c = if value <= 255 then value else 0x01000000 + value
  where value = fromIntegral (fromEnum c)

super, shift, control, alt :: Word32
super = 64
shift = 1
control = 4
alt = 8

keyReturn, keyEscape, keyTab, keyLeft, keyDown, keyUp, keyRight, keyPrint :: Word32
keyReturn = 0xff0d
keyEscape = 0xff1b
keyTab = 0xff09
keyLeft = 0xff51
keyDown = 0xff54
keyUp = 0xff52
keyRight = 0xff53
keyPrint = 0xff61

defaultKeyBindings :: [KeyBinding]
defaultKeyBindings =
  [ key (keySym 'j') super FocusNext
  , key (keySym 'k') super FocusPrevious
  , key (keySym 'j') shifted SwapNext
  , key (keySym 'k') shifted SwapPrevious
  , key keyReturn super Terminal
  , key keyReturn shifted SwapMaster
  , key (keySym ' ') super NextLayout
  , key (keySym 'h') super Shrink
  , key (keySym 'l') super Expand
  , key (keySym 'c') shifted Close
  , key (keySym 'p') super Launcher
  , key (keySym 'q') shifted Stop
  , key (keySym '.') super FocusNextOutput
  , key (keySym ',') super FocusPreviousOutput
  , key (keySym 't') super ToggleFloat
  , key (keySym 'f') super ToggleFullscreen
  ] ++ concat
  [ [key (keySym digit) super (View tag), key (keySym digit) shifted (Shift tag)]
  | (digit, tag) <- zip ['1'..'9'] [1..9] ]
  where shifted = super + shift

validateKeyBindings :: [KeyBinding] -> Either String ()
validateKeyBindings = go Set.empty
  where
    go _ [] = Right ()
    go seen (binding:rest)
      | bindingKeysym binding == 0 = Left "keybinding has NoSymbol keysym (zero)"
      | bindingModifiers binding .&. 0xffffff12 /= 0 = Left "keybinding has unknown or locked modifier bits"
      | Set.member chord seen = Left ("duplicate keybinding: " ++ show chord)
      | otherwise = go (Set.insert chord seen) rest
      where chord = (bindingMode binding, bindingKeysym binding, bindingModifiers binding)

validateConfig :: Config -> Either String ()
validateConfig cfg
  | null tags || any (<= 0) tags || nub tags /= tags =
      Left "workspaceIds must be nonempty, unique and positive"
  | null choices || nub choices /= choices =
      Left "layoutCycle must be nonempty and contain no duplicates"
  | initialMasterRatio cfg <= 0 || initialMasterRatio cfg >= 1 =
      Left "initialMasterRatio must lie between zero and one"
  | resizeIncrement cfg < 0 = Left "resizeIncrement must not be negative"
  | cursorSize cfg == 0 = Left "cursorSize must be positive"
  | otherwise = do
      validateKeyBindings (keyBindings cfg)
      mapM_ validAction (map bindingAction (keyBindings cfg))
  where
    tags = workspaceIds cfg
    choices = layoutCycle cfg
    validAction (View tag) = knownWorkspace tag
    validAction (Shift tag) = knownWorkspace tag
    validAction _ = Right ()
    knownWorkspace tag
      | tag `elem` tags = Right ()
      | otherwise = Left ("binding refers to unknown workspace " ++ show tag)

-- Letters the picker listens for while PickerMode is active. They are
-- registered after the user's bindings and are inert in every other mode.
pickerBindings :: [KeyBinding]
pickerBindings = map letterBinding (zip [0..] (['a'..'z'] ++ ['1'..'9']))
  ++ [KeyBinding keyEscape 0 PickerMode PickCancel]
  where
    letterBinding (index, symbol) = KeyBinding (keySym symbol) 0 PickerMode (PickCandidate index)

-- Check the mode again at dispatch, since earlier input in the same compositor
-- transaction may have switched modes after this key press was queued.
bindingAt :: [KeyBinding] -> BindingMode -> Word32 -> Maybe Action
bindingAt bindings mode index = at index (bindings ++ pickerBindings)
  where
    at _ [] = Nothing
    at 0 (binding:_)
      | bindingMode binding == mode = Just (bindingAction binding)
      | otherwise = Nothing
    at n (_:rest) = at (n - 1) rest
