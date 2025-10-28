#!/usr/bin/env zsh
set -eu

git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
sed -i -E 's/^ZSH_THEME=.*/ZSH_THEME="af-magic"/; s/^plugins=.*/plugins=(git docker docker-compose podman zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
