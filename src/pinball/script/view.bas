' The records of the table view. The host puts this in front of every
' program and fills balls() and pieces() before each decision.
type BallView
  id as integer
  x as fixed
  y as fixed
  vx as fixed
  vy as fixed
  level as integer
  state as integer
end type

type PieceView
  id as integer
  kind as integer
  x as fixed
  y as fixed
  rotation as fixed
  size as integer
  level as integer
  group as integer
  phase as integer
  lamp as integer
  down as integer
  face as integer
end type
