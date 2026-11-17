## The editing rules: how the arena changes while the ball is in play.
##
## New and moved pieces beam in as holograms and turn solid after a delay, and
## a hologram with a ball inside it waits. Pieces never slide: a move fades
## the piece out and beams it in at the new place. An edit that breaks a rule
## (keep-out zone, build budget, piece cap, overlap, edit rate) does nothing
## and is reported.
##
## A deleted piece stays in `table.components` while it fades out, but it is
## already gone for the rules here: its cost is back, its place is free and no
## edit can name it. A piece that fades out before a move is still there, and
## the place it claims is the one it is moving to.

import types, catalogue, geometry, layout, components

const
  PlacingEdits = {editCreate, editMove, editRotate, editResize}
  CountedEdits = PlacingEdits + {editDelete}   ## The edits the rate limit counts.
  GroupEdits = {editDelete, editSetting, editReset}
  NormalSizePercent = 100'i32
  MaxRotation = 360'fx   ## Either way. Keeps the angle maths far from wrapping.

proc isLeaving(component: Component): bool =
  component.phase == phaseFadingOut and not component.hasPendingMove

proc settled(component: Component): Component =
  ## The piece as it will be when its pending move is done.
  result = component
  if component.hasPendingMove:
    result.pos = component.pendingPos
    result.rotation = component.pendingRotation
    result.sizePercent = component.pendingSizePercent

proc targetIndexes(table: Table, edit: Edit): seq[int] =
  ## The pieces the edit names: one by id, or every piece of a group.
  let byGroup = edit.targetGroup != 0 and edit.kind in GroupEdits
  for index, component in table.components:
    if component.isLeaving:
      continue
    if (if byGroup: component.group == edit.targetGroup else: component.id == edit.targetId):
      result.add index

proc sizeOrNormal(sizePercent: int32): int32 =
  if sizePercent == 0: NormalSizePercent else: sizePercent

proc placedPiece(table: Table, edit: Edit): Component =
  ## The piece as a create, move, rotate or resize would leave it. For the
  ## last three the target must exist.
  if edit.kind == editCreate:
    return Component(
      id: table.nextComponentId,
      kind: edit.componentKind,
      pos: edit.pos,
      rotation: edit.rotation,
      sizePercent: sizeOrNormal(edit.sizePercent),
      level: max(edit.level, 1),
      group: edit.group,
      settings: defaultSettings(edit.componentKind),
      text: edit.text,
      phase: phaseBeamingIn,
      phaseTicks: table.settings.beamInTicks
    )
  result = settled(table.components[table.componentIndex(edit.targetId)])
  case edit.kind
  of editMove: result.pos = edit.pos
  of editRotate: result.rotation = edit.rotation
  else: result.sizePercent = sizeOrNormal(edit.sizePercent)

proc placementReason(table: Table, piece: Component): RejectReason =
  ## Why the piece may not stand where it is, if it may not.
  let outline = footprint(piece)
  # A track has no place of its own. It runs between its two mouths.
  if piece.kind != ckTrack and inKeepOut(outline):
    return rejectKeepOut
  if not KindInfos[piece.kind].hasFootprint:
    return rejectNone
  for other in table.components:
    if other.id == piece.id or other.isLeaving or other.level != piece.level or
        not KindInfos[other.kind].hasFootprint:
      continue
    if capsulesOverlap(outline, footprint(settled(other))):
      return rejectOverlap
  rejectNone

proc isCounted(table: Table, edit: Edit, rateLimited: bool): bool =
  rateLimited and table.phase == episodePlay and edit.kind in CountedEdits

proc currentSecond(table: Table): uint32 =
  table.tick div uint32(TicksPerSecond)

proc editsInWindow(table: Table): int32 =
  if table.editWindowSecond == table.currentSecond: table.editsThisSecond else: 0

proc pieceCount(table: Table): int32 =
  for component in table.components:
    if not component.isLeaving:
      inc result

proc rejectReason(table: Table, edit: Edit, rateLimited: bool): RejectReason =
  ## Every check an edit must pass. Changes nothing.
  if table.isCounted(edit, rateLimited) and
      table.editsInWindow >= table.settings.editsPerSecond:
    return rejectRateLimit

  let targets = table.targetIndexes(edit)
  if edit.kind != editCreate and targets.len == 0:
    return rejectUnknownTarget

  case edit.kind
  of editCreate:
    let info = KindInfos[edit.componentKind]
    if edit.componentKind == ckNone or edit.level notin 0 .. LevelCount or
        (edit.level > 1 and not info.allowedRaised) or edit.group < 0 or
        not isValidText(edit.text):
      return rejectBadValue
    if table.pieceCount >= table.settings.maxPieces:
      return rejectTooManyPieces
    if table.budgetUsed + info.cost > table.settings.buildBudget:
      return rejectOverBudget
  of editText:
    if table.components[targets[0]].kind != ckFloatingText or not isValidText(edit.text):
      return rejectBadValue
  of editSetting:
    if edit.value notin settingRange(edit.setting):
      return rejectBadValue
  else:
    discard

  if edit.kind in PlacingEdits:
    let piece = table.placedPiece(edit)
    if piece.sizePercent notin MinSizePercent .. MaxSizePercent or
        abs(piece.rotation) > MaxRotation:
      return rejectBadValue
    return table.placementReason(piece)
  rejectNone

