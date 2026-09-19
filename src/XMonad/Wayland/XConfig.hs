-- | XMonad-compatible configuration surface for X11 users migrating to
-- Wayland.  Supports the classic entrypoint idiom:
--
-- > import XMonad.Wayland.XConfig
-- >
-- > main :: IO ()
-- > main = xmonad $ def
-- >   { modMask    = mod4Mask
-- >   , terminal   = "kitty"
-- >   , workspaces = ["1" .. "9"]
-- >   , layoutHook = tall ||| mirror ||| full
-- >   , keys       = [ ((mod4Mask, xK_Return), spawn "kitty")
-- >                  , ((mod4Mask, xK_j),      focusNext) ]
-- >   , startupHook = [startup "swaybg -i ~/wallpaper.png"]
-- >   }
--
-- Not supported in this release: xmonad-contrib modules, X11 hooks, the
-- 'X ()' monad, 'manageHook' and non-numeric workspace tags.  Each limit
-- produces a clear error at startup, never a silent fallback.
module XMonad.Wayland.XConfig
  ( XConfig(..), def, xmonad, toConfig
  , KeyMask, KeySym, noModMask, shiftMask, controlMask, mod1Mask, mod4Mask
  , xK_Return, xK_space, xK_Tab, xK_Escape, xK_Left, xK_Up, xK_Right, xK_Down
  , xK_Home, xK_End, xK_Page_Up, xK_Page_Down, xK_Print
  , xK_0, xK_1, xK_2, xK_3, xK_4, xK_5, xK_6, xK_7, xK_8, xK_9
  , xK_a, xK_b, xK_c, xK_d, xK_e, xK_f, xK_g, xK_h, xK_i, xK_j, xK_k, xK_l
  , xK_m, xK_n, xK_o, xK_p, xK_q, xK_r, xK_s, xK_t, xK_u, xK_v, xK_w, xK_x
  , xK_y, xK_z
  , xK_period, xK_comma, xK_slash, xK_semicolon, xK_apostrophe, xK_grave
  , xK_bracketleft, xK_bracketright, xK_minus, xK_equal, xK_backslash
  , xK_F1, xK_F2, xK_F3, xK_F4, xK_F5, xK_F6, xK_F7, xK_F8, xK_F9, xK_F10
  , xK_F11, xK_F12
  , tall, mirror, full, columns, rows, tabbed, stacking, (|||)
  , spawn, startup, pickWindow, focusNext, focusPrevious, swapNext, swapPrevious
  , swapMaster, nextLayout, shrink, expand, close, toggleFloat
  , toggleFullscreen, nextOutput, previousOutput, viewWS, shiftWS, restart
  , reload, stop
  ) where

import Data.List (nub)
import Data.Word (Word32)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Keymap (keySym)
import XMonad.Wayland.Runtime (run)
import XMonad.Wayland.Types

type KeyMask = Word32
type KeySym = Word32

-- | The migration-friendly configuration record.  Field names follow the
-- XMonad ones users already know; cursor settings stay in the advanced
-- 'Config' API.
data XConfig = XConfig
  { modMask :: !KeyMask
  , terminal :: !String
  , workspaces :: ![String]
  , layoutHook :: !LayoutHook
  , keys :: ![((KeyMask, KeySym), Action)]
  , startupHook :: ![Command]
  }

-- | A single layout or a chain of choices cycled by 'nextLayout'.
data LayoutHook = OneLayout Layout | Layouts Layout LayoutHook
  deriving (Eq, Show)

-- | Append a layout to the choice chain, exactly like XMonad's @(|||)@.
(|||) :: LayoutHook -> LayoutHook -> LayoutHook
(|||) (OneLayout layout) rest = Layouts layout rest
(|||) (Layouts layout chain) rest = Layouts layout ((|||) chain rest)

tall, mirror, full, columns, rows, tabbed, stacking :: LayoutHook
tall = OneLayout Tall
mirror = OneLayout Mirror
full = OneLayout Full
columns = OneLayout Columns
rows = OneLayout Rows
tabbed = OneLayout Tabbed
stacking = OneLayout Stacking

layoutChoices :: LayoutHook -> [Layout]
layoutChoices (OneLayout layout) = [layout]
layoutChoices (Layouts layout rest) = layout : layoutChoices rest

