EMACS ?= emacs
CC ?= cc
PKG_CONFIG ?= pkg-config
EMACS_MODULE_INCLUDE ?= /usr/local/include
PYTHON ?= python3
DOTLOTTIE_VERSION := 0.1.58
DOTLOTTIE_ROOT ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/video.el/dotlottie/v$(DOTLOTTIE_VERSION)/linux-x86_64
DOTLOTTIE_HEADER := $(DOTLOTTIE_ROOT)/include/dotlottie_player.h
DOTLOTTIE_LIBRARY := $(DOTLOTTIE_ROOT)/lib/libdotlottie_rs.so
DOTLOTTIE_MANIFEST := $(DOTLOTTIE_ROOT)/.dotlottie-sdk.json
DOTLOTTIE_DEPLOYED = $(dir $(MODULE))libdotlottie_rs.so

MODULE := video-module.so
ANIMATION_SOURCES := src/video-animation.c src/video-lottie.c src/video-apng.c
SOURCES := src/video-module.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES)
HEADERS := src/video-runtime.h src/video-canvas.h src/video-animation.h src/video-lottie.h src/video-apng.h
LISP_SOURCES := video-source.el video-runtime.el video-view.el video-inline.el video-evil.el video.el
GST_PACKAGES := gstreamer-play-1.0 gstreamer-app-1.0 gstreamer-video-1.0 libass
AV_PACKAGES := libavformat libavcodec libavutil libswscale
CPPFLAGS += -I$(EMACS_MODULE_INCLUDE) -I$(DOTLOTTIE_ROOT)/include $(shell $(PKG_CONFIG) --cflags $(GST_PACKAGES) $(AV_PACKAGES))
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -Wall -Wextra -Wpedantic -Werror=implicit-function-declaration
LDFLAGS += -shared
LDLIBS += $(shell $(PKG_CONFIG) --libs $(GST_PACKAGES) $(AV_PACKAGES)) -L$(DOTLOTTIE_ROOT)/lib -ldotlottie_rs -Wl,-rpath,'$$ORIGIN'

.PHONY: all module clean fixture test native-test check checkdoc compile provision-dotlottie dotlottie-check dotlottie-runtime dotlottie-test-runtime

all: module

module: $(MODULE)

provision-dotlottie:
	$(PYTHON) provision-dotlottie.py provision --root "$(DOTLOTTIE_ROOT)"

dotlottie-check:
	$(PYTHON) provision-dotlottie.py check --root "$(DOTLOTTIE_ROOT)"

# Missing metadata or files must fail with provisioning instructions, not a
# misleading link error.  No build target fetches anything from the network.
$(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST):
	$(PYTHON) provision-dotlottie.py check --root "$(DOTLOTTIE_ROOT)"

dotlottie-runtime: | dotlottie-check
	mkdir -p "$(dir $(MODULE))"
	cmp -s "$(DOTLOTTIE_LIBRARY)" "$(DOTLOTTIE_DEPLOYED)" || cp "$(DOTLOTTIE_LIBRARY)" "$(DOTLOTTIE_DEPLOYED)"

dotlottie-test-runtime: | dotlottie-check
	mkdir -p test
	cmp -s "$(DOTLOTTIE_LIBRARY)" test/libdotlottie_rs.so || cp "$(DOTLOTTIE_LIBRARY)" test/libdotlottie_rs.so

$(MODULE): $(SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-runtime
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

test/video-native-test: test/video-native-test.c src/video-runtime.c src/video-canvas.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test/video-native-test.c src/video-canvas.c $(ANIMATION_SOURCES) $(LDLIBS) -lm

test/video-apng-test: test/video-apng-test.c $(ANIMATION_SOURCES) $(HEADERS) $(DOTLOTTIE_HEADER) $(DOTLOTTIE_LIBRARY) $(DOTLOTTIE_MANIFEST) | dotlottie-check dotlottie-test-runtime
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ test/video-apng-test.c $(ANIMATION_SOURCES) $(LDLIBS) $(shell $(PKG_CONFIG) --libs zlib) -lm

native-test: test/video-native-test test/video-apng-test
	./test/video-native-test
	./test/video-apng-test

test: module fixture compile native-test
	$(EMACS) --batch -Q -L . -L test -l ert -l test/video-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f $(MODULE) $(DOTLOTTIE_DEPLOYED) $(LISP_SOURCES:.el=.elc) test/fixtures/test.webm test/video-native-test test/video-apng-test test/libdotlottie_rs.so
