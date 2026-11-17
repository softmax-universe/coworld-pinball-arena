## The data model of the pinball simulation.
##
## Everything the simulation remembers lives in one `Table` value. The other
## modules in this folder are behaviour: each takes a `var Table` and changes
## the part of it that the module owns. Keeping the data in one place makes
## the state easy to hash (for replays), to copy, and to show to scripts.
##
## Rules for everything in `sim/`:
##
## - No floats. All maths is `Fixed` (Q16.16 from fixxy) or integers, so a
##   replay re-simulates to exactly the same state on every machine.
## - `Fixed * Fixed` wraps without warning once the result passes 32767. Never
##   multiply two lengths. Multiply a length by a unit vector or a small
##   factor, and compare distances with fixxy's `length` / `distance`.
## - Coordinates are millimetres. `x` grows to the right and `y` grows toward
##   the player, so the drain is at the largest `y`. Angles are degrees,
##   0 points along +x and angles grow clockwise as seen on screen.
## - Time is counted in ticks. One tick is one call of `step`.

import fixxy

export fixxy

const
  TicksPerSecond* = 120
  SubstepsPerTick* = 8
    ## Ball movement is integrated in smaller slices so that a fast ball
    ## cannot pass through a thin wall between two ticks.
  FlipperDecisionTicks* = 2   ## The Flipper script decides 60 times a second.
  ArenaDecisionTicks* = 10    ## The Arena script decides 12 times a second.

  PlayfieldWidth* = 520
  PlayfieldHeight* = 1080
  BallRadius* = 13.5'fx
  LevelCount* = 3

  MaxBallsInPlay* = 6
  BallsPerEpisode* = 3
  EpisodeClockTicks* = 8 * 60 * TicksPerSecond
  TiltWarningLimit* = 2       ## The nudge after this many warnings tilts.

  MaxFsms* = 32
  MaxNodesPerFsm* = 64        ## The initial node plus 63 others.
  MaxEdgesPerFsm* = 64
  MaxEdgeCount* = 255
  SignalCount* = 16           ## Per kind: 16 FSM signals and 16 script signals.
  MaxTextLength* = 40
  MaxScoreChange* = 1_000_000
  MinSizePercent* = 50
  MaxSizePercent* = 200

