# LogicLight

-- NOTE! Entirely AI Generated work. --

A tiny macOS menu-bar app that turns a [Home Assistant](https://www.home-assistant.io/) light on while **Logic Pro is recording**, and off when it stops. An "on air" light for your studio, no MIDI routing or control surfaces needed.

## Install

1. Download `LogicLight.zip` from the [latest release](../../releases/latest) and move `LogicLight.app` to Applications.
2. The app isn't notarised, so the first time, right-click it and choose **Open** (or run `xattr -cr /Applications/LogicLight.app`).
3. Grant **Accessibility** access when asked (System Settings → Privacy & Security → Accessibility). LogicLight uses it to read the state of Logic's Record button.
4. Enter your Home Assistant URL, a long-lived access token (your HA profile → Security) and the entity ID (`light.…`, `switch.…` or `input_boolean.…`).
5. Use **Test Light On/Off** in the menu to check Home Assistant works, then hit record.

Requires macOS 13 or later. Works on Apple Silicon and Intel.

## Features

- Watches Logic's Record button through the Accessibility API and only calls Home Assistant when the state changes, retrying if it's unreachable.
- Turns the light off when you quit LogicLight.
- **Enabled** toggle, **Open at Login**, and a red menu-bar indicator while recording.
- Token stored in the macOS Keychain.

## Troubleshooting

If the menu says *record button not found*, or the light doesn't follow recording, open Logic and choose **Copy Logic Diagnostics**. It copies every button Logic exposes along with its state, which shows what the Record button is called on your setup. Matching is on the English label `Record`, so a localised Logic needs that string changed in `findRecordButton`. Issues and PRs welcome.

## Building from source

```bash
./build.sh
```

Needs Xcode or the Command Line Tools. GitHub Actions builds every push. Pushes to `main` publish a release for the version in `VERSION`, so bump it to cut a new one.

## License

[MIT](LICENSE)
