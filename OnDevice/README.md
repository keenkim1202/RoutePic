# On-device generation (Core ML)

Stage 2 without a server. Apple ships [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion),
a Swift package that runs Stable Diffusion **with ControlNet** on device — the
same conditioning `DESIGN.md` §7.1 asks for.

`DESIGN.md` §7.5 wrote off Apple *Image Playground*, correctly: `ImageCreator`
stops compiling in iOS 27. This is a different path and it is still open.

## Why it matters

| | Server (§8.3) | On-device |
|---|---|---|
| Cost per generation | $0.02–0.08 | **$0** |
| Free tier scales with users | yes — the problem | **no** |
| Control image leaves the device | yes | **no** |
| Provider retention policy needed | **yes — blocks M6** | no |
| Works offline | no | **yes** |
| iOS floor | 17 | 16.2 (below ours) |
| Apple Intelligence required | — | **no** |
| Quality ceiling | SDXL / Flux | **SD 1.5** — ControlNet has no SDXL support |

The last row is the whole trade, and it points the wrong way for §4's open
question about whether output reads as a recognisable animal. That is why SP-1
compares this path against the server rather than either being assumed to win.

## Converting the model

Not checked in — the packs are gigabytes and `.gitignore` excludes them. Run
this once; it takes a while and needs ~15 GB free.

```sh
git clone --depth 1 https://github.com/apple/ml-stable-diffusion.git
python3.11 -m venv venv && ./venv/bin/pip install -e ./ml-stable-diffusion

./venv/bin/python -m python_coreml_stable_diffusion.torch2coreml \
  --model-version stable-diffusion-v1-5/stable-diffusion-v1-5 \
  --convert-unet --unet-support-controlnet \
  --convert-text-encoder --convert-vae-decoder \
  --convert-controlnet lllyasviel/sd-controlnet-scribble \
  --attention-implementation ORIGINAL \
  --bundle-resources-for-swift-cli \
  -o ./out
```

`--unet-support-controlnet` is not optional: a UNet converted without it has no
ControlNet inputs and the pipeline fails at load, not at conversion.

**`--attention-implementation` is per target, and the wrong one is slow rather
than broken:**

| Value | For |
|---|---|
| `ORIGINAL` | Mac GPU — use for the quality spike |
| `SPLIT_EINSUM` | iPhone/iPad Neural Engine — use for the shipped pack |

The quality question is model-dependent, not attention-dependent, so the spike
runs `ORIGINAL` on a Mac. Device speed and thermals are a separate question that
needs a real device (`PLAN.md` T-2).

`coremltools` warns that recent torch versions are untested. Pin torch to 2.7.x
if conversion fails.

## What the converter writes

`--bundle-resources-for-swift-cli` decides the layout, and the pipeline reads it
back. `ModelPack` is the one place that names it:

```
Resources/
  TextEncoder.mlmodelc        VAEDecoder.mlmodelc
  ControlledUnet.mlmodelc     ← or ControlledUnetChunk1/2.mlmodelc
  vocab.json                  merges.txt
  controlnet/
    lllyasviel_sd-controlnet-scribble.mlmodelc
```

Three things catch people out. The UNet is **`ControlledUnet`**, not `Unet` — a
plain one has no ControlNet inputs and fails at load. The ControlNet file is
named after the model id with `/` replaced by `_`, so it is never called
`ControlNet.mlmodelc`; `ModelPack` reads whatever is in `controlnet/` rather
than guessing. And the ControlNet has to be a **scribble** one: the app draws a
centreline and records `conditionMode: "scribble"`, so a Canny or pose pack
would load happily and stamp that claim on a picture conditioned on something
else. `ModelPack` refuses it rather than let the metadata lie.

## Answering the gate question first

`DESIGN.md` v0.6 leaves one thing unanswered, and it is the one the product
rests on: **at strength 1.4–1.8 the animal survives and the route is maximally
reflected — but nobody has been shown one and asked whether it reads as their
route.** `edgeToRoute` cannot answer it (0.0607 on a success, 0.0598 on a
failure), so a person has to.

