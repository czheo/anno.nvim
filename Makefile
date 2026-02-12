PLENARY ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim

.PHONY: test

test:
	nvim --headless -u NONE \
		-c "set rtp+=." \
		-c "set rtp+=$(PLENARY)" \
		-c "lua require('plenary.busted').run('tests/anno_spec.lua')"
