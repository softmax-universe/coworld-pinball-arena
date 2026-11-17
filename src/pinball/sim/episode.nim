## The flow of one Episode: a build phase, then three balls, ending when the
## third ball drains or the clock runs out. Also ball save, extra balls,
## multiball, the end of a tilt, and the ball search for a stuck ball.

import types, layout, components

proc addBall*(table: var Table): bool =
  ## Serve one more ball to the shooter lane. False at the multiball limit.
  discard

proc startBallSave*(table: var Table, ticks: int32) =
  ## A ball that drains within `ticks` from now is returned to the plunger.
  discard

proc awardExtraBall*(table: var Table) =
  discard

proc advanceEpisode*(table: var Table) =
  ## One tick of Episode bookkeeping: end the build phase and serve the first
  ## ball, handle drained balls, serve the next ball, run the clock, search
  ## for stuck balls, and end the Episode.
  discard
