#!/bin/sh
# Build a distributable zip for a mod in this repo.
#
#   sh package.sh                        # builds FS25_ForwardContracts
#   sh package.sh FS25_SubsoilerTillage  # or any other mod folder here
#
# ⚠ IT PACKAGES WHAT IS COMMITTED, NOT YOUR WORKING TREE.
#
# `git archive` reads from HEAD, so an uncommitted edit is NOT in the zip. That is deliberate —
# what you hand someone should be a thing you can point at a commit for — but it is also the
# obvious way to ship a stale file by accident, so this warns loudly when the tree is dirty.
#
# WHY GIT AND NOT A FILE LIST: .gitignore is already the manifest. Design notes, research and
# test/ are excluded there, and test/ vendors Realistic Livestock's own xml which is GPLv3 and
# not ours to redistribute. A second hand-written list would drift from it, and the first thing
# to leak would be the thing that must not.

set -e

MOD="${1:-FS25_ForwardContracts}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ ! -d "$MOD" ]; then
	echo "No such mod folder: $MOD" >&2
	exit 1
fi

if [ ! -f "$MOD/modDesc.xml" ]; then
	echo "$MOD has no modDesc.xml — that is not a mod folder." >&2
	exit 1
fi

# Version straight out of modDesc, so the filename can never disagree with what loads.
VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$MOD/modDesc.xml" | head -1)
OUT="$ROOT/$MOD.zip"

if [ -n "$(git status --porcelain -- "$MOD")" ]; then
	echo
	echo "⚠  WARNING: $MOD has uncommitted changes. They will NOT be in the zip."
	git status --short -- "$MOD" | sed 's/^/     /'
	echo
fi

rm -f "$OUT"

# HEAD:<subtree> puts modDesc.xml at the root of the archive, which is what FS25 requires.
#
# LICENSE is excluded rather than deleted. Giants' TestRunner rejects any file whose extension is
# not on its allow-list (.xml .lua .dds .i3d .shapes .anim .ogg .wav .gls .ogv .gdm .grle .cache),
# and an extensionless LICENSE fails that — no rename saves it, .txt is not on the list either.
# The licence still belongs in the public repo, so it stays in git and only the zip drops it.
git archive --format=zip -o "$OUT" "HEAD:$MOD" -- . ':(exclude)LICENSE'

# Counted from the archive, not from git ls-files, so the number cannot disagree with the zip.
COUNT=$(unzip -Z1 "$OUT" | grep -cv '/$')

echo "Built $MOD.zip  (version $VERSION, $COUNT files)"
echo

# A LEAK CHECK, because "the gitignore handles it" is a belief until something asserts it.
# These are the three things that must never reach a player: design notes, the test harness
# (which carries RL's data), and icon source files. LICENSE is in here too — not because it
# harms a player, but because TestRunner fails the whole submission over it, and the exclude
# pathspec above is exactly the kind of thing that gets lost in a future edit.
LEAKS=$(unzip -Z1 "$OUT" | grep -E '(^|/)(test/|.*\.md$|_source_icon|.*\.xcf$|.*\.psd$|LICENSE$)' | grep -v '^README.md$' || true)

if [ -n "$LEAKS" ]; then
	echo "❌ LEAKED FILES — do not send this zip:" >&2
	echo "$LEAKS" | sed 's/^/     /' >&2
	exit 1
fi

if ! unzip -Z1 "$OUT" | grep -qx 'modDesc.xml'; then
	echo "❌ modDesc.xml is not at the archive root — FS25 will not load this." >&2
	exit 1
fi

echo "✅ Clean: modDesc.xml at root, no notes, no test harness, no icon sources, no LICENSE."
echo "   $OUT"
