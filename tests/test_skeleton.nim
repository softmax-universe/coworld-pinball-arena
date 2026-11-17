## Compiles the whole simulation and takes one step.
import pinball/sim/simulation

var table = initTable()
table.step()
doAssert table.tick == 1
echo "skeleton ok ", table.stateHash()
