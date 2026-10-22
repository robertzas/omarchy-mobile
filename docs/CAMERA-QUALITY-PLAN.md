<!-- SPDX-License-Identifier: MIT -->
# Camera picture quality plan

**Status (2026-10-21):** Q1 (chroma noise reduction) and Q6 (defective
pixel correction) run on the phone in libcamera 0.7.2-4.21. Q2's CPU merge
runs in omacam: Night is a mode beside Photo, HDR a chip, and a 12-frame Night
burst merges in about 5.5 s on the phone (from 10-11 s), propped or handheld.
HDR protects highlights but loses deep shadows the ISP's tone curve already
crushed (Q5 is the fix). GPU merge: the first stage (alignment's
full-resolution step) runs 2.3x faster than the CPU through GLES 3.1 compute
on panfrost, reading the lumas as textures; storage buffers were slower than
the CPU through GLES and Vulkan alike. Next for it: the whole merge on the
GPU, with the frames kept there. Q5 (section 4a): the phone gives raw and
processed frames together at full rate, and Q5.1 passed: libcamera's
finishing shaders ported to the CPU reproduce the ISP's own frame to 0.05
levels. Q5.2 passed on the laptop: merging raw frames before the finish is
cleaner than merging finished ones (Q2's order), and an underexposed burst
brightened after a raw merge keeps the shadows Q2's order crushes. Q5.3
passed on the phone and shipped in omacam 0.3.3: Night and HDR bursts
merge the raw frames, Night in 4.6 s (5.4 s for Q2's merge), with HDR's
colors kept and its shadows open. Next is Q5.4 (the finish on the GPU). Q3 and Q4 have not started.

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

## 4a. Q5: raw-domain merge

**Why:** Q2 merges the ISP's 8-bit output, after its tone curve. Shadows the
curve crushed to 0 stay at 0 however many frames are averaged, so HDR keeps the
highlights but loses the deep shadows (Results, "Q2 HDR"). Merged before the
ISP, the frames are linear 10-bit: averaging N of them gains about
log2(sqrt(N)) bits, and the tone curve then sees shadows with real values.

**What the phone offers (2026-10-20, libcamera 4.21, main camera):**
- a `raw` stream, SGRBG10_CSI2P (10-bit packed, stride 5120, 15.7 MB a frame)
  at 2016x1136, 2032x1536, 4080x2288 and 4080x3072;
- **a raw and a processed stream together at full rate** (9.36 fps at
  4080x3072): every frame comes out both ways, so the ISP's statistics, AGC
  and AWB keep running during a burst, and each processed frame is an exact
  reference for its raw twin;
- the processed frame's metadata: `ColourCorrectionMatrix`, `ColourGains`,
  `SensorBlackLevels` (4096 at 16 bits, so 64 at 10), `Gamma`, `Contrast`,
  `Saturation`, `ColourTemperature`. A raw-only stream reports no exposure
  metadata. The rest of the processing (radial lens shading, denoise,
  sharpening, defective pixels, the look) is per-camera tuning, read from the
  tuning file.

**The pipeline:**
1. **Capture:** Q2's burst with a raw stream added beside the still stream;
   the raw frames are kept, the processed ones give the metadata. HDR can go
   2-3 stops under now, not 1.5.
2. **Unpack and normalise:** CSI-2 packed 10-bit to 16-bit, black level
   subtracted.
3. **Align:** omacam-merge's pyramid on a half-resolution grey image (each 2x2
   Bayer quad summed), offsets doubled to even pixels at full resolution so
   the colour pattern stays in phase (as HDR+ does).
4. **Merge:** each Bayer channel apart, with the robustness weights from a
   noise model of the raw (shot and read noise: σ² = a·x + b, fitted from the
   burst).
5. **Tone:** a gain map in the linear domain (exposure fusion of the merge at
   0, +1, +2 stops, as Q2 does now, but before the curve), so the shadows the
   curve would crush are lifted first.
6. **Finish:** libcamera's own software ISP shader (`debayer_egl`, LGPL-2.1+,
   which GPL-3 omacam may use) run over the merged Bayer frame through GLES,
   with the uniforms worked out the way the software ISP does, from the burst's
   metadata and the tuning file. That keeps the libcamera look exactly instead
   of copying it by hand.

**Order:**

