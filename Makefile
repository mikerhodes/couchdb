# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

# *******************************************************
# WARNING! If you edit this file, also edit Makefile.win!
# *******************************************************

include version.mk

REBAR?=$(shell echo `pwd`/bin/rebar)
ERLFMT?=$(shell echo `pwd`/bin/erlfmt)

# Handle the following scenarios:
#   1. When building from a tarball, use version.mk.
#   2. When building from a clean release tag (#.#.#), use that tag.
#   3. When building from a clean RC tag (#.#.#-RC#), use JUST the version
#      number inside the tarball, but use the full name for the name of the
#      tarball itself.
#   4. When not on a clean tag, use version.mk + git sha + dirty status.

COUCHDB_GIT_SHA=$(git_sha)

IN_RELEASE = $(shell if [ ! -d .git ]; then echo true; fi)
ifeq ($(IN_RELEASE), true)

# 1. Building from tarball, use version.mk.
COUCHDB_VERSION = $(vsn_major).$(vsn_minor).$(vsn_patch)

else

# Gather some additional information.
# We do it this way so we don't bake shell-isms into Makefile
# to make it easier to port to Windows. I know, I know. -jst
# IN_RC contains the -RCx suffix in the name if present
IN_RC = $(shell git describe --tags --always --first-parent \
        | grep -Eo -- '-RC[0-9]+' 2>/dev/null)
# ON_TAG matches *ONLY* if we are on a release or RC tag
ON_TAG = $(shell git describe --tags --always --first-parent \
        | grep -Eo -- '^[0-9]+\.[0-9]\.[0-9]+(-RC[0-9]+)?$$' 2>/dev/null)
# REL_TAG contains the #.#.# from git describe, which might be used
REL_TAG = $(shell git describe --tags --always --first-parent \
        | grep -Eo -- '^[0-9]+\.[0-9]\.[0-9]+' 2>/dev/null)
# DIRTY identifies if we're not on a commit
DIRTY = $(shell git describe --dirty | grep -Eo -- '-dirty' 2>/dev/null)
# COUCHDB_GIT_SHA is our current git hash.
COUCHDB_GIT_SHA=$(shell git rev-parse --short=7 --verify HEAD)

ifeq ($(ON_TAG),)
# 4. Not on a tag.
COUCHDB_VERSION_SUFFIX = $(COUCHDB_GIT_SHA)$(DIRTY)
COUCHDB_VERSION = $(vsn_major).$(vsn_minor).$(vsn_patch)-$(COUCHDB_VERSION_SUFFIX)
else
# 2 and 3. On a tag.
COUCHDB_VERSION = $(REL_TAG)$(DIRTY)
endif
endif

# needed to do text substitutions
comma:= ,
empty:=
space:= $(empty) $(empty)

DESTDIR=

# Rebar options
apps=
skip_deps=folsom,meck,mochiweb,triq,proper,snappy,bcrypt,hyper,ibrowse
suites=
tests=

COMPILE_OPTS=$(shell echo "\
	apps=$(apps) \
	" | sed -e 's/[a-z_]\{1,\}= / /g')
EUNIT_OPTS=$(shell echo "\
	skip_deps=$(skip_deps) \
	suites=$(suites) \
	tests=$(tests) \
	" | sed -e 's/[a-z]\{1,\}= / /g')
DIALYZE_OPTS=$(shell echo "\
	apps=$(apps) \
	skip_deps=$(skip_deps) \
	" | sed -e 's/[a-z]\{1,\}= / /g')
EXUNIT_OPTS=$(subst $(comma),$(space),$(tests))

TEST_OPTS="-c 'startup_jitter=0' -c 'default_security=admin_local'"

################################################################################
# Main commands
################################################################################


.PHONY: all
# target: all - Build everything
all: couch fauxton docs escriptize


.PHONY: help
# target: help - Print this help
help:
	@egrep "^# target: " Makefile \
		| sed -e 's/^# target: //g' \
		| sort \
		| awk '{printf("    %-21s", $$1); $$1=$$2=""; print "-" $$0}'


################################################################################
# Building
################################################################################


