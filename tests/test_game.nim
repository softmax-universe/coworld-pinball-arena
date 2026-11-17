## The game driver: one Episode after another on one table, with BASIC
## programs that arrive as messages from the page, the replay recording and
## the Episode summary.
##
## Each test plays the part of the page and of the person. Table programs go
## in through `receiveMessage`, and the person's part is a timer on the
## plunger: no flippers, so every ball drains and an Episode is over within a
## minute of game time. If a change to the physics makes a ball loop instead,
## the Episode clock still ends it, so the loops here wait that long at most.
##
## The bundled house and demo programs are not tested here: every test that
## needs a table sends its own small program.

import std/[json, sequtils, strutils, unittest]
import pinball/game

const
  QuickSettings = TableSettings(
    beamInTicks: 12,
    editsPerSecond: 4,
    buildBudget: 100,
    maxPieces: 128,
    buildPhaseTicks: 60)
  Second = TicksPerSecond
  EpisodeTickLimit = EpisodeClockTicks + 10 * Second
    ## An Episode cannot run longer than its clock.
  PlungerPeriodTicks = 120
  PlungerHoldTicks = 60
    ## The person pulls the plunger for half a second, once a second.
  KeepOutX = 240
  KeepOutY = 956
    ## Between the flippers, where nothing may be built.

# --- Programs ----------------------------------------------------------------

const
  LanesProgram = """
' Five rollovers above the drain, a rule that pays 5 points every two
' seconds, and one bumper where nothing may be built.
if built = 0 then
  built = 1
  for i = 0 to 4
    lane = create(kind_rollover, 180 + i * 30, 860, 0, 100, 1, 2)
  next
  blocked = create(kind_popbumper, 240, 956, 0, 100, 1, 0)
  rule = fsm()
  award = node(rule)
  doscore(rule, award, 5)
  timeout(rule, 0, award, 1)
  timeout(rule, award, 0, 1)
end if
"""
  LanesGroup = 2
  AwardNode = 1

  BumperProgram = """
' A pop bumper, and 100 points once for the program's own signal.
if built = 0 then
  built = 1
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
  rule = fsm()
  award = node(rule)
  doscore(rule, award, 100)
  edge(rule, 0, award, ev_scriptsignal, 0, 0, 1)
  signal(1)
end if
"""
  BumperScore = 100

  PostBody = """
if built = 0 then
  built = 1
  post = create(kind_rubberpost, 150, 300, 0, 100, 1, 0)
end if
"""
  PostProgram = "' One rubber post.\n" & PostBody
  PostNextEpisodeProgram = "' @effect next-episode\n" & PostBody
  PostNextBallProgram = "' @effect next-ball\n" & PostBody

  TargetProgram = """
' One drop target.
if built = 0 then
  built = 1
  target = create(kind_droptarget, 300, 450, 0, 100, 1, 0)
end if
"""

  TwelvePostsProgram = """
' @effect now
' Twelve rubber posts in three rows, all in one decision.
if built = 0 then
  built = 1
  for row = 0 to 2
    for column = 0 to 3
      post = create(kind_rubberpost, 100 + column * 60, 500 + row * 60, 0, 100, 1, 0)
    next
  next
end if
"""

  LatePostProgram = """
' A pop bumper at the start, and a rubber post three seconds in.
if built = 0 then
  built = 1
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
end if
if tick > 360 and late = 0 then
  late = 1
  post = create(kind_rubberpost, 150, 300, 0, 100, 1, 0)
end if
"""
  LatePostTick = 360

  # BASIC has no power operator.
  BrokenProgram = """
' Counts hits.
hits = hits + 1
bonus = hits ^ 2
"""

  FailingProgram = """
' A bumper and a rule that pays 5 points every two seconds. The third
' decision divides by zero.
runs = runs + 1
print "decision", runs
if built = 0 then
  built = 1
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
  rule = fsm()
  award = node(rule)
  doscore(rule, award, 5)
  timeout(rule, 0, award, 1)
  timeout(rule, award, 0, 1)
end if
if runs = 3 then share = 100 \ players
"""
  FailingLastLine = "decision 3"

  EndlessProgram = """
' Never returns.
while forever = 0
  spins = spins + 1
wend
"""

