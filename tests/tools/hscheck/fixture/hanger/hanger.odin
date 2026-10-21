package hangerp

import "core:fmt"
import "core:time"
import "core:sys/posix"

// hanger.odin — a suite that NEVER exits, plus a grandchild that never exits.
//
// This exists so selfcheck.sh can prove the gate's timeout actually fires.
// The grandchild is the important half: killing only the direct child leaves a
// hung grandchild running on the machine after the gate exits, which is how a
// CI runner slowly fills with zombies that hold ttys and ports. The gate puts
// the child in its own process group and kills the GROUP; this fixture is what
// distinguishes those two implementations.
main :: proc() {
	fmt.println("HS_TALLY hanger_test pass=1 fail=0 skip=0")

	pid := posix.fork()
	if pid == 0 {
		for true { time.sleep(1 * time.Second) }
	}

	fmt.println("hanger: grandchild spawned, blocking forever")
	for true {
		time.sleep(1 * time.Second)
	}
}