-- ── Modifier masks (River bitmask values) ──────────────────────────────
noModMask, shiftMask, controlMask, mod1Mask, mod4Mask :: KeyMask
noModMask = 0
shiftMask = 1
controlMask = 4
mod1Mask = 8
mod4Mask = 64

-- ── Keysyms (XKB numeric representation) ───────────────────────────────
xK_Return, xK_Tab, xK_Escape :: KeySym
xK_Return = 0xff0d
xK_Tab = 0xff09
xK_Escape = 0xff1b

xK_Left, xK_Up, xK_Right, xK_Down, xK_Home, xK_End, xK_Page_Up, xK_Page_Down
  , xK_Print :: KeySym
xK_Left = 0xff51
xK_Up = 0xff52
xK_Right = 0xff53
xK_Down = 0xff54
xK_Home = 0xff50
xK_End = 0xff57
xK_Page_Up = 0xff55
xK_Page_Down = 0xff56
xK_Print = 0xff61

xK_space, xK_period, xK_comma, xK_slash, xK_semicolon, xK_apostrophe, xK_grave
  , xK_bracketleft, xK_bracketright, xK_minus, xK_equal, xK_backslash :: KeySym
xK_space = keySym ' '
xK_period = keySym '.'
xK_comma = keySym ','
xK_slash = keySym '/'
xK_semicolon = keySym ';'
xK_apostrophe = keySym '\''
xK_grave = keySym '`'
xK_bracketleft = keySym '['
xK_bracketright = keySym ']'
xK_minus = keySym '-'
xK_equal = keySym '='
xK_backslash = keySym '\\'

xK_0, xK_1, xK_2, xK_3, xK_4, xK_5, xK_6, xK_7, xK_8, xK_9 :: KeySym
xK_0 = keySym '0'
xK_1 = keySym '1'
xK_2 = keySym '2'
xK_3 = keySym '3'
xK_4 = keySym '4'
xK_5 = keySym '5'
xK_6 = keySym '6'
xK_7 = keySym '7'
xK_8 = keySym '8'
xK_9 = keySym '9'

xK_a, xK_b, xK_c, xK_d, xK_e, xK_f, xK_g, xK_h, xK_i, xK_j, xK_k, xK_l, xK_m
  , xK_n, xK_o, xK_p, xK_q, xK_r, xK_s, xK_t, xK_u, xK_v, xK_w, xK_x, xK_y
  , xK_z :: KeySym
xK_a = keySym 'a'
xK_b = keySym 'b'
xK_c = keySym 'c'
xK_d = keySym 'd'
xK_e = keySym 'e'
xK_f = keySym 'f'
xK_g = keySym 'g'
xK_h = keySym 'h'
xK_i = keySym 'i'
xK_j = keySym 'j'
xK_k = keySym 'k'
xK_l = keySym 'l'
xK_m = keySym 'm'
xK_n = keySym 'n'
xK_o = keySym 'o'
xK_p = keySym 'p'
xK_q = keySym 'q'
xK_r = keySym 'r'
xK_s = keySym 's'
xK_t = keySym 't'
xK_u = keySym 'u'
xK_v = keySym 'v'
xK_w = keySym 'w'
xK_x = keySym 'x'
xK_y = keySym 'y'
xK_z = keySym 'z'

xK_F1, xK_F2, xK_F3, xK_F4, xK_F5, xK_F6, xK_F7, xK_F8, xK_F9, xK_F10, xK_F11
  , xK_F12 :: KeySym
xK_F1 = 0xffbe
xK_F2 = 0xffbf
xK_F3 = 0xffc0
xK_F4 = 0xffc1
xK_F5 = 0xffc2
xK_F6 = 0xffc3
xK_F7 = 0xffc4
xK_F8 = 0xffc5
xK_F9 = 0xffc6
xK_F10 = 0xffc7
xK_F11 = 0xffc8
xK_F12 = 0xffc9

-- ── Actions ─────────────────────────────────────────────────────────────
-- | Run a command through @\/bin\/sh -c@, like XMonad's 'spawn'.
spawn :: String -> Action
spawn command = RunCommand (Command "/bin/sh" ["-c", command])

-- | A startup command run once when the manager starts.
startup :: String -> Command
startup command = Command "/bin/sh" ["-c", command]

