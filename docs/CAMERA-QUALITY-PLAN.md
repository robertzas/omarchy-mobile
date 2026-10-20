<!-- SPDX-License-Identifier: MIT -->
# Camera picture quality plan

**Status (2026-10-19, late):** Q1 (chroma noise reduction) and Q6 (defective
pixel correction) run on the phone in libcamera 0.7.2-4.21. Q2's CPU merge
runs in omacam: Night is a mode beside Photo, HDR a chip, and a 12-frame Night
burst merges in about 5.5 s on the phone (from 10-11 s), propped or handheld.
HDR protects highlights but loses deep shadows the ISP's tone curve already
crushed (Q5 is the fix). Next: the merge on the GPU (Vulkan works on the
phone: PanVK, Mali-G710 MC7, a compute queue). Q3-Q5 have not started.

The cameras work end to end ([CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md),
[CAMERA-APP-PLAN](CAMERA-APP-PLAN.md)), and the pictures are decent but far
from stock. This plan closes as much of that gap as our route allows.

## 1. Where the gap is

Stock quality comes from three places. We have none of them:

1. **The hardware ISP with Google's tuning:** denoise, sharpening, lens
   shading and colour.
2. **Multi-frame merging:** HDR+ and Night Sight, in the Google Camera app.
3. **Per-module calibration.**

We run libcamera's software ISP on the GPU. Our patches
([packages/libcamera](../packages/libcamera/README.md)) have already added:
- radial lens shading (0028);
- a 3x3 luma denoise and an unsharp mask (0029, 0030);
- highlight handling (0033-0048);
- a hand-tuned look (0051, 0052);
- colour matrices tuned by eye, not measured (0039, 0045).

Running Google's camera HAL instead was reviewed again on 2026-10-19 and stays
out for now (CAMERA-PLAN section 0, option b). It needs:
- a SysMMU v8 driver and bring-up of the ISP power domains and clocks, which
  mainline doesn't have;
- Android EGL inside a chroot.

That is 6-12 months of work. Even then it gives only what third-party apps get
on a stock Pixel: HDR+ and Night Sight live in Google's app, not the HAL. A
cheap read-only probe (run the HAL under `strace` in a vendor chroot with no
camera nodes) can still be run to settle its first unknowns.

**The honest ceiling:** good single frames, plus our own burst merge for low
light and high contrast. That is less than stock's machine-learned processing,
but much closer than one frame from a software ISP.

## 2. Tracks

| Track | What | Where | Needs |
| --- | --- | --- | --- |
| **Q1** | Chroma noise reduction | libcamera 0053 (GPU second pass) | nothing; on the phone next |
| **Q2** | Burst merge: Night and HDR modes | omacam: `omacam-merge` (CPU reference, then GPU) | burst captures from the phone |
| **Q3** | Measured colour | each camera's `ccm` in the tuning files | a colour chart (24-patch), photographed by each camera under 2-3 lights |
| **Q4** | Better single-frame detail | libcamera: a better demosaic, wider denoise | raw captures to compare against |
| **Q6** | Defective pixel correction | libcamera 0055 (a GPU pass before the debayer) | nothing; done |
| **Q5** | Raw-domain merge | omacam: merge Bayer frames before the ISP, then our own finishing pass | Q2 working; the finishing pass must match the libcamera look |

Q1 and Q2 come first. Q3 waits on a chart. Q5 is the HDR+ way and the best
result, but it duplicates libcamera's processing, so it comes after Q2 has
proved the merge.

## 3. Q1: chroma noise reduction

**What it does:** the GPU's second pass averages the colour differences over a
9x9 footprint (16 taps). It is guided by luma and chroma similarity, so colour
stays inside edges. Its strength is `chromaDenoise` × sqrt(gain), with 0.03 for
each camera.

**Offline check:** a numpy port of the shader on a synthetic chart with
high-gain noise. Flat-patch chroma noise (8-bit RMS) falls from 6.1 to 2.8 at
gain 4 and from 12.1 to 5.6 at gain 16. On a clean picture, colour at edges and
in 6 px colour stripes moves by 1.0 and 1.9.

**On the phone (next):**
- Install libcamera 4.19.
- Take the same scene indoors at high gain with 4.18 and 4.19, one shot each,
  tripod or phone flat.
- **Pass:** less colour speckle in flat areas, with no colour bleeding at edges
  or on text, and the preview still at 30 fps on the main camera.
- **Rollback:** reinstall 4.18.

## 4. Q2: burst merge (Night and HDR)

