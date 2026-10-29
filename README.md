# Parsec Flatpak, auto-built

This fork of [flathub/com.parsecgaming.parsec](https://github.com/flathub/com.parsecgaming.parsec)
publishes its own signed Flatpak repo at
**https://nilltadios.github.io/com.parsecgaming.parsec/**.
Once Parsec is installed from it, COSMIC Store, Discover, GNOME Software and
`flatpak update` update it like any other app. You never download or
reinstall anything by hand.

## Install

Pick one of the three ways. They all add the same remote, `parsec-autobuild`,
and install the same app. The app keeps updating from that remote afterwards.

### A. COSMIC Store, Discover or GNOME Software (one click)

1. Open https://nilltadios.github.io/com.parsecgaming.parsec/com.parsecgaming.parsec.flatpakref.
   Your browser downloads a small `.flatpakref` file.
2. Open that file. COSMIC Store, Discover or GNOME Software shows Parsec. Click **Install**.

The store adds the `parsec-autobuild` remote for you. If the
`org.freedesktop.Platform` 26.08 runtime is missing, the store fetches it
from Flathub.

### B. Terminal

```bash
flatpak remote-add --user --if-not-exists parsec-autobuild https://nilltadios.github.io/com.parsecgaming.parsec/parsec.flatpakrepo
```

```bash
flatpak install --user parsec-autobuild com.parsecgaming.parsec
```

The remote needs Flathub for the runtime. If you have never added Flathub,
run this first:

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

### C. You already have Parsec from Flathub

Add the remote (the first command in B), then switch the installed app over:

```bash
flatpak install --user --reinstall parsec-autobuild com.parsecgaming.parsec
```

This replaces only the app's files. Your login and settings in
`~/.var/app/com.parsecgaming.parsec` stay where they are.

> **User vs. system installs.** The remote and the app must be in the same
> installation. The commands here use `--user`. If Parsec is installed
> system-wide (`flatpak list --app --columns=application,installation` says
> `system`), replace `--user` with `--system` in every command.

## Check it is set up right

```bash
flatpak list --app --columns=application,origin,version | grep -i parsec
```

You should see:

```
com.parsecgaming.parsec   parsec-autobuild   150-104a
```

The second column is what matters. `parsec-autobuild` means updates come
from this repo. `flathub` means it still updates from Flathub, so run the
command in C. The version shown here is Parsec's real build number. The
Flathub listing shows an old placeholder (3.9.9).

## How updates reach you

Once a day, the repo checks for a new Parsec `.deb` or new upstream changes.
If it finds one, it publishes a new build. Your machine picks it up wherever
you normally update:

| where | what to do |
|---|---|
| Terminal | run `flatpak update` (Parsec shows up under `parsec-autobuild`) |
| COSMIC Store | click **Updates** in the sidebar |
| KDE Discover | click **Updates**. If nothing is listed yet, click **Refresh** |
| GNOME Software | open the **Updates** tab and click the refresh button if needed |
| automatic updates | the stores' auto-update setting covers this app too |

To see whether an update is waiting, without installing it:

```bash
flatpak remote-ls --user --updates parsec-autobuild
```

To see what the server is publishing right now:

```bash
curl -s https://nilltadios.github.io/com.parsecgaming.parsec/state.json
```

**Seeing Parsec twice in the store?** If Flathub is also set up, the store
may list Parsec from both remotes. That is harmless: updates come from the
remote the app is installed from, which the `flatpak list` command above
shows. In GNOME Software, the app page has a **Source** dropdown to pick one.

## Go back to Flathub

```bash
flatpak install --user --reinstall flathub com.parsecgaming.parsec
```

```bash
flatpak remote-delete --user parsec-autobuild
```

Your settings are kept here as well.

---

## Why this exists

The Flathub package ships Parsec as *extra-data*: it stores the URL and
sha256 of `parsec-linux.deb`, and the `.deb` is downloaded at install time.
Parsec replaces that file in place. Until Flathub's bot updates the hash,
installs and updates fail with a checksum error. In July 2026 that took
9 days (the `.deb` changed on 07-09, and Flathub fixed it on 07-18).

## What CI does (`.github/workflows/build.yml`)

Once a day (07:23 UTC), on every push to `master`, and on manual runs
("Run workflow" in the Actions tab):

1. **Sync.** Merges `flathub/master` into this fork. Only `.github/`, `ci/`
   and this README differ from upstream, so the merge stays conflict-free.
2. **Pin.** `ci/prepare.py` writes a build copy of the manifest:
   - the `.deb` Parsec is serving right now (sha256 + size);
   - each git source moved to its newest tag matching its own
     `x-checker-data` pattern (libjpeg-turbo);
   - `ci/overrides.yml` applied (runtime 26.08, used only while newer than
     upstream's);
   - the `.deb`'s version added as a metainfo `<release>`, so the store
     shows the real Parsec version.
3. **Skip or build.** Compares a fingerprint of those inputs with the
   `state.json` already published. If they match, it stops there. If they
   differ, it builds in Flathub's container, signs the result, and deploys
   to Pages. If only the web page changed (`ci/publish.sh`,
   `ci/site/`), CI copies the live repo unchanged (`ci/mirror-live-repo.sh`)
   and redeploys it with the new page. Users see no app update.

Each build is a fresh repo containing one commit. `flatpak update` only
compares commit IDs, so it does not need the older commits.

| path on the site | purpose |
|---|---|
| `repo/` | the signed OSTree repo |
| `parsec.flatpakrepo` | adds the remote |
| `com.parsecgaming.parsec.flatpakref` | one-click install in COSMIC Store / Discover / GNOME Software |
| `state.json` | what is published: Parsec version, `.deb` sha, fingerprint, commits |

## Maintainer setup (once)

1. Add the signing key's private half as the repository secret
   `GPG_PRIVATE_KEY`. Its public half is embedded in the `.flatpakrepo` and
   `.flatpakref` files, so keep the same key: a new key makes every user
   re-add the remote.
2. Set Settings → Pages → Source to **GitHub Actions**.
3. Enable Actions on the fork (they start disabled on forks), then run the
   workflow once from the Actions tab.

To try a build locally:

```bash
python3 ci/prepare.py /tmp/inputs
```

```bash
flatpak-builder --user --force-clean builddir /tmp/inputs/com.parsecgaming.parsec.yml
```