.PHONY: couch
# target: couch - Build CouchDB core, use ERL_COMPILER_OPTIONS to provide custom compiler's options
couch: config.erl
	@COUCHDB_VERSION=$(COUCHDB_VERSION) COUCHDB_GIT_SHA=$(COUCHDB_GIT_SHA) $(REBAR) compile $(COMPILE_OPTS)
	@cp src/couch/priv/couchjs bin/


.PHONY: docs
# target: docs - Build documentation
ifeq ($(IN_RELEASE), true)
docs: share/docs/html
else
docs: src/docs/build
endif

.PHONY: fauxton
# target: fauxton - Build Fauxton web UI
fauxton: share/www


.PHONY: escriptize
# target: escriptize - Build CLI tools
escriptize: couch
	@$(REBAR) -r escriptize apps=weatherreport
	@cp src/weatherreport/weatherreport bin/weatherreport


################################################################################
# Testing
################################################################################


.PHONY: check
# target: check - Test everything
check: all
	@$(MAKE) eunit
	@$(MAKE) mango-test
	@$(MAKE) elixir-suite
	@$(MAKE) weatherreport-test

ifdef apps
subdirs = $(apps)
else
subdirs=$(shell ls src)
endif

.PHONY: eunit
# target: eunit - Run EUnit tests, use EUNIT_OPTS to provide custom options
eunit: export BUILDDIR = $(shell pwd)
eunit: export ERL_AFLAGS = -config $(shell pwd)/rel/files/eunit.config
eunit: export COUCHDB_QUERY_SERVER_JAVASCRIPT = $(shell pwd)/bin/couchjs $(shell pwd)/share/server/main.js
eunit: export COUCHDB_TEST_ADMIN_PARTY_OVERRIDE=1
eunit: couch
	@COUCHDB_VERSION=$(COUCHDB_VERSION) COUCHDB_GIT_SHA=$(COUCHDB_GIT_SHA) $(REBAR) setup_eunit 2> /dev/null
	@for dir in $(subdirs); do \
            COUCHDB_VERSION=$(COUCHDB_VERSION) COUCHDB_GIT_SHA=$(COUCHDB_GIT_SHA) $(REBAR) -r eunit $(EUNIT_OPTS) apps=$$dir || exit 1; \
        done


.PHONY: exunit
# target: exunit - Run ExUnit tests, use EXUNIT_OPTS to provide custom options
exunit: export BUILDDIR = $(shell pwd)
exunit: export MIX_ENV=test
exunit: export ERL_LIBS = $(shell pwd)/src
exunit: export ERL_AFLAGS = -config $(shell pwd)/rel/files/eunit.config
exunit: export COUCHDB_QUERY_SERVER_JAVASCRIPT = $(shell pwd)/bin/couchjs $(shell pwd)/share/server/main.js
exunit: export COUCHDB_TEST_ADMIN_PARTY_OVERRIDE=1
exunit: couch elixir-init setup-eunit
	@mix test --trace $(EXUNIT_OPTS)

setup-eunit: export BUILDDIR = $(shell pwd)
setup-eunit: export ERL_AFLAGS = -config $(shell pwd)/rel/files/eunit.config
setup-eunit:
	@$(REBAR) setup_eunit 2> /dev/null

just-eunit: export BUILDDIR = $(shell pwd)
just-eunit: export ERL_AFLAGS = -config $(shell pwd)/rel/files/eunit.config
just-eunit:
	@$(REBAR) -r eunit $(EUNIT_OPTS)

.PHONY: soak-eunit
soak-eunit: export BUILDDIR = $(shell pwd)
soak-eunit: export ERL_AFLAGS = -config $(shell pwd)/rel/files/eunit.config
soak-eunit: couch
	@$(REBAR) setup_eunit 2> /dev/null
	while [ $$? -eq 0 ] ; do $(REBAR) -r eunit $(EUNIT_OPTS) ; done

# target: erlfmt-check - Check source code formatting
erlfmt-check:
	ERLFMT_PATH=$(ERLFMT) python3 dev/format_check.py

# target: erlfmt-format - Apply source code format standards automatically
erlfmt-format:
	ERLFMT_PATH=$(ERLFMT) python3 dev/format_all.py

.venv/bin/black:
	@python3 -m venv .venv
	@.venv/bin/pip3 install black || touch .venv/bin/black

