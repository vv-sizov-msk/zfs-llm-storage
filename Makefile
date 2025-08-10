# Simple helper Makefile
.PHONY: deb docs

deb:
	mkdir -p dist
	# Placeholder for deb build. Integrate debhelper/fpm as needed.
	@echo "Build deb not fully implemented in this scaffold."

docs:
	mkdocs build
