## BASIC programs in the two seats: an Arena program builds the table and its
## rules, a Flipper program presses the flippers.
##
## Each test loads a BASIC program, calls `decide` the way the driver will
## (the Arena program every `ArenaDecisionTicks` ticks, the Flipper program
## every `FlipperDecisionTicks`) and looks at what happened to the table.
## What a program saw is read from what it printed. Pieces stand at
## (200, 400), (150, 300) and (300, 450), where the table has no fixed parts.

import std/[sequtils, strutils, unittest]
import pinball/sim/catalogue
import pinball/script/hosts

# --- Helpers -----------------------------------------------------------------

proc decisionTicks(script: Script): uint32 =
  if script.seat == seatArena: ArenaDecisionTicks else: FlipperDecisionTicks

proc play(game: var Table, script: Script, ticks: int) =
  ## Whole ticks as the driver runs them: the program decides, then the
  ## table steps.
  for _ in 0 ..< ticks:
    if game.tick mod script.decisionTicks == 0:
      script.decide(game)
    game.step()

proc checkRunning(script: Script) =
  if script.status != scriptRunning:
    echo "script stopped: ", script.status, ": ", script.error
  check script.status == scriptRunning

proc lastLine(script: Script): string =
  if script.output.len > 0: script.output[^1] else: ""

proc idsOfKind(game: Table, kind: ComponentKind): seq[int32] =
  for component in game.components:
    if component.kind == kind:
      result.add component.id

template piece(game: untyped, pieceId: int32): untyped =
  game.components[game.componentIndex(pieceId)]

proc deliver(game: var Table, event: Event) =
  ## Hand the table an event as if a ball had caused it, and run the tick
  ## that delivers it to the rules.
  game.pendingEvents.add event
  game.step()

proc putBall(game: var Table, id: int32, x, y: Fixed, velX = 0'fx, velY = 0'fx) =
  game.balls.add Ball(id: id, state: ballFree, level: 1,
    pos: fixedVec2(x, y), vel: fixedVec2(velX, velY))

proc hasCue(game: Table, kind: CueKind, sound = cueNone): bool =
  game.cues.anyIt(it.kind == kind and it.sound == sound)

# --- Programs ----------------------------------------------------------------

const
  BumperProgram = """
' A pop bumper that scores 5 and pings on every hit.
if built = 0 then
  built = 1
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
  rule = fsm()
  award = node(rule)
  doscore(rule, award, 5)
  dosound(rule, award, cue_ping)
  edge(rule, 0, award, ev_hit, bumper, 0, 1)
end if
"""

  QuestProgram = """
' The quest of Figure 2: drop the bank, then shoot the ramp within 20 seconds.
if built = 0 then
  built = 1
  bank = 1
  for i = 0 to 2
    target = create(kind_droptarget, 160 + i * 40, 300, 0, 100, 1, bank)
  next
  ramplamp = create(kind_insert, 300, 450, 0, 100, 1, 0)
  mouthin = create(kind_mouth, 150, 500, 0, 100, 1, 0)
  mouthout = create(kind_mouth, 400, 500, 180, 100, 1, 0)
  ramp = track(mouthin, mouthout, 200, 420, 350, 420)

  quest = fsm()
  bankdown = node(quest)
  jackpot = node(quest)
  missed = node(quest)
  edge(quest, 0, bankdown, ev_drop, 0, bank, 3)
  edge(quest, bankdown, jackpot, ev_trackcompleted, ramp, 0, 1)
  timeout(quest, bankdown, missed, 20)

  dolamp(quest, bankdown, ramplamp, lamp_on)
  domessage(quest, bankdown, slot_quest, "RAMP IS LIT")
  doscore(quest, jackpot, 50000)
  doflash(quest, jackpot)
  dosound(quest, jackpot, cue_fanfare)
  doresetgroup(quest, jackpot, bank)
  dolamp(quest, missed, ramplamp, lamp_off)
  domessage(quest, missed, slot_quest, "TOO SLOW")
  doresetgroup(quest, missed, bank)
end if
"""
  # The node indexes that `QuestProgram` gets, in the order it asks for them.
  BankDownNode = 1'i32

# --- The Arena seat ----------------------------------------------------------

