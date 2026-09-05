EMACS ?= emacs
CC ?= cc
PKG_CONFIG ?= pkg-config
EMACS_MODULE_INCLUDE ?= /usr/local/include

MODULE := video-module.so
SOURCES := src/video-module.c src/video-runtime.c src/video-canvas.c
HEADERS := src/video-runtime.h src/video-canvas.h
LISP_SOURCES := video-source.el video-runtime.el video-view.el video-inline.el video.el
GST_PACKAGES := gstreamer-play-1.0 gstreamer-app-1.0 gstreamer-video-1.0
CPPFLAGS += -I$(EMACS_MODULE_INCLUDE) $(shell $(PKG_CONFIG) --cflags $(GST_PACKAGES))
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -Wall -Wextra -Wpedantic -Werror=implicit-function-declaration
LDFLAGS += -shared
LDLIBS += $(shell $(PKG_CONFIG) --libs $(GST_PACKAGES))

.PHONY: all module clean fixture test check checkdoc compile

all: module

module: $(MODULE)

$(MODULE): $(SOURCES) $(HEADERS)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) $(LDLIBS)

test/fixtures/test.webm:
	mkdir -p test/fixtures
	gst-launch-1.0 -q videotestsrc num-buffers=45 pattern=ball \
		! video/x-raw,width=160,height=90,framerate=30/1 \
		! vp8enc deadline=1 \
		! webmmux \
		! filesink location=$@

fixture: test/fixtures/test.webm

compile: module
	$(EMACS) --batch -Q -L . -f batch-byte-compile $(LISP_SOURCES)

checkdoc:
	$(EMACS) --batch -Q -L . --eval '(progn (require (quote checkdoc)) (mapc (function checkdoc-file) command-line-args-left) (setq command-line-args-left nil))' $(LISP_SOURCES)

check: module compile checkdoc
	$(EMACS) --batch -Q -L . --eval '(progn (require (quote video)) (princ "video.el loaded\n"))'

test: module fixture compile
	$(EMACS) --batch -Q -L . -L test -l ert -l test/video-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f $(MODULE) $(LISP_SOURCES:.el=.elc) test/fixtures/test.webm
