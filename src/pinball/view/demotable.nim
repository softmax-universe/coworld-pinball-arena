## TEMPORARY SCAFFOLDING. Remove this module, and the `--demo-table` and
## `--demo-play` options in `pinball.nim`, when the bundled house program
## builds a real table.
##
## Until then nothing puts pieces on the table, so there is nothing to look
## at. `demoTick` builds one piece of every kind at the start of each Episode,
## with a build budget raised far above the real one and a build phase cut to
## half a second, and two small rules so that scores, a burst and the
## flashers can be seen. A few seconds in it adds one piece and removes one,
## to show a hologram and a fade-out. With `--demo-play` it also works the
## plunger and the flippers.
##
## The demo changes the table behind the driver's back: its edits are not in
## the Episode's recording, so a replay of a demo Episode does not check out.

import
  ../sim/simulation,
  ../game

const
  BuildPhaseTicks = 60
  LatePieceTick = 600       ## When the late piece is created and the old one deleted.
  LaunchPullTick = 240
  LaunchReleaseTick = 330
  FlipEveryTicks = 150
  FlipHoldTicks = 25

var doomedPostId: int32     ## The piece that `demoTick` deletes.

proc edit(game: Game, change: Edit): int32 =
  let outcome = game.table.apply(
    Command(tick: game.table.tick, seat: seatArena, kind: cmdEdit, edit: change))
  if not outcome.accepted:
    echo "Demo table: ", change.kind, " ", change.componentKind, " rejected: ", outcome.reason
  outcome.id

proc create(game: Game, kind: ComponentKind, x, y: int, rotation = 0, level = 1,
            group = 0, text = ""): int32 =
  game.edit(Edit(kind: editCreate, componentKind: kind,
    pos: fixedVec2(fixed(int32(x)), fixed(int32(y))), rotation: fixed(int32(rotation)),
    level: int32(level), group: int32(group), text: text))

proc setting(game: Game, id: int32, setting: Setting, value: int) =
  discard game.edit(Edit(kind: editSetting, targetId: id, setting: setting,
    value: fixed(int32(value))))

proc lamp(game: Game, id: int32, colour: LampColour, state: LampState) =
  game.setting(id, setColour, ord(colour))
  game.setting(id, setLamp, ord(state))

proc track(game: Game, mouthA, mouthB: int32, controlA, controlB: (int, int)) =
  let id = game.create(ckTrack, 0, 0)
  game.setting(id, setMouthA, mouthA)
  game.setting(id, setMouthB, mouthB)
  game.setting(id, setControlAX, controlA[0])
  game.setting(id, setControlAY, controlA[1])
  game.setting(id, setControlBX, controlB[0])
  game.setting(id, setControlBY, controlB[1])

proc arena(game: Game, command: Command): int32 =
  var command = command
  command.seat = seatArena
  command.tick = game.table.tick
  let outcome = game.table.apply(command)
  if not outcome.accepted:
    echo "Demo table: ", command.kind, " rejected: ", outcome.reason
  outcome.id

proc rule(game: Game, event: EventKind, results: openArray[NodeResult]) =
  ## A rule with one step: each time `event` happens, the results happen.
  let
    fsm = game.arena(Command(kind: cmdFsmCreate))
    node = game.arena(Command(kind: cmdFsmAddNode, fsmId: fsm))
  discard game.arena(Command(kind: cmdFsmAddEdge, fsmId: fsm,
    edge: Edge(fromNode: 0, toNode: node, event: event, value: -1, count: 1)))
  for nodeResult in results:
    discard game.arena(Command(kind: cmdFsmAddResult, fsmId: fsm, nodeIndex: node,
      result: nodeResult))

