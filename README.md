# Vox — an iPhone app for your audio.cpp server

A native SwiftUI app that talks straight to `audiocpp_server` on Tower, plus Ollama for
the conversation half. No companion container, no middle tier.

```
 iPhone: Vox  ──HTTP──►  Tower: audiocpp_server :8080   (TTS, ASR, voice cloning)
              └─HTTP──►  Tower: ollama          :11434  (the language model)
```

| Screen | What it does |
|---|---|
| **Speak** | Type text, pick a voice, hear it. Shows how long generation took against the length of the clip, and shares the WAV out. |
| **Listen** | Dictation. Record or bring in a file, get the transcript back with word timings and speaker turns where the model produces them. |
| **Talk** | Hands-free conversation: you talk, it transcribes, the LLM answers, and the answer is spoken back. Keeps listening after each reply. |
| **Voices** | Reference clips for cloning. Record one or import from Files; the app transcribes it for you and stores it on the phone. |
| **Settings** | Server addresses, which model does what, the system prompt, and a button to free the GPU. |

---

## 1. The bit that makes voice cloning work from a phone

audio.cpp's `voice_ref` normally points at a **file path on the server**, which is no use
from an iPhone. But it also accepts the clip inline:

```json
"voice_ref": { "type": "base64", "data": "UklGRh..." }
```

That is what Vox sends, on every request, capped by the server at 5 MB decoded. So a
reference clip recorded on your phone never has to be copied to Tower, and the app needs
no server-side half at all.

To keep inside that cap and give the models what they actually want, Vox converts
everything you hand it — Voice Memo `.m4a`, `.mp3`, a 48 kHz stereo `.wav` — down to
**16 kHz mono 16-bit WAV** and trims reference clips to **15 seconds**. A clip that size
is about 480 KB, well under the limit.

It also sends `reference_text` (the transcript of the clip). Cloning models line up what
they hear against what was said, and the difference with it right is audible — so when
you add a clip, Vox transcribes it with your ASR model and fills it in. You can correct it
on the voice's detail screen.

---

## 2. Set up the server

### server.json

Vox only sees models that are declared in the server's config, so it needs at least a TTS
model and an ASR model. Something like:

```json
{
  "host": "0.0.0.0",
  "port": 8080,
  "backend": "cuda",
  "device": 0,
  "lazy_load": true,
  "max_loaded_models": 1,
  "idle_unload_ms": 900000,
  "voice_dir": "/models/voice",
  "models": [
    {
      "id": "tts",
      "family": "qwen3_tts",
      "path": "/models/Qwen3-TTS",
      "task": "tts",
      "mode": "offline"
    },
    {
      "id": "asr",
      "family": "qwen3_asr",
      "path": "/models/Qwen3-ASR-0.6B",
      "task": "asr",
      "mode": "offline"
    }
  ]
}
```

Three things there are worth keeping:

- **`"host": "0.0.0.0"`** — the documented example binds to `127.0.0.1`, which your phone
  can't reach. This is the single most likely reason a fresh server shows as unreachable
  in the app.
- **`max_loaded_models: 1`** — with a 3090 and one model nearly filling it, this makes the
  server swap between TTS and ASR instead of failing on the second one. If you have room
  for both resident, drop it and they stay warm.
- **`idle_unload_ms`** — gives the VRAM back after 15 quiet minutes. The next request
  reloads on its own. Settings also has a manual "Free the GPU" button.

`voice_dir` is optional: point it at a folder of `.wav` files plus a `prompt_text` index
and those voices show up in the app's picker under "On the server", cloned server-side
with no upload at all. Handy for voices you use constantly.

### Keeping the config up to date

The WebUI downloads models but declares nothing to the API, so anything you add there
is invisible to `/v1/models` and to Vox until it's in `server.json`. You don't have to
write that by hand. On the Unraid box:

```bash
bash make-server-config.sh
docker restart Audio.cpp
```

