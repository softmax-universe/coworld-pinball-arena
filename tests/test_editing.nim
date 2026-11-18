## Editing rules: section 4 of the design ("Build budget", "Editing rules")
## with the limits of Appendix C and the keep-out zones of Appendix G.
##
## The tests drive `editing.nim` the way `simulation.step` does: edits arrive
## through `applyEdit`, and `advanceBeamIns` runs once per tick before the
## tick counter moves on. Every piece is placed on one of three points that
## are known to be open playfield, so the tests do not depend on the exact
## shape of the fixed parts.

import std/unittest
import pinball/sim/types
import pinball/sim/catalogue
import pinball/sim/layout
import pinball/sim/editing

const
  TestSettings = TableSettings(
    beamInTicks: 5,
    editsPerSecond: 2,
    buildBudget: 10,
    maxPieces: 8,
    buildPhaseTicks: 10 * TicksPerSecond
  )
  BeamIn = TestSettings.beamInTicks

let
  PlaceA = fixedVec2(200'fx, 400'fx)
  PlaceB = fixedVec2(150'fx, 300'fx)
  PlaceC = fixedVec2(300'fx, 450'fx)

proc newGame(settings = TestSettings): Table =
  ## An empty table in the build phase, as `simulation.initTable` makes it.
  Table(settings: settings, phase: episodeBuild,
        nextBallId: 1, nextComponentId: 1, nextFsmId: 1)

proc tick(game: var Table, count = 1) =
  for _ in 1 .. count:
    game.advanceBeamIns()
    inc game.tick

proc createEdit(kind: ComponentKind, pos: FixedVec2, level = 0'i32, group = 0'i32): Edit =
  Edit(kind: editCreate, componentKind: kind, pos: pos, level: level, group: group)

# The helpers that check something are templates, so a failed check counts
# against the test that uses the helper.

template create(game: var Table, kind: ComponentKind, pos: FixedVec2,
                level = 0'i32, group = 0'i32): int32 =
  ## Create a piece that must be accepted. Gives its id.
  let outcome = game.applyEdit(createEdit(kind, pos, level, group), rateLimited = false)
  check outcome.reason == rejectNone
  outcome.id

template createSolid(game: var Table, kind: ComponentKind, pos: FixedVec2,
                     level = 0'i32, group = 0'i32): int32 =
  ## Create a piece and wait until it is solid.
  let id = game.create(kind, pos, level, group)
  game.tick(BeamIn)
  id

proc exists(game: Table, id: int32): bool =
  game.componentIndex(id) >= 0

proc pieceOrEmpty(game: Table, id: int32): Component =
  let index = game.componentIndex(id)
  if index >= 0:
    result = game.components[index]

template piece(game: Table, id: int32): Component =
  ## The piece with this id. The test fails if there is none.
  check game.exists(id)
  game.pieceOrEmpty(id)