# --- Helpers -----------------------------------------------------------------

type
  NeedNotMet = object of CatchableError

  Session = ref object
    ## A game together with every message it has sent to the page so far.
    game: Game
    messages: seq[JsonNode]

template need(condition: bool) =
  ## A check that ends the test when it fails, because the rest of the test
  ## would mean nothing. (`require` of unittest ends the whole run.)
  check condition
  if not condition:
    raise newException(NeedNotMet, "the test cannot go on")

proc programMessage(name: string, version: int, source: string): string =
  $(%*{"type": "program", "name": name, "version": version, "source": source})

proc collect(session: Session) =
  for message in session.game.takeMessages():
    session.messages.add parseJson(message)

proc send(session: Session, message: string) =
  session.game.receiveMessage(message)
  session.collect()

proc newSession(mode = flipperHuman): Session =
  Session(game: newGame(GameOptions(settings: QuickSettings, flipperMode: mode)))

proc newSession(name: string, version: int, source: string): Session =
  ## A game whose table program arrived before the first tick, so it plays
  ## the first Episode from the start.
  result = newSession()
  result.send programMessage(name, version, source)

proc sent(session: Session, kind: string): seq[JsonNode] =
  session.messages.filterIt(it{"type"}.getStr == kind)

proc workPlunger(session: Session) =
  ## The person: pull the plunger once a second and let it go.
  let game = session.game
  if game.table.phase == episodeOver:
    return
  let phase = int(game.table.tick) mod PlungerPeriodTicks
  if phase == 0:
    game.humanInput Command(kind: cmdPlunger, pressed: true)
  elif phase == PlungerHoldTicks:
    game.humanInput Command(kind: cmdPlunger, pressed: false)

proc play(session: Session, ticks: int) =
  for _ in 0 ..< ticks:
    session.workPlunger()
    session.game.tick()
    session.collect()

proc playUntilBallInPlay(session: Session) =
  ## Through the build phase, to the tick that serves the first ball.
  for _ in 0 ..< 2 * QuickSettings.buildPhaseTicks:
    if session.game.table.phase == episodePlay:
      return
    session.play(1)

proc playToEnd(session: Session) =
  for _ in 0 ..< EpisodeTickLimit:
    if session.game.table.phase == episodeOver:
      return
    session.play(1)

proc pieces(game: Game, kind: ComponentKind): int =
  ## How many pieces of a kind are on the table. A piece that is fading out
  ## after its deletion does not count.
  for component in game.table.components:
    if component.kind == kind and component.phase != phaseFadingOut:
      inc result

proc summary(session: Session): JsonNode =
  ## The summary of the latest Episode that ended, or an empty object.
  let episodes = session.sent("episode")
  if episodes.len > 0: episodes[^1]{"summary"} else: newJObject()

proc endReasonWord(reason: EndReason): string =
  if reason == endClock: "clock" else: "lastBallDrained"

proc playedLanesEpisode(): Session =
  result = newSession("ramp-school", 3, LanesProgram)
  result.playToEnd()

# --- Tests -------------------------------------------------------------------