type
  TableSettings* = object
    ## The editing limits of one table. They are fixed for an Episode.
    beamInTicks*: int32
    editsPerSecond*: int32
    buildBudget*: int32
    maxPieces*: int32
    buildPhaseTicks*: int32

  # --- Balls, flippers, plunger ---------------------------------------------

  BallState* = enum
    ballFree      ## Rolling on the playfield under physics.
    ballHeld      ## Sitting in a component (saucer, scoop, lock, holding magnet).
    ballOnTrack   ## Travelling along a track curve.

  Ball* = object
    id*: int32
    state*: BallState
    pos*, vel*: FixedVec2   ## Millimetres and millimetres per second.
    spin*: Fixed            ## Surface speed from rotation, in mm/s. Positive is clockwise.
    level*: int32           ## 1 is the playfield. 2 and 3 are raised track.
    holderId*: int32        ## The component that holds the ball, or the track it is on.
    trackDistance*: Fixed   ## Distance travelled along the track from mouth A.
    trackSpeed*: Fixed      ## Speed along the track. Positive is toward mouth B.
    trackEntryMouthId*: int32
    ticksSinceLaunch*: int32
    quietTicks*: int32      ## Ticks without an event and with little movement, for ball search.

  FlipperSide* = enum
    flipperLeft, flipperRight

  Flipper* = object
    pressed*: bool
    angle*: Fixed            ## Degrees away from the rest position, 0 .. the full stroke.
    angularVelocity*: Fixed  ## Degrees per second. Positive is rising.
    holding*: bool
      ## The flipper has reached the top of its stroke since the press, so
      ## the coil is on its weaker hold power.

  Plunger* = object
    pressed*: bool
    pull*: Fixed             ## 0 is at rest and 1 is fully pulled back.
    fireSpeed*: Fixed        ## Speed of the released tip in mm/s. 0 when not firing.
    hasLaunched*: bool       ## This firing stroke has already reported its ball.

  NudgeDirection* = enum
    nudgeLeft, nudgeRight, nudgeUp

  # --- Collision shapes -------------------------------------------------------

  Surface* = enum
    surfaceMetal    ## Walls and guides: a firm bounce that loses some speed.
    surfaceRubber   ## A crisp, lively bounce.
    surfaceDead     ## Absorbs almost all of the impact.

  Collider* = object
    ## A capsule: every point within `radius` of the segment from `a` to `b`.
    ## A circle is a capsule whose ends are the same point. Physics only knows
    ## colliders. It does not know what kind of component owns one.
    a*, b*: FixedVec2
    radius*: Fixed
    surface*: Surface
    componentId*: int32      ## 0 for the fixed parts of the table.
    isSensor*: bool          ## Reports the ball but does not push it.
    kickSpeed*: Fixed        ## Extra speed added along the normal on a firm hit.
    passDirection*: FixedVec2
      ## Not zero for a one-way gate: a ball moving this way goes through.

  Contact* = object
    ## A ball touched a collider that belongs to a component.
    ballId*, componentId*: int32
    strength*: Fixed         ## Speed into the surface, in mm/s.
    normal*: FixedVec2       ## From the surface toward the ball.
    passed*: bool            ## The ball went through a one-way collider.

  # --- Components ------------------------------------------------------------

  ComponentKind* = enum
    ckNone
    # Bumpers
    ckPopBumper, ckPassiveBumper, ckSlingshot
    # Targets
    ckStandupTarget, ckDropTarget, ckToggleTarget, ckSpinner, ckRollover, ckCaptiveBall
    # Holes and launchers
    ckSaucer, ckScoop, ckBallLock, ckKicker, ckKickback
    # Magnets
    ckMagnet
    # Flow control
    ckGate, ckDiverter, ckUpPost, ckWall, ckRubberPost
    # Track
    ckMouth, ckTrack
    # Lights and text
    ckInsert, ckFlasher, ckFloatingText

  Setting* = enum
    ## The type-specific settings of a component. Each kind uses a few of
    ## these and ignores the rest. `components.nim` lists which kind uses
    ## which, with its default.
    setStrength     ## Kick or eject strength, or the pull of a magnet.
    setDirection    ## Eject or fire direction in degrees.
    setHoldTicks    ## How long a saucer holds the ball.
    setTravelTicks  ## How long a ball spends in a scoop's subway.
    setExitX        ## Where a scoop returns the ball.
    setExitY
    setCapacity     ## How many balls a lock holds.
    setRadius       ## The reach of a magnet.
    setMode         ## Magnet: 0 attract, 1 repel, 2 hold.
    setEnabled      ## 1 or 0. Magnet on, gate open, kickback lit, up-post raised.
    setPosition     ## Diverter: 0 or 1.
    setLength       ## Wall length, or the lane length of a captive ball.
    setCurve        ## Wall bend in degrees. 0 is straight.
    setBounce       ## Wall surface: 0 metal, 1 rubber, 2 dead.
    setStyle        ## Rollover: 0 lane style, 1 button style.
    setWidthA       ## Mouth: the width of the open end.
    setWidthB       ## Mouth: the width of the throat that joins the track.
    setMouthA       ## Track: the component id of each mouth.
    setMouthB
    setControlAX    ## Track: the control point next to each mouth.
    setControlAY
    setControlBX
    setControlBY
    setColour       ## A `LampColour`, for lamps, flashers and text.
    setLamp         ## A `LampState`.

  LampState* = enum
    lampOff, lampOn, lampFlashing

  LampColour* = enum
    colourYellow, colourRed, colourGreen, colourBlue, colourWhite

  ComponentPhase* = enum
    phaseBeamingIn   ## A hologram. It touches nothing yet.
    phaseSolid
    phaseFadingOut   ## Being deleted, or leaving its old place before a move.

  Component* = object
    id*: int32
    kind*: ComponentKind
    pos*: FixedVec2
    rotation*: Fixed        ## Degrees.
    sizePercent*: int32     ## 50 .. 200 percent of the normal size of the kind.
    level*: int32
    group*: int32           ## 0 is no group. Pieces that share a number form a bank.
    settings*: array[Setting, Fixed]
    text*: string           ## Only floating text uses this.

    phase*: ComponentPhase
    phaseTicks*: int32      ## Ticks left in the current phase.
    hasPendingMove*: bool   ## After fading out, beam in again with the values below.
    pendingPos*: FixedVec2
    pendingRotation*: Fixed
    pendingSizePercent*: int32

    isDown*: bool           ## Drop target: knocked down.
    face*: int32            ## Toggle target: 0 or 1.
    heldBallIds*: seq[int32]
    timerTicks*: int32      ## Hold, travel or cooldown time left.
    spinsLeft*: int32       ## Spinner: turns still to report.
    spinBallId*: int32      ## Spinner: the ball that set it turning.
    handledBallIds*: seq[int32]
      ## Balls the piece has reacted to (counted, fired, ejected, let go) and
      ## that have not left it yet. It reacts to a ball again only after the
      ## ball has gone, so one pass is one event and an ejected ball is not
      ## caught again on its way out.
    hitCount*: int32        ## For the Episode summary.
    colliders*: seq[Collider]
      ## Derived from the fields above while the piece is solid. Empty otherwise.

  # --- Events ----------------------------------------------------------------

  EventKind* = enum
    evNone
    # Component events (Appendix A)
    evHit, evDrop, evBankComplete, evReset, evFlip, evSpin, evRollover
    evCaptured, evReleased, evLocked, evFired, evUsedUp, evRelit
    evGrabbed, evPassed, evSwitched, evRaised, evLowered
    evTrackEntered, evTrackCompleted, evTrackFailed
    # Table events (Appendix B)
    evFlipperUp, evFlipperDown, evFlipperFullyRaised
    evPlungerPulled, evBallLaunched
    evNudge, evTiltWarning, evTilt
    evBallDrained, evBallSaved, evBallAdded, evBallCountChanged, evBallChangedLevel
    evComponentCreated, evComponentRemoved, evEditRejected
    evFsmSignal, evScriptSignal
    evClockThreshold
    evBuildPhaseEnded, evEpisodeEnding
    evProgramLoaded

  Event* = object
    ## Something that happened during a tick. Rules react to events, the view
    ## plays sounds for them, and the Episode summary counts them.
    kind*: EventKind
    componentId*: int32   ## 0 when no component is involved.
    group*: int32
    level*: int32
    ballId*: int32
    strength*: Fixed      ## Impact speed in mm/s for hits, else 0.
    value*: int32
      ## Depends on the kind: the flipper side, the new face of a toggle
      ## target, the signal number, the number of balls in play, or the
      ## minutes on the clock.

  # --- Edits -----------------------------------------------------------------

  EditKind* = enum
    editCreate, editMove, editRotate, editResize, editDelete
    editSetting   ## Change one setting. Takes effect at once, with no beam-in.
    editText      ## Change the text of a floating text.
    editReset     ## Raise a drop target again, or relight a kickback.

  Edit* = object
    ## One change to the arena. The Arena script makes edits directly and
    ## rule nodes make them as results. Both go through the same checks.
    kind*: EditKind
    targetId*: int32      ## The component to change. Not used by `editCreate`.
    targetGroup*: int32   ## If set, the edit applies to every piece of the group.
    componentKind*: ComponentKind
    pos*: FixedVec2
    rotation*: Fixed
    sizePercent*: int32
    level*: int32
    group*: int32
    setting*: Setting
    value*: Fixed
    text*: string

  RejectReason* = enum
    rejectNone
    rejectKeepOut        ## Inside a keep-out zone or off the playfield.
    rejectOverBudget
    rejectTooManyPieces
    rejectOverlap
    rejectRateLimit
    rejectUnknownTarget  ## No such component, FSM, node or signal.
    rejectBadValue       ## A size, level, setting, count or text outside its limits.
    rejectLimit          ## Too many FSMs, nodes or edges.
    rejectNotAllowed     ## The seat may not give this command, or the Episode is over.

  # --- Rules -----------------------------------------------------------------

  SoundCue* = enum
    ## The fixed sound library that rule nodes pick from. The view also plays
    ## some of these by itself for physical events.
    cueNone
    cuePing, cueBell, cueChime, cueThunk, cueClack, cuePop, cueSling
    cueSpinner, cueRollover, cueDrop, cueResetBank
    cueLaunch, cueDrain, cueBallSave, cueExtraBall
    cueKick, cueHole, cueLock, cueMagnet, cueGate
    cueBeamIn, cueFadeOut, cueSweepUp, cueSweepDown
    cueFanfare, cueJackpot, cueQuestStart, cueQuestFail
    cueWarning, cueTilt, cueGameOver, cueProgramLoaded

  BallAction* = enum
    ballActionAdd        ## Serve another ball (multiball).
    ballActionRelease    ## Release the balls held by a component or group.
    ballActionSave       ## Start a ball save.
    ballActionExtraBall  ## Award an extra ball.

  PanelSlot* = enum
    slotQuest   ## Upper message box: the current quest.
    slotAward   ## Lower message box: the last award or status.

  ResultKind* = enum
    resultScore, resultSound, resultLamp, resultFlashers, resultBurst
    resultPanelText, resultFloatText, resultEdit, resultBallAction, resultSignal

  NodeResult* = object
    ## One thing that happens when an FSM enters a node.
    kind*: ResultKind
    amount*: int32        ## Score change, signal number, or ball-save ticks.
    targetId*: int32      ## The component a lamp, burst, text or release is aimed at.
    targetGroup*: int32
    lamp*: LampState
    sound*: SoundCue
    slot*: PanelSlot
    text*: string
    ballAction*: BallAction
    edit*: Edit

  Edge* = object
    ## A transition between two nodes. It fires on an event that passes every
    ## filter, on the `count`-th such event since the FSM entered `fromNode`.
    ## A timeout edge fires after `timeoutTicks` in `fromNode` instead.
    fromNode*, toNode*: int32
    isTimeout*: bool
    timeoutTicks*: int32
    event*: EventKind
    componentId*: int32   ## 0 matches any component.
    group*: int32         ## 0 matches any group.
    level*: int32         ## 0 matches any level.
    value*: int32         ## -1 matches any value. See `Event.value`.
    minStrength*: Fixed
    count*: int32         ## 1 .. 255.

  Node* = object
    results*: seq[NodeResult]
    isFinal*: bool        ## Entering a final node stops the FSM.

  Fsm* = object
    id*: int32
    nodes*: seq[Node]     ## Node 0 is the initial node.
    edges*: seq[Edge]
    currentNode*: int32
    ticksInNode*: int32
    edgeHits*: seq[int32] ## Matching events seen per edge since entering the node.
    stopped*: bool

  # --- Commands --------------------------------------------------------------

  Seat* = enum
    seatFlipper, seatArena

  CommandKind* = enum
    # Flipper player
    cmdFlipper, cmdPlunger, cmdNudge
    # Arena player
    cmdEdit
    cmdFsmCreate, cmdFsmDelete, cmdFsmReset
    cmdFsmAddNode, cmdFsmAddEdge, cmdFsmAddResult, cmdFsmSetFinal
    cmdSignal
    cmdClearArena   ## Remove every piece and FSM, when a new program takes over.

  Command* = object
    ## Everything a player can do to the table, human or script. Commands are
    ## the only input of the simulation, so a replay is the list of accepted
    ## commands with the tick of each.
    tick*: uint32
    seat*: Seat
    kind*: CommandKind
    side*: FlipperSide
    pressed*: bool
    direction*: NudgeDirection
    edit*: Edit
    fsmId*: int32
    nodeIndex*: int32
    edge*: Edge
    result*: NodeResult
    signal*: int32

  CommandOutcome* = object
    reason*: RejectReason  ## `rejectNone` when the command was accepted.
    id*: int32             ## The new component id, FSM id or node index.

  # --- Episode ---------------------------------------------------------------

  EpisodePhase* = enum
    episodeBuild     ## The build phase before the first ball.
    episodePlay      ## A ball is in the shooter lane or in play.
    episodeOver

  EndReason* = enum
    endNone, endLastBallDrained, endClock

  LaunchSave* = enum
    ## The ball save that starts by itself. Each ball number gets one, and it
    ## gives back one ball at most.
    launchSaveReady     ## This ball number has not been launched yet.
    launchSaveRunning   ## `ballSaveTicks` is counting this save down.
    launchSaveSpent

  ScoreChange* = object
    amount*: int32
    componentId*: int32   ## The component whose event led to the change, or 0.

  CueKind* = enum
    cueKindSound, cueKindFlashers, cueKindBurst

  ViewCue* = object
    ## A request for a sound or a visual effect. Cues do not change the game.
    kind*: CueKind
    sound*: SoundCue
    componentId*: int32

  FloatingMessage* = object
    componentId*: int32
    text*: string
    ticksLeft*: int32

  RuleFiring* = object
    fsmId*, nodeIndex*, count*: int32

  RejectedEdit* = object
    tick*: uint32
    reason*: RejectReason
    edit*: Edit

  Table* = object
    settings*: TableSettings
    tick*: uint32

    balls*: seq[Ball]
    flippers*: array[FlipperSide, Flipper]
    plunger*: Plunger
    nextBallId*: int32

    components*: seq[Component]
    nextComponentId*: int32
    budgetUsed*: int32
    editsThisSecond*: int32   ## Rate-limited edits in the current one-second window.
    editWindowSecond*: uint32
      ## Which second of the Episode `editsThisSecond` counts. The windows
      ## are whole seconds from tick 0.
    freeEditsUntilTick*: uint32
      ## Script edits are not rate-limited before this tick. Set when the
      ## arena is cleared for a new program, so that it can lay out its table.

    fsms*: seq[Fsm]
    nextFsmId*: int32

    phase*: EpisodePhase
    endReason*: EndReason
    ballNumber*: int32            ## 1 .. 3 while playing.
    ballStartTick*: uint32        ## When the current ball number was first served.
    extraBalls*: int32
    ballSaveTicks*: int32         ## Ticks of ball save left.
    launchSave*: LaunchSave
    tiltWarnings*: int32
    tiltMeterTicks*: int32
      ## How shaken the table is. Each nudge adds to it and it falls by one
      ## every tick. A nudge that takes it over the limit warns or tilts.
    tilted*: bool                 ## Flippers are dead until the ball drains.
    score*: int64
    questText*, awardText*: string
    floatingMessages*: seq[FloatingMessage]

    # Outputs of the current tick. `step` clears them at the start of a tick.
    events*: seq[Event]
    pendingEvents*: seq[Event]
      ## Events raised outside the physics of a tick: by commands, by edits
      ## and by rule results (signals included). `step` moves them into
      ## `events` at the start of the next tick, so a rule can never react to
      ## its own results within one tick.
    contacts*: seq[Contact]
    cues*: seq[ViewCue]
    scoreChanges*: seq[ScoreChange]

    # Totals for the Episode summary.
    ballTicks*: seq[int32]        ## How long each ball lasted.
    ruleFirings*: seq[RuleFiring]
    rejectedEdits*: seq[RejectedEdit]

