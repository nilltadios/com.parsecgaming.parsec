#!/usr/bin/env bash
# Lay out the GitHub Pages site around an exported, signed OSTree repo:
#   site/repo/                         the flatpak repo itself
#   site/parsec.flatpakrepo            "add this remote" file
#   site/com.parsecgaming.parsec.flatpakref   one-click install (Discover / GNOME Software)
#   site/state.json                    what is published; CI compares against it to skip work
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
field() { sed -n "s/^ *\"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$inputs"; }
ostree_commit=$(cat "$repo/refs/heads/app/$app/x86_64/stable")
published=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  sed '$d' "$inputs" | sed '$s/$/,/'
  printf '  "source_commit": "%s",\n  "published_at": "%s",\n  "ostree_commit": "%s"\n}\n' \
    "$commit" "$published" "$ostree_commit"
} > "$site/state.json"

repo_name=${GITHUB_REPOSITORY:-nilltadios/com.parsecgaming.parsec}
deb_sha=$(field deb_sha256)
sed -e "s|@VERSION@|$(field version)|g" \
    -e "s|@DEB_DATE@|$(field deb_date)|g" \
    -e "s|@RUNTIME@|$(field runtime_version)|g" \
    -e "s|@DEB_SHA_SHORT@|${deb_sha:0:12}|g" \
    -e "s|@PUBLISHED@|${published%T*}|g" \
    -e "s|@COMMIT_SHORT@|${commit:0:12}|g" \
    -e "s|@COMMIT@|$commit|g" \
    -e "s|@REPO_URL@|https://github.com/$repo_name|g" \
    -e "s|@REPO_NAME@|$repo_name|g" \
    -e "s|@REMOTE@|$remote|g" \
    -e "s|@APP@|$app|g" \
    -e "s|@BASE@|$base|g" \
    "$(dirname "$0")/site/index.html.in" > "$site/index.html"
if grep -q '@[A-Z_]*@' "$site/index.html"; then
  echo "unfilled placeholders in index.html:" >&2; grep -o '@[A-Z_]*@' "$site/index.html" | sort -u >&2; exit 1
fi
