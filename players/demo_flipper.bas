' The demo Flipper program: the attract mode of Pinball Arena.
'
' It runs from the top 60 times a second. It plunges, flips a flipper when a
' ball is about to reach it, lets go again, and nudges now and then. It is
' meant to keep a ball going and show the table, not to play well.
'
' The flippers mirror about x = 240. Each turns about a pivot 90 mm from that
' line at y = 950, lies 30 degrees below level at rest, and reaches 78 mm
' toward the middle. The arrays below hold one value per flipper, at index
' "left" (0) and "right" (1).

dim want(1)   ' 1 when a ball is about to reach the flipper.
dim aim(1)    ' How far out along the blade a ball must be before the flip.
dim held(1)   ' Decisions the flipper has been up with a ball on it.
dim keep(1)   ' Decisions still to hold the flipper after the ball has gone.
dim rest(1)   ' Decisions to leave the flipper down.

' --- Plunger -----------------------------------------------------------------
' A ball that lies still at the bottom of the shooter lane is on the plunger.
' Pull until the plunger is as far back as this launch wants, then let go.
' The pull is different each time, so the ball drops into different top lanes.
waiting = 0
for i = 0 to ballcount - 1
  if balls(i).x > 480 and balls(i).y > 950 and abs(balls(i).vy) < 20 then waiting = 1
next
if waiting = 1 and pulling = 0 then
  pulling = 1
  pullwanted = 0.55 + rnd(46) / 100
  plunger(1)
end if
if pulling = 1 and plungerpull >= pullwanted then
  plunger(0)
  pulling = 0
end if

' --- Flippers ----------------------------------------------------------------
' Look a moment ahead along each ball's path. A flipper is wanted when the
' ball will then be just above its blade, far enough out from the pivot, and
' is not on its way up.
want(left) = 0
want(right) = 0
for i = 0 to ballcount - 1
  if balls(i).state = state_free and balls(i).level = 1 and balls(i).vy > -150 then
    aheadx = balls(i).x + balls(i).vx * 0.03
    aheady = balls(i).y + balls(i).vy * 0.03
    side = left
    if aheadx > 240 then side = right
    reach = 90 - abs(aheadx - 240)    ' Along the table, from the pivot toward the middle.
    blade = 950 + reach * 0.577       ' The height of the resting blade there.
    if reach > aim(side) and reach < 85 and aheady > blade - 42 and aheady < blade + 10 then want(side) = 1
  end if
next
work(left, leftpressed)
work(right, rightpressed)

sub work(side, pressed)
  ' Press when wanted and hold for a short time after. A flipper that has
  ' been up for most of a second is let down for a moment, so a ball it has
  ' caught rolls toward the tip and is shot on the next flip.
  if aim(side) = 0 then aim(side) = 40
  if rest(side) > 0 then
    rest(side) = rest(side) - 1
  elseif want(side) = 1 then
    if pressed = 0 then flip(side, 1)
    keep(side) = 8
    held(side) = held(side) + 1
    if held(side) > 40 then
      letgo(side)
      rest(side) = 12
    end if
  elseif pressed = 1 then
    keep(side) = keep(side) - 1
    if keep(side) <= 0 then letgo(side)
  end if
end sub

sub letgo(side)
  ' The next flip waits for a different place on the blade, so the shots go
  ' to different parts of the table.
  flip(side, 0)
  held(side) = 0
  aim(side) = 25 + rnd(36)
end sub

' --- Nudge -------------------------------------------------------------------
' Rarely. A ball that has lain still for two seconds somewhere on the table
' (not on the plunger, and not held on a raised flipper) gets one shove to
' the side. Ten seconds pass before the next nudge, so the table never tilts.
still = 0
for i = 0 to ballcount - 1
  if balls(i).state = state_free and balls(i).x < 478 then
    if abs(balls(i).vx) < 20 and abs(balls(i).vy) < 20 then still = 1
  end if
next
if still = 1 and leftpressed = 0 and rightpressed = 0 then stilltime = stilltime + 1 else stilltime = 0
if nudgewait > 0 then nudgewait = nudgewait - 1
if stilltime > 120 and nudgewait = 0 then
  if rnd(2) = 0 then nudge(nudge_left) else nudge(nudge_right)
  nudgewait = 600
  stilltime = 0
end if
