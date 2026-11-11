.PHONY: app run zip install clean

VERSION := $(shell cat VERSION)

# Build build/NFM.app (Apple silicon, macOS 27+)
app:
	scripts/build-app.sh

# Build and open it
run: app
	open build/NFM.app

# Build and package build/NFM-<version>.zip
zip: app
	cd build && ditto -c -k --keepParent NFM.app NFM-$(VERSION).zip

# Build and copy to /Applications
install: app
	rm -rf /Applications/NFM.app && cp -R build/NFM.app /Applications/

clean:
	rm -rf .build build build-test dist