It reads each package's `.audiocpp-package-*.json` sidecar, matches it to a family in
the container's `/app/model_specs`, works out the task, and writes the config — keeping
the previous one as `server.json.bak`. Run it again after every download. `DRY=1` shows
what it would write without touching anything.

Anything whose task it cannot establish is declared **without** a `task` field rather
than with a guessed one, because a wrong task can make the parser reject the whole
config and the server then won't start at all.

It also writes `specs-dump.txt` next to the models — the full spec for every family in
use, which is what says whether a model takes a style prompt, a speaking rate, or any
other per-request option.

### Filling in the voice transcripts

`make-prompt-text.sh` transcribes every clip in the `voice_dir` through your own ASR
model and writes the `prompt_text` file that lets the server inject a `reference_text`.
Clips added in the app's Voices tab get this automatically; server-side ones need this
once. `MODEL=asr-higgs` to use a different model, `FORCE=1` to redo them all.

### Docker on Unraid

If you run it as a container rather than a binary, use the CDI-style GPU config — the
legacy `deploy.resources.reservations.devices` syntax fails on your server with the
`nvidia-container-cli` ldcache error:

```yaml
services:
  audiocpp:
    image: your/audiocpp-server:latest
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=nvidia.com/gpu=all
    ports:
      - "8080:8080"
    volumes:
      - /mnt/user/appdata/audiocpp/models:/models
      - /mnt/user/appdata/audiocpp/server.json:/server.json
    command: ["--config", "/server.json"]
    restart: unless-stopped
```

### Ollama

Nothing special — Vox speaks the OpenAI-compatible dialect Ollama already serves on
`:11434`, so there's no key and no extra config. Make sure Ollama is listening on the
network rather than just localhost (`OLLAMA_HOST=0.0.0.0` in the container; the official
image already does).

Because it's on the same box, the whole round trip stays on Tower's own PCIe bus — the
speech → text → reply → speech chain is limited by inference, not the network.

**Sharing the 3090.** Ollama and audio.cpp each hold their models in VRAM independently,
and neither knows about the other. With 24 GB there's usually room for all three at once
— a 7–8B Q4 LLM is around 5 GB, a TTS model a few more, ASR a bit less — so you can
leave them warm and get fast replies. It only bites with a big quant: a 32B Q4 is close
to 20 GB on its own, and then whichever model loads second either fails or evicts the
first, and the conversation stutters as they swap back and forth.

If you hit that, the two knobs to turn are:

| Where | Setting | Effect |
|---|---|---|
| Ollama | `OLLAMA_KEEP_ALIVE=30s` | Drops the LLM from VRAM soon after each reply instead of holding it 5 minutes. |
| Ollama | `OLLAMA_MAX_LOADED_MODELS=1` | Stops a second LLM being resident alongside the first. |
| audio.cpp | `idle_unload_ms` / `max_loaded_models` | Same idea on the speech side (both already in the `server.json` above). |

Turning them down trades a second or two of reload time for reliability. Leave them
alone while everything fits — a warm model is the whole point.

### Check it from a computer first

```bash
curl http://tower.local:8080/health
curl http://tower.local:8080/v1/models
curl http://tower.local:11434/v1/models
```

If those three work from a laptop on your Wi-Fi, the app will work.

---

## 3. Build the app and get it on your phone

Same route as HiCPS-2: GitHub builds it on a cloud Mac, iLoader installs it. Nothing here
needs a Mac of your own, and nothing needs a paid Apple account.

1. **First time on a PC:** double-click **`github-auth.bat`**. It installs Git and the
   GitHub CLI if they're missing and signs you in through the browser. Once per machine.
2. Double-click **`push-to-github.bat`**. It pushes the folder, starts the Mac build,
   waits for it, and drops **`build-out\Vox.ipa`** next to the script.
3. Open **iLoader**, pick that `.ipa`, and install it.

First launch: open **Settings**, set the two server addresses, and tap **Test both
servers**. The model pickers fill themselves in from whatever the servers report.

