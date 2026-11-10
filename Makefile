# Thin entry points; the work is in scripts/ and tools/.
.PHONY: build install uninstall status stagetest tools clean

build:
	sh scripts/build.sh

install:
	sh scripts/install.sh

uninstall:
	sh scripts/uninstall.sh

# Read-only health check of the installed fix.
status:
	sh tools/status.sh

# Switches apps on screen to check Stage Manager; see tools/stagetest.sh.
stagetest:
	sh tools/stagetest.sh

# Builds the helper tools (wins, sfcmd) into build/tools.
tools:
	sh tools/build.sh

clean:
	rm -rf build
