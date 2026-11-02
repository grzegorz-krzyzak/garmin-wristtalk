# WristTalk - voice assistant for Home Assistant on a Garmin watch

A Connect IQ app: press START, say a command, see it and the reply as chat bubbles and hear the
reply from the watch speaker. The command goes to an Assist pipeline of your Home Assistant through
the **WristTalk integration** ([ha-wristtalk](https://github.com/grzegorz-krzyzak/ha-wristtalk)),
which has to be installed first.

**A personal, non-commercial hobby project by a private individual.** Not affiliated with or endorsed by
the Open Home Foundation, Home Assistant or Garmin.
Requires a Home Assistant server reachable over HTTPS with a trusted certificate (for example Home
Assistant Cloud) - the watch reaches it through the phone.

For Garmin watches with a microphone and a speaker for apps (Connect IQ API 6.0 or newer). The
first version supports the fēnix 8 Solar 51 mm; more models will follow.

## Use

1. In Home Assistant: WristTalk -> **Add watch**. Set the house address it shows in the app
   settings in Garmin Connect.
2. Open WristTalk on the watch: it shows a pairing code. Confirm it in Home Assistant if it matches.
3. Open the app from the glance list (DOWN, START) and speak. START ends the command early, BACK
   cancels, UP/DOWN scroll the conversation, hold UP switches between voice and text only.

Settings in Garmin Connect: house address, reconnect, listen as soon as it opens, after a reply
(wait for START / keep listening), reply (voice and text / text only), volume, text size,
vibration, close when idle.

The conversation language (speech-to-text, agent, voice) is the one of the Assist pipeline chosen
for the watch in Home Assistant; the watch language sets only the app's own texts (English and
Polish).

## Build

Requirements: Connect IQ SDK 9.3 or newer, a developer key (`~/.connectiq/developer_key.der`, or
`CIQ_KEY`), Java for the SDK tools.

```sh
tools/build.sh dev      # simulator build (bin/wristtalk.prg)
tools/build.sh run      # dev build, started in the simulator
tools/build.sh test     # unit tests (Run No Evil) in the simulator
tools/build.sh release  # strict type check, no debug information, bin/wristtalk.iq
```

For the simulator, put your house address in `.dev-house-url` (ignored by git): the dev build uses
it as the default. The dev build closes after 30 s without input and writes every response it gets
to `bin/simulator.log` when started with `tools/build.sh start`.

## Layout

- `source/logic` - the conversation: states, timers, decisions; no screen, no network.
- `source/net` - the WristTalk protocol client.
- `source/device` - microphone, speaker, vibration, what the watch can do.
- `source/ui` - views and drawing.
- `source-release`, `source-dev` (generated) - build profiles.
- `tests` - unit tests of the logic with fake connection, microphone and speaker.

## Licence

Apache-2.0 - see [LICENSE](LICENSE). The name "WristTalk" and the icon are not covered by the
licence: a modified or republished copy must use its own name and icon.