# target: python-black - Python code formatter, runs only on Python >= 3.6
python-black: .venv/bin/black
	@python3 -c "import sys; exit(1 if sys.version_info < (3,6) else 0)" || \
	       echo "Python formatter not supported on Python < 3.6; check results on a newer platform"
	@python3 -c "import sys; exit(1 if sys.version_info >= (3,6) else 0)" || \
		LC_ALL=C.UTF-8 LANG=C.UTF-8 .venv/bin/black --check \
		--exclude="build/|buck-out/|dist/|_build/|\.git/|\.hg/|\.mypy_cache/|\.nox/|\.tox/|\.venv/|src/erlfmt|src/jiffy|src/rebar/pr2relnotes.py|src/fauxton" \
		build-aux/*.py dev/run dev/format_*.py src/mango/test/*.py src/docs/src/conf.py src/docs/ext/*.py .

python-black-update: .venv/bin/black
	@python3 -c "import sys; exit(1 if sys.version_info < (3,6) else 0)" || \
	       echo "Python formatter not supported on Python < 3.6; check results on a newer platform"
	@python3 -c "import sys; exit(1 if sys.version_info >= (3,6) else 0)" || \
		LC_ALL=C.UTF-8 LANG=C.UTF-8 .venv/bin/black \
		--exclude="build/|buck-out/|dist/|_build/|\.git/|\.hg/|\.mypy_cache/|\.nox/|\.tox/|\.venv/|src/rebar/pr2relnotes.py|src/fauxton" \
		build-aux/*.py dev/run src/mango/test/*.py src/docs/src/conf.py src/docs/ext/*.py .

.PHONY: elixir
elixir: export MIX_ENV=integration
elixir: export COUCHDB_TEST_ADMIN_PARTY_OVERRIDE=1
elixir: elixir-init devclean
	@dev/run "$(TEST_OPTS)" -a adm:pass -n 1 \
		--enable-erlang-views \
		--locald-config test/elixir/test/config/test-config.ini \
		--no-eval 'mix test --trace --exclude without_quorum_test --exclude with_quorum_test $(EXUNIT_OPTS)'

.PHONY: elixir-init
elixir-init: MIX_ENV=integration
elixir-init: config.erl
	@mix local.rebar --force rebar3 ./bin/rebar3 && mix local.hex --force && mix deps.get

.PHONY: elixir-cluster-without-quorum
elixir-cluster-without-quorum: export MIX_ENV=integration
elixir-cluster-without-quorum: elixir-init devclean
	@dev/run -n 3 -q -a adm:pass \
		--degrade-cluster 2 \
		--no-eval 'mix test --trace --only without_quorum_test $(EXUNIT_OPTS)'

.PHONY: elixir-cluster-with-quorum
elixir-cluster-with-quorum: export MIX_ENV=integration
elixir-cluster-with-quorum: elixir-init devclean
	@dev/run -n 3 -q -a adm:pass \
		--degrade-cluster 1 \
		--no-eval 'mix test --trace --only with_quorum_test $(EXUNIT_OPTS)'

.PHONY: elixir-suite
# target: elixir-suite - Run Elixir-based integration tests
elixir-suite: export MIX_ENV=integration
elixir-suite: export COUCHDB_TEST_ADMIN_PARTY_OVERRIDE=1
elixir-suite: elixir-init devclean
	@dev/run -n 1 -q -a adm:pass \
		--enable-erlang-views \
		--no-join \
		--locald-config test/elixir/test/config/test-config.ini \
		--erlang-config rel/files/eunit.config \
		--no-eval 'mix test --trace --include test/elixir/test/config/suite.elixir --exclude test/elixir/test/config/skip.elixir'

.PHONY: elixir-search
# target: elixir-search - Run search tests, requires a running Clouseau instance
elixir-search: export MIX_ENV=integration
elixir-search: elixir-init devclean
	@dev/run -n 1 -q -a adm:pass \
		--locald-config test/config/test-config.ini \
		--no-eval 'mix test --trace --include test/elixir/test/config/search.elixir'

.PHONY: elixir-source-checks
# target: elixir-source-checks - Check source code formatting of Elixir test files
elixir-source-checks: export MIX_ENV=integration
elixir-source-checks: elixir-init
	@mix format --check-formatted
	@mix credo

.PHONY: build-report
# target: build-report - Generate a build report
build-report:
	build-aux/show-test-results.py --suites=10 --tests=10 > test-results.log

.PHONY: check-qs
# target: check-qs - Run query server tests (ruby and rspec required!)
check-qs:
	@QS_LANG=js rspec test/view_server/query_server_spec.rb


.PHONY: list-eunit-apps
# target: list-eunit-apps - List EUnit target apps
list-eunit-apps:
	@find ./src -type f -name *_test.erl -o -name *_tests.erl \
		| cut -d '/' -f 3 \
		| sort -u


.PHONY: list-eunit-suites
# target: list-eunit-suites - List EUnit target test suites
list-eunit-suites:
	@find ./src -type f -name *_test.erl -o -name *_tests.erl -exec basename {} \; \
		| cut -d '.' -f -1 \
		| sort


.PHONY: build-test
# target: build-test - Test build script
build-test:
	@test/build/test-configure.sh


.PHONY: mango-test
# target: mango-test - Run Mango tests
mango-test: export COUCHDB_TEST_ADMIN_PARTY_OVERRIDE=1
mango-test: devclean all
	@cd src/mango && \
		python3 -m venv .venv && \
		.venv/bin/python3 -m pip install -r requirements.txt
	@cd src/mango && \
		../../dev/run "$(TEST_OPTS)" \
		-n 1 \
		--admin=adm:pass \
		'COUCH_USER=adm COUCH_PASS=pass .venv/bin/python3 -m nose2 $(MANGO_TEST_OPTS)'


.PHONY: weatherreport-test
# target: weatherreport-test - Run weatherreport against dev cluster
weatherreport-test: devclean escriptize
	@dev/run -n 1 -a adm:pass --no-eval \
		'bin/weatherreport --etc dev/lib/node1/etc --level error'

################################################################################
# Developing
################################################################################


.PHONY: build-plt
# target: build-plt - Build project-specific PLT
build-plt:
	@$(REBAR) -r build-plt $(DIALYZE_OPTS)


.PHONY: check-plt
# target: check-plt - Check the PLT for consistency and rebuild it if it is not up-to-date
check-plt:
	@$(REBAR) -r check-plt $(DIALYZE_OPTS)


.PHONY: dialyze
# target: dialyze - Analyze the code for discrepancies
dialyze: .rebar
	@$(REBAR) -r dialyze $(DIALYZE_OPTS)


.PHONY: find_bugs
# target: find_bugs - Find unused exports etc
find_bugs:
	@$(REBAR) --keep-going --recursive xref $(DIALYZE_OPTS)

.PHONY: introspect
# target: introspect - Check for commits difference between rebar.config and repository
introspect:
	@$(REBAR) -r update-deps
	@build-aux/introspect

################################################################################
# Distributing
################################################################################


.PHONY: dist
# target: dist - Make release tarball
dist: all derived
	@./build-aux/couchdb-build-release.sh $(COUCHDB_VERSION)

	@cp -r share/www apache-couchdb-$(COUCHDB_VERSION)/share/
	@mkdir -p apache-couchdb-$(COUCHDB_VERSION)/share/docs/html
	@cp -r src/docs/build/html apache-couchdb-$(COUCHDB_VERSION)/share/docs/

	@mkdir -p apache-couchdb-$(COUCHDB_VERSION)/share/docs/man
	@cp src/docs/build/man/apachecouchdb.1 apache-couchdb-$(COUCHDB_VERSION)/share/docs/man/

	@tar czf apache-couchdb-$(COUCHDB_VERSION)$(IN_RC).tar.gz apache-couchdb-$(COUCHDB_VERSION)
	@echo "Done: apache-couchdb-$(COUCHDB_VERSION)$(IN_RC).tar.gz"


.PHONY: release
# target: release - Create an Erlang release including CouchDB!
-include install.mk
release: all
	@echo "Installing CouchDB into rel/couchdb/ ..."
	@rm -rf rel/couchdb
	@$(REBAR) generate # make full erlang release
	@cp bin/weatherreport rel/couchdb/bin/weatherreport

ifeq ($(with_fauxton), 1)
	@mkdir -p rel/couchdb/share/
	@cp -R share/www rel/couchdb/share/
endif

ifeq ($(with_docs), 1)
ifeq ($(IN_RELEASE), true)
	@mkdir -p rel/couchdb/share/www/docs/
	@mkdir -p rel/couchdb/share/docs/
	@cp -R share/docs/html/* rel/couchdb/share/www/docs/
	@cp share/docs/man/apachecouchdb.1 rel/couchdb/share/docs/couchdb.1
else
	@mkdir -p rel/couchdb/share/www/docs/
	@mkdir -p rel/couchdb/share/docs/
	@cp -R src/docs/build/html/ rel/couchdb/share/www/docs
	@cp src/docs/build/man/apachecouchdb.1 rel/couchdb/share/docs/couchdb.1
endif
endif

	@echo "... done"
	@echo
	@echo "    You can now copy the rel/couchdb directory anywhere on your system."
	@echo "    Start CouchDB with ./bin/couchdb from within that directory."
	@echo

.PHONY: install
# target: install - Install CouchDB :)
install: release
	@echo
	@echo "Notice: There is no 'make install' command for CouchDB 2.x+."
	@echo
	@echo "    To install CouchDB into your system, copy the rel/couchdb"
	@echo "    to your desired installation location. For example:"
	@echo "    cp -r rel/couchdb /usr/local/lib"
	@echo

################################################################################
# Cleaning
################################################################################


.PHONY: clean
# target: clean - Remove build artifacts
clean:
	@$(REBAR) -r clean
	@rm -rf .rebar/
	@rm -f bin/couchjs
	@rm -f bin/weatherreport
	@rm -rf src/*/ebin
	@rm -rf src/*/.rebar
	@rm -rf src/*/priv/*.so
	@rm -rf src/couch/priv/{couchspawnkillable,couchjs}
	@rm -rf share/server/main.js share/server/main-ast-bypass.js share/server/main-coffee.js
	@rm -rf tmp dev/data dev/lib dev/logs
	@rm -rf src/mango/.venv
	@rm -f src/couch/priv/couchspawnkillable
	@rm -f src/couch/priv/couch_js/config.h
	@rm -f dev/*.beam dev/devnode.* dev/pbkdf2.pyc log/crash.log
	@rm -f dev/erlserver.pem dev/couch_ssl_dist.conf


.PHONY: distclean
# target: distclean - Remove build and release artifacts
distclean: clean
	@rm -f install.mk
	@rm -f config.erl
	@rm -f rel/couchdb.config
ifneq ($(IN_RELEASE), true)
# when we are in a release, don’t delete the
# copied sources, generated docs, or fauxton
	@rm -rf rel/couchdb
	@rm -rf share/www
	@rm -rf src/docs
endif


.PHONY: devclean
# target: devclean - Remove dev cluster artifacts
devclean:
	@rm -rf dev/lib/*/data
	@rm -rf dev/lib/*/etc

################################################################################
# Misc
################################################################################


.rebar: build-plt

config.erl:
	@echo "Apache CouchDB has not been configured."
	@echo "Try \"./configure -h\" for help."
	@echo
	@false


src/docs/build:
ifeq ($(with_docs), 1)
	@cd src/docs; ./setup.sh ; $(MAKE)
endif


share/www:
ifeq ($(with_fauxton), 1)
	@echo "Building Fauxton"
	@cd src/fauxton && npm install && ./node_modules/grunt-cli/bin/grunt couchdb
endif


derived:
	@echo "COUCHDB_GIT_SHA:        $(COUCHDB_GIT_SHA)"
	@echo "COUCHDB_VERSION:        $(COUCHDB_VERSION)"
	@echo "COUCHDB_VERSION_SUFFIX: $(COUCHDB_VERSION_SUFFIX)"
	@echo "DIRTY:                  $(DIRTY)"
	@echo "IN_RC:                  $(IN_RC)"
	@echo "IN_RELEASE:             $(IN_RELEASE)"
	@echo "ON_TAG:                 $(ON_TAG)"
	@echo "REL_TAG:                $(REL_TAG)"
	@echo "SUB_VSN:                $(SUB_VSN)"