### About build minutes

`push-to-github.bat` creates this repo **public**, on purpose. GitHub's Mac runners count
**10×** against the free allowance on a private repo — that's what ate your HiCPS-2
budget — and public repos get unlimited free minutes. Vox holds no secrets: the server
addresses and any API key are typed into the app at runtime, never stored in the code.

If you'd rather keep it private, create the repo yourself with `--private` before running
the script. A build is roughly 15–20 minutes of the 2,000-per-month allowance, so about
100 builds a month — still fine, just not free-forever.

The workflow is manual-trigger only, so pushing code never spends minutes on its own.

---

## 4. How the conversation is put together

Worth knowing, because it's what makes the Talk screen feel quick.

**The reply is spoken a sentence at a time.** Tokens from the LLM are buffered until a
sentence closes; that sentence goes straight for speech while the next one is still being
written. Waiting for the whole reply first would add the full generation time to the
silence after you stop talking, which is what makes most voice assistants feel slow. The
splitter won't cut on "3.5" or "Dr.", and releases at a comma if a model rambles past
220 characters without punctuation.

**It stops listening on its own.** The mic tap tracks level, and once you've clearly
spoken and then gone quiet for the configured pause (1.4 s by default, adjustable in
Settings), it sends. Turn it off if you'd rather tap to stop.

**Tapping while it's speaking barges in** — it stops talking and listens again.

**The system prompt matters more than usual** because the reply is read aloud. The default
tells the model to answer in plain spoken sentences: markdown read out loud sounds like
someone reciting punctuation.

---

## 5. The optional streaming modes

Both are off by default and both need a model configured with `"mode": "streaming"` in
`server.json`.

**Live transcription** (`/v1/audio/transcriptions/live`) streams PCM up while text comes
back down on the same connection, so words appear while you're still talking. It works
from a native app — a browser can't do it at all — but it's fussier than the normal path,
and whether text really appears *during* speech depends on the model (`voxtral_realtime`
decodes incrementally; `nemotron_asr` waits for the end). If it drops, Vox falls back to
transcribing the finished recording, so you still get your text.

**Streaming speech** returns raw PCM chunks instead of a finished WAV. One gotcha: the
stream carries no header, so nothing announces its sample rate. If the voice comes out too
low or too high, change **Streamed PCM rate** in Settings — 24000 is the usual answer.

---

## 6. If something isn't right

| What you see | Usually |
|---|---|
| "audio.cpp unreachable" | Server bound to `127.0.0.1` instead of `0.0.0.0`, or the phone is on a different network. |
| Model pickers are empty | The server started with no `models` in `server.json`. |
| "The server is busy" | Another request is mid-inference. audio.cpp serialises per model; it clears on its own. |
| 503 mentioning memory | `min_free_memory_mb` refused the load. Free the GPU from Settings, or lower `max_loaded_models`. |
| Cloned voice sounds generic | The reference text is wrong or missing — check it on the voice's detail screen. |
| Cloned voice sounds rough | The clip is noisy or too short. 10–15 seconds of clean speech in a quiet room. |
| Speech plays at the wrong pitch | Streaming speech is on and the PCM rate is wrong. Settings → Streaming. |
| App won't open after a week | Free sideloaded signatures expire after 7 days. Re-sign it in iLoader. |

Build failed? `build-out\build.log` has the reason.

---

## Layout

```
ios/project.yml            XcodeGen config - the .xcodeproj is generated, never committed
ios/App/Net/               audio.cpp and LLM clients, SSE parsing, live upload
ios/App/Audio/             WAV encoding, format conversion, mic capture, playback
ios/App/Store/             settings, the voice library, server state, the conversation
ios/App/Views/             the five screens and the shared look
.github/workflows/ios.yml  the cloud Mac build
```

Endpoint and field names come from `app/server/README.md` in the audio.cpp tree. If you
upgrade the server and something moves, that file is the place to check it against
`ios/App/Net/AudioCPPClient.swift`.