| Step | What | Pass | Stop if |
| --- | --- | --- | --- |
| Q5.1 | Finish one raw frame on the laptop with the ported shader, and compare it with its processed twin | ΔE under 2 on 99% of pixels | the shader's uniforms can't be rebuilt from metadata and tuning |
| Q5.2 | Merge a raw burst on the laptop (CPU), finish it as in Q5.1 | shadows: the black share no higher than a single frame's; noise on flat areas at least as low as Q2's | worse than Q2 on the same scene |
| Q5.3 | In omacam: raw stream in the burst, merge and finish on the phone | Night and HDR saved as before; time within 1.5x of Q2's | memory: 12 raw frames are 190 MB packed, 300 MB unpacked |
| Q5.4 | The finish on the GPU (the gpu-spike's GLES path) | the same picture within 1 level; faster | |

Captures for Q5.1 and Q5.2 are taken with `cam` (both streams, `--file`),
read-only, and stay in the scratch directory: they show the user's home and
are never committed.

Two things Q5.1 found, which Q5.3 has to follow:
- **The ISP finishes frame N with frame N-1's white balance.** The
  `ColourGains` in frame N's metadata are the gains computed from its
  statistics, applied from the next frame on. With N-1's gains the port
  matches; with N's own it misses by 1.5 levels (92% within ΔE 2).
- **The last frame before `stop()` can be unpaired:** in one capture the
  final raw buffer was 28% darker than its processed twin and matched
  nothing. A burst drops its last frame or checks the pair.

Neither binds the raw path in omacam as built: it chooses its own white
balance (the reference frame's newest estimate) rather than matching the
ISP's frame, and it uses the processed twin only for its size and
metadata, never its pixels. Both matter again for any step that compares
the two streams.

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
| Q2 GPU spike | 2026-10-19 | omacam branch gpu-spike (b4e62b7) | the full-resolution alignment step as a WGSL compute shader through wgpu on Vulkan (PanVK, Mesa 26.2.4, Mali-G710 MC7 at 572 MHz): agrees with the CPU on 99.99% of 48514 tiles, but 295 ms (a workgroup per tile), 749 ms (shared tiles) and 1367 ms (an invocation per tile) against the phone CPU's 145-150 ms; on the laptop's Intel GPU 37-113 ms. 60-100x short of the hardware |
| Q2 GPU, GLES | 2026-10-19 | omacam branch gpu-spike (14ac2ae) | the same step through GLES 3.1 compute on panfrost: storage buffers as slow as Vulkan (294-313 ms a workgroup per tile, 1318-1432 ms an invocation per tile), so the API wasn't the cause. Reading the lumas as R32F textures: **64 ms** a workgroup per tile, against the CPU's 141-157 ms; 159 ms with shared tiles, 801-812 ms an invocation per tile. 99.99% agreement in all. Uploading two R32F frames took 63-68 ms per call: a GPU pipeline keeps the frames there |
| Q5.1 | 2026-10-21 | libcamera 4.21 | main camera, 4080x3072, gain 14-16, a lit indoor scene; a 1024 px crop of three frames finished on the laptop (DPC, debayer, the finishing pass, the post-filter) against the ISP's output: **mean 0.05 levels, 100% within ΔE 2** with the previous frame's white balance. High-pass correlation 0.97-0.98 for the matching raw frame and under 0.04 for the others, so processed N is raw N |
| Q5.2, first burst | 2026-10-21 | laptop prototype | main camera, 12 raw frames at a locked 107 ms and gain 14.3, a lit indoor scene, propped (it moved 6 quad pixels between frames 8 and 9). Alignment on the 2x2 quad image (global, then 32x32 raw tiles within 2), weights from a fitted noise model (var = 0.090 (Q-black) + 1.28), 8.4 effective frames. Two 1536 px crops, the same alignment and weights for both orders. Luma noise on flat areas (std of a 5x5 high-pass): single 1.41-1.49, merged after finishing (Q2's order) 0.56-0.60, **merged raw then finished 0.50-0.56**; chroma noise in dark flat areas 4.0-4.8, 1.86-1.87, **1.30-1.52**. With the post-filter set for the merge's lower noise (gain/8.4) the merged raw comes out sharper at about Q2's noise. No ghosts. No black pixels in either crop, so the shadow pass is untested: it needs a burst exposed under, as HDR takes it |
| Q5.2, underexposed | 2026-10-21 | laptop prototype | the same office, two locked bursts at 107 ms: gain 3.56 (1.65 stops under) brightened x3, and gain 1.0 (about 3.3 stops under, medians 11 levels above black at 10 bits) brightened x10; 9.2 and 10.4 effective frames. At x10 the plain frame has 9% black pixels on the dark crop. Q2's order (finish, merge in 8 bits, brighten) comes out a fifth darker (luma 106 against 129), more saturated, and flat in the deep shadows: those levels were gone in the 8-bit frames. The raw merge keeps them, at luma noise 1.10 against Q2's 1.32 (single frame 5.2); its chroma noise in the dark is higher (4.9 against 3.2), partly because it is brighter. Two prototype faults found: a flat gain clipped channel by channel turns bright orange pale pink (HDR needs a highlight-aware gain), and a plain border clamp in the tile warp broke the Bayer phase (magenta edge; fixed by clamping whole quads) |
| Q5.3 | 2026-10-21 | omacam `raw-merge` (2941663), libcamera 4.21 | main camera, the same office, propped. libcamera gives the raw stream at 4080x3072 beside a 4072x3072 processed one (the raw frame's left 4072 columns); the first build refused that as a size mismatch and fell back, fixed by accepting a raw frame up to 16 columns wider and cropping the merge. Night (12 frames, 43.8 ms, gain 16): raw merge 4.56 s (align 0.58, merge 0.50, finish 2.55, fusion 0.79) against 5.42 s for Q2's (align 2.56); peak RSS 2.1 GB against 2.5 GB. Flat-area luma noise 1.00 against Q2's 0.94 at 10% more brightness, chroma noise in the dark 1.43 against 1.61 (a single photo: 1.54 and 5.07) |
| Q5.3 HDR | 2026-10-21 | omacam `raw-merge` (2941663) | 8 frames at 15.5 ms, gain 16. Brightened x2.8 in the raw before the finish (the first build), an orange plush came out pale pink, as in a normal photo: its raw red sat at 210-280 of 1023, nowhere near clipping, and the look pushed it past display red, where the gamut step whitens along constant luma. A highlight knee on the white-balanced level barely changed it and tinted the clipped lamp. Finishing the burst at its own exposure and fusing at 0/+1.5/+2.5 stops, as Q2's HDR does, keeps the orange: luma 95.5 (normal photo 97.2, Q2's HDR 76.1), 5th percentile 27.7 against Q2's 6.0, luma noise 1.18 against 1.34, chroma noise in the dark 1.79 against 2.74. 4.6 s on the phone (fusion 1.19 s) |
