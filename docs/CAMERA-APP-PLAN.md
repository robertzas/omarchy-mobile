<!-- SPDX-License-Identifier: MIT -->
# Camera app plan: a phone camera, not a webcam

**Status (2026-10-14):** design only. Nothing is built and nothing on the phone has changed. The only phone queries were read-only (package versions, `cam -l`, `/proc/meminfo`, device node modes). Kernel on the phone: `7.3.0-rc6-omamobile-push1-00535-g8334caadc092`, libcamera 0.7.2-4.6, GNOME Snapshot 51.0.
**Goal:** a camera app that behaves like the stock Pixel camera. That means one zoom control from the ultrawide to the telephoto with automatic lens switching, full-resolution stills, tap to focus and expose, and exposure compensation. Later come HDR and night modes.
**Recommendation in one line:** **build our own app in Rust, with GTK 4 and libadwaita through gtk-rs, on libcamera directly through libcamera-rs.** The camera logic lives in a UI-free core crate. Spend one or two days first evaluating cosmic-utils/camera on the phone (§2.4), because it is the one existing app built on the same foundations. The kernel and libcamera items in §4 run in parallel in [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) and `packages/libcamera`.

The owner's request: *"a better camera app that allowed you to use ultrawide and telephoto with a zoom slider that automatically did this like the stock android camera … better equipped to handle modern camera features instead of essentially a webcam app"*, followed by *"should we build a rust camera app to meet all of our needs?"*

### Sources read for this plan

Every external project was read as a shallow clone at the commit below, checked 2026-10-14. Nothing from them was built, run or copied into our tree.

