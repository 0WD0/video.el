EMACS ?= emacs
BAZEL ?= bazel
BAZELFLAGS ?= --compilation_mode=opt
REPO_ROOT := $(abspath ../..)

MODULE := video-module.so
LISP_SOURCES := video-source.el video-runtime.el video-view.el video-inline.el video-evil.el video.el
.PHONY: all module clean fixture test native-test check checkdoc compile

all: module

module:
	$(BAZEL) build $(BAZELFLAGS) //appkit-apps/video.el:native_runtime
	@set -eu; \
	files="$$( $(BAZEL) cquery $(BAZELFLAGS) --output=files //appkit-apps/video.el:native_runtime )"; \
	mkdir -p "$(dir $(MODULE))"; \
	for file in $$files; do \
	  name="$${file##*/}"; \
	  destination="$(dir $(MODULE))$$name"; \
	  if test "$$name" = video-module.so; then destination="$(MODULE)"; fi; \
	  ln -sfnT "$$(realpath -- "$(REPO_ROOT)/$$file")" "$$destination"; \
	done

test/fixtures/test.webm: | module
	mkdir -p test/fixtures
	"$(dir $(MODULE))gstreamer/bin/gst-launch-1.0" -q videotestsrc num-buffers=45 pattern=ball \
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

native-test:
	$(BAZEL) test $(BAZELFLAGS) //appkit-apps/video.el:native_tests

test: module fixture compile native-test
	$(EMACS) --batch -Q -L . -L test -l ert -l test/video-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f "$(MODULE)" "$(dir $(MODULE))libdotlottie_rs.so" "$(dir $(MODULE))gstreamer" $(LISP_SOURCES:.el=.elc) test/fixtures/test.webm test/video-native-test test/video-apng-test test/video-webp-test test/video-lottie-test test/libdotlottie_rs.so
