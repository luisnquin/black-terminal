#!bin/zsh

autoload -U compinit && compinit

complete -C "$(which aws_completer)" aws

if command -v senv >/dev/null; then
	source <(senv completion zsh)
fi

# Show only Makefile rules unless they aren't defined
zstyle ':completion::complete:make::' tag-order targets variables