proc placeDemoTable(game: Game) =
  game.table.settings.buildBudget = 1000
  game.table.settings.buildPhaseTicks = BuildPhaseTicks

  game.rule(evHit, [NodeResult(kind: resultScore, amount: 500)])
  game.rule(evDrop, [NodeResult(kind: resultScore, amount: 2500),
    NodeResult(kind: resultBurst)])
  game.rule(evBallLaunched, [NodeResult(kind: resultFlashers),
    NodeResult(kind: resultBurst),
    NodeResult(kind: resultSound, sound: cueFanfare),
    NodeResult(kind: resultScore, amount: 1000),
    NodeResult(kind: resultPanelText, slot: slotQuest, text: "HIT THE BUMPERS"),
    NodeResult(kind: resultFloatText, text: "GO!")])

  # Bumpers.
  game.lamp(game.create(ckPopBumper, 175, 300), colourYellow, lampOn)
  game.lamp(game.create(ckPopBumper, 290, 300), colourRed, lampFlashing)
  game.lamp(game.create(ckPopBumper, 232, 395), colourBlue, lampOff)
  discard game.create(ckPassiveBumper, 130, 440)
  discard game.create(ckRubberPost, 350, 430)
  doomedPostId = game.create(ckRubberPost, 385, 468)
  discard game.create(ckSlingshot, 105, 830, rotation = 65)
  discard game.create(ckSlingshot, 375, 830, rotation = -65)

  # Targets.
  for index in 0 .. 2:
    discard game.create(ckDropTarget, 300 + index * 35, 562 - index * 12, rotation = -19, group = 1)
  game.lamp(game.create(ckStandupTarget, 50, 530, rotation = 80), colourRed, lampOn)
  discard game.create(ckStandupTarget, 62, 596, rotation = 80)
  game.lamp(game.create(ckToggleTarget, 440, 640, rotation = 100), colourYellow, lampOn)
  discard game.create(ckSpinner, 165, 540)
  for index in 0 .. 2:
    let id = game.create(ckRollover, 190 + index * 50, 168, rotation = 90)
    game.lamp(id, colourGreen, if index == 1: lampOn else: lampOff)
  let button = game.create(ckRollover, 240, 630)
  game.setting(button, setStyle, 1)
  game.lamp(button, colourBlue, lampFlashing)
  discard game.create(ckCaptiveBall, 440, 740, rotation = 270)

  # Holes and launchers.
  discard game.create(ckSaucer, 400, 250)
  discard game.create(ckScoop, 70, 335)
  discard game.create(ckBallLock, 425, 395)
  game.setting(game.create(ckKicker, 55, 760), setDirection, 315)
  discard game.create(ckKickback, 24, 880)
  discard game.create(ckMagnet, 240, 520)

  # Flow control.
  discard game.create(ckGate, 430, 530, rotation = 270)
  discard game.create(ckDiverter, 160, 650)
  discard game.create(ckUpPost, 240, 770)
  let guide = game.create(ckWall, 345, 735, rotation = 200)
  game.setting(guide, setLength, 130)
  game.setting(guide, setCurve, 70)
  let band = game.create(ckWall, 130, 735, rotation = -30)
  game.setting(band, setBounce, 1)
  let pad = game.create(ckWall, 300, 880, rotation = 10)
  game.setting(pad, setLength, 50)
  game.setting(pad, setBounce, 2)

  # A wire ramp from the playfield up to level 2, and a clear plastic lane on level 3.
  game.track(game.create(ckMouth, 395, 700, rotation = 90),
             game.create(ckMouth, 110, 150, rotation = 180, level = 2),
             (430, 330), (330, 105))
  game.track(game.create(ckMouth, 150, 250, rotation = 270, level = 3),
             game.create(ckMouth, 60, 690, rotation = 90, level = 3),
             (20, 380), (30, 560))

  # Lamps and text.
  for index, (colour, state) in [(colourYellow, lampOn), (colourRed, lampFlashing),
      (colourGreen, lampOn), (colourBlue, lampOff), (colourWhite, lampOn)]:
    game.lamp(game.create(ckInsert, 180 + index * 30, 705 - (if index in 1 .. 3: 12 else: 0)),
      colour, state)
  game.lamp(game.create(ckFlasher, 60, 200), colourWhite, lampOff)
  game.lamp(game.create(ckFlasher, 420, 165), colourRed, lampFlashing)
  game.setting(game.create(ckFloatingText, 240, 470, text = "DEMO TABLE"), setColour, ord(colourBlue))

proc demoTick*(game: Game, play: bool) =
  ## Call before every tick.
  let tick = int(game.table.tick)
  if tick == 0 and game.table.components.len == 0:
    placeDemoTable(game)
  if tick == LatePieceTick:
    game.lamp(game.create(ckPopBumper, 330, 215), colourGreen, lampOn)
    discard game.edit(Edit(kind: editDelete, targetId: doomedPostId))
  if not play:
    return
  if tick == LaunchPullTick:
    game.humanInput(Command(kind: cmdPlunger, pressed: true))
  elif tick == LaunchReleaseTick:
    game.humanInput(Command(kind: cmdPlunger, pressed: false))
  if tick > LaunchReleaseTick:
    let pressed = tick mod FlipEveryTicks < FlipHoldTicks
    for side in FlipperSide:
      if pressed != game.table.flippers[side].pressed:
        game.humanInput(Command(kind: cmdFlipper, side: side, pressed: pressed))
