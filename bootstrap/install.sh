#!/usr/bin/env sh

# This will:
# - install clang
# - download axe bootstrap repo
# - build axe binary from bootstrap repo
# - copy binary and dependencies to /usr/local/bin
# - delete bootstrap repo and clean up axc binary

# Detect package manager
if command -v pacman &> /dev/null; then
  PKG_MANAGER="pacman"
elif command -v dnf &> /dev/null; then
  PKG_MANAGER="dnf"
elif command -v apt &> /dev/null; then
  PKG_MANAGER="apt"
elif command -v brew &> /dev/null; then
  PKG_MANAGER="brew"
else
  echo "No supported package manager found (apt, dnf, pacman, brew)."
  exit 1
fi

echo "Detected package manager: $PKG_MANAGER"

# Install clang
PACKAGE="clang"
case $PKG_MANAGER in
  pacman) sudo pacman -Sy --noconfirm base-devel $PACKAGE openmp ;;
  dnf) sudo dnf install -y $PACKAGE libomp-devel ;;
  apt) sudo apt update && sudo apt install -y build-essential $PACKAGE libomp-dev ;;
  brew) brew install $PACKAGE libomp ;;
esac

# Build axe binary
git clone https://github.com/axelang/axe-bootstrap.git 
chmod +x ./axe-bootstrap/build_exp.sh
(cd ./axe-bootstrap && ./build_exp.sh)
cp ./source/compiler/std ./axe-bootstrap/std -r
./axe-bootstrap/axe ./source/compiler/axc.axe
rm -rf ./source/compiler/axc

# Copy binary and depedencies to /usr/local/bin
sudo mv ./axe-bootstrap/axe /usr/local/bin/
sudo mv ./axe-bootstrap/std /usr/local/bin/
sudo rm -rf ./axe-bootstrap