suite "game driver":

  test "an Episode runs to its end and its summary carries the score":
    let session = playedLanesEpisode()
    let game = session.game
    need game.table.phase == episodeOver
    # The program that arrived before the first tick built the table.
    check game.pieces(ckRollover) == 5
    check game.table.score > 0

    session.play(2 * Second)
    check session.sent("episode").len == 1
    check session.sent("programError").len == 0
    check session.summary{"score"}.getBiggestInt(-1) == game.table.score

  test "the Episode summary holds what the cogent needs":
    let session = playedLanesEpisode()
    let table = session.game.table
    let summary = session.summary
    need table.phase == episodeOver
    need summary.len > 0

    check summary{"program", "name"}.getStr == "ramp-school"
    check summary{"program", "version"}.getInt == 3
    check summary{"endReason"}.getStr == endReasonWord(table.endReason)
    check summary{"scriptError"}.kind == JNull

    # How long each ball lasted.
    let balls = summary{"balls"}.getElems
    check table.ballTicks.len >= BallsPerEpisode
    check balls.len == table.ballTicks.len
    if balls.len == table.ballTicks.len:
      for index, ball in balls:
        let seconds = table.ballTicks[index] / TicksPerSecond
        check abs(ball{"seconds"}.getFloat(-1) - seconds) <= 0.5

    # The pieces that were hit, and only those.
    let hitPieces = table.components.filterIt(it.hitCount > 0)
    let components = summary{"components"}.getElems
    check hitPieces.len > 0
    check components.len == hitPieces.len
    for piece in hitPieces:
      let entries = components.filterIt(it{"id"}.getInt == piece.id)
      check entries.len == 1
      if entries.len == 1:
        check entries[0]{"kind"}.getStr == "rollover"
        check entries[0]{"group"}.getInt == LanesGroup
        check entries[0]{"hits"}.getInt == piece.hitCount

    # The rule nodes that fired.
    let rules = summary{"rules"}.getElems
    check table.ruleFirings.anyIt(it.nodeIndex == AwardNode)
    check rules.len == table.ruleFirings.len
    for firing in table.ruleFirings:
      check rules.anyIt(it{"fsm"}.getInt == firing.fsmId and
        it{"node"}.getInt(-1) == firing.nodeIndex and it{"count"}.getInt == firing.count)

    # The bumper between the flippers, refused in the first decision.
    let rejected = summary{"rejectedEdits"}.getElems
    check rejected.len == 1
    if rejected.len == 1:
      check rejected[0]{"second"}.getFloat(-1) == 0.0
      check rejected[0]{"reason"}.getStr == "keepOut"
      check rejected[0]{"edit"}.getStr == "create"

  test "a replay of an Episode matches the original, and a changed recording does not":
    let session = playedLanesEpisode()
    let game = session.game
    need game.table.phase == episodeOver

    let recording = game.replay()
    check recording.settings == QuickSettings
    check recording.hashes.len == int(game.table.tick)
    check recording.commands.anyIt(it.seat == seatFlipper and it.kind == cmdPlunger)
    check recording.commands.anyIt(it.seat == seatArena and it.kind == cmdFsmCreate)
    # The refused bumper is recorded too: a rejected edit changes the table's
    # list of rejected edits, which is part of the hash.
    check recording.commands.anyIt(it.kind == cmdEdit and
      it.edit.pos == fixedVec2(fixed(int32(KeepOutX)), fixed(int32(KeepOutY))))
    check recording.verify()

    need recording.commands.len > 0
    need recording.hashes.len > 0

    var withoutFirstCommand = recording
    withoutFirstCommand.commands.delete 0
    check not withoutFirstCommand.verify()

    var withoutLaunch = recording
    for index, command in recording.commands:
      if command.kind == cmdPlunger and not command.pressed:
        withoutLaunch.commands.delete index
        break
    check withoutLaunch.commands.len == recording.commands.len - 1
    check not withoutLaunch.verify()

    var withChangedHash = recording
    let middle = withChangedHash.hashes.len div 2
    withChangedHash.hashes[middle] = withChangedHash.hashes[middle] xor 1
    check not withChangedHash.verify()

  test "the same programs and the same inputs give the same Episode twice":
    let
      first = playedLanesEpisode()
      second = playedLanesEpisode()
    need first.game.table.phase == episodeOver
    check first.game.table.score > 0
    check first.game.replay().hashes.len > 0
    check second.game.table.score == first.game.table.score
    check second.game.table.tick == first.game.table.tick
    check second.game.replay().hashes == first.game.replay().hashes

  test "a program takes effect at the next Episode unless it says otherwise":
    let session = newSession("first", 1, BumperProgram)
    let game = session.game
    session.playUntilBallInPlay()
    need game.table.phase == episodePlay

    session.send programMessage("second", 1, PostNextEpisodeProgram)
    session.send programMessage("third", 1, TargetProgram)   # No directive.
    let loaded = session.sent("programLoaded").filterIt(it{"name"}.getStr != "first")
    check loaded.len == 2
    if loaded.len == 2:
      check loaded[0]{"name"}.getStr == "second"
      check loaded[0]{"effect"}.getStr == "next-episode"
      check loaded[1]{"name"}.getStr == "third"
      check loaded[1]{"version"}.getInt == 1
      check loaded[1]{"effect"}.getStr == "next-episode"

    # The Episode in play stays on the table it has.
    session.playToEnd()
    need game.table.phase == episodeOver
    check game.pieces(ckPopBumper) == 1
    check game.pieces(ckRubberPost) == 0
    check game.pieces(ckDropTarget) == 0
    check session.summary{"program", "name"}.getStr == "first"

    # The next Episode is built by the newest program.
    session.send """{"type":"restart"}"""
    session.play(2 * ArenaDecisionTicks)
    check game.table.phase == episodeBuild
    check game.table.score == 0
    check game.pieces(ckDropTarget) == 1
    check game.pieces(ckRubberPost) == 0
    check game.pieces(ckPopBumper) == 0

  test "a next-ball program takes over when the next ball is served, and the score stays":
    let session = newSession("first", 1, BumperProgram)
    let game = session.game
    session.playUntilBallInPlay()
    need game.table.phase == episodePlay
    need game.table.ballNumber == 1

    session.send programMessage("second", 1, PostNextBallProgram)
    let loaded = session.sent("programLoaded").filterIt(it{"name"}.getStr == "second")
    check loaded.len == 1
    if loaded.len == 1:
      check loaded[0]{"effect"}.getStr == "next-ball"

    var changedDuringBallOne = false
    for _ in 0 ..< EpisodeTickLimit:
      session.play(1)
      if game.table.ballNumber != 1 or game.table.phase != episodePlay:
        break
      if game.pieces(ckRubberPost) > 0 or game.pieces(ckPopBumper) != 1:
        changedDuringBallOne = true
    check not changedDuringBallOne
    need game.table.phase == episodePlay
    need game.table.ballNumber == 2
    let tickOfBallTwo = game.table.tick

    session.play(2 * Second)
    check game.pieces(ckRubberPost) == 1
    check game.pieces(ckPopBumper) == 0
    check game.table.fsms.len == 0
    check game.table.score == BumperScore
    check game.table.tick > tickOfBallTwo
    check session.sent("episode").len == 0

  test "a program that says now replaces the table during play without waiting on the edit rate":
    let session = newSession("first", 1, BumperProgram)
    let game = session.game
    session.playUntilBallInPlay()
    session.play(Second)
    need game.table.phase == episodePlay
    check game.pieces(ckPopBumper) == 1
    let
      tickBefore = game.table.tick
      ballNumberBefore = game.table.ballNumber

    session.send programMessage("second", 1, TwelvePostsProgram)
    let loaded = session.sent("programLoaded").filterIt(it{"name"}.getStr == "second")
    check loaded.len == 1
    if loaded.len == 1:
      check loaded[0]{"effect"}.getStr == "now"

    # By the new program's first decision the old pieces are fading out and
    # all twelve new ones are on the table. The normal edit rate would have
    # let four through.
    session.play(2 * ArenaDecisionTicks)
    check game.pieces(ckPopBumper) == 0
    check game.pieces(ckRubberPost) == 12
    check game.table.rejectedEdits.len == 0
    check game.table.fsms.len == 0

    # The Episode itself goes on: the score, the ball number and the clock stay.
    session.play(2 * Second)
    check game.table.components.allIt(it.kind == ckRubberPost)
    check game.pieces(ckRubberPost) == 12
    check game.table.tick == tickBefore + uint32(2 * ArenaDecisionTicks + 2 * Second)
    check game.table.score == BumperScore
    check game.table.ballNumber == ballNumberBefore
    check game.table.phase == episodePlay

  test "a restart during an Episode starts a new one at once, on the newest program":
    let session = newSession("first", 1, BumperProgram)
    let game = session.game
    session.playUntilBallInPlay()
    session.play(Second)
    need game.table.phase == episodePlay
    check game.table.score == BumperScore

    session.send programMessage("second", 1, PostProgram)
    session.send """{"type":"restart"}"""
    session.play(1)
    check game.table.tick == 1
    check game.table.phase == episodeBuild
    check game.table.score == 0
    check game.table.ballNumber == 0
    check game.table.balls.len == 0
    check game.replay().hashes.len == 1

    session.play(2 * ArenaDecisionTicks)
    check game.pieces(ckRubberPost) == 1
    check game.pieces(ckPopBumper) == 0

  test "a compile error is reported once and the current program keeps playing":
    let session = newSession("steady", 1, LatePostProgram)
    let game = session.game
    session.play(Second)
    check game.pieces(ckPopBumper) == 1

    session.send programMessage("broken", 2, BrokenProgram)
    let errors = session.sent("programError")
    check errors.len == 1
    if errors.len == 1:
      check errors[0]{"name"}.getStr == "broken"
      check errors[0]{"version"}.getInt == 2
      check errors[0]{"stage"}.getStr == "compile"
      check "line 3" in errors[0]{"message"}.getStr
    check not session.sent("programLoaded").anyIt(it{"name"}.getStr == "broken")

    # The program in play makes its late edit all the same.
    session.play(LatePostTick)
    check game.pieces(ckRubberPost) == 1

    session.playToEnd()
    need game.table.phase == episodeOver
    check session.summary{"program", "name"}.getStr == "steady"

    # A restart plays the newest program that compiled.
    session.send """{"type":"restart"}"""
    session.play(2 * ArenaDecisionTicks)
    check game.table.phase == episodeBuild
    check game.pieces(ckPopBumper) == 1
    check session.sent("programError").len == 1

  test "a program that fails while running is reported once and its table keeps scoring":
    let session = newSession("fragile", 4, FailingProgram)
    let game = session.game
    session.play(Second)

    let errors = session.sent("programError")
    check errors.len == 1
    if errors.len == 1:
      check errors[0]{"name"}.getStr == "fragile"
      check errors[0]{"version"}.getInt == 4
      check errors[0]{"stage"}.getStr == "run"
      check errors[0]{"message"}.getStr.len > 0
      let output = errors[0]{"output"}.getElems
      check output.len == 3
      if output.len > 0:
        check output[^1].getStr == FailingLastLine

    # The table is frozen as the program left it, and its rule keeps paying.
    check game.pieces(ckPopBumper) == 1
    check game.table.fsms.len == 1
    let scoreAtFailure = game.table.score
    session.play(5 * Second)
    check game.table.score > scoreAtFailure
    check game.pieces(ckPopBumper) == 1

    session.playToEnd()
    need game.table.phase == episodeOver
    check session.sent("programError").len == 1
    let summary = session.summary
    check summary{"score"}.getBiggestInt(-1) == game.table.score
    check summary{"scriptError", "stage"}.getStr == "run"
    check summary{"scriptError", "message"}.getStr.len > 0
    let summaryOutput = summary{"scriptError", "output"}.getElems
    check summaryOutput.len == 3
    if summaryOutput.len > 0:
      check summaryOutput[^1].getStr == FailingLastLine

  test "a program that never returns is stopped and reported, and the game goes on":
    let session = newSession("endless", 1, EndlessProgram)
    let game = session.game
    session.play(Second)

    let errors = session.sent("programError")
    check errors.len == 1
    if errors.len == 1:
      check errors[0]{"name"}.getStr == "endless"
      check errors[0]{"stage"}.getStr == "budget"
      check errors[0]{"message"}.getStr.len > 0

    check game.table.tick == uint32(Second)
    check game.table.phase == episodePlay
    check game.table.balls.len == 1

    session.playToEnd()
    need game.table.phase == episodeOver
    check session.sent("programError").len == 1
    check session.summary{"scriptError", "stage"}.getStr == "budget"

  test "after an Episode the game waits for a restart":
    let session = playedLanesEpisode()
    let game = session.game
    need game.table.phase == episodeOver
    let endTick = game.table.tick

    session.play(5 * Second)
    check game.table.phase == episodeOver
    check game.table.tick == endTick
    check game.replay().hashes.len == int(endTick)
    check session.sent("episode").len == 1

    # The same program plays the next Episode, from an empty table.
    session.send """{"type":"restart"}"""
    session.play(1)
    check game.table.tick == 1
    check game.table.phase == episodeBuild
    check game.table.score == 0

    session.playToEnd()
    check game.table.phase == episodeOver
    check game.pieces(ckRollover) == 5
    check session.sent("episode").len == 2
    check session.summary{"program", "name"}.getStr == "ramp-school"
    check game.replay().verify()

  test "in demo mode the next Episode starts by itself":
    # Whatever the bundled programs do, the Episode clock ends the Episode.
    let session = newSession(flipperDemo)
    let game = session.game
    for _ in 0 ..< EpisodeTickLimit:
      if session.sent("episode").len > 0:
        break
      game.tick()
      session.collect()
    need session.sent("episode").len == 1

    for _ in 0 ..< 30 * Second:
      if game.table.phase != episodeOver:
        break
      game.tick()
      session.collect()
    check game.table.phase == episodeBuild
    check game.table.score == 0
    check session.sent("episode").len == 1
    check session.sent("programError").len == 0

  test "the bundled house program can be chosen by name":
    let session = newSession("first", 1, BumperProgram)
    session.send """{"type":"program","name":"house"}"""
    let loaded = session.sent("programLoaded")
    check loaded.len == 2
    if loaded.len == 2:
      check loaded[1]{"name"}.getStr == "house"
    session.play(Second)
    check session.sent("programError").len == 0
    check session.game.table.tick == uint32(Second)

  test "a program can start from the house table":
    # `' @table house` runs the bundled house program for one decision before
    # the program itself. The house program is a placeholder for now, so
    # there is no house table to look for. When it is written: send a program
    # with `' @table house` that adds one piece, and check that the house
    # pieces and the program's own piece are both on the table.
    skip()

  test "malformed and unknown messages are ignored":
    let session = newSession()
    let game = session.game
    for message in [
        "",
        "not json",
        "{",
        "[1, 2]",
        "7",
        """{"name":"nothing"}""",
        """{"type":7}""",
        """{"type":"teleport"}""",
        """{"type":"program"}""",
        """{"type":"program","name":"odd","version":"three","source":5}""",
        """{"type":"flipper"}""",
        """{"type":"flipper","mode":"sideways"}"""]:
      game.receiveMessage(message)
    check game.takeMessages().len == 0

    # The game is as it was: it plays, and it still takes a program.
    session.play(ArenaDecisionTicks)
    check game.table.tick == uint32(ArenaDecisionTicks)
    session.send programMessage("first", 1, BumperProgram)
    session.send """{"type":"restart"}"""
    session.play(2 * ArenaDecisionTicks)
    check session.sent("programLoaded").len == 1
    check session.sent("programError").len == 0
    check game.pieces(ckPopBumper) == 1
