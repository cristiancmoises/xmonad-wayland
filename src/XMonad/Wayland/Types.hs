-- | Protocol-independent policy types. No X11 or compositor bindings.
module XMonad.Wayland.Types where

import Data.Word (Word32)

type WindowId = Word32
type OutputId = Word32
type WorkspaceId = Int

data Rect = Rect
  { rectX :: !Int, rectY :: !Int, rectWidth :: !Int, rectHeight :: !Int
  } deriving (Eq, Show)

data Layout = Tall | Mirror | Full deriving (Eq, Show, Enum, Bounded)
data LayoutState = LayoutState
  { layoutKind :: !Layout, masterRatio :: !Rational
  } deriving (Eq, Show)

-- | An executable and literal arguments, never interpreted by a shell.
data Command = Command FilePath [String] deriving (Eq, Show)
data Config = Config
  { terminalCommand :: !Command
  , launcherCommand :: !Command
  , initialLayout :: !Layout
  , initialMasterRatio :: !Rational
  , resizeIncrement :: !Rational
  } deriving (Eq, Show)

data Action
  = FocusNext | FocusPrevious | SwapMaster | NextLayout | Shrink | Expand
  | View WorkspaceId | Shift WorkspaceId | Close | Terminal | Launcher
  | Stop | SwapNext | SwapPrevious
  deriving (Eq, Show)

data Event
  = OutputUpsert OutputId Rect | OutputRemoved OutputId
  | WindowAdded WindowId | WindowRemoved WindowId | FocusRequested WindowId
  | ActionRequested Action | Locked | Unlocked
  deriving (Eq, Show)

data Effect = CloseWindow WindowId | Spawn Command | StopRuntime
  deriving (Eq, Show)

data Placement = Placement
  { placementWindow :: !WindowId
  , placementRect :: !Rect
  , placementVisible :: !Bool
  , placementFocused :: !Bool
  } deriving (Eq, Show)