const DefaultSettings* = TableSettings(
  beamInTicks: TicksPerSecond div 2,
  editsPerSecond: 4,
  buildBudget: 100,
  maxPieces: 128,
  buildPhaseTicks: 10 * TicksPerSecond
)

proc accepted*(outcome: CommandOutcome): bool =
  outcome.reason == rejectNone

proc emit*(table: var Table, event: Event) =
  ## For events that happen inside a tick, before the rules run.
  table.events.add event

proc emitNext*(table: var Table, event: Event) =
  ## For events from commands, edits and rule results. See `pendingEvents`.
  table.pendingEvents.add event

proc componentIndex*(table: Table, id: int32): int =
  ## The index of the component with this id, or -1.
  for index, component in table.components:
    if component.id == id:
      return index
  -1

proc ballIndex*(table: Table, id: int32): int =
  for index, ball in table.balls:
    if ball.id == id:
      return index
  -1

proc fsmIndex*(table: Table, id: int32): int =
  for index, fsm in table.fsms:
    if fsm.id == id:
      return index
  -1

const TextCharacters = {'A' .. 'Z', '0' .. '9', ' ',
                        '!', '?', '.', ',', ':', ';', '\'', '"', '-', '+', '*', '/',
                        '%', '&', '#', '=', '<', '>', '(', ')'}

proc isValidText*(text: string): bool =
  ## The rule for all text that comes from an Arena script (Appendix C).
  if text.len > MaxTextLength:
    return false
  for character in text:
    if character notin TextCharacters:
      return false
  true