| Project | Licence | Commit / release | What was read |
| --- | --- | --- | --- |
| [GNOME Snapshot](https://gitlab.gnome.org/GNOME/snapshot) and its `aperture` crate | GPL-3.0-or-later | `77eb1674` (2026-09-17), tag `51.0` (2026-09-14) | `aperture/src/{viewfinder,device_provider,utils}.rs`; issues #201, #215, #273, #360, #364; MRs !196, !202 |
| [libcamera](https://git.libcamera.org/libcamera/libcamera.git) | LGPL-2.1-or-later (library) | `v0.7.2` (2026-07-10); master `a92285e9` (2026-10-13) | `src/libcamera/pipeline/simple/simple.cpp`, `src/ipa/simple/algorithms/*`, `src/gstreamer/gstlibcamerasrc.cpp`; patchwork 28382, 26677, 26241 |
| [libcamera-rs](https://github.com/lit-robotics/libcamera-rs) | MIT OR Apache-2.0 | crates `libcamera`/`libcamera-sys` 0.7.0 (2026-02-28); last merge `ac022208` (2026-02-25) | the crate source, `versioned_files/`, open PRs #83, #87, #88, issues #70, #79, #85, #86 |
| [cosmic-utils/camera](https://github.com/cosmic-utils/camera) | GPL-3.0-only | v1.3.7 (2026-09-24), `4e6e320b` (2026-10-13) | README, `src/backends/camera/libcamera/`, `src/app/video_widget.rs` |
| [Plasma Camera](https://invent.kde.org/plasma-mobile/plasma-camera) | GPL-3.0-or-later | v2.1.1 (2025-12-05), `15f6d3b2` (2026-10-05) | `src/plasmacamera/{worker,converter}.cpp`, `src/contents/ui/*.qml`, `CMakeLists.txt` |
| [Megapixels](https://gitlab.com/megapixels-org/Megapixels) / [libmegapixels](https://gitlab.com/megapixels-org/libmegapixels) | GPL-3.0 | 2.1.0 (2026-02-17), `578b1474` (2026-07-27) / 0.2.3, `1f86f248` (2026-06-24) | `meson.build`, `config/*.conf`, `src/gles2_debayer.c` |
| [Millipixels](https://source.puri.sm/Librem5/millipixels) | GPL-3.0 | v0.24.0 (2026-04-30), `8cedfd5d` | `meson.build`, `src/libcam.cpp`, README |
| [Lomiri Camera App](https://gitlab.com/ubports/development/apps/lomiri-camera-app) | GPL-3.0 | v4.1.1 (2025-08-11), `2672c233` (2026-10-03) | `CMakeLists.txt`, `debian/control`, QML |
| [Droidian Camera](https://github.com/droidian/droidian-camera), [FuriOS Camera](https://github.com/FuriLabs/furios-camera) | GPL-2.0 | `a0b51cd8` (2024-06-08), `dae1fc3f` (2026-10-02) | README, build files |
| [gtk4-rs](https://github.com/gtk-rs/gtk4-rs) | MIT | 0.11.5 (2026-09-20), `472c2f8` (2026-10-11) | `gdk4/src/dmabuf_texture_builder.rs` |
| [cxx-qt](https://github.com/KDAB/cxx-qt) | MIT OR Apache-2.0 | v0.10.0 (2026-08-24), `f62f0570` (2026-09-29) | README, `examples/qml_features`, `cxx-qt-lib` type list |
| [Slint](https://github.com/slint-ui/slint), [iced](https://github.com/iced-rs/iced), [libcosmic](https://github.com/pop-os/libcosmic) | GPL-3.0-only/royalty-free/commercial; MIT; MPL-2.0 | 1.18.1 (2026-09-21); 0.14.0 (2025-12-07), `ab336f6d`; `e1f2cd2e` (2026-10-13) | CHANGELOGs, gesture and texture APIs |
| Google, [Pixel 7 Pro tech specs](https://support.google.com/pixelphone/answer/7158570) | (facts) | read 2026-10-14 | field of view, aperture and pixel size per camera |

On our side: [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) (CAM-M.5l, CAM5.3, CAM5.4, 7.Q, section 8), [`packages/libcamera`](../packages/libcamera/README.md) (patches 0001-0015), [`packages/mesa`](../packages/mesa/README.md) (0002, in progress), [`omamobile-apps`](../packages/omamobile-apps/PKGBUILD), `omamobile-device-cheetah` (`50-omamobile-cameras.conf`, `70-omamobile-dma-heap.rules`), `omamobile-shell`'s `omamobile.access` sheet and `omamobile-portal-access`, and `omamobile-sensors` (`net.hadess.SensorProxy`).

---

## 1. Where we stand, and why Snapshot feels like a webcam

### 1.1 The hardware as libcamera sees it today

| Camera | Sensor | Modes we run (CAMERA-PLAN) | Focus | libcamera today |
| --- | --- | --- | --- | --- |
| Main | Samsung S5KGN1, 50 MP Quad Bayer; we run its 2x2-binned output | 4080x3072 (12.5 MP) at **about 9 fps**, because the WDMA takes at most about 400 MB/s within a line (CAM-M.5l); 2016x1136 at 30 fps (up to about 128) | AK7375 VCM; contrast AF in the soft ISP works ("Autofocus completed at 925", CAM5.4) | listed, previews, AF |
| Ultrawide | Sony IMX386, 12 MP | 2016x1508 binned at 30/60 fps; full 4032x3016 still overruns the WDMA (needs the same line-throughput rule as the main, CAM-M.5l) | AK7375; AF works with the `camera-uw-lens` overlay | listed, previews, AF |
| Telephoto | Samsung S5KGM5, 48 MP behind a 5x folded lens | 2016x1512 at 30 fps; 4032x3024 (binned) at 26 fps | SEM1215SA NACKs (CAM-T T.3), so the lens sits at its stop and pictures are soft | listed, previews, **no AF** |
| Front | Samsung S5K3J1, 10.8 MP | 1920x1368/1920x1116 binned; 3840x2736 at 26 fps | fixed focus | listed, previews |

Constraints that shape the app:

- **One camera streams at a time.** All CSIS links share WDMA context 0. A second camera's stream-on gets `EBUSY` (CAMERA-PLAN, the `gs201-csis` "links share WDMA context 0" change). The hardware has four CSIS WDMA contexts, so concurrent streams are a possible later kernel project. Even then, two software ISPs would double the GPU and CPU load. **Seamless dual-stream handoff, as stock does it, is out of reach. The app needs a fast switch (§3.4).**
- **One processed stream per camera.** In libcamera 0.7.2, `simple.cpp` `matchDevice()` says that with the software ISP the simple pipeline handler "exposes the raw stream, giving a total of two streams": **one processed stream plus an optional raw stream**. A pending patch says so explicitly ("pipeline: simple: Reject multiple processed streams with software ISP", patchwork 28382, v2 2026-09-25). So there is no viewfinder plus still at two processed sizes. A full-resolution still means reconfiguring into the large mode (§3.3).
- **The soft ISP's controls** (0.7.2 plus our patches): `ExposureTime`, `AnalogueGain`, `DigitalGain` (0011), `ColourGains`, `ColourTemperature`, `ColourCorrectionMatrix`, `Contrast`, `Saturation`, `Gamma`, `SensorBlackLevels`; `AfMode`, `AfTrigger`, `AfState` and `LensPosition` (0005-0007, centre window only). **Missing:** `ExposureValue` (exposure compensation), `AfWindows` (tap to focus), `ScalerCrop` (digital zoom; Kieran Bingham's series 26677 only *reports* the crop), AE metering regions, and lens shading and denoise.
- **Memory:** `CmaTotal` 618496 kB, `CmaFree` 495488 kB on today's phone (the 384 MiB default area plus the camera and display pools). The heaps `system`, `reserved` and `default_cma_region` are open to the seat user (`70-omamobile-dma-heap.rules`). Libcamera's default for the main and telephoto, four RGB888 buffers of about 37 MB at full size, failed to allocate before the CMA grew (CAM-M.5l). The app must choose its buffer counts (§3.6).
- **Device access:** `/dev/media*`, `/dev/video*` and `/dev/v4l-subdev*` are `root:video 0660` with a uaccess ACL, so the logged-in user can open libcamera directly without the portal.

### 1.2 What Snapshot does, from its source

- `aperture/src/device_provider.rs` wraps GStreamer's `pipewiredeviceprovider` on a PipeWire fd from the camera portal's `OpenPipeWireRemote()`. **Every camera is a separate PipeWire video source**, which is what WirePlumber publishes from libcamera (our `50-omamobile-cameras.conf` names them Main, Ultrawide, Telephoto, Front).
- `aperture/src/viewfinder.rs` runs one `camerabin` around a single `wrappercamerabinsrc`. `take_picture()` switches to `mode-image` and emits `start-capture`, so **the photo is a frame of the preview stream**.
- `aperture/src/utils.rs` `caps::best_mode()` caps the size at `const MAX_HEIGHT: i32 = 1080` (MR !202, 2024-02-20, after !196 "Pick highest resolution", 2024-01-29).
- No zoom, focus, exposure or lens concept exists in the code. Open issues: #201 "Implement zooming in viewfinder" (2024-07-02; it proposes client-side zoom first and `ScalerCrop` through PipeWire later), #215 manual focus/exposure/white balance and locks (2024-08-13), #273 wrong resolution and scaling on mobile, #360 pictures flipped left-right with a soft-ISP camera (2026-04-09), and #364 aperture ignores `api.libcamera.rotation` (2026-06-09). The last two touch our phone directly: the owner should check the CAM5.4 rotations against them.

PipeWire is the deeper limit. The libcamera SPA plugin offers one stream per node with a few properties, so per-request controls, still captures and lens grouping would need work in PipeWire, GStreamer and Snapshot together.

---

## 2. Options

### 2.1 Summary

| Option | Reachable features | Effort to the Pixel-like feature set | Maintenance | Verdict |
| --- | --- | --- | --- | --- |
| **(a) Patch Snapshot** | Client-side digital zoom (#201). Lens switching only as app logic over separate PipeWire nodes, each switch a full pipeline restart. Full-res stills, tap to focus and EV need PipeWire's libcamera SPA, `pipewiresrc` and aperture to carry controls and a second stream | Large, spread over three upstreams (Snapshot, PipeWire, libcamera) | Patches against a fast-moving GNOME app, or upstream review in three projects | **No.** The single-webcam model goes down to PipeWire. Send the client-side zoom and the rotation fixes upstream separately (§2.2) |
| **(b1) Megapixels 2.x** | Raw V4L2 and media-controller capture with its own GLES debayer and DNG post-processing | A gs201 config is possible, but Megapixels **does not use libcamera**, so we would lose our soft ISP, AF and tuning patches | Its own device-config world | **No** |
| **(b2) Millipixels** | Uses libcamera only to set modes (`src/libcam.cpp`); capture is its own V4L2 path | As (b1) | Purism-specific | **No** |
| **(b3) Lomiri Camera** | Has `ZoomControl` bound to QtMultimedia's `digitalZoom`; Qt5, Android HAL plugin through Halium | Port to Qt6 and to a libcamera backend first | Qt5, UBports-specific | **No** |
| **(b4) Droidian/FuriOS Camera** | gst-droid, the Android HAL | Not applicable without the HAL | | **No** |
| **(b5) Plasma Camera** | Qt6/QML/Kirigami on **libcamera directly** since "Port to libcamera backend" (2025-07-02). Handles AeEnable, ExposureValue, ExposureTime, AnalogueGain, AWB, Contrast, Saturation. One `Viewfinder` stream; frames converted on the CPU into a `QImage`; `AF_WINDOWS` and `SCALER_CROP` detected but not acted on; a `ZoomControl.qml` that isn't clearly wired | A good base for a C++/QML app: about 6,200 lines. We would add zoom and lens switching, a GPU display path, a still path and tap to focus | KDE upstream, active (last code change 2026-07-23); Kirigami look | **Reference, and the fallback** if the owner prefers C++/QML (§2.3) |
| **(b6) cosmic-utils/camera** | Rust, libcosmic/iced with wgpu; **libcamera-rs 0.7.0 natively** (ViewFinder plus Raw), GPU debayer and filters, JPEG via `turbojpeg`, EXIF via `little_exif`, DNG, pinch-to-zoom (digital), multi-camera switching, hotplug, "for desktops and phones alike" | Closest existing match. Needs lens grouping and a zoom-driven switch, full-res stills, tap to focus and phone tuning | Very large (about 90k lines, 885 crates in `Cargo.lock`, about 57 MB aarch64 tarballs); one main author; COSMIC look | **Evaluate first (§2.4)**, then decide whether to contribute instead of build |
| **(c) Our own app** | Everything libcamera can do on our hardware, designed around one-stream-at-a-time | §6: about 18-23 days to a first release with zoom and stills, about 30-40 days to the full set | Ours. A small codebase (target under 10k lines) | **Chosen**, in Rust with gtk-rs (§2.3) |

### 2.2 Snapshot in more detail

Snapshot is Rust and GTK, the same stack as our recommendation, so it is worth separating what it *can* take from what it can't.

- **Accepted upstream, likely:** client-side digital zoom in the viewfinder (#201 asks for it); honouring `api.libcamera.rotation` (#364); the soft-ISP mirror fix (#360). These help every phone running Snapshot, ours included, and are worth sending regardless of our app (Q8).
- **Unlikely upstream:** grouping the four nodes into one zoomable "rear camera" with a phone-specific lens table; a second still stream (PipeWire can't provide it); per-request focus and exposure controls. The project describes itself as "Take pictures and videos on your computer, tablet, or phone". We could not read the maintainers' issue comments without logging in, so we don't know their stated scope. Ask before assuming (Q8).
- **What we reuse:** the shape of Snapshot's GStreamer video recording, and its GTK patterns. Its code is GPL-3.0-or-later and could be copied only if our app is GPL-3.0-compatible (Q2).

### 2.3 Our own app: which language and toolkit

The owner asked whether Rust can meet all our needs. It can. These are the four candidate stacks:

| | **Rust + GTK 4/libadwaita (gtk-rs)** | **Rust + Qt/QML (cxx-qt)** | **C++ + Qt6/QML** | **Rust + Slint / iced / libcosmic** |
| --- | --- | --- | --- | --- |
| libcamera binding | libcamera-rs 0.7.0 (MIT/Apache) | libcamera-rs | libcamera's own C++ API, no binding layer | libcamera-rs |
| Zero-copy display of soft ISP frames | `gdk::DmabufTextureBuilder` (gtk4-rs feature `v4_14`, `build_with_release_func` since 0.9.0, 2024-07-10). The release callback requeues the request. Shown in a `gtk::Picture`/`GraphicsOffload`. `set_fd`/`build` are `unsafe` | **Not in cxx-qt-lib** (no `QVideoSink`, `QSGTexture` or image provider). We would write C++ glue: a `QQuickItem::updatePaintNode` wrapping an EGLImage as a `QSGTexture`. So the most delicate part is C++ anyway | The same `QQuickItem`/EGLImage path, or `QVideoSink` with `QVideoFrame` from a dmabuf; all native C++ | Slint: `BorrowedOpenGLTextureBuilder` (1.2+), so EGL import is ours. iced: wgpu custom shader, no public dmabuf import. libcosmic: iced fork |
| Pinch, tap and long-press | `GestureZoom`, `GestureClick`, `GestureLongPress`, `GestureDrag` built in | QML `PinchHandler`, `TapHandler` | QML handlers | Slint `ScaleRotateGestureHandler` since 1.16.0 (2026-04-16); iced: raw touch events, pinch hand-written (winit PR #3656 closed unmerged) |
| Proven on this phone | **Snapshot (gtk-rs, libadwaita) runs on it today**, touch included. Mesa 0002 fixes the GTK GL-texture export crash after photos | Quickshell is QML, but no cxx-qt app has run here | Quickshell (QML) | Nothing |
| Look and feel | libadwaita's adaptive widgets (bottom sheets, breakpoints). Omarchy colours via a CSS provider generated from the theme's `colors.toml`. A camera app is mostly a full-screen viewfinder with our own overlays, so the toolkit's look shows only in settings | QML like the shell, **but a separate app can't import `qs.Commons`**, so the theme still has to be read from `colors.toml` | As cxx-qt | Own styling; libcosmic follows COSMIC |
| Safety | Rust owns the request and buffer lifecycle (the hard part of a camera app). `unsafe` sits in libcamera-rs and the one dmabuf call | Rust core, but C++ glue in the render path, plus the bridge | All C++. Request and buffer lifetimes are by convention, as Plasma Camera and qcam do it | Rust |
| Maturity of the binding/toolkit | gtk4-rs mature (MIT). libcamera-rs "experimental", slow merges (last 2026-02-25), known fd leak in `OwnedFrameBuffer::new` (PR #88), `ActiveCamera` not `Send` (#86) | cxx-qt README: "early development, API changes frequently" | Qt mature | Slint mature, licence choice; iced pre-1.0 |
| Contributor appeal | High (Rust, GNOME stack) | Medium (three languages) | Medium | Medium |
| Build | Rust under qemu is slow (§5.3). Snapshot installs at 4.5 MB | Rust plus host Qt tools (moc, qmlcachegen); the hardest to cross-build | Fast, sub-MB binary on shared Qt | Rust; iced/wgpu dependency trees are large |
| Effort to our first release | Baseline | +20-30 % (bridge, C++ video item, cxx-qt churn) | About the same as gtk-rs; less binding work, more lifetime care | +20 % (custom gestures, own EGL import) |

**Recommendation: Rust with gtk-rs and libadwaita.**

1. **Safety where it matters.** A camera app's bugs are lifetime bugs: requeuing a request while the GPU still reads its buffer, leaking dmabuf fds across reconfigurations (the libcamera-rs leak is exactly this kind), or using a camera after release. Rust's ownership model expresses these rules. `DmabufTextureBuilder`'s release callback is the one point where GTK hands a buffer back.
2. **The display path is a supported toolkit API**, not glue we write in a second language. With cxx-qt, the zero-copy video item would be C++ anyway.
3. **It already works on this phone.** Snapshot is gtk-rs and libadwaita with touch on Hyprland. The Mesa fix in progress (0002, panfrost image BOs not private on panthor) is the one GTK-specific bug we know of.
4. **The look gap is smaller than it seems.** QML wouldn't give us the shell's components either (no `qs.Commons` outside Quickshell). The viewfinder UI is our own drawing in either toolkit. Settings use libadwaita's mobile patterns, coloured from Omarchy's theme.
5. **Contributors.** Rust and GTK are the common ground of mobile Linux apps today (Snapshot, Loupe, cosmic-camera, Megapixels' GTK 4 UI).

**When C++/QML would be better instead:** if the owner wants the camera to *look* like the shell's QML surfaces, or to borrow Plasma Camera's code (GPL-3.0-or-later). The architecture in §3 carries over one-to-one; only the UI layer and the binding change. Not recommended: cxx-qt (two bridges, early API) and Slint/iced (hand-made gestures and texture import, no proof on this phone).

**libcamera-rs risk and mitigation:** we pin 0.7.0 (it builds against 0.7.2 with the 0.7.0 control set through its caret version match). We carry its open fixes (PR #88's fd leak and the `bytes_used` issue #85) as patches in our package, and send what we change upstream. Controls newer than 0.7.0, and our own (none planned), are reachable through `set_raw`. If the crate stalls, our core crate's `Camera` trait (§3.1) isolates it, and the fallback is a thin C++ shim of our own, as `libcamera-sys` already is.

### 2.4 Evaluate cosmic-utils/camera first (phase P0)

It has most of what we would write: libcamera-rs in production, a ViewFinder plus Raw stream negotiation, a GPU debayer, JPEG/EXIF/DNG writers, pinch-to-zoom and multi-camera hotplug. Before writing our own, install it on the phone (its aarch64 release tarball, or a local build) and record:

- whether it starts on Hyprland on the phone and whether wgpu runs on panthor (Vulkan through PanVK or GL);
- the frame rate and CPU at 2016x1136 with our soft ISP, and whether it uses the GPU debayer or its own on the Raw stream;
- touch, rotation, switch time between cameras, and photo quality against Snapshot's.

**Decision rule:** if it runs well, and its author is open to lens grouping, a zoom-driven switch and phone layouts (ask, Q9), contributing may be cheaper than building. We would still own a phone-specific lens table. If it doesn't run, or the answer is no, we build our own and read its libcamera backend as a reference. It is GPL-3.0-only, so we can't copy from it into an MIT app (Q2).

---

## 3. Architecture (recommended option)

Working name `omacam`, to settle in Q1. Two crates in one workspace under `apps/omacam/` (or its own repository, Q3):

```
omacam-core (no UI; unit-tested on the laptop)
  ├─ CameraBackend trait ─┬─ LibcameraBackend (libcamera-rs)
  │                       └─ MockBackend (synthetic frames, scripted metadata; tests)
  ├─ LensTable           per-camera FOV, zoom factor, modes, AF, rotation, mirror (from a TOML)
  ├─ ZoomPlanner         zoom value -> (camera, crop rect); thresholds, hysteresis
  ├─ SwitchController    the fast lens switch state machine (§3.4)
  ├─ CaptureController   still sequence: lock 3A, reconfigure, capture, restore (§3.3)
  ├─ Exposure transfer   EV, gain and exposure mapping between cameras
  └─ Writers             JPEG (turbojpeg) + EXIF (little_exif), later DNG; file naming
omacam (GTK 4 / libadwaita)
  ├─ Viewfinder          GdkDmabufTexture per completed request, crop via a GskTransform/clip
  ├─ Controls            zoom pills + slider + pinch, shutter, mode switch, flip, thumbnail
  ├─ Gestures            GestureZoom, GestureClick (tap to focus), GestureLongPress (AE/AF lock)
  └─ Services            SensorProxy (orientation), GeoClue, canberra (shutter sound)
```

### 3.1 libcamera usage

- **One `CameraManager` per app run, released when the app goes to the background** (§3.8). While a camera manager runs, libcamera keeps the lens subdevs open, and the AK7375 VCMs stay powered (CAM5.3 note). PipeWire's camera monitor already does this today. Measuring it belongs in POWER-PLAN.
- **Lens table** (`/usr/share/omacam/cheetah.toml`, overridable in `~/.config/omacam/`): cameras matched by libcamera id (the DT path `cam -l` prints, as WirePlumber matches them). For each: role (`ultrawide`/`main`/`tele`/`front`), FOV, the zoom factor relative to the main, preview and still modes, focus capability, and the measured centre offset for alignment (§3.4).
- **Viewfinder configuration:** one processed stream, `StreamRole::ViewFinder`, **XRGB8888** (not RGB888: a 24-bit format is a poor EGL import target, and 32-bit linear XRGB8888 is the safe one on panfrost [I]; check in P2), at the camera's preview mode (main 2016x1136, ultrawide 2008x1508, tele 2016x1512, front 1912x1080 or 1920x1368), at 30 fps. Four buffers.
- **Requests are reused** (`Request::reuse(REUSE_BUFFERS)`). A request is requeued only after GTK's texture release callback, never earlier.
- **Per-request controls:** `AfMode`/`AfTrigger`, and later `AfWindows`, `ExposureValue`, `ExposureTime`/`AnalogueGain` (bracketing), `ColourGains`. Metadata read per frame: `ExposureTime`, `AnalogueGain`, `DigitalGain`, `ColourGains`, `ColourTemperature`, `AfState`, `LensPosition`, `SensorTimestamp`. These feed the switch transfer, EXIF and the UI.
- **Properties:** `Rotation` (main 90, ultrawide 270, telephoto 90, front 90 since CAM5.4), `Location` (front/back), `PixelArraySize`, `Model`.

### 3.2 Display path

- Each completed request's plane fd goes to `gdk::DmabufTextureBuilder` (fourcc XRGB8888, `DRM_FORMAT_MOD_LINEAR`, stride from the stream configuration). It is shown in a `gtk::Picture`. The release callback hands the request back to the core, which requeues it.
- **Zoom within a lens is a crop of the texture** (a GSK transform and clip), not a libcamera `ScalerCrop`. The soft ISP doesn't apply one (§1.1). A crop costs nothing on the GPU, and the still path applies the same rectangle to the full-resolution frame.
- **Rotation:** the preview is rotated by the camera's `Rotation` in the same transform. The UI stays portrait, as stock does: only the icons rotate with the phone's orientation (from SensorProxy).
- **Dependencies:** Mesa 0002 (in progress) for GTK's own GL texture export, which crashed Snapshot after photos. The import of foreign dmabufs is a different path and needs its own check in P2. If it fails, the fallback is `MemoryMappedFrameBuffer` plus a `gdk::MemoryTexture` (one CPU copy of about 9 MB a frame: workable at 30 fps on an X1/A78, but it costs battery).
- **Frame pacing:** the panel runs at 120 Hz and the cameras at 30, so the app redraws only on a new frame. While the panel is off (gs-decon `screen_off`) or the app is hidden, it stops streaming entirely.

### 3.3 Full-resolution stills from a separate configuration

The soft ISP gives one processed stream, so a still is a **short reconfiguration into the large mode**, not a second stream:

1. **Shutter pressed.** Freeze the last preview frame on screen (the "capture" animation). Lock 3A: read the latest `ExposureTime`, `AnalogueGain`, `DigitalGain` and `ColourGains` from metadata. If AF is continuous, wait for `AfState` Focused (at most 500 ms) and read `LensPosition`.
2. Stop and reconfigure: ViewFinder role at the camera's still mode (main 4080x3072, telephoto 4032x3024, front 3840x2736, ultrawide 4032x3016 once its WDMA rule lands, else 2008x1508). Add a **Raw stream too** when DNG is on. Two buffers each.
3. Start with the locked values as manual controls (`ExposureTime`, `AnalogueGain`, `LensPosition`, `ColourGains`), discard frames until the metadata shows them applied (the sensor's two-frame delay from our sensor properties), then keep **one** frame (or N for bracketing).
4. Reconfigure back to the preview mode with the same values as the start point, so the preview resumes at the same brightness, then return 3A to auto.
5. Off the UI thread: crop to the zoom rectangle, encode with libjpeg-turbo (`turbojpeg` crate, NEON), apply the orientation with turbojpeg's **lossless transform** (so the file is upright and EXIF Orientation is 1), write EXIF and the file, and update the thumbnail.

Expected cost on the main camera: two reconfigurations plus 2-4 frames at about 9 fps (the WDMA limit). Roughly 0.5-0.8 s with the preview frozen [I, measured in P3]. Stock is instant thanks to zero shutter lag. Two things would shorten it, both kernel or ISP work (§4): lifting the 400 MB/s line limit (CAM-M.5l follow-up 3) so the large mode runs at 30 fps, and a soft ISP that can downscale, so the preview can run from the large mode. With both, a still becomes "keep the next full frame", with no reconfiguration.

**Quick mode** (a setting, and the default for burst): the still is the preview frame at preview resolution, as Snapshot does it, but uncapped by 1080p and with a crop at the preview's resolution.

### 3.4 Zoom, lens switching and a fast handoff

**Zoom factors from field of view.** For a rectilinear lens, zoom relative to the main is z = tan(FOV_main/2) / tan(FOV_x/2) (diagonal FOVs from Google's spec page; 35 mm equivalents from f = 43.27 / (2 tan(FOV/2))):

| Camera | Diagonal FOV (Google) | Aperture, pixel | Zoom vs main | 35 mm equivalent (derived) | Stock's label |
| --- | --- | --- | --- | --- | --- |
| Ultrawide | 125.8° | f/2.2, 1.25 µm | **0.45x** | about 11 mm | 0.5x |
| Main | 82° | f/1.85, 1.2 µm, 1/1.31" | 1.0x | about 25 mm | 1x |
| Telephoto | 20.6° | f/3.5, 0.7 µm | **4.78x** | about 119 mm | 5x |
| Front | 92.8° | f/2.2, 1.22 µm | (0.84x) | about 21 mm | |

The stock HAL's static focal lengths aren't in its tuning protobufs (we checked the APEX's `etc/lib64/camera/*.binarypb`: they are ISP tuning trees, and the focal lengths live in code). So these values are derived from the published FOVs and must be **calibrated on our own frames** (P4): a printed target at a fixed distance, photographed by each rear camera, gives each mode's real factor *including the mode's crop*. A 16:9 mode crops a 4:3 sensor, and our sensor drivers don't report crop selections yet (§4, K4). Two more effects the calibration measures: the **optical centre offset** between lenses (they sit about 1-2 cm apart, so the switch has to shift the crop to keep the subject still), and the ultrawide's **distortion**, which stock corrects ("lens correction" on Google's page) and we don't yet.

**The zoom control:** pills for 0.5x, 1x, 2x and 5x, a slider that appears while dragging (logarithmic, 0.45x to 15x), and pinch anywhere on the viewfinder. The ZoomPlanner maps a zoom value to a camera and a crop:

| Zoom | Camera | Crop of that camera | Notes |
| --- | --- | --- | --- |
| 0.45-0.99 | ultrawide | z / 0.45 | 0.5x is a 10 % crop |
| 1.0-4.79 | main | z | 2x is a centre crop of the 4080x3072 still (2040x1536, about 3 MP) |
| 4.8-15 | telephoto | z / 4.78 | 15x is a 3.1x crop of the tele; stock's 30x relies on Super Res Zoom, which we don't have |
| (low light, or closer than the tele's minimum focus) | main | z | stock falls back to the main crop; we do the same when the tele's AGC hits its gain ceiling, or (once its lens works) AF fails |

**Hysteresis:** switch up at the threshold, switch back down 6 % below it. Switch only after the pinch or slider has been still for 150 ms, or on a pill tap, so a pinch through 1x doesn't flap between cameras.

**The fast switch** (the SwitchController state machine; the target is under 400 ms from the pinch settling to live frames from the new camera, measured in P4):

1. **Freeze:** keep the current camera's last frame as a texture and keep applying the zoom gesture to it, so the image follows the fingers while the switch runs.
2. **Prepare in advance:** every camera's `CameraConfiguration` is generated and validated when the app starts (no validation during a switch). The cameras are acquired once and kept acquired while the app is in the foreground; libcamera's acquire takes the media device lock, not the power.
3. **Transfer exposure and colour:** the new camera starts with manual controls computed from the old camera's metadata. Exposure is scaled by the aperture ratio squared, (N_new/N_old)² (main to tele: (3.5/1.85)² = 3.6x more light needed), with the pixel-size ratio and the measured sensitivity ratio from the gain models (CAM4.3c, M.6, F.6) applied too. Time is kept under the frame budget, the rest goes to gain, and `ColourGains` is copied. AE and AWB switch back to auto after the first good frame.
4. **Stop the old camera, start the new one.** Sensor power-up and stream start are the fixed cost. CAMERA-PLAN's sensor drivers power the module per stream, so this is the number to measure (P4 also measures it in Snapshot for comparison).
5. **Cross-fade** from the frozen frame, aligned by the calibrated centre offset and zoom, to the first frame whose metadata shows the transferred exposure (at most 3 frames, then cross-fade anyway).
6. **Focus:** the new camera starts with `AfMode` continuous, and the main camera's `LensPosition` is mapped to the other lens's position through each lens's calibration, so the scan starts near the answer.

The "seamless" alternative, streaming two cameras and cross-fading live, needs separate WDMA contexts per link in the kernel, and twice the soft ISP load. It is listed as research (K5), not planned.

### 3.5 Focus and exposure

| Feature | How | Needs |
| --- | --- | --- |
| Continuous AF | `AfMode` continuous (our 0007 "a continuous mode that doesn't hunt") | Works on main and ultrawide; telephoto waits for its lens (CAM-T) |
| Tap to focus | `AfWindows` = tapped region in sensor coordinates (through the inverse of rotation, crop and mode scale), `AfTrigger` start, a focus ring shown until `AfState` settles; long-press locks AE/AF | **libcamera patch L2**: our 0006 uses a fixed centre window. Make it honour `AfWindows` |
| Tap to expose | The app reads the tapped region's mean luma from the displayed frame (on the GPU, or a 64x64 CPU downsample of a mapped buffer) and sets an `ExposureValue` offset that brings it to mid-grey; the offset resets when the scene changes a lot | L1 (`ExposureValue`). No AE metering region control exists in the soft ISP, and this avoids needing one |
| EV slider | `ExposureValue` -2 to +2 in 1/3 steps, as stock's vertical slider beside the focus ring | **libcamera patch L1**: `ExposureValue` in the simple IPA's AGC (scale its target by 2^EV). Small; offer it upstream together with the libipa `AgcAlgorithm` port that landed 2026-08-26 (`b2a20ad89`) |

### 3.6 Memory under the CMA limit

| Use | Size | Buffers | Total |
| --- | --- | --- | --- |
| Preview, 2016x1136 XRGB8888 | 9.2 MB | 4 | 37 MB |
| Raw input of the preview mode (CSIS, RAW10 packed) | about 2.9 MB | 4 (the pipeline's) | 12 MB |
| Still, 4080x3072 XRGB8888 | 50 MB | 2 | 100 MB |
| Raw input at 4080x3072 (5120-byte lines) | 15.7 MB | 2-4 | 31-63 MB |
| Optional raw stream for DNG | 15.7 MB | 2 | 31 MB |
| Peak (still with DNG; the preview buffers freed at reconfigure) | | | **about 230 MB of 618 MB** |

The app sets every stream's `buffer_count` explicitly (libcamera's default of four full-size RGB888 buffers is what failed in CAM-M.5l). It frees preview buffers before allocating still buffers, and logs `CmaFree` at each allocation failure. JPEG encoding works from the mapped still buffer. Its own heap use (the JPEG output, about 5-8 MB) is ordinary memory.

### 3.7 Storage and metadata

- Photos go to `$(xdg-user-dir PICTURES)/Camera/IMG_YYYYMMDD_HHMMSS[_n].jpg`, videos to `$(xdg-user-dir VIDEOS)/Camera/VID_….mp4`, DNGs next to their JPEG. The directories are created on first use.
- **EXIF** through `little_exif` (MIT/Apache, writes Orientation and the GPS IFD) or `kamadak-exif`'s experimental writer (BSD-2-Clause), spliced in with `img-parts` if needed. Fields: Make/Model (from DMI or the DT `model`), DateTimeOriginal with OffsetTime, ExposureTime, ISO (analogue × digital gain × 100, approximate), FNumber, FocalLength and FocalLengthIn35mmFilm (from the lens table), the digital zoom ratio, Orientation 1 (pixels already rotated), and GPS when on. **No serial numbers or device identifiers** (our identifying-data rule).
- **Location tags** are off by default (Q5). When on, the app asks GeoClue for an accuracy level at startup and keeps the last fix while the app is open. GeoClue answers only through an agent: `omamobile-gnss` runs one as a user unit, and the app's desktop id needs a `[omacam]` entry in GeoClue's allow list (AGENTS.md: GeoClue gotcha).
- **The gallery thumbnail** shows the last capture. Tapping it opens the file in the system image viewer (`xdg-open`; `imv` today, Q6).
- **The shutter sound** is `camera-shutter` from the freedesktop sound theme through libcanberra (both on the phone). It respects a mute setting, and plays only when the phone isn't in silent mode (Q7: stock lets you turn it off in most regions).

### 3.8 Integration, permissions and the portal

- **Direct libcamera, not the portal.** The app is a host app (not Flatpak). The seat user's uaccess ACL on `/dev/media*`, `/dev/video*`, `/dev/v4l-subdev*` and the DMA heaps gives it the cameras, as `cam` has them. xdg-desktop-portal's Camera interface, and so our `omamobile.access` sheet, applies only to apps that go through PipeWire (browsers, Snapshot, Flatpaks). It isn't asked for `omacam`. That is the same trust as any host app with device access. If the owner wants the sheet anyway (Q4), the app can call the portal's `AccessCamera` first and ignore the PipeWire remote it doesn't use.
- **Sharing the cameras with PipeWire.** libcamera locks a camera's media device per process when acquired. While `omacam` holds the cameras, a browser's or Snapshot's PipeWire stream on them fails with busy, and the reverse is also true. So the app **releases all cameras and its camera manager when it is hidden**. It uses GTK's toplevel `suspended` state (xdg-shell `suspended`, GTK 4.12+), with a 10 s fallback timer on focus loss. It also releases them when the panel goes off.
- **Packaging:** `packages/omacam` (PKGBUILD with `cargo build --release --locked`, offline vendored crates) and a desktop file with `Categories=AudioVideo;Video;Photography;` and `X-Purism-FormFactor=Workstation;Mobile;`. `omamobile-apps` moves `snapshot` to `optdepends` ("video calls and a second camera app") once `omacam` passes P5. Snapshot stays the camera *portal* app for browsers either way, since `pipewire-libcamera` stays.
- **The shell:** the app grid shows the desktop file. A lock-screen camera shortcut and the double-press of power that stock uses are later shell work (Q10).

### 3.9 Video

- **Recording:** a GStreamer pipeline `appsrc` (the soft ISP's dmabufs, as `video/x-raw(memory:DMABuf)` XRGB8888 or after a GL colour convert) → `videoconvert`/`glcolorconvert` → `x264enc speed-preset=ultrafast tune=zerolatency` (x264 is on the phone; the SoC's MFC has no mainline driver) → `mp4mux`. Audio comes from PipeWire (`pipewiresrc` on the AoC's EP1 capture), in Opus or AAC (a licensing question, Q11). We feed GStreamer ourselves rather than using `libcamerasrc`, which in 0.7.2 still lists "application driven request (snapshot)" and DMABuf support as TODO.
- **Sizes:** 1080p30 from the main camera's 2016x1136 mode (cropped to 1920x1080), and 720p as a fallback if the CPU encoder can't hold 30 fps alongside the soft ISP (measured in P6).
- **Zoom during video** is the crop only, without lens switching while recording, at first (stock does switch).

### 3.10 Testing

- **Core (laptop, no container needed):** unit tests for ZoomPlanner (thresholds, hysteresis, crop maths for every rotation), exposure transfer (aperture and gain ratios, budget clamps), coordinate transforms for tap to focus (screen → texture → sensor across rotations 90/270 and mirroring), EXIF content (read back with `kamadak-exif`), file naming, and the switch and capture state machines driven by the MockBackend with scripted metadata delays.
- **libcamera integration (container):** libcamera's `vimc` or virtual pipeline handler [I: which of these works in a container is checked in P1] behind the real LibcameraBackend, to exercise configure, reconfigure, buffer counts and request reuse. The buffer lifecycle runs under `valgrind`/ASan-instrumented libcamera for leaks (the fd leak in libcamera-rs PR #88 is the kind we want caught).
- **UI (container, never on the laptop's desktop):** GTK under a headless compositor inside the container (`weston --backend=headless` or `cage` with wlroots' headless backend; AGENTS.md and memory forbid nested Hyprland on the laptop), the MockBackend feeding synthetic frames, scripted gestures through GTK's test API, and screenshots per theme compared by eye. The same approach as WIDGET-INTEROP-PLAN §7.2.
- **Phone runbooks** (§6): userspace only, announced before they run (the app turns cameras on; the shutter sound plays; P8's flash uses the LM3644).

---

## 4. Feature set against what our hardware supports

**Legend:** **Today** works with libcamera 0.7.2-4.6 and today's kernel; **App** is app work only; **L** needs a libcamera patch (ours, offered upstream); **K** needs kernel work (CAMERA-PLAN).

| Feature (stock Pixel) | Status | Work |
| --- | --- | --- |
| One zoom control 0.5x → 1x → 2x → 5x → digital | App | §3.4; FOV calibration (P4); centre offsets |
| Automatic lens switching with a smooth handoff | App (fast switch); seamless is K5 | §3.4 |
| Pinch to zoom | App | `GestureZoom` |
| Tap to focus | L2 (`AfWindows`) | Main and ultrawide; telephoto needs K3 |
| Tap to expose, exposure compensation | L1 (`ExposureValue`) | §3.5 |
| Full-resolution stills from a separate configuration | App, today's modes | §3.3; main 12.5 MP at about 9 fps capture; ultrawide full res needs K1 |
| Fast full-resolution stills (no reconfigure) | K2 and L5 | Lift the 400 MB/s WDMA line limit; a soft ISP downscale |
| Photo and video modes | App (§3.9) | x264 on the CPU; measure |
| Front/back flip | Today | Mirror the front preview, not the file (setting) |
| Gallery thumbnail, shutter sound | App | §3.7 |
| Location tags | Today (GeoClue + agent) | §3.7; allow-list entry |
| Sharp telephoto | K3 | SEM1215SA power order (CAM-T next step 1) |
| Ultrawide distortion correction | App (a GPU warp from our own checkerboard calibration) | Later; matters most near the 1x handoff |
| RAW (DNG) | Today (Raw stream beside the processed one) | DNG writer: a Rust `dng` crate or `libdng` (Megapixels', licence to check) |
| Flash for stills | Today (LM3644 works as the torch) | Pre-flash for 3A, fire on the still frame; announce before testing |
| HDR (bracketing and merge) | App + L | Per-request manual `ExposureTime`/`AnalogueGain` (honoured by the simple IPA [I]), 3 frames in the still mode, merged on the GPU with alignment. At about 9 fps in the main's large mode a 3-frame bracket takes 0.33 s, so handheld alignment is needed: K2 helps a lot |
| Night (multi-frame) | App + L, K2 | 6-15 frames of the binned mode at long exposure, aligned and averaged; denoise helps more (L6) |
| Portrait (background blur) | Research | No depth sensor path; dual-camera depth is impossible without K5; a segmentation model (ML, licence and size) only. Out of scope for this plan |
| Better base picture quality | L6, colour calibration | Lens shading and denoise in the soft ISP; our own colour matrices (CAMERA-PLAN 7.Q) |

**Kernel items** (to add to CAMERA-PLAN, one per boot as always):

- **K1:** the IMX386 gets `samsung,max-line-throughput`-style line lengthening, so its 4032x3016 mode lands (CAM-M.5l notes the same failure).
- **K2:** whether the 400 MB/s limit is a WDMA QoS or burst setting (CAM-M.5l follow-up 3). Lifting it brings the main's large mode from 9 to 30 fps, which is the biggest single gain for stills, HDR and switch time.
- **K3:** the telephoto lens (CAM-T T.3/T.6).
- **K4:** sensor crop selections (V4L2 selection API), so libcamera knows each mode's crop: exact zoom factors per mode, and `ScalerCropMaximum`.
- **K5 (research):** one WDMA context per link, for two cameras at once (EBUF, DVFS and interrupt sharing are why they share context 0 today).
- **K6:** AK7375 runtime PM tied to streaming, so a running camera manager doesn't keep the lenses powered.

**libcamera items** (in `packages/libcamera`, each offered upstream):

- **L1:** `ExposureValue` in the simple IPA AGC.
- **L2:** `AfWindows` in our AF (generalise 0006's fixed centre).
- **L3 (optional):** honour `ExposureTime`/`AnalogueGain`/`ColourGains` given at `start()` as the AGC/AWB starting point. Check first whether 0008 already covers this across cameras (it covers reconfiguring the same mode).
- **L4 (optional):** `ScalerCrop` applied in the soft ISP (debayer only the crop: less GPU work at high zoom).
- **L5:** a soft ISP output smaller than its input (downscale), for preview from a large mode.
- **L6:** lens shading and denoise (upstream direction; quality).

---

## 5. Build, licence and packaging

### 5.1 Licence of our app (Q2)

- **MIT** (our repository's default) works with every dependency: libcamera is LGPL and linked dynamically, gtk4-rs and libadwaita-rs are MIT, GTK and libadwaita are LGPL, libcamera-rs is MIT/Apache, turbojpeg is Unlicense/MIT, little_exif is MIT/Apache, GStreamer is LGPL. But we may only *read* GPL code (Snapshot, cosmic-camera, Plasma Camera, Megapixels), not copy from it.
- **GPL-3.0-or-later** would let us copy from Snapshot and Plasma Camera (and from cosmic-camera, which is GPL-3.0-only, only if we're GPL-3.0-only too). It would also make contributing back simpler.

### 5.2 JPEG and EXIF choices

| Need | Choice | Licence | Why |
| --- | --- | --- | --- |
| Encode | `turbojpeg` 1.5.1 (libjpeg-turbo 3.2.0 on the phone) | Unlicense OR MIT; libjpeg-turbo BSD-3-Clause/IJG | NEON. `jpeg-encoder` 0.7.1 has AVX2 SIMD only, so it runs scalar on aarch64. Lossless rotate (`tjTransform`) included |
| EXIF write | `little_exif` 0.6.23 | MIT OR Apache-2.0 | Writes Orientation and GPS. Fallback: `kamadak-exif` 0.6.1's `experimental::Writer` (BSD-2-Clause) |
| C equivalents, for comparison | libexif 0.6.26 (LGPL), exiv2 0.28.9 (GPL-2.0-or-later) | | exiv2's licence would force GPL |

### 5.3 Building Rust for aarch64

`tools/build-packages` builds inside an Arch Linux ARM container under qemu-user. rustc under qemu is slow, often tens of minutes for a GTK app [I: measured in P1]. Options, in order:

1. **Cross-compile in the container:** an x86_64 rustc with the `aarch64-unknown-linux-gnu` target and `aarch64-linux-gnu-gcc` (Arch `extra`), against an ALARM sysroot holding gtk4, libadwaita and libcamera. Set `PKG_CONFIG_SYSROOT_DIR`/`PKG_CONFIG_ALLOW_CROSS=1`. `libcamera-sys` needs `BINDGEN_EXTRA_CLANG_ARGS="--sysroot=… --target=aarch64-linux-gnu"` and the same sysroot for its C++ shim. cosmic-camera cross-builds with cross-rs, which shows it works.
2. Build under qemu as other packages do, with `sccache` and vendored crates, if P1 measures it as tolerable.
3. The phone build (`tools/phone-install-package`), only as an opt-in accelerator (builds are local by default).

The dependency tree stays small: gtk4, libadwaita, libcamera, gstreamer, turbojpeg, little_exif, zbus (SensorProxy), geoclue (via zbus) and libcanberra (through a tiny FFI or `canberra-gtk-play`). Expected size: a few MB installed, as Snapshot's 4.5 MB.

---

## 6. Phases, estimates and runbooks

One developer, estimates in working days. The human approves every phone step. No phase reboots or flashes anything except the kernel items in §4, which follow CAMERA-PLAN's own runbooks. Every phone step is a package install and app run, **announced first** (cameras on, shutter sound, flash).

| Phase | Work | Effort | Exit criteria |
| --- | --- | --- | --- |
| **P0** Decide and evaluate | Owner answers Q1-Q4. cosmic-camera on the phone (§2.4). Baselines in Snapshot: switch time between cameras, CPU, preview fps | 1-2 d | Decision recorded here: build, or contribute to cosmic-camera |
| **P1** Skeleton | Workspace, `omacam-core` with the MockBackend, the libcamera-rs pin with our patches (PR #88 fd leak, #85), packaging and the aarch64 build path (§5.3), the libcamera virtual/vimc test in the container, CI for core tests | 3-4 d | `cargo test` passes; the package builds for aarch64 in a measured time; the vimc/virtual integration test runs |
| **P2** Viewfinder | One camera, XRGB8888, dmabuf import into GTK, rotation, release when hidden and with the panel off, camera picker | 3-4 d | Phone: main camera preview at 30 fps, CPU below Snapshot's, no fd growth over 10 min (`ls /proc/PID/fd \| wc -l`), the camera usable by Snapshot after `omacam` is hidden |
| **P3** Stills | §3.3 capture sequence, JPEG+EXIF, storage, thumbnail, shutter sound, quick mode | 4-5 d | 4080x3072 JPEGs from the main camera, upright, EXIF readable, about 1 s shutter-to-preview or better; no CMA failure in 50 captures |
| **P4** Zoom and lens switching | Lens table, FOV and centre calibration (target photos), ZoomPlanner, the pill/slider/pinch UI, SwitchController with exposure transfer and cross-fade | 6-8 d | Pinch from 0.5x to 10x and back crosses both handoffs without a black frame; switch time measured (target under 400 ms) and compared with Snapshot's; brightness step at the handoff under about 1/3 EV |
| **P5** Focus and exposure | L1 and L2 libcamera patches (with `packages/libcamera` tests), tap to focus and expose, AE/AF lock, EV slider | 4-5 d | Tap on a near subject focuses it (main, ultrawide); EV ±2 changes the exposure as expected; patches sent upstream |
| **P6** Video | GStreamer recording, audio, 1080p/720p | 5-7 d | 5 min of 1080p30 (or 720p30) without dropped frames, audio in sync, the phone not overheating (thermal zones logged) |
| **P7** Release | Front/back flip and mirroring, location tags, settings, accessibility labels, translations scaffold, default app in `omamobile-apps`, README and docs | 3-4 d | The owner uses it as the default camera for a week |
| **P8** Later | HDR bracketing (8-12 d), night mode (5-8 d), DNG (2-3 d), flash (2 d), distortion correction (3-4 d), lock-screen shortcut (shell) | | Each its own runbook |

**Totals:** P0-P4 (a first release with zoom, lens switching and full-res stills): **about 17-23 days**. P0-P7: **about 29-39 days**. The kernel items K1-K4 run in parallel in CAMERA-PLAN. K2 is the one that changes the user experience most.

### 6.1 Phone runbook template (P2 as the example)

```sh
# P2.0 (laptop) build and install. Announce first: "camera app test, the main camera turns on"
tools/phone-install-package packages/omacam        # or the local aarch64 package
#   expect: omacam installed; no other package changed
# P2.1 the app lists the cameras (read-only: no stream)
tools/phone-ssh 'sudo -u <user> omacam --list'
#   expect: four cameras with the lens table's roles; stop: fewer than four (check cam -l first)
# P2.2 preview for 60 s, then hide the app (the human switches away)
#   record: fps (app overlay), CPU (top -b -n1), fd count every 10 s, CmaFree before and after
#   pass: 30 fps, CPU at or below Snapshot's, fd count flat, CmaFree back to its start value
#   stop: a GPU error in dmesg (panthor), an fd count that grows, a WDMA error
# P2.3 hand-over: open Snapshot while omacam is hidden
#   pass: Snapshot previews the main camera within 2 s
# Rollback: pacman -R omacam (nothing else changed)
# Risk: low (userspace; the cameras are already used daily through Snapshot)
```

### 6.2 Risks

| Risk | Mitigation |
| --- | --- |
| **The dmabuf import into GTK fails on panthor** (format, modifier or the Mesa bug) | P2 tests it first. Fallback: one mapped copy into a `MemoryTexture`, then fix Mesa |
| **Switch time is far over target** (sensor power-up, AGC settling) | The frozen-frame and transfer design hides most of it. If sensor power-up dominates, keep the sensor powered between streams (a driver option, K-item, power cost to measure) |
| **Full-res still latency** (9 fps, reconfiguration) | Quick mode as a fallback; K2 and L5 remove the reconfiguration |
| **libcamera-rs stalls or breaks with libcamera 0.8** | Pinned, patched in our package; the backend trait isolates it; a thin C++ shim of our own is the fallback |
| **Rust build time under qemu** | Cross-compilation (§5.3) |
| **cosmic-camera turns out to be the better base** after P0 | P0 decides it before anything is written |
| **Upstream libcamera rejects L1/L2 in our form** | They stay in our package. The upstream direction (libipa AGC/AF) is followed when it lands |
| **The PipeWire and libcamera camera lock** blocks browsers while `omacam` runs | Release when hidden or with the panel off (§3.8); P2.3 tests it |
| **Users expect stock's image quality** | Say so in the README: no HDR+ and no Google tuning. CAMERA-PLAN 7.Q lists what can improve and the honest ceiling |

---

## 7. Questions for the owner

| # | Question |
| --- | --- |
| Q1 | **Name.** `omacam` as the working name? The user-visible name could just be "Camera". |
| Q2 | **Licence.** MIT like the rest of our tree (we read GPL apps but copy nothing), or GPL-3.0-or-later, so we can reuse code from Snapshot and Plasma Camera and contribute more freely? |
| Q3 | **Where it lives.** A directory in this repository (`apps/omacam` + `packages/omacam`), or its own repository so other distributions (postmarketOS, Mobian) can package it? |
| Q4 | **Permission sheet.** Direct libcamera skips the portal and our `omamobile.access` sheet, as `cam` and every host app do. Is that fine, or should the app ask through the portal's `AccessCamera` once anyway for consistency? |
| Q5 | **Location tags:** off by default, with a toggle (our proposal), or on? |
| Q6 | **Gallery.** The thumbnail opens `imv` today. Do you want a phone gallery (GNOME Loupe isn't installed), or is a minimal in-app viewer of the last shots (swipe, delete, share) better? |
| Q7 | **Shutter sound:** always on, or follow a silent mode and a setting? |
| Q8 | **Snapshot upstream.** Shall we send Snapshot the client-side zoom (#201), the rotation (#364) and mirror (#360) fixes anyway, since Snapshot stays the camera for browsers and video calls? |
| Q9 | **cosmic-camera.** May we contact its author about lens grouping and phone layouts before deciding (P0)? |
| Q10 | **Quick launch.** A lock-screen camera button, and a double-press of power to open the camera as stock does? Both are shell work. |
| Q11 | **Video audio codec.** Opus in MP4/MKV (free) or AAC (wider playback, patent-encumbered encoders)? |
| Q12 | **Stack.** We recommend Rust with GTK 4/libadwaita. If matching the shell's QML look matters more to you than the reasons in §2.3, the fallback is C++/QML (Plasma Camera as a reference). Which do you prefer? |
