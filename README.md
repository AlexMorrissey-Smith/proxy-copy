# proxy-copy

Recover full-resolution images that Capture One's wireless tethering never finished
downloading.

With gen 2 wireless tethering, Capture One first saves a low-res **proxy** CR3, then
swaps in the full file when it arrives. If the camera disconnects, or the capture folder
changes before the full file lands, the swap fails. The camera then marks the image as
transferred, so **ReTether skips it**. You're left with a soft proxy in your session and no
built-in way to force a re-import.

`proxy-copy` finds every proxy in your session, pulls the matching originals straight off
the camera over USB, and puts them in place.

## Requirements

- A Mac with Apple silicon, macOS 13 or later
- Capture One
- The camera connected by USB, or its card mounted as a volume

Nothing else needs to be installed. It uses only frameworks that ship with macOS.

Tested with Canon CR3 files. Other cameras' proxies may differ.

## Install

1. Download `proxy-copy-macos-arm64.zip` from the
   [latest release](https://github.com/AlexMorrissey-Smith/proxy-copy/releases/latest).
2. Unzip it and move `proxy-copy` somewhere on your `PATH`:

   ```bash
   sudo mkdir -p /usr/local/bin
   sudo mv ~/Downloads/proxy-copy /usr/local/bin/
   ```

The binary is signed with a Developer ID and notarized by Apple. If macOS still blocks it
(for example, while offline on first run), clear the download
flag:

```bash
xattr -d com.apple.quarantine /usr/local/bin/proxy-copy
```

## Use

Open the affected session in Capture One, connect the camera by USB, then run:

```bash
proxy-copy
```

To see what it would do without changing anything:

```bash
proxy-copy --dry
```

The first time, macOS asks whether your terminal may control Capture One. Allow it, so the
tool can find the open session and quit and reopen Capture One.

### Options

| Option | What it does |
| --- | --- |
| *(no paths)* | Use the session open in Capture One, and reopen it when done |
| `SESSION_DIR` or `FILE.CR3` | Work on that session folder or those files instead |
| `--card FOLDER` | Also take originals from a folder of CR3s, such as a mounted card |
| `--dry` | List what would be replaced, change nothing |
| `-h`, `--help` | Show help |

If no camera is connected, it tells you to point it at a card:

```bash
proxy-copy --card /Volumes/EOS_DIGITAL
```

## What it does

1. Asks Capture One which session is open.
2. Quits Capture One. Capture One holds the camera while it runs, so nothing else can
   read it.
3. Scans the whole session folder for proxies. A proxy CR3 starts with a `crxp` box
   instead of `ftyp`. Each one is printed with its folder, such as `Look 9/Look 9-1083.CR3`.
4. Lists the files on every connected camera, plus any `--card` folder.
5. Reads **Canon ImageUniqueID** directly from the proxy and original CR3 metadata. The ID
   and **exact byte size** must match. This works with `crxp` proxies without modifying them;
   no ExifTool installation is needed. Camera files are inspected through ranged USB reads.
6. Confirms the **entire retained reduced-RAW track and capture-metadata track** with SHA-256,
   and rejects originals whose full-resolution raw track is still empty. If an image ID is
   missing or invalid, matching falls back to the embedded capture date, but still requires
   exact size and both retained-track checks. Conflicting IDs never fall back to dates.
7. Downloads each match, repeats identity and retained-track verification, and stages a copy
   beside the proxy. The staged copy must also match the downloaded original's **whole-file
   SHA-256**. Backs up and verifies the proxy in `<session>/_proxy_backup/`, then atomically
   replaces it. Existing backups are preserved under their names; another backup gets a
   unique name.
8. Reopens the session in Capture One.

Multiple originals passing verification are treated as ambiguous and skipped. Size or
filenames alone never authorize a replacement. Unmatched or failed recoveries return a
nonzero exit status, including in dry runs. `--dry` does not quit or reopen Capture One;
while Capture One holds a camera, use `--card` or close Capture One yourself for USB inspection.

These checks verify identity and the data retained in the proxy. They cannot prove that
unrepresented full-resolution pixels on the camera/card are free of corruption.

Once you've checked the images, you can delete `_proxy_backup/`.

## Build from source

```bash
./build.sh
```

This needs the Xcode command line tools. The binary lands in `build/proxy-copy`.
To sign and notarize, set `SIGN_ID` and `NOTARY_PROFILE`; see the top of `build.sh`.

## License

MIT

## Tests

```bash
swift test --jobs 4
```

Tests use synthetic CR3 structures and temporary files. They cover wrong IDs with identical
sizes and dates, missing IDs, date fallback, raw/metadata mismatches, empty full-raw tracks,
malformed inputs, ambiguous sources, backup preservation and failed replacements.

Optional read-only tests can use a local paired corpus by setting `PROXY_COPY_CORPUS` to a
folder with `Capture/Look 4/Look 4-0684.CR3` (proxy) and `full res/Look 4-0684.CR3` (original),
and the corresponding `Look 5-0656.CR3` and `Look 9-1083.CR3` pairs. Test images are not shipped.

`proxy-copy --version` prints the installed version.
