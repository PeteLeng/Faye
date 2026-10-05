EMACS ?= emacs

FILES = faye.el faye-session.el faye-openai.el faye-view.el faye-context.el faye-output.el
TESTS = $(wildcard test/*-test.el)

.PHONY: test compile check clean

clean:
	rm -f *.elc

test:
	$(EMACS) -Q --batch -L . -L test \
	  $(foreach test,$(TESTS),-l $(test)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval "(progn (require 'bytecomp) (let ((byte-compile-error-on-warn t)) (dolist (f (split-string \"$(FILES)\")) (unless (byte-compile-file f) (error \"Byte compilation failed: %s\" f)))))"

check: compile test
