SHELL := /bin/bash

.PHONY: help up reset lint test demo preflight acceptance

help:
	@echo "Available targets:"
	@echo "  make up          # start local dev environment"
	@echo "  make reset       # reset local dev environment"
	@echo "  make lint        # run lint checks (placeholder)"
	@echo "  make test        # run tests (placeholder)"
	@echo "  make demo        # run demo (placeholder)"
	@echo "  make acceptance  # run acceptance checks from SPEC.md"

up:
	docker-compose up -d

reset:
	docker-compose down -v --rmi all || true
	docker-compose up -d --build

lint:
	@echo "Lint placeholder: configure project-specific lint command and update Makefile."

test:
	@echo "Test placeholder: use 'docker-compose run --rm app <test-command>' to run your suite."

demo:
	@echo "Demo placeholder: use 'docker-compose run --rm app <demo-command>' to showcase the app."

preflight:
	./tools/ai/preflight.sh

acceptance: preflight
	@if [ -f SPEC.md ]; then \
		if [ -x ./tools/ai/run_acceptance.sh ]; then \
			./tools/ai/run_acceptance.sh SPEC.md; \
		else \
			echo "tools/ai/run_acceptance.sh is missing or not executable" && exit 1; \
		fi; \
	else \
		echo "SPEC.md not found; run ./tools/ai/plan.sh first."; \
	fi