template giveStandInCollider(game: var Table, id: int32) =
  ## `components.rebuildColliders` gives a solid piece its collision shape.
  ## This puts a shape there by hand, so a test can see that a piece which
  ## stops being solid loses it, whatever `rebuildColliders` builds.
  check game.exists(id)
  if game.exists(id):
    let standInPos = game.components[game.componentIndex(id)].pos
    game.components[game.componentIndex(id)].colliders.add Collider(
      a: standInPos, b: standInPos, radius: 8'fx, componentId: id)

proc countEvents(game: Table, kind: EventKind, componentId = 0'i32): int =
  ## Events waiting for the next tick. `componentId` 0 counts any component.
  for event in game.pendingEvents:
    if event.kind == kind and (componentId == 0 or event.componentId == componentId):
      inc result

proc addFreeBall(game: var Table, pos: FixedVec2, level = 1'i32): int32 =
  result = game.nextBallId
  inc game.nextBallId
  game.balls.add Ball(id: result, state: ballFree, pos: pos, level: level)

template checkRejected(game: var Table, rejectedEdit: Edit, expected: RejectReason,
                       limited = false) =
  ## The edit must be refused for the expected reason, change no piece and not
  ## touch the budget, and be reported: one more `RejectedEdit` and one
  ## `evEditRejected`.
  block:
    let
      componentsBefore = game.components
      budgetBefore = game.budgetUsed
      reportsBefore = game.rejectedEdits.len
      eventsBefore = game.countEvents(evEditRejected)
      outcome = game.applyEdit(rejectedEdit, limited)
    check outcome.reason == expected
    check game.components == componentsBefore
    check game.budgetUsed == budgetBefore
    check game.rejectedEdits.len == reportsBefore + 1
    if game.rejectedEdits.len == reportsBefore + 1:
      check game.rejectedEdits[^1].reason == expected
      check game.rejectedEdits[^1].edit == rejectedEdit
      check game.rejectedEdits[^1].tick == game.tick
    check game.countEvents(evEditRejected) == eventsBefore + 1

suite "beam-in":
  test "a new piece is a hologram first, spends its cost, and turns solid after the beam-in time":
    var game = newGame()
    let outcome = game.applyEdit(createEdit(ckMagnet, PlaceA), rateLimited = false)
    check outcome.reason == rejectNone
    check outcome.id != 0
    check game.budgetUsed == KindInfos[ckMagnet].cost
    check game.countEvents(evComponentCreated, outcome.id) == 1

    let hologram = game.piece(outcome.id)
    check hologram.kind == ckMagnet
    check hologram.pos == PlaceA
    check hologram.phase == phaseBeamingIn
    check hologram.colliders.len == 0
    # A size and a level that the edit leaves out mean the normal ones.
    check hologram.sizePercent == 100
    check hologram.level == 1
    check hologram.settings == defaultSettings(ckMagnet)

    game.tick(BeamIn - 1)
    check game.piece(outcome.id).phase == phaseBeamingIn
    game.tick()
    check game.piece(outcome.id).phase == phaseSolid
    check game.budgetUsed == KindInfos[ckMagnet].cost

  test "a hologram with a ball inside it waits until the ball is clear":
    var game = newGame()
    let
      blocked = game.create(ckRubberPost, PlaceA)
      underRaisedBall = game.create(ckRubberPost, PlaceB)
      ballId = game.addFreeBall(PlaceA)
    # A ball up on a rail is not inside a piece on the playfield below it.
    discard game.addFreeBall(PlaceB, level = 2)

    game.tick(BeamIn)
    check game.piece(underRaisedBall).phase == phaseSolid
    check game.piece(blocked).phase == phaseBeamingIn
    game.tick(2 * BeamIn)
    check game.piece(blocked).phase == phaseBeamingIn

    game.balls[game.ballIndex(ballId)].pos = PlaceC
    game.tick(BeamIn)
    check game.piece(blocked).phase == phaseSolid

suite "delete":
  test "a deleted piece gives its cost back at once and is gone after the fade-out":
    var game = newGame()
    let
      kept = game.createSolid(ckRubberPost, PlaceB)
      id = game.createSolid(ckMagnet, PlaceA)
    game.giveStandInCollider(id)
    check game.budgetUsed == KindInfos[ckMagnet].cost + KindInfos[ckRubberPost].cost

    let outcome = game.applyEdit(Edit(kind: editDelete, targetId: id), rateLimited = false)
    check outcome.reason == rejectNone
    check game.budgetUsed == KindInfos[ckRubberPost].cost
    check game.countEvents(evComponentRemoved, id) == 1
    check game.piece(id).phase == phaseFadingOut
    check game.piece(id).colliders.len == 0

    game.tick(BeamIn - 1)
    check game.piece(id).phase == phaseFadingOut
    game.tick()
    check not game.exists(id)
    check game.piece(kept).phase == phaseSolid

  test "a deleted piece that holds a ball releases it":
    # The release itself is the work of `components.releaseBalls`.
    var game = newGame()
    let
      id = game.createSolid(ckSaucer, PlaceA)
      ballId = game.nextBallId
    inc game.nextBallId
    game.balls.add Ball(id: ballId, state: ballHeld, pos: PlaceA, level: 1, holderId: id)
    check game.exists(id)
    if game.exists(id):
      game.components[game.componentIndex(id)].heldBallIds.add ballId

    check game.applyEdit(Edit(kind: editDelete, targetId: id), rateLimited = false).accepted
    check game.balls[game.ballIndex(ballId)].state == ballFree

suite "move, rotate, resize":
  test "a solid piece never slides: it fades out, beams in at the new place, then is solid":
    var game = newGame()
    let id = game.createSolid(ckRubberPost, PlaceA)
    game.giveStandInCollider(id)
    let budget = game.budgetUsed

    let outcome = game.applyEdit(Edit(kind: editMove, targetId: id, pos: PlaceB),
                                 rateLimited = false)
    check outcome.reason == rejectNone
    check game.budgetUsed == budget

    # Fading out where it was. Not solid from the moment of the edit.
    for _ in 1 .. BeamIn:
      let fading = game.piece(id)
      check fading.phase == phaseFadingOut
      check fading.pos == PlaceA
      check fading.colliders.len == 0
      game.tick()

    # A hologram at the new place.
    for _ in 1 .. BeamIn:
      let hologram = game.piece(id)
      check hologram.phase == phaseBeamingIn
      check hologram.pos == PlaceB
      check hologram.colliders.len == 0
      game.tick()

    check game.piece(id).phase == phaseSolid
    check game.piece(id).pos == PlaceB
    check game.components.len == 1
    check game.budgetUsed == budget

  test "moving a hologram restarts its beam-in at the new place":
    var game = newGame()
    let id = game.create(ckRubberPost, PlaceA)
    game.tick(BeamIn - 2)

    check game.applyEdit(Edit(kind: editMove, targetId: id, pos: PlaceB),
                         rateLimited = false).accepted
    check game.piece(id).phase == phaseBeamingIn
    check game.piece(id).pos == PlaceB

    game.tick(BeamIn - 1)
    check game.piece(id).phase == phaseBeamingIn
    game.tick()
    check game.piece(id).phase == phaseSolid
    check game.piece(id).pos == PlaceB

  test "rotate and resize keep the piece in place and beam it in again with the new values":
    # The piece must not count as overlapping itself.
    var game = newGame()
    let id = game.createSolid(ckKicker, PlaceA)

    check game.applyEdit(Edit(kind: editRotate, targetId: id, rotation: 90'fx),
                         rateLimited = false).accepted
    check game.piece(id).phase == phaseFadingOut
    game.tick(2 * BeamIn)
    check game.piece(id).phase == phaseSolid
    check game.piece(id).rotation == 90'fx

    check game.applyEdit(Edit(kind: editResize, targetId: id, sizePercent: 150),
                         rateLimited = false).accepted
    check game.piece(id).phase == phaseFadingOut
    game.tick(2 * BeamIn)
    check game.piece(id).phase == phaseSolid
    check game.piece(id).sizePercent == 150
    check game.piece(id).rotation == 90'fx
    check game.piece(id).pos == PlaceA

suite "rejected edits":
  test "nothing can be built in a keep-out zone or off the playfield":
    var game = newGame()
    let
      leftFlipper = flipperCollider(flipperLeft, 0'fx)
      rightFlipper = flipperCollider(flipperRight, 0'fx)
      forbidden = [
        (leftFlipper.a + leftFlipper.b) / 2'i32,
        (rightFlipper.a + rightFlipper.b) / 2'i32,
        shooterLaneStart(),
        fixedVec2(-50'fx, 400'fx),
        fixedVec2(fixed(PlayfieldWidth + 50), 400'fx),
        fixedVec2(200'fx, -50'fx),
        fixedVec2(200'fx, fixed(PlayfieldHeight + 50))
      ]
    for pos in forbidden:
      game.checkRejected(createEdit(ckRubberPost, pos), rejectKeepOut)

    # A piece on open playfield cannot be moved there either.
    let id = game.createSolid(ckRubberPost, PlaceA)
    game.checkRejected(Edit(kind: editMove, targetId: id, pos: shooterLaneStart()),
                       rejectKeepOut)

  test "an edit that would pass the build budget is rejected, but free pieces still fit":
    var game = newGame()  # A budget of 10.
    discard game.create(ckMagnet, PlaceA)   # 6
    discard game.create(ckKicker, PlaceB)   # 4
    check game.budgetUsed == 10
    game.checkRejected(createEdit(ckRubberPost, PlaceC), rejectOverBudget)

    discard game.create(ckInsert, PlaceC)
    check game.budgetUsed == 10

  test "the piece cap counts the free pieces":
    var settings = TestSettings
    settings.maxPieces = 3
    var game = newGame(settings)
    for _ in 1 .. 3:
      discard game.create(ckInsert, PlaceA)
    check game.budgetUsed == 0
    game.checkRejected(createEdit(ckInsert, PlaceA), rejectTooManyPieces)
    game.checkRejected(createEdit(ckRubberPost, PlaceB), rejectTooManyPieces)

  test "pieces on the same level may not overlap":
    var game = newGame()
    let
      post = game.createSolid(ckRubberPost, PlaceA)
      rollover = game.createSolid(ckRollover, PlaceB)
    game.checkRejected(createEdit(ckPassiveBumper, PlaceA), rejectOverlap)
    game.checkRejected(Edit(kind: editMove, targetId: rollover, pos: PlaceA), rejectOverlap)

    # Lamps sit under anything, and a raised piece is above the playfield.
    discard game.create(ckInsert, PlaceA)
    discard game.create(ckRollover, PlaceB, level = 2)
    game.checkRejected(createEdit(ckRollover, PlaceB, level = 2), rejectOverlap)
    check game.piece(post).phase == phaseSolid

  test "the place a piece is moving to is taken":
    var game = newGame()
    let id = game.createSolid(ckRubberPost, PlaceA)
    check game.applyEdit(Edit(kind: editMove, targetId: id, pos: PlaceB),
                         rateLimited = false).accepted
    check game.piece(id).phase == phaseFadingOut
    game.checkRejected(createEdit(ckRubberPost, PlaceB), rejectOverlap)

  test "an edit that names no piece is rejected":
    var game = newGame()
    discard game.create(ckRubberPost, PlaceA)
    game.checkRejected(Edit(kind: editMove, targetId: 99, pos: PlaceB), rejectUnknownTarget)
    game.checkRejected(Edit(kind: editDelete, targetId: 99), rejectUnknownTarget)
    game.checkRejected(Edit(kind: editSetting, targetId: 99, setting: setEnabled, value: 1'fx),
                       rejectUnknownTarget)
    game.checkRejected(Edit(kind: editReset, targetId: 99), rejectUnknownTarget)
    # A group that has no pieces.
    game.checkRejected(Edit(kind: editDelete, targetGroup: 7), rejectUnknownTarget)

  test "values outside their limits are rejected":
    var game = newGame()
    game.checkRejected(createEdit(ckNone, PlaceA), rejectBadValue)

    var tooSmall = createEdit(ckRubberPost, PlaceA)
    tooSmall.sizePercent = MinSizePercent - 1
    game.checkRejected(tooSmall, rejectBadValue)
    var tooBig = createEdit(ckRubberPost, PlaceA)
    tooBig.sizePercent = MaxSizePercent + 1
    game.checkRejected(tooBig, rejectBadValue)

    game.checkRejected(createEdit(ckRollover, PlaceA, level = LevelCount + 1), rejectBadValue)
    # A rubber post belongs on the playfield. Only some kinds may be raised.
    game.checkRejected(createEdit(ckRubberPost, PlaceA, level = 2), rejectBadValue)

    let post = game.createSolid(ckRubberPost, PlaceA)
    game.checkRejected(Edit(kind: editResize, targetId: post, sizePercent: MaxSizePercent + 1),
                       rejectBadValue)

suite "edit rate":
  test "script edits are limited during play, and the window moves on after a second":
    var game = newGame()  # 2 edits per second.
    game.phase = episodePlay

    let first = game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true)
    check first.accepted
    check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted
    game.checkRejected(createEdit(ckInsert, PlaceA), rejectRateLimit, limited = true)
    game.checkRejected(Edit(kind: editDelete, targetId: first.id), rejectRateLimit,
                       limited = true)

    # Setting and reset edits never count, and rule results are not limited.
    check game.applyEdit(Edit(kind: editSetting, targetId: first.id, setting: setLamp,
                              value: 1'fx), rateLimited = true).accepted
    check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = false).accepted

    game.tick(TicksPerSecond div 2)
    game.checkRejected(createEdit(ckInsert, PlaceA), rejectRateLimit, limited = true)
    game.tick(TicksPerSecond div 2)
    check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted

  test "the build phase has no rate limit":
    var game = newGame()
    check game.phase == episodeBuild
    for _ in 1 .. 3 * TestSettings.editsPerSecond:
      check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted
    check game.components.len == 3 * TestSettings.editsPerSecond

suite "settings and groups":
  test "a setting change takes effect at once, with no beam-in":
    var game = newGame()
    let magnet = game.createSolid(ckMagnet, PlaceA)

    check game.applyEdit(Edit(kind: editSetting, targetId: magnet, setting: setEnabled,
                              value: 0'fx), rateLimited = false).accepted
    check game.piece(magnet).settings[setEnabled] == 0'fx
    check game.piece(magnet).phase == phaseSolid

  test "a group edit reaches every piece of the group and no other":
    var game = newGame()
    const Bank = 5'i32
    let
      first = game.createSolid(ckRollover, PlaceA, group = Bank)
      second = game.createSolid(ckRollover, PlaceB, group = Bank)
      lamp = game.createSolid(ckInsert, PlaceC, group = Bank)
      outsider = game.createSolid(ckRubberPost, PlaceC)
    check game.piece(first).group == Bank

    check game.applyEdit(Edit(kind: editSetting, targetGroup: Bank, setting: setLamp,
                              value: 1'fx), rateLimited = false).accepted
    for id in [first, second, lamp]:
      check game.piece(id).settings[setLamp] == 1'fx
    check game.piece(outsider).settings[setLamp] == 0'fx

    check game.applyEdit(Edit(kind: editReset, targetGroup: Bank), rateLimited = false).accepted

    check game.applyEdit(Edit(kind: editDelete, targetGroup: Bank), rateLimited = false).accepted
    check game.budgetUsed == KindInfos[ckRubberPost].cost
    for id in [first, second, lamp]:
      check game.piece(id).phase == phaseFadingOut
    game.tick(BeamIn)
    check game.components.len == 1
    check game.piece(outsider).phase == phaseSolid

suite "clear arena":
  test "clearing the arena fades out every piece and returns the whole budget":
    var game = newGame()
    let solid = game.createSolid(ckMagnet, PlaceA)
    game.giveStandInCollider(solid)
    discard game.createSolid(ckInsert, PlaceA)
    discard game.create(ckRubberPost, PlaceB)  # Still a hologram.
    check game.budgetUsed > 0

    game.clearArena()
    check game.budgetUsed == 0
    check game.piece(solid).colliders.len == 0
    for component in game.components:
      check component.phase == phaseFadingOut

    game.tick(BeamIn)
    check game.components.len == 0
    check game.budgetUsed == 0

    # The whole budget can be spent again.
    discard game.create(ckMagnet, PlaceA)
    discard game.create(ckKicker, PlaceB)
    check game.budgetUsed == 10

  test "after the arena is cleared a script may build for one build-phase length without the edit rate":
    var game = newGame()  # 2 edits per second.
    game.phase = episodePlay
    game.tick(3 * TicksPerSecond)
    game.clearArena()

    for _ in 1 .. 3 * TestSettings.editsPerSecond:
      check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted

    # Then the edit rate is back.
    game.tick(TestSettings.buildPhaseTicks)
    check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted
    check game.applyEdit(createEdit(ckInsert, PlaceA), rateLimited = true).accepted
    game.checkRejected(createEdit(ckInsert, PlaceA), rejectRateLimit, limited = true)
