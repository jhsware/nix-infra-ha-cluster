#!/usr/bin/env sh
BRANCH=${BRANCH:-"main"}
REPO=${REPO:-"git@github.com:jhsware/nix-infra-ha-cluster.git"}


# Check for git CLI
if ! command -v git >/dev/null 2>&1; then
  echo "You need 'git' for this script to work."
  echo "Install git using your prefered package manager. If in doubt, install Determinate Nix"
  echo "https://docs.determinate.systems/determinate-nix/ and run: 'nix-shell -p git'"
  echo
  echo "With nix-shell you get ephemeral shell environments. Learn more:"
  echo "https://medium.com/@nonickedgr/exploring-nix-shell-a-game-changer-for-ephemeral-environments-5c622e4074a8"
  exit 1
fi


printf "Enter folder name [test-nix-infra-ha-cluster]: "
read -r name
name=${name:-test-nix-infra-ha-cluster}

if [ -e "./$name" ]; then
  echo "Folder or file $name already exists in this directory, aborting."
  exit 1
fi

git clone -b "$BRANCH" "$REPO" "$name"
cp "$name/.env.in" "$name/.env"

echo "Done!"
echo
echo "Make sure you have installed nix-infra, then:"
echo
echo "1. cd ./$name"
echo "2. Edit .env"
echo "3. Run:"
echo "   ./cli --help              - Manage infrastructure (create, destroy, ssh, etc.)"
echo "   ./__test__/run-tests.sh --help - Run test suite against cluster"
echo
