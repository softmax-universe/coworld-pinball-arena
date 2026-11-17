## The recording of one Episode, and the check that it plays back the same.
##
## The simulation is deterministic and commands are its only input, so the
## table settings and the commands rebuild every tick of an Episode. No BASIC
## runs in a playback: the commands that the programs gave are in the list.

import flatty
import sim/simulation

type
  Replay* = object
    settings*: TableSettings
    commands*: seq[Command]
      ## Every command either seat gave, in the order they were applied, each
      ## with its tick. Rejected commands are included, because a rejected
      ## edit is logged in the table and so changes its hash.
    hashes*: seq[uint64]       ## The table hash after each tick.

proc verify*(replay: Replay): bool =
  ## Plays the recording on a fresh table, from the commands alone, and
  ## checks the table hash after every tick.
  var
    table = initTable(replay.settings)
    next = 0
  for hash in replay.hashes:
    while next < replay.commands.len and replay.commands[next].tick == table.tick:
      discard table.apply(replay.commands[next])
      inc next
    table.step()
    if table.stateHash != hash:
      return false
  next == replay.commands.len

proc saveReplay*(replay: Replay, path: string) =
  ## The file is the flatty binary form of `Replay`. It is only readable by a
  ## build with the same simulation types.
  writeFile(path, replay.toFlatty())

proc loadReplay*(path: string): Replay =
  readFile(path).fromFlatty(Replay)
