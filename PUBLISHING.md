# Publish Music Flow to the Omarchy plugin site

The release folder is `/home/rajesh/Work/music-flow-lyrics`. The root manifest is the one marketplace listing; it includes the standalone lyrics plugin as an installer-managed companion.

## 1. Create the public GitHub repository

The GitHub CLI login on this machine is currently invalid. Re-authenticate, then create and push the repository from the release folder:

```bash
gh auth login
cd /home/rajesh/Work/music-flow-lyrics
gh repo create music-flow-lyrics --public --source=. --remote=origin --push
```

The release is already committed locally. If you edit it first, commit your edits before running `gh repo create`.

If you create the repository in the GitHub website instead, make it public and empty, then push this folder to its `main` branch.

## 2. Submit the listing

Open the [Omarchy plugin submission form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml) and use:

- **Title:** `[Plugin]: Music Flow with Synced Lyrics`
- **Repository URL:** `https://github.com/Rajesh-bandi/music-flow-lyrics`
- **Category:** `Widgets`
- **Tags:** `media, bar, quickshell`

Use this issue body and review every statement before checking the boxes:

```markdown
### Repository URL

https://github.com/Rajesh-bandi/music-flow-lyrics

### Category

Widgets

### Tags

media, bar, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

The full installer sets up both the root Music Flow plugin and the bundled Synced Lyrics companion. The marketplace's direct plugin install installs the root plugin; use the repository's install.sh for both widgets and automatic bar configuration.

### Submission checklist
- [ ] The repository is public and contains installation and removal instructions.
- [ ] I have documented the plugin license and any external dependencies.
- [ ] I confirm that I own or have permission to submit this plugin and its preview assets.
- [ ] The plugin does not overwrite user configuration without explicit consent.
- [ ] I understand that approval is for listing and is not a security review.
```

The marketplace requires all five checklist boxes checked and asks the plugin owner to review and approve the exact submission. The fork retains the upstream MIT copyright and credits Clifford Baidoo; confirm that the README, license, and preview assets accurately reflect your permissions before submitting.

## 3. Wait for marketplace validation

After you create the issue, marketplace automation checks the repository and posts its result. Fix any reported problems in GitHub and edit the same issue to rerun validation. A maintainer must approve the exact validated commit before it appears on the site.

The marketplace does not run `install.sh` for users. The README therefore documents the full setup command (`git clone`, then `./install.sh`) as well as the direct plugin install limitation.