suite "arena scripts":

  test "a program of 20 lines places a pop bumper and makes it score":
    check BumperProgram.strip.splitLines.len <= 20
    var game = initTable()
    let script = loadScript(seatArena, BumperProgram)

    # Through the build phase. The bumper beams in and the first ball is served.
    for _ in 0 ..< 2 * game.settings.buildPhaseTicks:
      if game.phase == episodePlay:
        break
      game.play(script, 1)
    script.checkRunning()
    check game.phase == episodePlay
    let bumpers = game.idsOfKind(ckPopBumper)
    check bumpers.len == 1
    check game.balls.len == 1
    if bumpers.len == 1 and game.balls.len == 1:
      check game.piece(bumpers[0]).phase == phaseSolid
      check game.score == 0

      # Roll the ball down the table into the bumper.
      game.balls[0].pos = fixedVec2(200'fx, 320'fx)
      game.balls[0].vel = fixedVec2(0'fx, 600'fx)
      for _ in 0 ..< 2 * TicksPerSecond:
        if game.score != 0:
          break
        game.play(script, 1)
      check game.score == 5
      check game.hasCue(cueKindSound, cuePing)

  test "the quest of Figure 2 can be written":
    var game = initTable()
    let script = loadScript(seatArena, QuestProgram)
    script.decide(game)
    script.checkRunning()
    check game.rejectedEdits.len == 0

    let
      targets = game.idsOfKind(ckDropTarget)
      lamps = game.idsOfKind(ckInsert)
      mouths = game.idsOfKind(ckMouth)
      tracks = game.idsOfKind(ckTrack)
    check targets.len == 3
    check lamps.len == 1
    check mouths.len == 2
    check tracks.len == 1
    check game.fsms.len == 1
    if targets.len == 3 and lamps.len == 1 and mouths.len == 2 and tracks.len == 1 and
        game.fsms.len == 1:
      let
        lamp = lamps[0]
        track = tracks[0]
      check game.piece(track).settings[setMouthA] == fixed(mouths[0])
      check game.piece(track).settings[setMouthB] == fixed(mouths[1])
      check game.piece(track).settings[setControlAX] == 200'fx
      check game.piece(track).settings[setControlBY] == 420'fx

      proc dropBank(game: var Table) =
        for id in targets:
          game.deliver Event(kind: evDrop, componentId: id, group: game.piece(id).group, level: 1)
          game.piece(id).isDown = true

      proc bankIsUp(game: Table): bool =
        targets.allIt(not game.piece(it).isDown)

      # Two drops are not enough.
      for id in targets[0 .. 1]:
        game.deliver Event(kind: evDrop, componentId: id, group: game.piece(id).group, level: 1)
      check game.questText == ""
      check game.fsms[0].currentNode == 0

      # The third lights the ramp. Then the ramp shot pays the jackpot.
      game.dropBank()
      check game.questText == "RAMP IS LIT"
      check game.piece(lamp).settings[setLamp] == fixed(int32(ord(lampOn)))
      check game.fsms[0].currentNode == BankDownNode
      check game.score == 0

      game.deliver Event(kind: evTrackCompleted, componentId: track, level: 1)
      check game.score == 50_000
      check game.hasCue(cueKindFlashers)
      check game.hasCue(cueKindSound, cueFanfare)
      check game.bankIsUp
      check game.fsms[0].currentNode == 0

      # The second time the player is too slow.
      game.dropBank()
      check game.fsms[0].currentNode == BankDownNode
      for _ in 0 ..< 19 * TicksPerSecond:
        game.step()
      check game.questText == "RAMP IS LIT"
      check not game.bankIsUp
      for _ in 0 ..< 2 * TicksPerSecond:
        game.step()
      check game.questText == "TOO SLOW"
      check game.piece(lamp).settings[setLamp] == fixed(int32(ord(lampOff)))
      check game.bankIsUp
      check game.fsms[0].currentNode == 0
      check game.score == 50_000

  test "variables persist and the program runs from the top on every decision":
    var game = initTable()
    let script = loadScript(seatArena, """
runs = runs + 1
if built = 0 then
  built = 1
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
end if
print runs
""")
    for _ in 1 .. 3:
      script.decide(game)
    script.checkRunning()
    check script.lastLine == "3"
    check game.components.len == 1
    check game.rejectedEdits.len == 0

  test "a rejected edit reaches the program as a negative reason code":
    var game = initTable()
    # (240, 956) is between the flippers, where nothing may be built.
    let script = loadScript(seatArena, """
runs = runs + 1
if runs = 1 then outcome = create(kind_popbumper, 240, 956, 0, 100, 1, 0)
print outcome, lastreject, rejectcount
""")
    let keepOut = $ord(rejectKeepOut)
    script.decide(game)
    script.checkRunning()
    check script.lastLine.startsWith("-" & keepOut & " ")
    check game.components.len == 0
    # The rejected edit is still a command the program gave: the table logs it.
    check script.issued.len == 1
    check game.rejectedEdits.len == 1

    script.decide(game)
    check script.lastLine == "-" & keepOut & " " & keepOut & " 1"

  test "the program sees the table as it is before each decision":
    var game = initTable()
    let script = loadScript(seatArena, """
runs = runs + 1
if runs = 1 then
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
  rule = fsm()
  waiting = node(rule)
  edge(rule, 0, waiting, ev_scriptsignal, 0, 0, 1)
  timeout(rule, waiting, 0, 60)
  signal(3)
end if
if runs = 2 then
  print ballcount; " "; balls(0).id; " "; balls(0).x; " "; balls(0).y; " "; balls(0).vy; " "; balls(0).level
  print piececount; " "; pieces(0).id; " "; pieces(0).kind; " "; pieces(0).x; " "; pieces(0).y; " "; pieces(0).phase
  print budgetleft; " "; fsmcount; " "; fsmnode(rule); " "; tick; " "; phase
end if
""")
    script.decide(game)
    game.step()   # Delivers the signal, so the FSM is in its second node.
    game.putBall(5, 250.5'fx, 600'fx, velY = -100'fx)
    script.decide(game)
    script.checkRunning()

    check game.components.len == 1
    check script.output.len == 3
    if game.components.len == 1 and script.output.len == 3:
      let
        bumper = game.components[0]
        budgetLeft = game.settings.buildBudget - KindInfos[ckPopBumper].cost
      check bumper.kind == ckPopBumper
      check script.output[0] == "1 5 250.50000 600.00000 -100.00000 1"
      check script.output[1] == "1 " & $bumper.id & " " & $ord(ckPopBumper) &
        " 200.00000 400.00000 " & $ord(phaseBeamingIn)
      check script.output[2] == $budgetLeft & " 1 1 1 " & $ord(episodeBuild)

  test "replaying the issued commands rebuilds the same table":
    const Ticks = 4 * ArenaDecisionTicks
    var game = initTable()
    let script = loadScript(seatArena, """
runs = runs + 1
if runs = 1 then
  bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
  post = create(kind_rubberpost, 300, 450, 0, 100, 1, 0)
  setting(bumper, set_strength, 1200)
  rule = fsm()
  award = node(rule)
  doscore(rule, award, 25)
  domessage(rule, award, slot_award, "NICE SHOT")
  edge(rule, 0, award, ev_scriptsignal, 0, 0, 1)
end if
if runs = 2 then move(post, 150, 300)
if runs = 3 then signal(2)
' (240, 956) is between the flippers: rejected, and logged in the table.
if runs = 4 then create(kind_popbumper, 240, 956, 0, 100, 1, 0)
""")
    var
      log: seq[Command]
      hashes: seq[uint64]
    for _ in 0 ..< Ticks:
      if game.tick mod ArenaDecisionTicks == 0:
        script.decide(game)
        for command in script.issued:
          check command.tick == game.tick
          check command.seat == seatArena
        log.add script.issued
      game.step()
      hashes.add game.stateHash
    script.checkRunning()
    # Eight calls on the first decision, then the move, the signal and the
    # rejected create.
    check log.len == 11
    check game.score == 25
    check game.awardText == "NICE SHOT"
    check game.rejectedEdits.len == 1

    var
      replay = initTable()
      replayHashes: seq[uint64]
    for _ in 0 ..< Ticks:
      for command in log:
        if command.tick == replay.tick:
          discard replay.apply(command)
      replay.step()
      replayHashes.add replay.stateHash
    check replayHashes == hashes

  test "a compile error names the author's own line":
    var game = initTable()
    # BASIC has no power operator.
    let script = loadScript(seatArena, """
' Counts hits.
hits = hits + 1
bonus = hits ^ 2
""")
    check script.status == scriptCompileError
    check "line 3," in script.error
    script.decide(game)
    check script.status == scriptCompileError
    check script.issued.len == 0

  test "a run-time error stops the program for good and what it built keeps working":
    var game = initTable()
    let script = loadScript(seatArena, BumperProgram & """
runs = runs + 1
print runs
if runs = 3 then share = 100 \ players
""")
    for _ in 1 .. 2:
      script.decide(game)
    script.checkRunning()
    script.decide(game)
    check script.status == scriptFailed
    check "division by zero" in script.error

    for _ in 1 .. 2:
      script.decide(game)
    check script.status == scriptFailed
    check script.lastLine == "3"
    check script.issued.len == 0

    let bumpers = game.idsOfKind(ckPopBumper)
    check bumpers.len == 1
    if bumpers.len == 1:
      game.deliver Event(kind: evHit, componentId: bumpers[0], level: 1, strength: 800'fx)
      check game.score == 5

  test "an endless loop runs out of budget and the game goes on":
    var game = initTable()
    let script = loadScript(seatArena, """
bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
while bumper > 0
  spins = spins + 1
wend
""")
    script.decide(game)
    check script.status == scriptOverBudget
    check script.error.len > 0
    check game.components.len == 1

    # A second run would try to build the bumper again, on top of the first.
    game.play(script, 3 * ArenaDecisionTicks)
    check script.status == scriptOverBudget
    check game.tick == uint32(3 * ArenaDecisionTicks)
    check game.components.len == 1
    check game.rejectedEdits.len == 0

  test "printed lines are kept, and only the last few":
    var game = initTable()
    let script = loadScript(seatArena, """
runs = runs + 1
print "decision", runs
""")
    const Decisions = KeptOutputLines + 5
    for _ in 1 .. Decisions:
      script.decide(game)
    script.checkRunning()
    check script.output.len == KeptOutputLines
    if script.output.len == KeptOutputLines:
      check script.output[0] == "decision " & $(Decisions - KeptOutputLines + 1)
      check script.output[^1] == "decision " & $Decisions

  test "rnd gives the same numbers on every run of a program":
    const Source = """
print rnd(1000); " "; rnd(1000); " "; rnd(1000); " "; rnd(1000)
"""
    var outputs: array[2, seq[string]]
    for run in 0 .. 1:
      var game = initTable()
      let script = loadScript(seatArena, Source)
      for _ in 1 .. 3:
        script.decide(game)
      script.checkRunning()
      outputs[run] = script.output
    check outputs[0].len == 3
    check outputs[0] == outputs[1]

    var numbers: seq[int]
    for line in outputs[0]:
      for word in line.splitWhitespace:
        numbers.add parseInt(word)
    check numbers.len == 12
    check numbers.allIt(it in 0 .. 999)
    check numbers.deduplicate.len > 6

  test "an Arena program cannot flip":
    var game = initTable()
    let script = loadScript(seatArena, "flip(left, 1)\n")
    script.decide(game)
    check script.status != scriptRunning
    check not game.flippers[flipperLeft].pressed

# --- The Flipper seat --------------------------------------------------------

proc initPlayTable(): Table =
  ## A table in play with one ball at rest, low on the left.
  result = initTable()
  result.phase = episodePlay
  result.ballNumber = 1
  result.putBall(1, 200'fx, 900'fx)

suite "flipper scripts":

  test "a program sees the ball and works the flippers, the plunger and the nudge":
    var game = initPlayTable()
    let script = loadScript(seatFlipper, """
' Left flipper up while the ball is low on the table. Pull the plunger, let
' it go, then nudge once.
runs = runs + 1
if ballcount > 0 then
  if balls(0).y > 800 then flip(left, 1) else flip(left, 0)
end if
if runs = 1 then plunger(1)
if runs = 2 then plunger(0)
if runs = 3 then nudge(nudge_right)
""")
    script.decide(game)
    script.checkRunning()
    check game.flippers[flipperLeft].pressed
    check not game.flippers[flipperRight].pressed
    check game.plunger.pressed
    check script.issued.len == 2
    check script.issued.allIt(it.seat == seatFlipper)

    game.balls[0].pos.y = 300'fx
    script.decide(game)
    check not game.flippers[flipperLeft].pressed
    check not game.plunger.pressed

    script.decide(game)
    script.checkRunning()
    check script.issued.anyIt(it.kind == cmdNudge and it.direction == nudgeRight)
    check game.balls[0].vel.x > 0'fx

  test "a Flipper program cannot build":
    var game = initPlayTable()
    let script = loadScript(seatFlipper, """
bumper = create(kind_popbumper, 200, 400, 0, 100, 1, 0)
""")
    script.decide(game)
    check script.status != scriptRunning
    check script.error.len > 0
    check game.components.len == 0

  test "a failed program leaves the flippers limp":
    var game = initPlayTable()
    let script = loadScript(seatFlipper, """
runs = runs + 1
flip(left, 1)
flip(right, 1)
plunger(1)
if runs = 2 then aim = 100 \ targets
""")
    script.decide(game)
    script.checkRunning()
    check game.flippers[flipperLeft].pressed
    check game.flippers[flipperRight].pressed
    check game.plunger.pressed

    script.decide(game)
    check script.status == scriptFailed
    check not game.flippers[flipperLeft].pressed
    check not game.flippers[flipperRight].pressed
    check not game.plunger.pressed
    # The releases are commands like any other, so a replay has them too.
    for side in FlipperSide:
      check script.issued.anyIt(it.kind == cmdFlipper and it.side == side and not it.pressed)
    check script.issued.anyIt(it.kind == cmdPlunger and not it.pressed)

    script.decide(game)
    check not game.flippers[flipperLeft].pressed
    check not game.plunger.pressed
