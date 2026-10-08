EMACS ?= emacs
CC ?= cc
PKG_CONFIG ?= pkg-config
EMACS_MODULE_INCLUDE ?= /usr/local/include
PYTHON ?= python3
ifndef DOTLOTTIE_ROOT
DOTLOTTIE_ROOT := $(shell $(PYTHON) dotlottie-sdk.py root)
endif
DOTLOTTIE_HEADER := $(DOTLOTTIE_ROOT)/include/dotlottie_player.h
DOTLOTTIE_LIBRARY := $(DOTLOTTIE_ROOT)/lib/libdotlottie_rs.so
DOTLOTTIE_MANIFEST := $(DOTLOTTIE_ROOT)/.dotlottie-sdk.json
DOTLOTTIE_DEPLOYED = $(dir $(MODULE))libdotlottie_rs.so

MODULE := video-module.so
ANIMATION_SOURCES := src/video-animation.c src/video-lottie.c src/video-apng.c src/video-webp.c
SOURCES := src/video-module.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES)
HEADERS := src/video-runtime.h src/video-canvas.h src/video-animation.h src/video-lottie.h src/video-apng.h src/video-webp.h
LISP_SOURCES := video-source.el video-runtime.el video-view.el video-inline.el video-evil.el video.el
GST_PACKAGES := gstreamer-play-1.0 gstreamer-app-1.0 gstreamer-video-1.0 libass
AV_PACKAGES := libavformat libavcodec libavutil libswscale
WEBP_PACKAGES := libwebp libwebpdemux
CPPFLAGS += -I$(EMACS_MODULE_INCLUDE) -I$(DOTLOTTIE_ROOT)/include $(shell $(PKG_CONFIG) --cflags $(GST_PACKAGES) $(AV_PACKAGES) $(WEBP_PACKAGES))
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -Wall -Wextra -Wpedantic -Werror=implicit-function-declaration
LDFLAGS += -shared
LDLIBS += $(shell $(PKG_CONFIG) --libs $(GST_PACKAGES) $(AV_PACKAGES) $(WEBP_PACKAGES)) -L$(DOTLOTTIE_ROOT)/lib -ldotlottie_rs -Wl,-rpath,'$$ORIGIN'

.PHONY: all module clean fixture test native-test check checkdoc compile dotlottie-sdk dotlottie-check dotlottie-runtime dotlottie-test-runtime

all: module

module: $(MODULE)

dotlottie-sdk:
	$(PYTHON) dotlottie-sdk.py build --root "$(DOTLOTTIE_ROOT)"

dotlottie-check:
	$(PYTHON) dotlottie-sdk.py check --root "$(DOTLOTTIE_ROOT)"

# SDK construction is explicit; ordinary module builds only inspect it.
# Report missing or stale inputs before invoking the compiler.
$(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST):
	$(PYTHON) dotlottie-sdk.py check --root "$(DOTLOTTIE_ROOT)"

dotlottie-runtime: | dotlottie-check
	mkdir -p "$(dir $(MODULE))"
	cmp -s "$(DOTLOTTIE_LIBRARY)" "$(DOTLOTTIE_DEPLOYED)" || \
	  { cp "$(DOTLOTTIE_LIBRARY)" "$(DOTLOTTIE_DEPLOYED).tmp" && mv -f "$(DOTLOTTIE_DEPLOYED).tmp" "$(DOTLOTTIE_DEPLOYED)"; }

dotlottie-test-runtime: | dotlottie-check
	mkdir -p test
	cmp -s "$(DOTLOTTIE_LIBRARY)" test/libdotlottie_rs.so || \
	  { cp "$(DOTLOTTIE_LIBRARY)" test/libdotlottie_rs.so.tmp && mv -f test/libdotlottie_rs.so.tmp test/libdotlottie_rs.so; }

$(MODULE): $(SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@.tmp $(SOURCES) $(LDLIBS) && mv -f $@.tmp $@

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

test/video-native-test: test/video-native-test.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test/video-native-test.c src/video-canvas.c $(ANIMATION_SOURCES) $(LDLIBS) -lm

test/video-apng-test: test/video-apng-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test/video-apng-test.c $(ANIMATION_SOURCES) $(LDLIBS) $(shell $(PKG_CONFIG) --libs zlib) -lm

test/video-webp-test: test/video-webp-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) $(shell $(PKG_CONFIG) --cflags libwebpmux) -o $@ test/video-webp-test.c $(ANIMATION_SOURCES) $(LDLIBS) $(shell $(PKG_CONFIG) --libs libwebpmux) -lm

test/video-lottie-test: test/video-lottie-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test/video-lottie-test.c $(ANIMATION_SOURCES) $(LDLIBS) -lm

native-test: test/video-native-test test/video-apng-test test/video-webp-test test/video-lottie-test
	./test/video-native-test
	./test/video-apng-test
	./test/video-webp-test
	./test/video-lottie-test

test: module fixture compile native-test
	$(EMACS) --batch -Q -L . -L test -l ert -l test/video-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f $(MODULE) $(DOTLOTTIE_DEPLOYED) $(LISP_SOURCES:.el=.elc) test/fixtures/test.webm test/video-native-test test/video-apng-test test/video-webp-test test/video-lottie-test test/libdotlottie_rs.so
