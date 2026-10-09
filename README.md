
<p align="center">
  <a href="https://github.com/jasshans/cotabby" target="_blank">
    <img height="150" alt="Ghostype logo" src=".github/assets/readme/logo.png" />
  </a>
</p>

<h1 align="center">Ghostype [beta]</h1>

<p align="center"><em>Open-source, local-first AI autocomplete for macOS.</em></p>

<p align="center">
<a href="https://github.com/jasshans/cotabby/releases">
<img width="200" alt="download" src="https://github.com/user-attachments/assets/d5cb4454-d2ab-41d3-9d36-171d44ebfc52" /></a>
</p>

<p align="center">
  <a href="https://github.com/jasshans/cotabby/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/jasshans/cotabby/build.yml?branch=main" /></a>
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?logo=swift&amp;logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" />
</p>

<p align="center">
  <sub>Ghostype is free and open-source. Forked from <a href="https://github.com/FuJacob/cotabby">Cotabby</a> by FuJacob, licensed AGPL-3.0.</sub>
</p>

---

## What It Does

Ghostype adds AI autocomplete to almost any text field on your Mac. As you type, a gray suggestion appears inline next to your cursor. Press `Tab` to accept it a word at a time, or keep typing to ignore it.

The default Apple Intelligence and Open Source engines run on your Mac. No account or telemetry is
required. An optional OpenAI-compatible engine can connect to a server you configure.

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE"><strong>Watch on YouTube →</strong></a>
</p>

<div align="center">

|  |  |
|:---:|:---:|
| <img src="gifs/slack.gif" alt="Ghostype emoji autocomplete demo" width="400" height="225" /> | <img src="gifs/imessage.gif" alt="Ghostype autocomplete demo" width="400" height="225" /> |
| <img src="gifs/autocorrect.gif" alt="Ghostype autocorrect demo" width="400" height="225" /> | <img src="gifs/macros.gif" alt="Ghostype inline macros demo" width="400" height="225" /> |

</div>

## Features

- **Ghost-text autocomplete** — AI suggestions inline in almost any macOS text field; `Tab` accepts a word at a time
- **Emoji autocomplete** — type `:rocket:` and accept it without leaving the field
- **Inline macros** — type `/` for quick math, unit and currency conversion, dates, and random values
- **One-key autocorrect** — fix a likely typo with a single keystroke
- **Prediction controls** — choose whether to predict ahead, suggest within words, and show following words
- **Optional screen context** — control visual context independently of the local prediction settings

## Privacy

Privacy is the whole point, so Ghostype's default engines keep generation on your Mac:

- Apple Intelligence and Open Source generation run on-device.
- The optional OpenAI-compatible engine sends a bounded request only to the endpoint you configure;
  that endpoint can be loopback, on your local network, or a public HTTPS service.
- No analytics, no telemetry, no crash reporting.
- A normal install never writes what you type to disk, except for the encrypted suggestion-memory
  database described below.
- Suggestion memory (Settings → Context, on by default) learns words and phrases from accepted
  and dismissed suggestions into an AES-encrypted SQLite database in your Application Support
  folder; the key lives in your Keychain and never leaves the Mac. Phrase lookup hashes are
  HMAC-SHA256 under a per-database salt so they can't be matched against a precomputed
  dictionary. Password fields are never recorded, the learned vocabulary is never sent to an
  endpoint, and "Clear memory…" deletes the database and rotates the key so it can never be
  decrypted again. Usage metadata (which app a suggestion was accepted in, and when) is stored
  in plaintext alongside the encrypted content.
- Apart from a configured endpoint, the network is used for model downloads and update checks, not
  suggestion generation.

## Engines

Ghostype generates suggestions in three ways. You choose which in Settings → Engine:

- **Apple Intelligence** — Apple's model, built into macOS 26 or later on supported Macs. Nothing to download.
- **Open Source** — a small AI model you download that runs entirely on your Mac. Works on any supported Mac (macOS 14+), with or without Apple Intelligence.
- **OpenAI-compatible** — a completion or chat endpoint you configure, including local Ollama,
  another LAN host, or a public HTTPS service. Endpoint credentials are stored in Keychain.

If your Mac supports Apple Intelligence, that's the easiest place to start. Otherwise, use the Open Source engine and pick one of the built-in models:

