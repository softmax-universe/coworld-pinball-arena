## The two bundled programs as shipped: the house table (`players/house.bas`)
## and the demo Flipper program (`players/demo_flipper.bas`).
##
## The game driver is not used here. Each test runs the programs the way the
## driver does: the Arena program decides every `ArenaDecisionTicks` ticks,
## the Flipper program every `FlipperDecisionTicks`, then the table steps.

import std/[sequtils, unittest]
import pinball/script/hosts

const
  HouseProgram = staticRead("../players/house.bas")
  DemoFlipperProgram = staticRead("../players/demo_flipper.bas")

  # What "no flipper player" means for the comparison: somebody still has to
  # launch the ball, or it would lie on the plunger until the clock ran out.
  PlungeOnlyProgram = """
' Plunges every ball at full strength and never flips.
waiting = 0
for i = 0 to ballcount - 1
  if balls(i).x > 480 and balls(i).y > 950 and abs(balls(i).vy) < 20 then waiting = 1
next
if waiting = 1 then plunger(1)
if plungerpull >= 1 then plunger(0)
"""

  QuestHint = "DROP 3 TARGETS TO LIGHT THE RAMP"
  JackpotScore = 50_000

# --- Helpers -----------------------------------------------------------------

template piece(game: untyped, pieceId: int32): untyped =
  game.components[game.componentIndex(pieceId)]

proc idsOfKind(game: Table, kind: ComponentKind): seq[int32] =
  for component in game.components:
    if component.kind == kind:
      result.add component.id

proc checkRunning(script: Script) =
  if script.status != scriptRunning:
    echo script.seat, " program stopped: ", script.status, ": ", script.error
  check script.status == scriptRunning

proc houseTableInPlay(): Table =
  ## The house table at the end of its build phase, with the first ball served.
  result = initTable()
  let house = loadScript(seatArena, HouseProgram)
  while result.phase == episodeBuild:
    if result.tick mod ArenaDecisionTicks == 0:
      house.decide(result)
    result.step()

proc deliver(game: var Table, event: Event) =
  ## Hand the table an event as if a ball had caused it, and run the tick
  ## that delivers it to the rules.
  game.pendingEvents.add event
  game.step()

proc dropBank(game: var Table) =
  for id in game.idsOfKind(ckDropTarget):
    game.piece(id).isDown = true
    game.deliver Event(kind: evDrop, componentId: id, group: game.piece(id).group, level: 1)

proc bankIsUp(game: Table): bool =
  game.idsOfKind(ckDropTarget).allIt(not game.piece(it).isDown)

proc flashingLamps(game: Table): int =
  game.components.countIt(it.kind == ckInsert and
    it.settings[setLamp] == fixed(int32(ord(lampFlashing))))

type Played = object
  game: Table
  arena, flipper: Script

proc playEpisode(flipperProgram: string): Played =
  ## One whole Episode on the house table.
  result.game = initTable()
  result.arena = loadScript(seatArena, HouseProgram)
  result.flipper = loadScript(seatFlipper, flipperProgram)
  # The clock ends an Episode, so the loop ends too. The bound is a guard.
  for _ in 0 .. EpisodeClockTicks + TicksPerSecond:
    if result.game.phase == episodeOver:
      break
    if result.game.tick mod ArenaDecisionTicks == 0:
      result.arena.decide(result.game)
    if result.game.tick mod FlipperDecisionTicks == 0:
      result.flipper.decide(result.game)
    result.game.step()

proc meanBallSeconds(game: Table): float =
  game.ballTicks.foldl(a + b, 0'i32) / (game.ballTicks.len * TicksPerSecond)

# --- Tests -------------------------------------------------------------------

suite "house table":

  test "the house program builds its whole table in its first decision":
    var game = initTable()
    let house = loadScript(seatArena, HouseProgram)
    house.checkRunning()
    house.decide(game)
    house.checkRunning()

    check game.rejectedEdits.len == 0
    check game.components.len > 0
    check game.fsms.len > 0
    check game.budgetUsed <= game.settings.buildBudget
    check game.components.len <= game.settings.maxPieces
    # No command at all was refused, rule commands included: every one is
    # accepted again by a fresh table.
    var fresh = initTable()
    check house.issued.allIt(fresh.apply(it).accepted)

    # The rest of the build phase adds nothing, and every piece turns solid.
    let pieceCount = game.components.len
    while game.phase == episodeBuild:
      if game.tick mod ArenaDecisionTicks == 0:
        house.decide(game)
        check house.issued.len == 0
      game.step()
    house.checkRunning()
    check game.components.len == pieceCount
    check game.components.allIt(it.phase == phaseSolid)
    check game.rejectedEdits.len == 0

  test "the quest pays the jackpot for a ramp shot while the ramp is lit":
    var game = houseTableInPlay()
    let tracks = game.idsOfKind(ckTrack)
    check game.idsOfKind(ckDropTarget).len == 3
    check tracks.len == 1
    check game.questText == QuestHint
    check game.flashingLamps == 0

    game.dropBank()
    check game.questText == "RAMP IS LIT"
    check game.flashingLamps == 1

    if tracks.len == 1:
      let before = game.score
      game.deliver Event(kind: evTrackCompleted, componentId: tracks[0], level: 1)
      check game.score - before >= JackpotScore
      check game.awardText == "JACKPOT 50,000"
      check game.questText == QuestHint
      check game.flashingLamps == 0
      check game.bankIsUp

      # The quest has started again: an unlit ramp pays only its ordinary score.
      let afterJackpot = game.score
      game.deliver Event(kind: evTrackCompleted, componentId: tracks[0], level: 1)
      check game.score > afterJackpot
      check game.score - afterJackpot < JackpotScore

  test "the quest is lost when the ramp is not shot in time":
    var game = houseTableInPlay()
    game.dropBank()
    let lit = game.score
    for _ in 0 ..< 19 * TicksPerSecond:
      game.step()
    check game.questText == "RAMP IS LIT"
    check game.flashingLamps == 1
    check not game.bankIsUp

    for _ in 0 ..< 2 * TicksPerSecond:
      game.step()
    check game.awardText == "TOO SLOW"
    check game.questText == QuestHint
    check game.flashingLamps == 0
    check game.bankIsUp
    check game.score == lit

suite "house table and demo flipper":

  test "an Episode runs to its end and the demo flipper keeps the ball alive":
    let demo = playEpisode(DemoFlipperProgram)
    demo.arena.checkRunning()
    demo.flipper.checkRunning()
    check demo.game.phase == episodeOver
    check demo.game.score > 0
    check demo.game.rejectedEdits.len == 0
    check demo.game.ballTicks.len >= BallsPerEpisode

    let unplayed = playEpisode(PlungeOnlyProgram)
    unplayed.flipper.checkRunning()
    check unplayed.game.phase == episodeOver
    check unplayed.game.ballTicks.len >= BallsPerEpisode
    if demo.game.ballTicks.len > 0 and unplayed.game.ballTicks.len > 0:
      # The margin is half again as long. In the experiments behind this
      # table the demo kept a ball about three and a half times as long.
      check demo.game.meanBallSeconds > 1.5 * unplayed.game.meanBallSeconds

  test "the same Episode played twice ends on the same score":
    let
      first = playEpisode(DemoFlipperProgram)
      second = playEpisode(DemoFlipperProgram)
    check first.game.phase == episodeOver
    check first.game.score == second.game.score
    check first.game.tick == second.game.tick
    check first.game.stateHash == second.game.stateHash