**This does not need Core ML.** Apple's pipeline adds the ControlNet residuals
unscaled and exposes no conditioning scale — that is why the app records
`fixedControlStrength = 1.0`, and why the last spike had to patch a harness that
then lived outside the repository and was lost. `diffusers` has the knob:

```sh
python3.11 -m venv venv
./venv/bin/pip install diffusers transformers accelerate torch pillow

# `swift build` compiles but installs nothing, so run them where they land.
# Functions, not variables: zsh does not word-split a scalar, so a string
# holding a command and its arguments is looked up as one long program name.
shapelab() { swift run -c release --package-path Packages/ShapeKit shapelab "$@"; }
genlab()   { swift run -c release --package-path Packages/GenerationKit genlab "$@"; }

# `your-route.gpx` must be the app's own export (Detail -> Export GPX). Only
# that file carries the segmentation the app stored: a recorder's GPX declares
# its own `<trkseg>` breaks, and a dropout the app cuts is then bridged here,
# changing both the control image and the subject. Both tools warn if the file
# was written by anything else.
#
# Both flags must match the activity, and both commands must get the same
# pair. `--mode` picks the resample spacing (5 / 8 / 25 m) and `--trim` is the
# person's privacy setting (0, 200 or 500) — either one changes the shape, and
# the shape can change the subject. Judged with the wrong pair, the sweep is
# measuring a picture the app would not have made.
shapelab render your-route.gpx --mode walk --trim 200 --out ./frames/

./venv/bin/python OnDevice/sweep.py \
  --control ./frames/00_000.png \
  --prompt "$(genlab subject your-route.gpx --mode walk --trim 200)" \
  --out ./sweep
```

That is 15 images — three strengths, five seeds — named `001.png` upward in a
shuffled order, so a filename says nothing about its condition. `blind.json` is
what to judge from; `conditions.json` is the key and should stay shut until
after. The prompt is Stage 1's subject plus the app's own style and negative
prompt, so what is judged is what the app would produce — never hand-written
(SP-1 #7), and the runner is usually a judge (SP-1 #9).

`genlab` takes the GPX, not a fingerprint, because it applies every refusal the
app applies: under 300 m (`GenerationClient.availability`), near-straight
(`isDegenerate`), and nothing recognisable (`GenerationCoordinator.prepare`).
Two of those cannot be seen in a fingerprint at all. It prints nothing and exits
non-zero for any of them — there is no point judging an image the app would
never make. The length it checks is what survives trimming, which is what
production measures: a 400 m route can fall under the bar once its ends go.

The one question: **does this read as the route you walked?**

Conversion below is for shipping on a device, and is worth doing only once that
answer is yes.

## Getting the pack onto a device

Roughly 1–2 GB with 6-bit palettisation, so it is not in the app bundle. There
is also no server to download it from — that is the same choice that keeps
routes on the phone. So the pack is copied in from a folder:

1. Convert on a Mac with the command above
2. Put the `Resources` folder in Files or iCloud Drive
3. **Settings → Picture model → Add a picture model**, and pick it

`ModelPackInstaller` checks the layout before copying a byte, stages the copy
beside the destination and swaps it in at the end, so an interrupted install
never leaves a half-pack that reports itself usable. The installed pack is
marked excluded from backup — it is reproducible from the conversion above, and
two gigabytes in every iCloud backup buys nothing. Swapping the folder for an
`https` download later touches only `install`.

The local card (§4.4) keeps working while the pack is absent, and
`GenerationTransport.readiness()` says so on the detail screen rather than
letting someone wait on a generation that cannot start.

## Where it plugs in

`OnDeviceTransport` conforms to `GenerationTransport`, so `GenerationClient`,
the polling policy, and the UI do not know which path ran. The one thing that
must not be shared is the quota: `isMetered` is false here, and the client skips
reserve/commit/refund entirely. `DESIGN.md` §8.3's ledger is about money leaving
an account, and none does.

`OnDeviceImageGenerator` is the seam the Core ML pipeline implements; the tests
drive a stub so the policy above it is verified without a model pack present.