| Model          | Size    | Good for                          |
| -------------- | ------- | --------------------------------- |
| `tabby-2-nano` | ~0.8 GB | Older or low-memory Macs; fastest |
| `tabby-2-mini` | ~1.4 GB | A solid everyday balance          |
| `tabby-2-base` | ~4.5 GB | Higher-quality suggestions        |
| `tabby-2-pro`  | ~5.0 GB | Best quality                      |

Download any of them straight from Ghostype's menu bar.

<details>
<summary><strong>Advanced:</strong> model files, custom models, and how generation works</summary>

<br />

Under the hood, the Open Source engine runs local GGUF *base* models in-process through [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [CotabbyInference](https://github.com/FuJacob/cotabbyinference)). Instead of prompting an instruction-tuned chat model, Ghostype treats the model as a pure text continuer and conditions it on your name, writing style, language, and on-screen context.

| Model          | File                             | Size    | Source                                                                       |
| -------------- | -------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `tabby-2-nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `tabby-2-mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)   |
| `tabby-2-base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)       |
| `tabby-2-pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)       |

**Bring your own model.** Any GGUF small enough to run on-device works. Drop a `.gguf` file into Ghostype's models folder and refresh the model list from the menu bar. Browse the [unsloth GGUF collection](https://huggingface.co/unsloth) for more variants — smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

For the full suggestion pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

</details>

## Install

**Compatibility:** macOS 14.0 or later. The Apple Intelligence engine needs macOS 26 or later on a supported Mac; on older systems, use the Open Source engine.

### Download

Grab `Ghostype.zip` from the [stable release](https://github.com/jasshans/cotabby/releases/tag/stable) and drag Ghostype into your Applications folder. (The app is ad-hoc signed rather than notarized, so on first launch macOS may ask you to confirm: right-click → Open, then Open.)

### Updates

Ghostype checks for updates automatically once a day, and you can check manually any time from the menu bar (**Check for Updates**) or Settings → About. Every push to `main` publishes a new build to the `stable` release, signed with the project's Sparkle EdDSA key, so updates install in one click.

## Using Ghostype

Start typing in almost any text field. When a gray suggestion appears:

- **`Tab`** — accept the next word. (Prefer whole phrases? Switch this in Settings → Acceptance Mode.)
- **`` ` `` (backtick)** — accept the entire suggestion at once.
- **`Esc`**, or just keep typing — dismiss it.

Every shortcut is rebindable under Settings → Shortcuts.

## Permissions

Ghostype works inside other apps, so macOS asks for a few permissions. Each one maps to a specific feature, and Ghostype walks you through them on first launch:

- **Accessibility** — read the text and cursor position in the field you're typing in, and insert what you accept.
- **Input Monitoring** — notice your typing so it knows when to suggest, and detect the accept keys.
- **Screen Recording** *(optional)* — capture the area around your cursor for visual context, and to match the ghost text's font, size, and position to the app's own text where the app doesn't report them. Leave it off and everything else still works.

Ghostype blocks generation, presentation, and insertion in password and other secure fields.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/jasshans/cotabby.git ghostype
cd ghostype
scripts/prepare_cotabby_workspace.sh
open build/cotabby-dependencies/Ghostype.xcworkspace
```

Use the **Ghostype Dev** scheme for local work. The workspace temporarily supplies the native
APIs in our pending CotabbyInference patch; preparation is automatic in CI and release builds.

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For a tour of the runtime and suggestion pipeline, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp), [CotabbyInference](https://github.com/FuJacob/cotabbyinference), [Sparkle](https://github.com/sparkle-project/Sparkle), and [swift-log](https://github.com/apple/swift-log) for runtime, updates, and logging.
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern) for macOS login-item integration.
- Apple's FoundationModels, Accessibility, SwiftUI, and AppKit for on-device generation and macOS integration.
- [GitHub gemoji](https://github.com/github/gemoji) and Hugging Face for the emoji data and downloadable models.
- [SymSpell](https://github.com/wolfgarbe/SymSpell) by Wolf Garbe (MIT) for multilingual autocorrect; frequency dictionaries derive from [Google Ngrams](https://books.google.com/ngrams) (CC BY 3.0) and licensed SCOWL/Hunspell word lists.
- Everyone who filed issues, tested prereleases, and sent pull requests.

## Created by

Ghostype is a fork of [Cotabby](https://github.com/FuJacob/cotabby) by [@FuJacob](https://github.com/FuJacob), maintained by [@jasshans](https://github.com/jasshans). Licensed AGPL-3.0, like upstream.

## License

Ghostype is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
