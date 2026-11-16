# WristTalk - voice assistant for Home Assistant on a Garmin watch

A Connect IQ app: press START, say a command, see it and the reply as chat bubbles and hear the
reply from the watch speaker. The command goes to an Assist pipeline of your Home Assistant through
the **WristTalk integration** ([ha-wristtalk](https://github.com/grzegorz-krzyzak/ha-wristtalk)),
which has to be installed first. The middle number of the version is the protocol the app and the
integration speak: the app 1.6.x needs the integration 1.6.0 or newer.

**A personal, non-commercial hobby project by a private individual.** Not affiliated with or endorsed by
the Open Home Foundation, Home Assistant or Garmin.
Requires a Home Assistant server reachable over HTTPS with a trusted certificate (for example Home
Assistant Cloud) - the watch reaches it through the phone.

For Garmin watches with a microphone and a speaker for apps (Connect IQ API 6.0 or newer). The
first version supports the fēnix 8 Solar 51 mm; more models will follow.

## Use

1. In Home Assistant: WristTalk -> **Add watch**. Set the house address it shows in the app's
   settings in the Connect IQ app on the phone.
2. Open WristTalk on the watch: it shows a pairing code. Type it in Home Assistant.
3. Open the app from the glance list (DOWN, START) and speak. START ends the command early, BACK
   cancels, UP/DOWN scroll the conversation, hold UP opens the menu (text only, pair again, the version).

The watch can do everything you exposed to Assist in Home Assistant, also over the internet: turn on
the watch's passcode, and delete a lost watch in Home Assistant (its key stops working at once).

Settings in the Connect IQ app: house address, listen as soon as it opens, after a reply
(wait for START / keep listening), reply (voice and text / text only), volume,
vibration, close when idle, and a link to the help page.

The conversation language (speech-to-text, agent, voice) is the one of the Assist pipeline chosen
for the watch in Home Assistant; the watch language sets only the app's own texts (English and
Polish).

## Data

- **What the watch sends:** when pairing, the watch's unique identifier, its model name and the app's
  version; with every command, the recording of your voice (only after you press START) and the
  watch's key; with every request, the app's version and protocol number.
- **Where:** only to your own Home Assistant, at the address you set, through Garmin Connect on your
  phone. Nothing goes to the developer or anyone else.
- **What stays on the watch:** the key, the address it belongs to, a pairing in progress, the
  settings, and a random identifier if the watch gives the app none. Recordings and replies are not stored: the conversation on screen goes when the app closes.

## Build

Requirements: Connect IQ SDK 9.3 or newer, a developer key (`~/.connectiq/developer_key.der`, or
`CIQ_KEY`), Java for the SDK tools. `tools/build.sh` is written for macOS (the SDK's paths there, `open`
for the simulator); on another system run the same `monkeyc` / `monkeydo` commands it shows.

```sh
tools/build.sh dev      # simulator build (bin/wristtalk.prg)
tools/build.sh run      # dev build, started in the simulator
tools/build.sh test     # unit tests (Run No Evil) in the simulator
tools/build.sh release  # strict type check, no debug information, bin/wristtalk.iq
```

For the simulator, put your house address in `.dev-house-url` (ignored by git): the dev build uses
it as the default. The dev build closes after 5 minutes without input; started with
`tools/build.sh start`, what the simulator prints goes to `bin/simulator.log`.

## Layout

- `source/logic` - the conversation: states, timers, decisions; no drawing and no requests of its own
  (it asks the view to redraw, the app to close, and the client in `source/net` to send).
- `source/net` - the WristTalk protocol client.
- `source/device` - microphone, speaker, vibration, what the watch can do.
- `source/ui` - views and drawing.
- `source-release`, `source-dev` (generated) - build profiles.
- `tests` - unit tests of the logic with fake connection, microphone and speaker.

## Support

WristTalk is free. If it is useful to you, you can support it on [GitHub Sponsors](https://github.com/sponsors/grzegorz-krzyzak).

## Licence

Apache-2.0 - see [LICENSE](LICENSE). The name "WristTalk" and the icon are not covered by the
licence: a modified or republished copy must use its own name and icon.
