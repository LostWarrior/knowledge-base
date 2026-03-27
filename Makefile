PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/share/kb/lib
TPLDIR = $(PREFIX)/share/kb/templates
HOOKDIR = $(PREFIX)/share/kb/hooks

.PHONY: install uninstall test lint

install:
	@echo "Installing kb to $(PREFIX)..."
	@mkdir -p $(BINDIR) $(LIBDIR) $(TPLDIR) $(HOOKDIR)
	@cp bin/kb $(BINDIR)/kb
	@chmod +x $(BINDIR)/kb
	@cp lib/*.sh $(LIBDIR)/
	@cp templates/* $(TPLDIR)/
	@cp hooks/* $(HOOKDIR)/
	@chmod +x $(HOOKDIR)/*
	@sed -i '' "s|^KB_ROOT=.*|KB_ROOT=\"$(PREFIX)/share/kb\"|" $(BINDIR)/kb 2>/dev/null || \
		sed -i "s|^KB_ROOT=.*|KB_ROOT=\"$(PREFIX)/share/kb\"|" $(BINDIR)/kb
	@echo "Done. Run 'kb help' to get started."

uninstall:
	@echo "Removing kb from $(PREFIX)..."
	@rm -f $(BINDIR)/kb
	@rm -rf $(PREFIX)/share/kb
	@echo "Done."

test:
	@bash tests/run_all.sh

lint:
	@shellcheck --exclude=SC2329,SC2317,SC2154,SC2034 bin/kb lib/*.sh tests/run_all.sh
	@echo "ShellCheck passed."
