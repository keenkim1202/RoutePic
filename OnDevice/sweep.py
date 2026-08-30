#!/usr/bin/env python3
"""Generate the strength sweep SP-1 needs, and shuffle it for blind judging.

Why this is not Core ML: `StableDiffusionPipeline` adds the ControlNet
residuals unscaled and exposes no conditioning scale, which is why the app
records `fixedControlStrength = 1.0`. Answering "does the route read as mine at
1.4-1.8" needs that knob, and `diffusers` has it. Converting to Core ML costs
~15 GB and answers nothing this does not.

It lives in the repository because the last harness did not, and the strength
knob it patched in had to be rebuilt from scratch (`SPIKE-RESULTS.md` 2차).

    python3 OnDevice/sweep.py --control frames/00_000.png \
        --prompt "$(genlab subject fp.json)" --out ./sweep
"""

import argparse
import json
import random
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", required=True, type=Path,
                        help="control image from `shapelab render`")
    parser.add_argument("--prompt", required=True,
                        help="Stage 1's subject — never hand-written (SP-1 #7)")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--strengths", type=float, nargs="+",
                        default=[1.0, 1.4, 1.8],
                        help="the window the 42-cell grid left standing")
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3, 4, 5],
                        help="five per cell: one told seed noise from condition (SP-1 #1)")
    parser.add_argument("--steps", type=int, default=20)
    parser.add_argument("--style", default="flat-vector",
                        help="appended to the subject, as OnDeviceTransport does")
    parser.add_argument("--negative", default="text, watermark, blurry, low quality",
                        help="the app's negative prompt; changing it changes what is judged")
    args = parser.parse_args()

    if not args.prompt.strip():
        # `genlab` exits without a prompt for a route the app refuses. An empty
        # one here would generate an unconditioned image and call it a result.
        raise SystemExit(
            "no prompt: Stage 1 refused this route, and the app would not draw it either"
        )

    import torch
    from diffusers import ControlNetModel, StableDiffusionControlNetPipeline
    from PIL import Image

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    controlnet = ControlNetModel.from_pretrained(
        "lllyasviel/sd-controlnet-scribble", torch_dtype=torch.float32
    )
    pipe = StableDiffusionControlNetPipeline.from_pretrained(
        "stable-diffusion-v1-5/stable-diffusion-v1-5",
        controlnet=controlnet,
        torch_dtype=torch.float32,
        safety_checker=None,
    ).to(device)

    control = Image.open(args.control).convert("RGB").resize((512, 512))
    args.out.mkdir(parents=True, exist_ok=True)

    # What the app actually sends. Judging a bare subject would measure a
    # configuration the product never produces (`OnDeviceTransport.run`).
    prompt = f"{args.prompt}, {args.style}"

    # Shuffled before generating, not after naming. Numbering a sorted list
    # leaves the key in the terminal scrollback and in the file creation times:
    # the first five printed would be 1.0, the next five 1.4. The person who ran
    # this is usually a judge, and watching it run must tell them nothing.
    cells = [(s, seed) for s in args.strengths for seed in args.seeds]
    random.shuffle(cells)

    manifest = [
        {"file": f"{number:03d}.png", "strength": strength, "seed": seed}
        for number, (strength, seed) in enumerate(cells, start=1)
    ]

    # Written before a single image is, and the old pair removed first. A rerun
    # into the same directory overwrites images under a fresh assignment, so a
    # run that dies halfway would otherwise leave a complete-looking directory
    # whose key belongs to the previous one.
    # The old images go before the new key arrives. Publishing a mapping over
    # a directory that still holds the previous run's PNGs means an interrupted
    # rerun leaves every named file present, some of them from the old
    # assignment, described by the new one.
    for stale in args.out.glob("[0-9][0-9][0-9].png"):
        stale.unlink()

    conditions = args.out / "conditions.json"
    blind = args.out / "blind.json"
    conditions.unlink(missing_ok=True)
    blind.unlink(missing_ok=True)
    conditions.write_text(json.dumps(sorted(manifest, key=lambda e: e["file"]), indent=2))
    blind.write_text(json.dumps(sorted(e["file"] for e in manifest), indent=2))
    for entry in manifest:
        name, strength, seed = entry["file"], entry["strength"], entry["seed"]
        image = pipe(
            prompt,
            negative_prompt=args.negative,
            image=control,
            num_inference_steps=args.steps,
            controlnet_conditioning_scale=strength,
            generator=torch.Generator(device="cpu").manual_seed(seed),
        ).images[0]
        image.save(args.out / name)
        # The number only. Printing the condition alongside it hands the key
        # to whoever is watching, and that is usually a judge.
        print(f"  {name}")

    print(
        f"\n{len(manifest)} images, named in a shuffled order so the number says"
        " nothing.\nJudge from blind.json. Do not open conditions.json until after."
    )


if __name__ == "__main__":
    main()
