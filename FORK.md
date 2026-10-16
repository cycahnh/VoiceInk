# Personal fork notes

Free local build of VoiceInk with dictionary sync over a private GitHub repo
(local builds have no CloudKit).

## Set up a Mac

```bash
brew install cmake gh
gh auth login
xcodebuild -downloadComponent MetalToolchain
git clone https://github.com/cycahnh/VoiceInk.git && cd VoiceInk
make local LOCAL_CODESIGN_IDENTITY=-

gh repo clone cycahnh/voiceink-dictionary ~/.voiceink-dictionary
git -C ~/.voiceink-dictionary config --add credential.https://github.com.helper '!/opt/homebrew/bin/gh auth git-credential'
open ~/Downloads/VoiceInk.app
```

If `xcodebuild` complains about Command Line Tools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Dictionary sync

`GitDictionarySyncService` syncs on launch, 5 s after any dictionary change, and
every 5 minutes. It merges the remote `dictionary.json` into the local store and
pushes the result. Sync is skipped when `~/.voiceink-dictionary` is not a git clone.

Merging only adds entries. To delete an entry, remove it in the app **and** from
`dictionary.json` in the repo, or the next sync restores it.

## Updating from upstream

```bash
git fetch upstream && git merge upstream/main && make local LOCAL_CODESIGN_IDENTITY=-
```
