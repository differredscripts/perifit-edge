# XToys integration — v1.0.0

There are two independent directions. Neither starts automatically after launch.

## Export pressure and arousal to XToys (new in v1.0.0)

1. Sign in to [XToys](https://xtoys.app) and open Profile → Webhooks. Create a
   **Private Webhook** and copy its ID. Shared webhooks/auth tokens are not
   supported by this exporter.
2. In your XToys script/tease, add a connection for that Private Webhook. Add a
   Webhook trigger for action **`perifit`** and select the supplied fields you
   want to use in actions/variables. XToys documents receiving arbitrary flat
   JSON key/value pairs on these triggers; use its editor’s field/trigger picker.
3. In Perifit Edge, open **Main → Export pressure / arousal to XToys**. Enter the
   ID (not a URL), then select **Start sharing readings**. This explicitly sends
   live readings to XToys’ cloud endpoint. The ID is cleared from the field and
   held only in memory for the active connection; it is not logged or saved.
4. Verify changing pressure/score in the XToys receiving trigger before using
   it to control anything. Export works independently of the Arduino and does
   not require XToys motor-input mode. Calibration is required for a meaningful
   conditioned pressure and arousal score.
5. Select **Stop sharing** to end export. App shutdown also ends it. Network or
   non-success HTTP responses stop export and leave local motor control alone.

The destination is `https://webhook.xtoys.app/<private-webhook-id>`. Only an ID
is accepted; arbitrary URLs, credentials embedded in URLs and redirects are
rejected. Requests are JSON HTTPS POSTs, at most twice a second, with one in
flight, no pending queue and a 1.5-second network timeout. There are no automatic
retries or automatic reconnects. The ID is sensitive: anyone with it may be able
to send input to scripts using that webhook. Do not publish it.

### Payload

The flat JSON object has these keys. This is a synthetic example, not a recording:

```json
{"action":"perifit","schema":1,"timestampMs":1700000000000,"pressureBase":1200,"pressureTip":700,"pressure":200,"arousal":450,"arousalPercent":75,"edge":360,"cutoff":600,"fresh":true,"calibrated":true,"armed":true,"permitted":true,"automaticCutoffs":true,"simulated":false}
```

| Field | Meaning |
| --- | --- |
| `action`, `schema` | `perifit`, payload version `1` |
| `timestampMs` | Creation time, Unix milliseconds; use to reject delayed packets |
| `pressureBase`, `pressureTip` | Raw unsigned sensor counts; zeroed when stale/missing |
| `pressure` | Baseline-adjusted, gain-scaled base pressure; zero without valid calibration/fresh input |
| `arousal` | Current heuristic score, not a measured physiological arousal level |
| `arousalPercent` | `arousal / cutoff * 100`, clamped to 0–100; raw score can exceed cutoff |
| `edge`, `cutoff` | Current configured score thresholds |
| `fresh` | Both raw channels nonzero and sample age at most 0.5 s |
| `calibrated` | Conditioned values are usable for this sample |
| `armed` | The local session is armed |
| `permitted` | Local controller currently permits output, with freshness/arming/guard checks |
| `automaticCutoffs` | Whether automatic edging cutoffs remain enabled |
| `simulated` | Data comes from Demo input rather than a physical sensor |

No peripheral UUID, Bluetooth characteristic, serial port, hostname, username,
resting baseline, session history, feedback label or personal profile is sent.
When samples go stale, numeric sensor/score values become zero and `fresh` and
`permitted` become false. Do not interpret those zeros as a fresh measurement.
When the local session stops, `armed` and `permitted` become false. Export can
continue as observation while stopped, until Stop sharing is selected.

### Receiving-script requirements

Start with a display-only script: copy the incoming `arousal`, `arousalPercent`
and `pressure` fields into variables or a text display. Map fields in the XToys
editor; do not assume `arousalPercent` is an intensity command. This project does
not distribute a preconfigured script tied to a personal XToys account.

If you later connect that script to a toy, it must set output to zero when
`fresh`, `calibrated`, `armed` or `permitted` is false. It must reject Demo data
unless you have deliberately enabled a test, reject packets older than two
seconds, and stop if no new update arrives for two seconds. Use a periodic
watchdog/timer trigger independent of the webhook event: a check only inside
the receive handler cannot notice missing messages. Never retain the last
nonzero command indefinitely. On app/network exit there may be no final packet.

Other XToys-controlled toys are outside this app’s physical motor-control path.
The Arduino stops do not automatically stop those toys, and cloud telemetry is
not suitable as their sole safety mechanism. The existing local bridge below
keeps Arduino motor commands inside Perifit Edge’s controller instead.

The payload and transport are tested locally with HTTP mocks. Live delivery to
your XToys account requires the receiving script setup above; no developer
account, webhook ID or remote session is bundled or used by tests.

Primary references: [XToys Webhooks](https://guide.xtoys.app/tools/webhook.html),
[script variables and triggers](https://guide.xtoys.app/script-creation/definitions.html),
[XToys JavaScript/editor helpers](https://guide.xtoys.app/script-creation/javascript.html).

## Receive XToys motor patterns in Perifit Edge

1. Select Arduino output and turn Finder off for the session. In **XToys pattern
   control**, enable XToys for M1/M2/M3 while stopped.
2. In [XToys Custom Toys](https://xtoys.app/me/custom-toys), create a Websocket toy:
   2 Channel Vibrator, JSON format, 100 steps, maximum message frequency 10.
   Use the local URL displayed by Perifit Edge (normally `ws://127.0.0.1:48971`).
3. For M3, create a separate single-channel Websocket toy using the displayed
   third-motor URL (normally `ws://127.0.0.1:48972`). XToys channel 1 on that
   endpoint maps to Arduino M3.
4. Connect in XToys on the same Mac, then Start / Arm in Perifit Edge. Play/save
   patterns in XToys. Target sliders in Perifit Edge remain output ceilings.

The first endpoint accepts `{"channel":1,"vibrate":50}` and channel 2; the M3
endpoint accepts channel 1 mapped to M3. Levels must be finite values 0–100.
The bridge binds IPv4 loopback, validates the XToys browser origin, bounds
messages/rate and accepts one client per endpoint. It cannot remotely arm the
app. Invalid messages, connection loss or failed keepalive stop the session.
The new export does not weaken these checks and can be used independently.
