EMACS ?= emacs
CC ?= cc
PKG_CONFIG ?= pkg-config
EMACS_MODULE_INCLUDE ?= /usr/local/include
DOTLOTTIE_ROOT ?= /usr/local
DOTLOTTIE_HEADER := $(DOTLOTTIE_ROOT)/include/dotlottie_player.h
DOTLOTTIE_LIBRARY := $(DOTLOTTIE_ROOT)/lib/libdotlottie_rs.so

MODULE ?= video-module.so
ANIMATION_SOURCES := src/video-animation.c src/video-lottie.c src/video-apng.c src/video-webp.c
SOURCES := src/video-module.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES)
HEADERS := src/video-runtime.h src/video-canvas.h src/video-animation.h src/video-lottie.h src/video-apng.h src/video-webp.h
LISP_SOURCES := video-source.el video-runtime.el video-view.el video-inline.el video-evil.el video.el
GST_PACKAGES := gstreamer-play-1.0 gstreamer-app-1.0 gstreamer-video-1.0 libass
AV_PACKAGES := libavformat libavcodec libavutil libswscale
WEBP_PACKAGES := libwebp libwebpdemux
override CPPFLAGS += -I$(EMACS_MODULE_INCLUDE) -I$(DOTLOTTIE_ROOT)/include $(shell $(PKG_CONFIG) --cflags $(GST_PACKAGES) $(AV_PACKAGES) $(WEBP_PACKAGES))
CFLAGS ?= -O2 -g
override CFLAGS += -std=c11 -fPIC -Wall -Wextra -Wpedantic -Werror=implicit-function-declaration
override LDFLAGS += -L$(DOTLOTTIE_ROOT)/lib -Wl,-rpath,'$(abspath $(DOTLOTTIE_ROOT))/lib'
override LDLIBS += $(shell $(PKG_CONFIG) --libs $(GST_PACKAGES) $(AV_PACKAGES) $(WEBP_PACKAGES)) -ldotlottie_rs -lm

.PHONY: all module clean fixture test native-test check checkdoc compile

all: module

module: $(MODULE)

$(MODULE): $(SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY)
	mkdir -p "$(dir $(MODULE))"
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -shared -o "$@.tmp" $(SOURCES) $(LDLIBS) && mv -f "$@.tmp" "$@"

test/fixtures/test.webm:
	mkdir -p test/fixtures
	gst-launch-1.0 -q videotestsrc num-buffers=45 pattern=ball \
		! video/x-raw,width=160,height=90,framerate=30/1 \
		! vp8enc deadline=1 \
		! webmmux \
		! filesink location=$@

fixture: test/fixtures/test.webm

compile: module
	$(EMACS) --batch -Q -L . -l "$(abspath $(MODULE))" -f batch-byte-compile $(LISP_SOURCES)

checkdoc:
	$(EMACS) --batch -Q -L . --eval '(progn (require (quote checkdoc)) (mapc (function checkdoc-file) command-line-args-left) (setq command-line-args-left nil))' $(LISP_SOURCES)

check: module compile checkdoc
	$(EMACS) --batch -Q -L . -l "$(abspath $(MODULE))" --eval '(progn (require (quote video)) (princ "video.el loaded\n"))'

test/video-native-test: test/video-native-test.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ test/video-native-test.c src/video-canvas.c $(ANIMATION_SOURCES) $(LDLIBS)

test/video-apng-test: test/video-apng-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(shell $(PKG_CONFIG) --cflags zlib) $(LDFLAGS) -o $@ test/video-apng-test.c $(ANIMATION_SOURCES) $(LDLIBS) $(shell $(PKG_CONFIG) --libs zlib)

test/video-webp-test: test/video-webp-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(shell $(PKG_CONFIG) --cflags libwebpmux) $(LDFLAGS) -o $@ test/video-webp-test.c $(ANIMATION_SOURCES) $(LDLIBS) $(shell $(PKG_CONFIG) --libs libwebpmux)

test/video-lottie-test: test/video-lottie-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ test/video-lottie-test.c $(ANIMATION_SOURCES) $(LDLIBS)

native-test: test/video-native-test test/video-apng-test test/video-webp-test test/video-lottie-test
	./test/video-native-test
	./test/video-apng-test
	./test/video-webp-test
	./test/video-lottie-test

test: module fixture compile native-test
	$(EMACS) --batch -Q -L . -l "$(abspath $(MODULE))" -L test -l ert -l test/video-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f "$(MODULE)" "$(MODULE).tmp" $(LISP_SOURCES:.el=.elc) test/fixtures/test.webm test/video-native-test test/video-apng-test test/video-webp-test test/video-lottie-test
