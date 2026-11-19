## Sound: the cues that rules ask for, and the sounds of the table itself
## (flippers, bumpers, the drain, a piece beaming in).
##
## Sound follows the game and never changes it. `playTickSounds` reads what
## happened in one tick and plays a cue for it.
##
## The files are `assets/sounds/<name>.ogg`, named after the `SoundCue`
## values: `cueBallSave` is `ball_save.ogg`. They are not equally loud, so
## each cue has its own gain here. Tune by ear.

import
  std/[monotimes, os, strutils],
  ../../polyworld/sounddevices,
  ../sim/types

const
  SoundFolder =
    when defined(emscripten): "/assets/sounds"
    else: currentSourcePath().parentDir.parentDir.parentDir.parentDir / "assets" / "sounds"

  DefaultGain = 0.6'f32
  DefaultCooldown = 0.07
    ## Seconds before the same cue may play again. A burst of the same event
    ## (a ball rattling between two bumpers) would otherwise machine-gun.
  QuietHitSpeed = 250'f32     ## mm/s. A hit this soft plays at `QuietHitShare`.
  LoudHitSpeed = 1500'f32     ## A hit this hard, or harder, plays at full gain.
  QuietHitShare = 0.35'f32

proc cueGain(cue: SoundCue): float32 =
  case cue
  of cuePing, cuePop, cueSling: 0.75
  of cueClack: 0.55
  of cueThunk, cueDrop, cueResetBank, cueKick, cueGate: 0.65
  of cueSpinner, cueRollover: 0.45
  of cueBeamIn, cueFadeOut: 0.35
  of cueMagnet: 0.4
  of cueFanfare, cueJackpot, cueQuestStart, cueQuestFail, cueGameOver: 0.7
  of cueWarning, cueTilt: 0.8
  else: DefaultGain

proc cueCooldown(cue: SoundCue): float64 =
  case cue
  of cueBeamIn, cueFadeOut: 0.25      # A whole table beams in at once.
  of cueSpinner: 0.04
  of cueFanfare, cueJackpot, cueGameOver: 0.5
  else: DefaultCooldown

proc fileName(cue: SoundCue): string =
  ## `cueBallSave` -> `ball_save.ogg`.
  let name = ($cue)[3 .. ^1]
  for index, character in name:
    if character.isUpperAscii and index > 0:
      result.add '_'
    result.add character.toLowerAscii
  result.add ".ogg"

var
  ready = false
  lastPlayed: array[SoundCue, float64]

proc initSound*() =
  ## Open the sound device and load every cue. Without a device, or with a
  ## file missing, the game carries on without that sound.
  if not openSoundDevice():
    echo "No sound device. Playing without sound."
    return
  for cue in SoundCue:
    if cue != cueNone and not loadSoundBuffer(ord(cue), SoundFolder / cue.fileName):
      echo "Cannot load sound ", SoundFolder / cue.fileName
  prepareSoundDevice()
  ready = true

proc play*(cue: SoundCue, share = 1'f32) =
  ## Play a cue at `share` of its gain. Nothing happens for a cue that
  ## played a moment ago. In a browser nothing is heard until the player
  ## has pressed a key or clicked, which is the browser's rule.
  if not ready or cue == cueNone:
    return
  let now = getMonoTime().ticks.float64 / 1e9
  if lastPlayed[cue] != 0 and now - lastPlayed[cue] < cueCooldown(cue):
    return
  if startSoundVoice(ord(cue), cueGain(cue) * share, pan = 0, ui = false):
    lastPlayed[cue] = now

proc hitCue(kind: ComponentKind): SoundCue =
  case kind
  of ckPopBumper: cuePop
  of ckSlingshot: cueSling
  of ckPassiveBumper, ckRubberPost: cuePing
  of ckCaptiveBall: cueClack
  else: cueThunk

proc eventCue(table: Table, event: Event): SoundCue =
  ## The sound a player expects for a thing that happened on the table.
  case event.kind
  of evHit:
    let index = table.componentIndex(event.componentId)
    if index >= 0: hitCue(table.components[index].kind) else: cueThunk
  of evDrop: cueDrop
  of evBankComplete: cueChime
  of evReset: cueResetBank
  of evFlip: cueThunk
  of evSpin: cueSpinner
  of evRollover: cueRollover
  of evCaptured: cueHole
  of evLocked: cueLock
  of evReleased, evFired: cueKick
  of evGrabbed: cueMagnet
  of evPassed: cueGate
  of evSwitched, evRaised, evLowered: cueClack
  of evFlipperUp: cueClack
  of evPlungerPulled: cuePlungerPull
  of evNudge: cueNudge
  of evBallLaunched: cueLaunch
  of evTiltWarning: cueWarning
  of evTilt: cueTilt
  of evBallDrained: cueDrain
  of evBallSaved: cueBallSave
  of evComponentCreated: cueBeamIn
  of evComponentRemoved: cueFadeOut
  of evEpisodeEnding: cueGameOver
  of evProgramLoaded: cueProgramLoaded
  else: cueNone

proc playTickSounds*(table: Table) =
  ## Call after every tick.
  for event in table.events:
    var share = 1'f32
    if event.kind == evHit:
      # A harder hit is louder.
      let strength = toFloat32(event.strength)
      share = clamp(QuietHitShare + (1 - QuietHitShare) *
        (strength - QuietHitSpeed) / (LoudHitSpeed - QuietHitSpeed), QuietHitShare, 1)
    play(eventCue(table, event), share)
  for cue in table.cues:
    if cue.kind == cueKindSound:
      play(cue.sound)

proc closeSound*() =
  if ready:
    closeSoundDevice()
    ready = false