**The approach (HDR+'s):**
1. A burst of N frames at one short exposure: 1-2 stops under what the AGC
   picks, so that highlights don't clip.
2. Aligned, merged with motion rejection, then tone mapped so the shadows come
   back.

One exposure for every frame avoids most of bracketing's alignment and ghosting
trouble. One mechanism serves both:
- **Night:** N about 12-15, the exposure capped for hand shake;
- **HDR:** N about 6-8, underexposed.

**Stage 1 merges the processed frames,** the 8-bit RGB the software ISP
outputs. That keeps libcamera's whole look. Averaging N noisy 8-bit frames
recovers precision, because the noise dithers.

**The pipeline, in a new crate `omacam-merge` with no UI and no libcamera:**

1. **Reference:**
   - the sharpest of the first three frames, by mean gradient energy on a
     downscaled luma.
2. **Align:**
   - a 4-level luma pyramid, scaled 1/1, 1/4, 1/16 and 1/64;
   - tile block matching from coarse to fine (32 px tiles at the top, 16 px at
     full resolution), with a ±4 px search a level and the coarser level's
     offset as the start;
   - integer offsets at full resolution;
   - tiles overlap by half and are blended with a raised-cosine window, so
     tile seams don't show.
3. **Merge:**
   - each aligned tile is weighted against the reference by how much it differs
     beyond the expected noise (Hasinoff et al. 2016's robustness term, in the
     spatial domain): a tile that moved gets little weight, so moving things
     come from the reference only;
   - the noise level per brightness is estimated from the burst itself.
4. **Finish:**
   - exposure fusion (Mertens et al. 2007) of the merged picture at 3 virtual
     exposures (0, +1, +2 stops on the linearised merge), to lift the shadows
     and keep the highlights;
   - a light final sharpen.
5. **Output:** an 8-bit RGB picture for the existing JPEG and EXIF path.

**Capture side (omacam-core `capture.rs`):**
- a `Burst` mode keeps N frames after the settle step instead of one, at locked
  manual exposure, gain and colour gains, with the exposure scaled down by the
  mode's stops;
- the frame interval is the sensor's (main camera about 9 fps at full size, so
  12 frames take about 1.3 s);
- the UI says "Hold still" with a progress ring, then shows the result when the
  merge finishes.

**Order:**
1. **CPU reference with tests on synthetic bursts:**
   - an image shifted by known sub-tile motions, with noise added and one moving
     patch;
   - **Pass:** offsets recovered to within 1 px, the merged noise close to
     σ/sqrt(N) on static areas, and no ghost of the moving patch.
2. **Real bursts from the phone:**
   - a capture script writes N full-size frames to files;
   - merged on the laptop and compared by eye and by noise on flat areas with a
     single frame.
3. **In omacam on the phone:** a Night mode, with the merge time measured on
   the phone's CPU.
4. **GPU backend:**
   - the same stages as compute shaders, through wgpu on Vulkan (PanVK) or GLES
     3.1;
   - checked against the CPU reference within a small tolerance;
   - used when it is faster.
5. **HDR mode:** the same pipeline with fewer frames and a stronger
   underexposure.

**Licences:** the algorithms are published (Hasinoff et al., "Burst
photography for high dynamic range and low-light imaging on mobile cameras",
SIGGRAPH Asia 2016; Mertens et al., "Exposure Fusion", 2007). We write our own
code from the papers and copy no Google code.

## 5. Q3: measured colour

The colour matrices for the Samsung sensors are hand-tuned without a chart
(0039, softened in 0045). The ultrawide uses a stand-in. CAMERA-PLAN 7.Q,
"What needs captures", is the method:
- a 24-patch colour chart filling a third of the frame;
- daylight, a 4000 K LED and a tungsten bulb;
- raw DNGs from each camera;
- libcamera's own `libtuning` CCM fit.

It needs a physical chart. Nothing from Google's tuning is used.

## 6. Results

| Step | Date | Version | Result |
| --- | --- | --- | --- |
| Q1 offline | 2026-10-19 | libcamera 4.19 (0053) | shader port on a synthetic chart: chroma noise halved at gains 4 and 16, edge colour within 1-2 levels |
| Q1 on the phone | 2026-10-19 | libcamera 4.19 | installed; preview at 30 fps |
| Q2 propped, dim room | 2026-10-19 | omacam test build | 12 frames, weights 0.94 each, merged in 11.3 s, 2.4 GB peak; at 100% the wall's grain is gone and text stays sharp, no ghosts; shadows lifted (mean 112 vs 98). A hot pixel survives (it doesn't move between frames) |
| Q2 handheld, dim room | 2026-10-19 | omacam test build | 12 frames at 66 ms, weights 0.92 each, merged in 9.8 s; sharp at 100%, no ghosts or doubled edges |
| Q2 HDR | 2026-10-19 | omacam 697fd46 | 8 frames 1.5 stops under; fused at 0/+1/+2 stops it came out darker than a plain shot (mean 80 vs 100); at 0/+1.5/+2.5, 91 vs 99, the lamp less bloomed, but 4.6% of the picture black against 1%: shadows the ISP's curve crushed in the 8-bit frames stay crushed |
| Q2 speed | 2026-10-19 | omacam e4a26a4, f87c6ba | Night merge on the phone 8.9 s with the serial loops parallel, then 5.4-5.6 s with tiles inside the frame read as slices (alignment 2.5 s, merge 1.7 s, fusion 0.8 s); the preview keeps 10-15 fps meanwhile (merge threads one core short, nice 10) |
| Q2 preview after a burst | 2026-10-19 | omacam c857488, libcamera 4.20 (0054) | the preview kept the burst's manual exposure (66 ms, 15 fps): the simple pipeline dropped Camera::start()'s controls. Fixed on both sides; each alone brings back 33 ms and 30 fps |
| Q6 hot pixel | 2026-10-19 | libcamera 4.21 (0055) | the main camera's magenta spot (one red sensor pixel, about 5 px wide in the JPEG) is gone; a green one in a dark area too; `LIBCAMERA_SOFTISP_NO_DPC=1` brings both back. Only 12 pixels of the 12.5 MP differ by more than 30% between the two. One small bright spot on a red object was dimmed: a hot pixel or a real glint, to watch |