pickWindow, focusNext, focusPrevious, swapNext, swapPrevious, swapMaster, nextLayout
  , shrink, expand, close, toggleFloat, toggleFullscreen, nextOutput, previousOutput
  , restart, reload, stop :: Action
pickWindow = Pick
focusNext = FocusNext
focusPrevious = FocusPrevious
swapNext = SwapNext
swapPrevious = SwapPrevious
swapMaster = SwapMaster
nextLayout = NextLayout
shrink = Shrink
expand = Expand
close = Close
toggleFloat = ToggleFloat
toggleFullscreen = ToggleFullscreen
nextOutput = FocusNextOutput
previousOutput = FocusPreviousOutput
restart = Restart
reload = Reload
stop = Stop

-- | Focus the workspace whose tag parses as a positive number.
viewWS :: String -> Action
viewWS = View . readTag

-- | Move the focused window to the workspace whose tag parses as a positive
-- number.
shiftWS :: String -> Action
shiftWS = Shift . readTag

readTag :: String -> WorkspaceId
readTag tag = case reads tag of
  [(number, "")] | number > 0 -> number
  _ -> error ("workspace tag must be a positive number in this release: " ++ show tag)

-- ── Conversion ──────────────────────────────────────────────────────────
-- | Convert the migration-friendly record to the internal configuration,
-- reporting every unsupported or invalid choice before anything starts.
toConfig :: XConfig -> Either String Config
toConfig cfg
  | null (workspaces cfg) = Left "workspaces must not be empty"
  | nub (workspaces cfg) /= workspaces cfg =
      Left "workspaces must be unique"
  | any (not . numericTag) (workspaces cfg) =
      Left ("workspace tags must be positive numbers in this release: "
            ++ show (filter (not . numericTag) (workspaces cfg)))
  | otherwise = Right defaultConfig
      { terminalCommand = Command (terminal cfg) []
      , initialLayout = case choices of
          first:_ -> first
          [] -> Tall
      , layoutCycle = choices
      , workspaceIds = map read (workspaces cfg)
      , keyBindings = map convert (keys cfg)
      , startupCommands = startupHook cfg
      }
  where
    choices = layoutChoices (layoutHook cfg)
    numericTag tag = case reads tag of
      [(number, "")] -> number > 0
      _ -> False
    convert ((modifiers, symbol), action) =
      KeyBinding symbol modifiers NormalMode action

-- | Defaults mirror the generic executable: mod4Mask, Foot, nine numeric
-- workspaces and the Tall\/Mirror\/Full cycle.
def :: XConfig
def = XConfig
  { modMask = mod4Mask
  , terminal = "foot"
  , workspaces = map show [1..9]
  , layoutHook = tall ||| mirror ||| full
  , keys = defaultCompatKeys
  , startupHook = []
  }

defaultCompatKeys :: [((KeyMask, KeySym), Action)]
defaultCompatKeys =
  [ ((mod4Mask, xK_j), focusNext)
  , ((mod4Mask, xK_k), focusPrevious)
  , ((shiftMask + mod4Mask, xK_j), swapNext)
  , ((shiftMask + mod4Mask, xK_k), swapPrevious)
  , ((mod4Mask, xK_Return), Terminal)
  , ((shiftMask + mod4Mask, xK_Return), swapMaster)
  , ((mod4Mask, xK_space), nextLayout)
  , ((mod4Mask, xK_h), shrink)
  , ((mod4Mask, xK_l), expand)
  , ((shiftMask + mod4Mask, xK_c), close)
  , ((mod4Mask, xK_p), Launcher)
  , ((shiftMask + mod4Mask, xK_q), stop)
  , ((mod4Mask, xK_period), nextOutput)
  , ((mod4Mask, xK_comma), previousOutput)
  , ((mod4Mask, xK_t), toggleFloat)
  , ((mod4Mask, xK_f), toggleFullscreen)
  , ((mod4Mask, xK_v), pickWindow)
  ] ++ concat
  [ [((mod4Mask, digit), viewWS tag), ((shiftMask + mod4Mask, digit), shiftWS tag)]
  | (digit, tag) <- zip [xK_1 .. xK_9] (map show [1..9]) ]

-- | Run the manager with the given configuration.
xmonad :: XConfig -> IO ()
xmonad cfg = case toConfig cfg of
  Left problem -> ioError (userError ("invalid xmonad.hs configuration: " ++ problem))
  Right internal -> run internal
