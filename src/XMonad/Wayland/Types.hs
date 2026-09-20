-- | Protocol-independent policy types. No X11 or compositor bindings.
module XMonad.Wayland.Types where

import Data.Word (Word32)

type WindowId = Word32
type OutputId = Word32
type SeatId = Word32
type WorkspaceId = Int

data Rect = Rect
  { rectX :: !Int, rectY :: !Int, rectWidth :: !Int, rectHeight :: !Int
  } deriving (Eq, Read, Show)

data Layout = Tall | Mirror | Full | Tabbed | Stacking | Rows | Columns
  deriving (Eq, Read, Show, Enum, Bounded)
data LayoutState = LayoutState
  { layoutKind :: !Layout, masterRatio :: !Rational
  } deriving (Eq, Read, Show)

-- | An executable and literal arguments, never interpreted by a shell.
data Command = Command FilePath [String] deriving (Eq, Read, Show)
data Direction = GoLeft | GoDown | GoUp | GoRight deriving (Eq, Read, Show)
data Axis = Width | Height deriving (Eq, Read, Show)
data BindingMode = NormalMode | ResizeMode | PickerMode deriving (Eq, Ord, Read, Show, Enum)
data KeyBinding = KeyBinding
  { bindingKeysym :: !Word32
  , bindingModifiers :: !Word32
  , bindingMode :: !BindingMode
  , bindingAction :: !Action
  } deriving (Eq, Read, Show)
data Config = Config
  { terminalCommand :: !Command
  , launcherCommand :: !Command
  , initialLayout :: !Layout
  , layoutCycle :: ![Layout]
  , initialMasterRatio :: !Rational
  , resizeIncrement :: !Rational
  , workspaceIds :: ![WorkspaceId]
  , keyBindings :: ![KeyBinding]
  , startupCommands :: ![Command]
  , cursorTheme :: !(Maybe String)
  , cursorSize :: !Word32
  } deriving (Eq, Read, Show)

data Action
  = FocusNext | FocusPrevious | SwapMaster | NextLayout | Shrink | Expand
  | View WorkspaceId | Shift WorkspaceId | Close | Terminal | Launcher
  | Stop | SwapNext | SwapPrevious
  | FocusNextOutput | FocusPreviousOutput | ToggleFloat | ToggleFullscreen
  | FocusDirection Direction | MoveDirection Direction | Sink | FocusModeToggle
  | SetLayout Layout | ToggleSplit | CycleSwayLayout | Resize Axis Int
  | EnterMode BindingMode | RunCommand Command | Reload | ConfirmExit Command
  | Restart | Pick | SwapToWindow WindowId | PickCandidate Int | PickCancel
  deriving (Eq, Read, Show)

data Event
  = OutputUpsert OutputId Rect | OutputRemoved OutputId | OutputWorkArea OutputId Rect
  | WindowAdded WindowId | WindowRemoved WindowId | FocusRequested WindowId
  | WindowParent WindowId (Maybe WindowId)
  | WindowSizeHints WindowId Int Int Int Int
  | WindowFullscreen WindowId Bool
  | WindowAppId WindowId String
  | WindowTitle WindowId String
  | PointerStarted SeatId WindowId Word32 Int Int
  | PointerMoved SeatId Int Int
  | PointerReleased SeatId | PointerCancelled SeatId
  | WindowActualSize WindowId Int Int
  | ActionRequested Action | Locked | Unlocked
  deriving (Eq, Show)

data Effect = CloseWindow WindowId | Spawn Command | StopRuntime | ReloadConfig
  | ConfirmSessionExit Command | RestartRuntime
  | ShowPicker [(Char, Rect)] | HidePicker
  deriving (Eq, Show)

data Placement = Placement
  { placementWindow :: !WindowId
  , placementRect :: !Rect
  , placementVisible :: !Bool
  , placementFocused :: !Bool
  , placementOutput :: !(Maybe OutputId)
  , placementFloating :: !Bool
  , placementFullscreen :: !Bool
  } deriving (Eq, Show)
