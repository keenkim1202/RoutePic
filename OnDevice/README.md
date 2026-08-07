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

## Shipping the pack

Roughly 1–2 GB with 6-bit palettisation. Do **not** put it in the app bundle:

- On-demand resources or a first-run download, so install size stays small
- Gate on device memory and report progress — `OnDeviceUnavailability` carries
  `.modelNotDownloaded`, `.downloadInProgress`, `.deviceUnsupported` for exactly
  this, and each has user-facing copy
- Keep the local card (§4.4) working while the pack is absent. Generation is
  additive; the app must not appear broken to someone who declined a 2 GB download

## Where it plugs in

`OnDeviceTransport` conforms to `GenerationTransport`, so `GenerationClient`,
the polling policy, and the UI do not know which path ran. The one thing that
must not be shared is the quota: `isMetered` is false here, and the client skips
reserve/commit/refund entirely. `DESIGN.md` §8.3's ledger is about money leaving
an account, and none does.

`OnDeviceImageGenerator` is the seam the Core ML pipeline implements; the tests
drive a stub so the policy above it is verified without a model pack present.
