EMACS ?= emacs

ELISP_SOURCES := $(sort $(wildcard kemacs*.el))
ELISP_COMPILED := $(ELISP_SOURCES:.el=.elc)
TEST_FILE := test/kemacs-test.el
TEST_COMPILED := $(TEST_FILE:.el=.elc)

.DEFAULT_GOAL := check
.PHONY: test compile checkdoc check clean
.NOTPARALLEL:

test:
	$(EMACS) -Q --batch -L . -L test \
	  --eval '(setq load-prefer-newer t)' \
	  -l $(TEST_FILE) \
	  -f ert-run-tests-batch-and-exit

compile: clean
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(ELISP_SOURCES) $(TEST_FILE)

checkdoc:
	$(EMACS) -Q --batch -L . -L test \
	  --eval '(setq load-prefer-newer t)' \
	  -l $(TEST_FILE) \
	  -f kemacs-test-checkdoc-batch

check: compile test checkdoc

clean:
	$(RM) $(ELISP_COMPILED) $(TEST_COMPILED)
