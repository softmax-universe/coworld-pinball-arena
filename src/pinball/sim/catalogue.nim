## The component catalogue: what each kind costs, how big it is, and which
## settings it starts with. These are the numbers of Appendix A of the design.
## They are starting values for playtest, so change them here.

import types

type
  KindInfo* = object
    cost*: int32          ## Build budget spent while the piece is on the table.
    radius*: Fixed        ## Footprint radius at 100% size, in millimetres.
    isLong*: bool         ## The footprint is a capsule along `setLength`, not a circle.
    hasFootprint*: bool   ## False for lamps and text, which may sit under anything.
    allowedRaised*: bool  ## May be placed on level 2 or 3.

const KindInfos*: array[ComponentKind, KindInfo] = [
  ckNone:          KindInfo(),
  ckPopBumper:     KindInfo(cost: 4, radius: 30'fx, hasFootprint: true),
  ckPassiveBumper: KindInfo(cost: 2, radius: 15'fx, hasFootprint: true),
  ckSlingshot:     KindInfo(cost: 3, radius: 40'fx, hasFootprint: true),
  ckStandupTarget: KindInfo(cost: 2, radius: 15'fx, hasFootprint: true),
  ckDropTarget:    KindInfo(cost: 2, radius: 15'fx, hasFootprint: true),
  ckToggleTarget:  KindInfo(cost: 2, radius: 15'fx, hasFootprint: true),
  ckSpinner:       KindInfo(cost: 2, radius: 20'fx, hasFootprint: true, allowedRaised: true),
  ckRollover:      KindInfo(cost: 1, radius: 12'fx, hasFootprint: true, allowedRaised: true),
  ckCaptiveBall:   KindInfo(cost: 3, radius: 14'fx, isLong: true, hasFootprint: true),
  ckSaucer:        KindInfo(cost: 4, radius: 18'fx, hasFootprint: true),
  ckScoop:         KindInfo(cost: 5, radius: 22'fx, hasFootprint: true),
  ckBallLock:      KindInfo(cost: 5, radius: 22'fx, hasFootprint: true),
  ckKicker:        KindInfo(cost: 4, radius: 16'fx, hasFootprint: true),
  ckKickback:      KindInfo(cost: 3, radius: 16'fx, hasFootprint: true),
  ckMagnet:        KindInfo(cost: 6, radius: 18'fx, hasFootprint: true),
  ckGate:          KindInfo(cost: 2, radius: 20'fx, hasFootprint: true, allowedRaised: true),
  ckDiverter:      KindInfo(cost: 3, radius: 30'fx, hasFootprint: true),
  ckUpPost:        KindInfo(cost: 2, radius: 8'fx, hasFootprint: true),
  ckWall:          KindInfo(cost: 1, radius: 4'fx, isLong: true, hasFootprint: true),
  ckRubberPost:    KindInfo(cost: 1, radius: 8'fx, hasFootprint: true),
  ckMouth:         KindInfo(cost: 2, radius: 30'fx, hasFootprint: true, allowedRaised: true),
  ckTrack:         KindInfo(cost: 3, allowedRaised: true),
  ckInsert:        KindInfo(cost: 0, radius: 10'fx, allowedRaised: true),
  ckFlasher:       KindInfo(cost: 0, radius: 14'fx, allowedRaised: true),
  ckFloatingText:  KindInfo(cost: 0, allowedRaised: true)
]

proc defaultSettings*(kind: ComponentKind): array[Setting, Fixed] =
  ## The settings a new piece of this kind starts with. Speeds are mm/s.
  case kind
  of ckPopBumper:
    result[setStrength] = 900'fx
  of ckSlingshot:
    result[setStrength] = 800'fx
  of ckCaptiveBall:
    result[setLength] = 60'fx
  of ckSaucer:
    result[setStrength] = 700'fx
    result[setDirection] = 90'fx
    result[setHoldTicks] = 120'fx
  of ckScoop:
    result[setStrength] = 700'fx
    result[setDirection] = 90'fx
    result[setTravelTicks] = 180'fx
  of ckBallLock:
    result[setStrength] = 700'fx
    result[setDirection] = 90'fx
    result[setCapacity] = 2'fx
  of ckKicker:
    result[setStrength] = 1200'fx
    result[setDirection] = 270'fx
  of ckKickback:
    result[setStrength] = 1500'fx
    result[setDirection] = 270'fx
    result[setEnabled] = 1'fx
  of ckMagnet:
    result[setStrength] = 600'fx
    result[setRadius] = 80'fx
    result[setEnabled] = 1'fx
  of ckUpPost:
    result[setEnabled] = 1'fx
  of ckWall:
    result[setLength] = 80'fx
    result[setBounce] = 0'fx
  of ckMouth:
    result[setWidthA] = 60'fx
    result[setWidthB] = 36'fx
  else:
    discard

proc settingRange*(setting: Setting): Slice[Fixed] =
  ## The values an edit may give a setting. The ranges keep lengths and
  ## speeds far below the point where `Fixed` wraps. Like the costs, they are
  ## starting values for playtest.
  case setting
  of setStrength: 0'fx .. 3000'fx
  of setDirection, setCurve: -360'fx .. 360'fx
  of setHoldTicks, setTravelTicks: 0'fx .. fixed(int32(10 * TicksPerSecond))
  of setExitX, setControlAX, setControlBX: 0'fx .. fixed(int32(PlayfieldWidth))
  of setExitY, setControlAY, setControlBY: 0'fx .. fixed(int32(PlayfieldHeight))
  of setCapacity: 1'fx .. fixed(int32(MaxBallsInPlay))
  of setRadius: 0'fx .. 200'fx
  of setMode: 0'fx .. 2'fx
  of setEnabled, setPosition, setStyle: 0'fx .. 1'fx
  of setLength: 20'fx .. 400'fx
  of setBounce: 0'fx .. fixed(int32(ord(high(Surface))))
  of setWidthA, setWidthB: 30'fx .. 120'fx
  of setMouthA, setMouthB: 0'fx .. 32767'fx
  of setColour: 0'fx .. fixed(int32(ord(high(LampColour))))
  of setLamp: 0'fx .. fixed(int32(ord(high(LampState))))

proc scaled*(length: Fixed, sizePercent: int32): Fixed =
  ## A length at the given size. `sizePercent` is 50 .. 200.
  multiplyDivide(length, fixed(sizePercent), 100'fx)  # A long wall times 200 would wrap.

proc footprint*(component: Component): Collider =
  ## The space a piece claims on its level, used to refuse overlapping edits
  ## and to tell whether a ball is inside a hologram. It is a rough outline,
  ## not the collision shape.
  let
    info = KindInfos[component.kind]
    radius = scaled(info.radius, component.sizePercent)
  result.radius = radius
  result.a = component.pos
  result.b = component.pos
  if info.isLong:
    let half = direction(component.rotation * FixedPi / 180'i32) *
      (scaled(component.settings[setLength], component.sizePercent) / 2'i32)
    result.a = component.pos - half
    result.b = component.pos + half
