#!/usr/bin/env bash
# Lay out the GitHub Pages site around an exported, signed OSTree repo:
#   site/repo/                         the flatpak repo itself
#   site/parsec.flatpakrepo            "add this remote" file
#   site/com.parsecgaming.parsec.flatpakref   one-click install (Discover / GNOME Software)
#   site/state.json                    what was built; CI compares against it to skip builds
#   site/index.html                    install instructions
#
# Usage: publish.sh REPO_DIR SITE_DIR BASE_URL GPG_KEY_ID INPUTS_JSON SOURCE_COMMIT
set -euo pipefail

repo=$1 site=$2 base=${3%/}/ key=$4 inputs=$5 commit=$6
app=com.parsecgaming.parsec
remote=parsec-autobuild

rm -rf "$site"
mkdir -p "$site"
cp -a "$repo" "$site/repo"
rm -f "$site/repo/.lock"

gpgkey=$(gpg --export "$key" | base64 -w0)

cat > "$site/parsec.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Parsec (auto-built)
Url=${base}repo/
Homepage=${base}
Comment=Parsec flatpak rebuilt whenever Parsec ships a new .deb
Description=Automatic rebuilds of com.parsecgaming.parsec from the Flathub manifest
Icon=${base}icon.png
GPGKey=${gpgkey}
EOF

cat > "$site/$app.flatpakref" <<EOF
[Flatpak Ref]
Title=Parsec
Name=$app
Branch=stable
Url=${base}repo/
SuggestRemoteName=$remote
Homepage=${base}
Icon=${base}icon.png
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=${gpgkey}
EOF

cp "$(dirname "$inputs")/$app.png" "$site/icon.png"

# Plain shell instead of jq, which the flatpak build container may not have.
ostree_commit=$(cat "$repo/refs/heads/app/$app/x86_64/stable")
{
  sed '$d' "$inputs" | sed '$s/$/,/'
  printf '  "source_commit": "%s",\n  "built_at": "%s",\n  "ostree_commit": "%s"\n}\n' \
    "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ostree_commit"
} > "$site/state.json"

version=$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' "$inputs")
cat > "$site/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Parsec Flatpak</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 16px}pre{background:#f4f4f4;padding:.75rem;overflow-x:auto}</style>
</head><body>
<h1>Parsec Flatpak (auto-built)</h1>
<p>Current build: Parsec <b>$version</b>, built from <code>${commit:0:12}</code>. Details: <a href="state.json">state.json</a>.</p>
<p><a href="$app.flatpakref">Install with Discover / GNOME Software</a></p>
<p>Or from a terminal:</p>
<pre>flatpak remote-add --user --if-not-exists $remote ${base}parsec.flatpakrepo
flatpak install --user $remote $app</pre>
<p>Already have Parsec from Flathub? Switch it over (your login and settings in ~/.var/app are kept):</p>
<pre>flatpak install --user --reinstall $remote $app</pre>
</body></html>
EOF
