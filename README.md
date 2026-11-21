# coach-w

[中文](README_CN.md)

A realtime voice workout coach that stays beside you. Apple Watch watches your body; a coach talks in your ear.

Wear an Apple Watch, carry an iPhone, put on your headphones (bone-conduction first) and go. The watch streams heart rate, pace, cadence, power and running form; the iPhone sends those metrics and your voice to a coach agent on the server, which speaks through a realtime speech-to-speech model (Qwen Realtime first). It cues, corrects, encourages, and chats, and you can interrupt it any time.

Running comes first, then cycling and walking (where it is more of a walking buddy than a coach). Every other Apple Watch workout type is covered by a generic profile.

> Status: M0, preparing. Nothing runs yet. See [`docs/spec.md`](docs/spec.md).

## How it works

```
Apple Watch (watchOS app)    HKWorkoutSession, live metrics, haptics
        │ mirrored workout session
iPhone (iOS app)             audio session, LiveKit client, offline fallback cues
        │ WebRTC (audio + data channel)
Server                       LiveKit Server + coach agent (Python, LiveKit Agents)
        │
Qwen Realtime (DashScope)
```

- **The watch is the only source of workout data.** Server or network failures never lose a workout.
- **The model never guesses numbers.** Every figure the coach says comes from a tool call or injected state.
- **Code decides when to speak; the model decides how.** A director, an event engine and a cue queue (priority, cooldown, expiry, "don't talk over the user") pick the moments; the realtime model turns each cue into natural speech.
- **One core, many activity profiles.** No sport-specific branches outside `profiles/`.

## Repository

```
apple/CoachKit/     Swift package: wire protocol and platform-free logic
apple/iOS, Watch/   iPhone and watchOS apps (M1)
server/             Python: coach agent, token API, profiles
protocol/fixtures/  canonical wire-protocol samples shared by both sides
deploy/             docker compose for LiveKit + agent (M2)
docs/               spec and setup checklist
```

## Development

Requires macOS with Xcode (Swift 6) and [uv](https://docs.astral.sh/uv/).

```sh
./scripts/check.sh
```

See [`docs/setup.md`](docs/setup.md) for accounts, devices and servers to prepare, and [`AGENTS.md`](AGENTS.md) for contribution rules.

## License

[Apache-2.0](LICENSE)
