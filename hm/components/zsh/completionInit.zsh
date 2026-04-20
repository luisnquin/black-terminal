#!bin/zsh

autoload -U compinit && compinit

if whence complete >/dev/null 2>&1 && command -v aws_completer >/dev/null 2>&1; then
	complete -C "$(command -v aws_completer)" aws
fi

if command -v senv >/dev/null; then
	source <(senv completion zsh)
fi

# Show only Makefile rules unless they aren't defined
zstyle ':completion::complete:make::' tag-order targets variables
