#!/bin/bash

# This script installs the tools needed to run the k8s-planning project
os=$(uname)
if
    [ "$os" = "Linux" ]
then
    echo "checking package manager"
    if
        command -v apt >/dev/null 2>&1
    then
        echo "apt package manager"
    elif
        command -v dnf >/dev/null 2>&1
    then
        echo "dnf package manager"
    elif
        command -v yum >/dev/null 2>&1
    then
        echo "yum package manager"
    elif
        command -v zypper >/dev/null 2>&1
    then
        echo "zypper package manager"
    elif
        command -v pacman >/dev/null 2>&1
    then
        echo "pacman package manager"
        echo "installing tools"
        sudo pacman -S openbao packer kubectl helm argocd velero mc ansible jq git curl
        echo "checking if brew is installed"
        homebrew=$(command -v brew)
        if
            [ -z "$homebrew" ]
        then
            echo "homebrew not installed"
            echo "installing homebrew"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew tap tofuutils/tap
        brew install gh tofuenv
    else
        echo "no known package manager"
    fi
elif
    [ "$os" = "Darwin" ]
then
    echo "macOS"
else
    echo "unknown OS"
fi