proc fadeOut(table: var Table, index: int) =
  ## The piece stops being solid now and lets go of any ball it holds.
  if table.components[index].phase == phaseFadingOut:
    return
  table.releaseBalls(table.components[index].id, 0)
  table.components[index].colliders.setLen 0
  table.components[index].phase = phaseFadingOut
  table.components[index].phaseTicks = table.settings.beamInTicks

proc deletePiece(table: var Table, index: int) =
  table.fadeOut(index)
  table.components[index].hasPendingMove = false
  let component = table.components[index]
  table.budgetUsed -= KindInfos[component.kind].cost
  table.emitNext Event(kind: evComponentRemoved, componentId: component.id,
                       group: component.group, level: component.level)

proc replacePiece(table: var Table, index: int, placed: Component) =
  ## Give a piece a new place, rotation or size. A hologram takes the values
  ## and starts its beam-in again. Any other piece fades out first.
  if table.components[index].phase == phaseBeamingIn:
    table.components[index].pos = placed.pos
    table.components[index].rotation = placed.rotation
    table.components[index].sizePercent = placed.sizePercent
    table.components[index].phaseTicks = table.settings.beamInTicks
  else:
    table.fadeOut(index)
    table.components[index].hasPendingMove = true
    table.components[index].pendingPos = placed.pos
    table.components[index].pendingRotation = placed.rotation
    table.components[index].pendingSizePercent = placed.sizePercent

proc applyEdit*(table: var Table, edit: Edit, rateLimited: bool): CommandOutcome =
  ## Check one edit and carry it out. Edits from the Arena script are rate
  ## limited during play. Edits from rule results are not. A rejected edit is
  ## added to `table.rejectedEdits` and raises `evEditRejected`.
  let reason = table.rejectReason(edit, rateLimited)
  if reason != rejectNone:
    table.rejectedEdits.add RejectedEdit(tick: table.tick, reason: reason, edit: edit)
    table.emitNext Event(kind: evEditRejected, componentId: edit.targetId,
                         group: edit.targetGroup, value: int32(ord(reason)))
    return CommandOutcome(reason: reason)

  if table.isCounted(edit, rateLimited):
    table.editsThisSecond = table.editsInWindow + 1
    table.editWindowSecond = table.currentSecond

  let targets = table.targetIndexes(edit)
  case edit.kind
  of editCreate:
    let piece = table.placedPiece(edit)
    table.components.add piece
    inc table.nextComponentId
    table.budgetUsed += KindInfos[piece.kind].cost
    table.emitNext Event(kind: evComponentCreated, componentId: piece.id,
                         group: piece.group, level: piece.level)
    result.id = piece.id
  of editMove, editRotate, editResize:
    table.replacePiece(targets[0], table.placedPiece(edit))
  of editDelete:
    for index in targets:
      table.deletePiece(index)
  of editSetting:
    for index in targets:
      let oldValue = table.components[index].settings[edit.setting]
      table.components[index].settings[edit.setting] = edit.value
      table.settingChanged(index, edit.setting, oldValue)
  of editText:
    table.components[targets[0]].text = edit.text
  of editReset:
    if edit.targetGroup != 0:
      table.resetTargets(0, edit.targetGroup)
    else:
      table.resetTargets(edit.targetId, 0)

proc ballInside(table: Table, component: Component): bool =
  ## True when a free ball on the level of the piece reaches into its footprint.
  if not KindInfos[component.kind].hasFootprint:
    return false
  let outline = footprint(component)
  for ball in table.balls:
    if ball.state == ballFree and ball.level == component.level and
        capsulesOverlap(outline, Collider(a: ball.pos, b: ball.pos, radius: BallRadius)):
      return true
  false

proc advanceBeamIns*(table: var Table) =
  ## Count down holograms and fade-outs by one tick.
  var index = 0
  while index < table.components.len:
    template component: untyped = table.components[index]
    if component.phase != phaseSolid and component.phaseTicks > 0:
      dec component.phaseTicks
    if component.phaseTicks == 0:
      case component.phase
      of phaseSolid:
        discard
      of phaseBeamingIn:
        if not table.ballInside(component):
          component.phase = phaseSolid
          rebuildColliders(component)
      of phaseFadingOut:
        if not component.hasPendingMove:
          table.components.delete(index)
          continue
        component = settled(component)
        component.hasPendingMove = false
        component.phase = phaseBeamingIn
        component.phaseTicks = table.settings.beamInTicks
    inc index

proc clearArena*(table: var Table) =
  ## Fade out every piece. A piece that holds a ball releases it.
  for index in 0 ..< table.components.len:
    if not table.components[index].isLeaving:
      table.deletePiece(index)
