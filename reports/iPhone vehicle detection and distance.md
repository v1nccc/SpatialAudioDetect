# Upgrade the detector, let geometry measure distance

Replace Apple's YOLOv3 with Ultralytics **YOLO26s** exported to Core ML at a larger rectangular input. Take Depth Anything out of the live distance path. Measure range with geometry instead: a class-height prior fused with a LiDAR-referenced ground plane, smoothed by a Kalman filter, with warnings driven by box-scale time-to-contact (TTC). That is the only combination with evidence behind it at 5–50 m on a phone. YOLO26s scores **48.6 COCO mAP and 29.5 small-object AP**, against YOLOv3's 28.2 mAP. It is also the only modern detector with a first-party Core ML export and measured iPhone 17 Pro Neural Engine timings. RF-DETR-S (Apache-2.0, 32.0 small-object AP) is the right pick only if the app must stay closed-source without a paid Ultralytics licence, and its Neural Engine speed is unproven. D-FINE and DEIMv2 are ruled out: neither has a Core ML exporter, D-FINE breaks in naive FP16, and DEIMv2 has a custom licence. No monocular depth network, from Depth Anything V2 or 3 to Metric3D v2, UniDepth v2 or Depth Pro, has published evidence of accurate metres for vehicles at 5–50 m from a phone. The current LiDAR-fitted extrapolation can turn a true 40 m into anything from 29 to 67 m. Most false positives come from the tracker's gates, not the network. One 0.3-confidence box starts a track, "person" can raise a warning, and a hand over the lens throws away LiDAR and reads as a vehicle about a metre away. Gating fixes these at no compute cost. The JOIV YOLOv8 paper validates distance only below 5 m, and its method is no better than the pinhole formula the app already uses. With these changes I estimate distance error of about **±5% at 10 m, ±7–9% at 20 m and ±10–17% at 40 m at roughly 20–30 fps**. These are derivations that the field test at the end must confirm. YOLO26 is AGPL-3.0 right down to fine-tuned weights: that suits an open-source challenge entry, but a closed App Store release needs an Enterprise licence.

*Reading the numbers:* a figure followed by a citation is published or measured. A figure marked **(est.)** is my own derivation from the cited equations, scaling rules or stated assumptions. None of them has been measured on this app's body-worn setup.

## Five design choices in the prototype explain most of its errors

**The detector.** The app stretches the whole upright camera frame into the square input of Apple's YOLOv3 Int8 model using `.scaleFill`. It keeps any box whose top label reaches **0.3 confidence**, with the same threshold for every class ([CameraRadar.swift](../SpatialAudioDetect/CameraRadar.swift)).

**The tracker.** It starts a new track from every unmatched detection. It tracks `person` alongside car, motorbike, bicycle, bus and truck. It lets the label switch whenever a new box is nearly as confident as the last one, and drops a track after 0.7 s unseen ([VehicleTracker.swift](../SpatialAudioDetect/VehicleTracker.swift)).

**Distance.** When the LiDAR median inside the box falls between 0.2 and 5 m, that median is the distance. Otherwise distance is `focal × class height ÷ box height`, with car at 1.5 m and motorbike-plus-rider at 1.45 m. Depth Anything V2 Small runs every third frame and is refitted every frame as `value = a/z + b` against LiDAR pixels at 0.4–5 m, then extrapolated to farther pixels. Its output is logged but is not used for warnings ([DepthModel.swift](../SpatialAudioDetect/DepthModel.swift); [CameraRadar.swift](../SpatialAudioDetect/CameraRadar.swift)).

A warning fires in one of two cases. The first is when time-to-reach is under 3 s and the lateral offset is within 2 m. Time-to-reach comes from the slope of ln(box size) over 0.6 s and needs at least five samples. The second is when LiDAR shows something within 3 m closing faster than 1 m/s ([VehicleTracker.swift](../SpatialAudioDetect/VehicleTracker.swift)).

Two consequences follow from this structure:

- **The warning trigger is already the right one.** Box-scale TTC needs no size prior, camera height or pitch. Distance error reaches the warning only through the lateral gate and through what the runner is shown. Lateral offset is image offset × distance, so a 20% range error is a 20% lateral error.
- **The false-positive path is wide open.** A hand or sleeve over the lens gives a LiDAR reading under 0.2 m. The code discards that reading and falls back to box size, and a near-full-frame box then reads as roughly 1 m away **(est., from the code's own formula)**. If that box grows for half a second, it can warn.

The square stretch also distorts every object relative to how YOLO models are trained (letterboxed). And it spends the model's few pixels evenly across sky, ground and road.

## YOLO26s is the strongest detector that demonstrably runs on the Neural Engine

Ultralytics released **YOLO26 in January 2026**. It removes DFL, offers an optional NMS-free one-to-one head, and adds small-target-aware label assignment (STAL). Ultralytics reports CPU inference up to 43% faster than YOLO11n ([Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/)). At every size it beats YOLO11 on COCO: **+1.6 AP at small size, and +3.3 small-object AP at medium size** (33.4 → 36.7) ([YOLO26 paper, arXiv 2606.03748](https://arxiv.org/html/2606.03748v1)). Ultralytics itself labels YOLO12 a community release with "training instability" and slower CPU throughput, kept "for benchmarking and research" ([Ultralytics YOLO12 docs](https://docs.ultralytics.com/models/yolo12/)). Since YOLO11 carries the same licence as YOLO26, there is no reason to choose it.

The DETR family is genuinely competitive on COCO, and its small-object lead shows at small model sizes:

- **RF-DETR-S** (Apache-2.0) reaches **52.9 AP and 32.0 AP_S** at 512 px ([RF-DETR paper, arXiv 2511.09554](https://arxiv.org/html/2511.09554)).
- **D-FINE-S**, pretrained on Objects365, reaches 50.7 AP and 32.6 AP_S ([D-FINE GitHub](https://github.com/Peterande/D-FINE); [arXiv 2511.09554](https://arxiv.org/html/2511.09554)).

| Model | COCO AP | AP_S (small objects) | Params | Core ML path | iPhone evidence | Licence |
|---|---|---|---|---|---|---|
| Apple YOLOv3 (current) | 28.2 mAP @320 px ([arXiv 1804.02767](https://arxiv.org/abs/1804.02767)) | not published | — | Apple gallery | none published | Darknet, public domain ([LICENSE](https://github.com/pjreddie/darknet/blob/master/LICENSE)) |
| YOLO26n | 40.9 | not published | 2.4M | Ultralytics `format=coreml` | **3.2 ms burst / 11.3 ms sustained**, iPhone 17 Pro ([docs](https://docs.ultralytics.com/integrations/coreml/)) | AGPL-3.0 |
| **YOLO26s** | **48.6** | **29.5** | 9.5M | same | none; 10–20 ms sustained **(est.)** | AGPL-3.0 |
| YOLO26m | 53.1 | 36.7 | 20.4M | same | none; 20–40 ms **(est.)** | AGPL-3.0 |
| YOLO11s | 47.0 | 29.0 | 9M | same | none | AGPL-3.0 |
| RF-DETR-N | 48.0 | 25.2 | 30.5M | `rfdetr[coreml]>=1.9.0` | anecdotal ~15 fps FP32, iPhone 14 Pro | Apache-2.0 |
| **RF-DETR-S** | **52.9** | **32.0** | 32.1M | same | none | Apache-2.0 |
| RF-DETR-M | 54.7 | 36.1 | 33.7M | same | none | Apache-2.0 |
| D-FINE-S (O365) | 50.7 | 32.6 | 10M | ONNX/TensorRT only | none | Apache-2.0; O365 weights not cleared |
| DEIMv2-S | 50.9 | not published | 9.7M | ONNX/TensorRT only | none | custom DEIMv2 licence |

Sources: YOLO rows from the [YOLO26 docs](https://docs.ultralytics.com/models/yolo26/) and [arXiv 2606.03748](https://arxiv.org/html/2606.03748v1). RF-DETR and D-FINE AP_S from [arXiv 2511.09554](https://arxiv.org/html/2511.09554). DEIMv2 from its [GitHub](https://github.com/Intellindust-AI-Lab/DEIMv2).

Two caveats shrink the DETR advantage:

- **The protocols differ.** The RF-DETR authors re-measured YOLO11s at 44.1 AP, not 47.0. They argue that YOLO papers measure latency in FP16 while reporting FP32 accuracy, and leave NMS out of the timing ([arXiv 2511.09554](https://arxiv.org/html/2511.09554)). On the published numbers, RF-DETR's real small-object lead is about **2–3 AP_S at "small" size and roughly zero at "medium" size** (YOLO26m 36.7 vs RF-DETR-M 36.1).
- **Parameter counts mislead.** RF-DETR's "nano" carries 30.5M parameters because of its DINOv2 ViT backbone. On a phone it is closer to a YOLO "m" than to a nano.

Deployment, not COCO, separates the candidates:

- **Ultralytics has the mature path.** Its Core ML exporter takes a rectangular `imgsz=(h, w)`, FP16/INT8/W8A16 quantisation, and either embedded NMS (`nms=True`) or the NMS-free head (`nms=False`). Its iOS SDK defaults to CPU+Neural Engine because leaving out the GPU "avoids contention and frame-time jitter" ([Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)). Embedded NMS returns `VNRecognizedObjectObservation`, which is what the app's Vision code already consumes. The detector swap is close to a file replacement plus a check of the label names (the tracker keys on Apple's `"motorbike"`).
- **RF-DETR's path is newer and unproven.** It gained a native Core ML export in `rfdetr[coreml]>=1.9.0`. FP16 is opt-in, "with more numeric drift" ([RF-DETR Core ML cookbook](https://rfdetr.roboflow.com/latest/cookbooks/export-coreml/)). On the iOS 27 beta, a community build found the Core AI runtime still placed RF-DETR's backbone on the GPU even when asked to prefer the Neural Engine ([HF coreai-community/RF-DETR-CoreAI](https://huggingface.co/coreai-community/RF-DETR-CoreAI)). Reported iPhone speeds range from about 10 to a claimed 120 fps ([Reddit snapshot](https://reddit.sentinel-team.org/posts/1uc3qdf/snapshots/2026-06-26T22%3A16%3A49.53411Z)). Roboflow itself lists "some transformer attention mechanisms" as problematic on the ANE ([Roboflow iOS guide](https://roboflow.com/blog/best-ios-object-detection-models)).
- **D-FINE fails on FP16.** Naively converting D-FINE to FP16 "reduces performance to 0.5 AP" ([arXiv 2511.09554](https://arxiv.org/html/2511.09554)). That disqualifies it for an FP16 accelerator unless someone does a careful mixed-precision conversion.

The decision therefore turns on licensing more than accuracy:

- **Open-source app:** use YOLO26s. Step up to YOLO26m only if the frame budget allows.
- **Closed-source app without an Ultralytics Enterprise licence:** benchmark RF-DETR-S on the 17 Pro Max before committing. Accept running it on the GPU if the Neural Engine refuses it.
- **Skip** YOLO11, YOLO12, D-FINE, DEIMv2 and YOLO-NAS. YOLO-NAS's pretrained weights are non-commercial, and its original team no longer maintains it ([Roboflow YOLO-NAS](https://roboflow.com/model-licenses/yolo-nas)).

### Pixels, not architecture, decide whether a motorbike at 40 m is seen

Architecture choice moves small-object AP by a few points, while input resolution changes the object's size in pixels several-fold. The table below assumes a motorbike-plus-rider 0.8 m wide and 1.5 m tall, about 74° across the frame's long side, and the long side mapped to the model input **(est.)**:

| Model input, long side | 10 m | 20 m | 40 m | 50 m |
|---|---|---|---|---|
| 416 px (current) | ~24×48 px | ~12×24 px | ~6×12 px | ~5×9 px |
| 640 px | ~40×76 px | ~20×38 px | ~10×19 px | ~8×15 px |
| 1280 px | ~80×150 px | ~40×75 px | ~20×37 px | ~16×30 px |

At 40–50 m, every row is inside COCO's "small" class (<32×32 px). That is exactly where all detectors are weakest. YOLO26's STAL lifts AP_S by only 0.6 ([arXiv 2606.03748](https://arxiv.org/pdf/2606.03748)). Its P2 small-object head ships as an architecture file with no pretrained weights ([YOLO26 docs](https://docs.ultralytics.com/models/yolo26/)).

**Resolution also sets distance accuracy.** Two pixels of box jitter on a 12 px box is about 17% range error. On a 37 px box it is about 5% **(est.)**.

**Detection range buys warning time.** A motorbike at 50 km/h covers 50 → 10 m in about 2.9 s, so each extra 10 m of detection range buys roughly 0.7 s of warning **(est.)**.

**Cost.** Compute scales with input pixels. A YOLO26s at 1280×720 costs about 47 GFLOPs, against 68 for a YOLO26m at 640 **(est., from published FLOPs)**. That makes "s at high resolution" a better buy than "m at 640" for far targets. Fine-tuning on the app's own rear-camera footage at the deployment resolution should raise far-object recall more than any architecture switch. That is an inference: no per-distance recall study exists for any of these models.

## No depth network yet delivers trustworthy metres beyond LiDAR's 5 m

The current depth trial fails for a structural reason. A least-squares fit of inverse depth is anchored where 1/z runs from 0.2 to 2.5 m⁻¹. A 40 m car sits at 0.025 m⁻¹, almost at zero, where the offset term b dominates. The resulting error grows with the square of distance **(est.)**:

| True distance | Offset error ±0.005 m⁻¹ | Offset error ±0.01 m⁻¹ |
|---|---|---|
| 10 m | 9.5–10.5 m | 9.1–11.1 m |
| 20 m | 18.2–22.2 m | 16.7–25 m |
| 40 m | 33.3–50 m | 28.6–66.7 m |
| 50 m | 40–66.7 m | 33.3–100 m |

An offset error of 0.01 m⁻¹ is only about 0.4% of the span the fit covers, well inside LiDAR noise.

**The fit is imperfect even inside LiDAR range.** Depth Anything V2 aligned to iPhone LiDAR with RANSAC scored **0.137 m RMSE** indoors on ARKitScenes. Prompt Depth Anything, which feeds LiDAR into the network, scored 0.032 m ([Prompt Depth Anything, arXiv 2412.14015](https://arxiv.org/html/2412.14015)).

**On a per-vehicle benchmark it is worse than the size prior.** On KITTI per-object distance, Depth Anything V2 Base and Large reached only **27% abs-rel**. A dedicated distance network reached 10.4% ([DistFormer, arXiv 2401.03191](https://arxiv.org/html/2401.03191)). The Small model in the app is unlikely to do better.

True metric models do far better on driving benchmarks, but none is both accurate and real-time on a phone:

| Model | Zero-shot KITTI δ1 / AbsRel | Mean error at 10 / 20 / 40 m (est.) | Size | Licence | iPhone feasibility |
|---|---|---|---|---|---|
| Metric3D v2 | 0.976 / 0.051 | 0.5 / 1.0 / 2.0 m | ViT-S to 1.38B | BSD-2 | ViT-S has ONNX weights but no published accuracy or iPhone timing |
| UniDepth v2 | 0.968 / 0.076 | 0.8 / 1.5 / 3.0 m | ViT-S/B/L | **CC BY-NC 4.0** | non-commercial; no Core ML |
| DA3-Metric-Large | 0.953 / 0.086 | 0.9 / 1.7 / 3.4 m | 0.35B | Apache-2.0 | ~1–5 Hz **(est.)** |
| Depth Pro | 0.843 / 0.121 | 1.2 / 2.4 / 4.8 m | 504M | Apple sample code | 3.6–4.8 s/frame on an M-series Mac |
| DA-V2 Metric-Outdoor | not published; **nuScenes δ1 17.7%** | not estimable | 24.8M (S) | see note | no Core ML build |

Sources: KITTI columns from the [Depth Anything 3 paper](https://arxiv.org/html/2511.10647). DA-V2 nuScenes figure from the [Depth Pro paper](https://arxiv.org/html/2410.02073). Licences from [Metric3D](https://github.com/YvanYin/Metric3D), [UniDepth](https://github.com/lpiccinelli-eth/UniDepth) and [DA3](https://github.com/ByteDance-Seed/Depth-Anything-3). Depth Pro timing from [mickeyvanolst/depthpro-coreml](https://huggingface.co/mickeyvanolst/depthpro-coreml).

Note on DA-V2 Metric-Outdoor: its checkpoints were fine-tuned only on synthetic Virtual KITTI 2 with an 80 m cap, and the repo publishes no evaluation numbers for the released checkpoints ([DA-V2 metric_depth README](https://github.com/DepthAnything/Depth-Anything-V2/tree/main/metric_depth)). Its 17.7% nuScenes δ1 is the clearest warning that synthetic metric fine-tunes do not transfer to real cameras.

The "mean error" column is optimistic for this app, for three reasons. First, AbsRel is averaged over all KITTI LiDAR pixels, and most of those are near road surface. No source reports error per distance bin, or for vehicles alone at 20–50 m. Second, a δ1 of 0.84 means about 16% of pixels are off by more than 25%. Third, every benchmark uses a car-roof camera at about 1.65 m facing forward ([KITTI setup](https://www.cvlibs.net/datasets/kitti/setup.php)). A bouncing, rear-facing phone at chest height is outside all of them.

The canonical-camera models are the right *kind* of model for a phone, because they consume real intrinsics. DA3 converts its output as `focal × output / 300` ([DA3 GitHub](https://github.com/ByteDance-Seed/Depth-Anything-3)). The app already reads intrinsics from `cameraCalibrationData`. But only DA3's Large model is metric, and at 0.35B parameters it is a periodic cross-check, not a per-frame sensor.

The only proven real-time depth model on Apple silicon is the one already in the app. Depth Anything V2 Small F16 runs in **26.21 ms on an iPhone 16 Pro** and **33.90 ms on an iPhone 15 Pro Max** ([Apple ML models](https://developer.apple.com/machine-learning/models/); [Apple Core ML DA-V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)). It produces relative depth only. Prompt Depth Anything solves LiDAR fusion elegantly indoors, but its authors note iPhone LiDAR is "very noisy" for far objects. Its outdoor results are qualitative only ([arXiv 2412.14015](https://arxiv.org/html/2412.14015)).

The answer to question (2) is therefore no. Today's best monocular metric depth would give about 1 m error at 20 m and 2–3.5 m at 40 m on in-domain car cameras, from models that run a few times per second at best **(est.)**. Its accuracy on vehicles at range from a runner's phone is unmeasured. Retiring Depth Anything from the live loop also frees about 26–34 ms of Neural Engine time every third frame. That time pays for the higher detector resolution argued for above.

## Height priors, a LiDAR-anchored ground plane and box-scale TTC do the ranging

### Size prior

Range from known size has a roughly constant *relative* error, and that error is set by how much real vehicles vary in size. Mobileye found that width-based range for an unknown vehicle type is "only about 30% accurate" ([Stein, Mano & Shashua 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)). Height within one class is much tighter: KITTI car heights "mainly vary from 1.4 to 1.6 meters" ([WeakM3D, arXiv 2203.08332](https://arxiv.org/pdf/2203.08332)). That gives about ±7% for sedans, or ±15% once SUVs and vans appear **(est.)**.

Height is the right dimension from behind, for two reasons:

- It does not change as a car yaws. Width inflates when the side comes into view.
- Motorbike width is set by handlebars, mirrors and arms. One nuScenes size table puts motorcycle widths at 0.4–1.5 m ([arXiv 2205.12519](https://arxiv.org/pdf/2205.12519)).

The 1.5 m car prior makes a 1.8 m SUV read about 17% closer than it is **(est.)**. For a warning app, that is the safe direction. One comparison found a known-height assumption beat learned depth at longer ranges ([arXiv 2005.07424](https://arxiv.org/pdf/2005.07424)). That supports keeping this formula as the backbone.

### Ground plane

The ground-plane cue, `Z = f·H / (y_bottom − y_horizon)`, is excellent in a car with fixed calibration. Mobileye reports 5% error at 44 m for 1 px of contact-point error ([Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)). It is very sensitive to pitch, though: a pitch-calibration patent puts 0.5° of pitch error at about 15% range error at 20 m ([US 10769793](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10769793)).

With the camera at about 1.1 m, a 1° pitch error turns a true 20 m into 15–29 m, and a true 40 m into 25–110 m **(est.)**. A runner's arm swing and footstrikes plausibly cause errors of that size if pitch comes from the IMU. The phone's own LiDAR is the fix: it almost always sees the ground within 5 m behind the runner. Fitting a plane to it each frame gives camera height and pitch relative to the actual road, synchronised with the image. If that holds pitch to about 0.25°, the ground-plane estimate stays competitive out to about 20 m **(est.)**. The real pitch error during running is unmeasured, and it is the single most important number the field test must produce.

### Fusion, tracking and TTC

The two cues should be combined, not chosen between, because they fail for different reasons:

- **Their biases are complementary.** CHARM3R showed that size-type and ground-type depth drift in opposite directions when camera height changes. Averaging the two improved generalisation to unseen camera heights by more than 45% ([CHARM3R, arXiv 2508.11185](https://arxiv.org/html/2508.11185v1)).
- **Combine them by inverse variance.** Weight each by 1/σ². The size error is about Z × 7–15%. The ground-plane error is about Z × (Z·σθ/H), so the weighting fades the ground plane out automatically at range.
- **Gate the ground plane** whenever the box bottom touches the frame edge, or the ray sits less than about 2σθ below the horizon.
- **Track each vehicle with a constant-velocity Kalman filter in log distance.** Its rate term is directly −1/TTC, and a Mahalanobis gate rejects single-frame box glitches.
- **Get closing speed from scale change.** Mobileye's analysis is blunt: "subtracting two noisy values for Z at two different time points cannot produce accurate measurements". Closing speed should come from scale change instead. The optimal window runs from **0.27 s at 24 m to 0.65 s at 57 m** ([Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)).

The app's 0.6 s ln(size) slope is already in that range. With 1.5 px of box jitter, a 0.2 s window would give about 25% TTC error at 20 m, and a 0.5 s window about 8% **(est.)**. Mobileye aligns image patches to 0.1 px, ten times finer than detector boxes manage. Optical flow inside the box is therefore the upgrade path for scale-rate precision if needed.

### LiDAR calibration and learned regressors

LiDAR can also replace a track's class prior with its measured height once the vehicle comes within 5 m. That mostly helps vehicles that pass and recede, so it does little for approach warnings.

Learned box-to-distance regressors are not a shortcut. On KITTI they reach about 7–11% mean relative error over 0–150 m: Dist-YOLO 11% ([Dist-YOLO](https://doi.org/10.3390/app12031354)), DECADE 7.3–8% ([DECADE, arXiv 2410.19336](https://arxiv.org/html/2410.19336v1)). But zero-shot transfer to a new camera roughly doubles DistFormer's error, to 17.6–20.7% ([DistFormer](https://arxiv.org/html/2401.03191)). Monocular depth also degrades at camera heights the model was not trained on ([CHARM3R](https://arxiv.org/html/2508.11185v1)). A KITTI-trained regressor on a 1.1 m bouncing phone would need fine-tuning on the app's own LiDAR-labelled data before it could compete with geometry.

### Expected accuracy by method

All values below are derived estimates, assuming f ≈ 1000 px in detector pixels (about a 1280 px input), 2 px box jitter and camera height ≈ 1.1 m.

| Method | 10 m | 20 m | 40 m | Dominant failure |
|---|---|---|---|---|
| Height prior alone | ±8–15% | ±8–16% | ±9–17% | SUV/van height variance; truncation <5 m; occlusion |
| Ground plane, IMU pitch σθ ≈ 1° | −14 / +19% | −24 / +47% | −39 / +174% | bounce, slope; unusable past ~10 m |
| Ground plane, LiDAR-referenced σθ ≈ 0.25° | ±5% | ±8–10% | ±15–20% | slope change between runner and vehicle |
| **Inverse-variance fusion of the two** | **±5%** | **±7–9%** | **±10–15%** | occlusion hits both cues |
| LiDAR (≤5 m) | cm-level, out of range | — | — | range limit |
| TTC from box scale, 0.5 s window, TTC = 2 s | ~3–5% | ~8% | ~30%+ | box jitter; independent of priors |

## Two thresholds, three confirmations and a lens check remove most false alarms

A better detector reduces false positives. At "small" size, modern models score about 20 COCO mAP points above YOLOv3, so at equal recall they should produce far fewer false boxes. But I found no published study comparing false-positive rates or calibration between YOLOv3 and YOLO26 or DETRs. Confidence scores also are not comparable across models, so the 0.3 threshold must be re-tuned after any swap. Detector confidence is miscalibrated in ways that depend on box size and position ([Küppers et al., CVPRW 2020](https://openaccess.thecvf.com/content_CVPRW_2020/papers/w20/Kuppers_Multivariate_Confidence_Calibration_for_Object_Detection_CVPRW_2020_paper.pdf); [arXiv 2112.01901](https://arxiv.org/pdf/2112.01901)). Thresholds therefore have to come from the app's own recordings, not the literature.

The cheapest and most certain gains are in the tracker, in this order:

1. **Split the threshold in two.** ByteTrack matches high-score boxes first and uses low-score boxes only to keep existing tracks alive, never to start new ones. Its default start threshold is 0.6 ([ByteTrack, arXiv 2110.06864](https://arxiv.org/html/2110.06864v3)). Ultralytics' tracker config comments that a higher `new_track_thresh` "reduces false tracks" ([bytetrack.yaml](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/trackers/bytetrack.yaml)). For this app: start a track at about **0.5 for cars, buses and trucks**, possibly 0.4 for motorbikes if recall suffers, and keep it alive above about 0.15–0.2. These starting values are mine, to be tuned. The low keep-alive threshold also stops a real car from dropping out when running blurs it for a few frames.
2. **Confirm before warning.** SORT reports a track only after three consecutive hits (`min_hits = 3`) ([abewley/sort](https://github.com/abewley/sort/blob/master/sort.py)). Requiring 3 hits in the first 5 frames before a track can warn costs only 0.1–0.2 s at 15–30 fps, against a 3 s warning horizon **(est.)**. The rule should apply to both warning paths, and the track's label should be decided by majority vote so a box flickering between person and car never warns.
3. **Take `person` out of the warning-eligible labels.** Also suppress person boxes that mostly overlap a motorbike or bicycle box, so a rider does not become a second track.
4. **Reject the lens.** Treat a LiDAR median below about 0.3 m as an occluded lens and drop the detection, rather than falling back to box size. Do the same for a box taller than about 60–70% of the frame, or touching three edges.

The plausibility checks are engineering heuristics; no source gives numeric thresholds for them:

- Distrust a box whose size-based and LiDAR distances disagree by more than about 2× inside 5 m.
- Exclude edge-clipped boxes from TTC, because their size is wrong.
- Learn per-class aspect-ratio ranges from recordings.
- Require box growth to be consistent across the window, not just positive on average.
- Down-weight boxes floating entirely above the horizon.

The horizon check needs field validation, because a swinging phone moves the horizon quickly.

Once these gates are in, the app's existing "Vehicle passed now / Missed one / False warning" buttons, video and `tracks.csv` become a hard-negative mining loop ([CameraRadar.swift](../SpatialAudioDetect/CameraRadar.swift)). The loop works like this:

- Frames around each false warning become unlabeled background images.
- Each missed vehicle gets labeled.
- Background frames stay at Ultralytics' recommended **0–10% background images** to reduce false positives ([Ultralytics training tips](https://docs.ultralytics.com/yolov5/tutorials/tips_for_best_training_results/)).
- The operating point is chosen by false warnings per hour versus missed approaches, not by mAP.

Two-wheelers deserve the extra data. A YOLOv3 fine-tuned for crossroads scored 62% AP on vehicles but only **25.66% on bikes and motorcycles** ([OpenVINO model card](https://docs.openvino.ai/2024/omz_models_model_person_vehicle_bike_detection_crossroad_yolov3_1020.html)). Public driving datasets are a licensing trap for anything commercial:

- BDD100K is limited to "educational, research, and not-for-profit purposes" ([BDD100K licence](https://huggingface.co/datasets/dgural/bdd100k/commit/8e52994dbb62a377f075b6a345e913cc11b3a72e)).
- Waymo's licence is non-commercial and covers trained models as "Derivative IP" ([Waymo Open licensing](https://waymo.com/open/licensing)).

A crop-verification classifier, run once when a track is confirmed, is a later option. Its cost scales with new tracks, not with frame rate. Its benefit is unmeasured.

## The JOIV YOLOv8 paper stops at 5 m and adds no new ranging method

The suggested paper is "Object Detection with YOLOv8 and Enhanced Distance Estimation Using OpenCV for Visually Impaired Accessibility", by Syahrudin, Utami and Hartanto of Universitas Amikom Yogyakarta. It appeared in JOIV vol. 9 no. 2 (31 March 2025, DOI 10.62527/joiv.9.2.2826) ([Crossref](https://api.crossref.org/works/10.62527/joiv.9.2.2826)). It targets blind pedestrians, not vehicles or runners.

Its abstract reports "average object detection accuracy of 91% with a low error rate of about 3.6%". It also reports degraded performance in low light, and describes spoken Indonesian output with a panic button ([Crossref abstract](https://api.crossref.org/works/10.62527/joiv.9.2.2826)). **I could not read the full text.** joiv.org is behind a Cloudflare human check. So the exact distance formula, test ranges, sample counts and hardware are unverified. The PDF opens in a normal browser at [joiv.org viewFile/2826/1261](https://joiv.org/index.php/joiv/article/viewFile/2826/1261).

The same authors' immediately preceding paper on the same system (JURNAL RESTI, 2024) is open, and it shows how thin the method is:

- It names a stereo formula, `distance = F × T / disparity`, using OpenCV StereoBM/StereoSGBM. But it never describes a second camera, a baseline or a calibration.
- In the same breath it mentions monocular "size or perspective" cues, without saying which method actually ran.
- Ground truth was measured by hand. Cars were tested with **six samples at 2–3 m**, and the farthest measured object was 3.8 m.
- The YOLOv5-vs-YOLOv8 speed table is quoted from another paper, not measured ([RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)).
- The paper's own per-class averages work out to a mean of 2.58%, not its stated 3.15%.

A 2025 follow-up reports error over 0–5 m only ([CommIT landing page](https://journal.binus.ac.id/index.php/commit/article/view/11820)).

The method does not help here, whichever version they used:

- **If it is stereo, it is useless at range.** The iPhone's rear lenses sit roughly 1–2 cm apart, and stereo error grows as Z²·Δd/(f·B). With B ≈ 0.012 m, f ≈ 1500 px and 1 px of disparity error, the error at 20 m already exceeds the distance itself **(est., assumed baseline)**.
- **If it is monocular size, it is the formula the app already runs.**

The paper offers two useful signals. Low light degrades detection, so dusk runs belong in the field test. And YOLOv8 is indeed newer than YOLOv3, though YOLO26 supersedes it under the same AGPL licence.

## The recommended pipeline runs at an estimated 20–30 fps with ±10–17% error at 40 m

| Stage | Recommendation | Basis |
|---|---|---|
| Capture | Keep the back LiDAR depth camera, ≤1920 px wide at 30 fps, intrinsics from `cameraCalibrationData` | existing code |
| Detector | **YOLO26s**, Ultralytics Core ML export, `nms=True`, compute units CPU+Neural Engine, rectangular input matching the 3:4 upright frame: try `imgsz=(960,720)` and `(1280,960)`, fall back to `(640,480)`. Export FP16 and INT8 and compare on own clips. Closed-source fallback: RF-DETR-S. | cited capability; resolution choice est. |
| Tracker | Start ≥0.5 (motorbike ~0.4), keep ≥0.15–0.2; 3-of-5 confirmation before any warning; class-agnostic vehicle matching with majority label; `person` never warns | ByteTrack/SORT pattern; values est. |
| False-positive gates | LiDAR <0.3 m or box >60–70% of frame or ≥3 edges → reject; size/LiDAR disagreement >2× → no warning; edge-clipped boxes excluded from TTC | heuristics, tune on recordings |
| Distance | LiDAR median in box (0.3–5 m) when available; otherwise inverse-variance fusion of height prior and LiDAR-plane ground estimate; Kalman filter in log Z | cited methods; weights est. |
| Warning | TTC from ln(box height) over ~0.6 s (or the Kalman rate), lateral offset from fused distance, confirmed vehicle tracks only | cited method |
| Monocular depth | Removed from the live loop. Optional experiment: DA3-Metric-Large at 1–2 Hz with real intrinsics, as a cross-check only | cited evidence against per-frame use |

Expected distance error **(all est.)**:

| Distance | Current: height prior at 416 px | Current: DA-V2 extrapolation (offset ±0.01 m⁻¹) | Recommended: fusion at ~960–1280 px | TTC (0.5 s window, TTC = 2 s) |
|---|---|---|---|---|
| 10 m | ±12% (±1.2 m) | 9.1–11.1 m | **±5% (±0.5 m)** | 3–5% |
| 20 m | ±14% (±2.7 m) | 16.7–25 m | **±7–9% (±1.4–1.8 m)** | ~8% |
| 40 m | ±20% (±8 m) | 28.6–66.7 m | **±10–17% (±4–7 m)** | ≥30% |

The 40 m band for the recommended pipeline depends on the pitch accuracy actually achieved. At σθ ≈ 0.25° the fusion helps and gives ±10–15%. If σθ turns out nearer 1°, the ground plane is gated out and the height prior alone gives ±9–17%.

Frame-rate estimates are anchored on the one measured device figure, YOLO26n INT8 at 640 px on an iPhone 17 Pro: **3.2 ms in single-image bursts but 11.3 ms per frame sustained on live camera** ([Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/)). That 3.5× gap means planning must use sustained figures. It also assumes the 17 Pro Max uses the same chip class as the 17 Pro, which is not verified.

| Component | Per-frame time on iPhone 17 Pro Max | Basis |
|---|---|---|
| YOLO26s @ (640,480) | 10–20 ms | est. from FLOPs ratio and sustained overhead |
| YOLO26s @ (960,720) | 15–30 ms | est. |
| YOLO26s @ (1280,960) | 20–40 ms | est. (≈ YOLO26m @640 compute) |
| RF-DETR-S @512 | unknown; community reports for RF-DETR (mostly Nano) range from ~10–15 fps on older iPhones up to a claimed 120 fps | anecdotal |
| Depth Anything V2 Small F16 (removed) | 26–34 ms every 3rd frame | measured, iPhone 16 Pro / 15 Pro Max |
| Tracker, fusion, LiDAR plane fit | <2 ms on CPU | est. |
| **Pipeline total** | **~20–35 ms → 20–30 fps** (camera caps at 30) | est. |

Licensing implications, by component:

| Component | Licence | Open-source challenge entry | Closed-source App Store |
|---|---|---|---|
| YOLO26 / YOLO11 / YOLOv8, including your fine-tuned weights | AGPL-3.0 ([Ultralytics licence](https://www.ultralytics.com/license)) | allowed if the **entire app source** is published under AGPL-3.0 | Enterprise licence, custom quote |
| RF-DETR N/S/M/L | Apache-2.0 ([RF-DETR](https://github.com/roboflow/rf-detr)) | allowed | allowed |
| RF-DETR Atto/Femto/Pico/XL/2XL | PML 1.0 (terms not retrieved) | avoid | avoid |
| D-FINE | Apache-2.0; Objects365 checkpoints "should not be assumed" commercially cleared ([D-FINE](https://github.com/Peterande/D-FINE)) | allowed | COCO-only weights only |
| DEIMv2 | custom licence ([DEIMv2](https://github.com/Intellindust-AI-Lab/DEIMv2)) | check | contact authors |
| Apple YOLOv3 (current) | Darknet public domain | allowed | allowed |
| Depth Anything V2 Small (Apple Core ML) | Apache-2.0 ([HF card](https://huggingface.co/apple/coreml-depth-anything-v2-small)) | allowed | allowed |
| DA3-Metric-Large / Metric3D v2 / UniDepth | Apache-2.0 / BSD-2 / CC BY-NC | allowed | UniDepth excluded |
| BDD100K, Waymo, nuScenes for fine-tuning | non-commercial | allowed with attribution | avoid; Waymo binds trained models |
| SORT reference code | GPL-3.0 ([abewley/sort](https://github.com/abewley/sort/blob/master/sort.py)) | — | keep the app's own tracker code |

Whether AGPL code can ship through the App Store at all was not researched and needs legal review. Apple also announced "Core AI" at WWDC 2026 as Core ML's successor, according to secondary reporting ([AppleInsider](https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml)). Whether Core ML is being deprecated is unclear, so the Core ML path above remains the practical one on iOS 27.

## Ship the free fixes first, then let road tests set the numbers

The order below front-loads changes that cost no compute and need no new model. Each step is measured against a baseline recorded before anything changes.

| Priority | Step | Effort (est.) | Done when |
|---|---|---|---|
| 0 | **Baseline.** Record at least 5 runs with the current build, using the marker buttons. Count false warnings per hour, missed approaches, and distance against measured cones. | 1–2 days | baseline numbers exist |
| 1 | **Tracker gates.** Take `person` out of warnings; add near-lens rejection; split start/keep thresholds; require 3-of-5 confirmation on both warning paths; use majority labels; exclude edge-clipped boxes from TTC. | 1–2 days | false warnings per hour fall on replayed baseline clips, with no added misses |
| 2 | **Retire Depth Anything** from the live loop. | hours | detector time budget freed |
| 3 | **Detector swap.** Export YOLO26s at (640,480), (960,720) and (1280,960), FP16 and INT8. Measure sustained ms over 10+ minutes on the 17 Pro Max. Map label names and re-tune thresholds. If the app must be closed-source, benchmark RF-DETR-S in the same week instead. | 3–5 days | largest input that holds ≥20 fps is chosen |
| 4 | **Geometry.** Fit the LiDAR ground plane each frame for H and pitch; add the ground-plane range; fuse by inverse variance; add a Kalman filter in log Z; compute lateral offset from fused distance. | 3–5 days | per-bin error measured against cones |
| 5 | **Data loop.** Mine hard negatives and misses, fine-tune YOLO26s on own footage with 0–10% background frames, and set per-class thresholds by false warnings per hour vs misses. | 1–2 weeks | held-out runs beat step 3 |
| 6 | **Experiments only if targets are missed:** DA3-Metric-Large keyframes; optical-flow scale rate inside the box; crop verifier; YOLO26 P2 head trained on own data. | open | measurable gain over step 4 |

The field test should run in a closed car park or quiet road with a spotter and a cooperating driver. It reuses the app's existing video plus `tracks.csv` recording, so ground truth can be annotated after the run rather than live.

| Measurement | Method | Proposed target (my proposal) |
|---|---|---|
| Distance accuracy | Cones at 5, 10, 20, 30, 40, 50 m placed with a laser rangefinder; annotate the frame where the vehicle's front crosses each cone; compare logged distance | median error ≤10% at 20 m, ≤20% at 40 m |
| Detection range | Distance at first *confirmed* track, per class (car, motorbike), in daylight and at dusk | motorbike confirmed by ≥40 m in daylight |
| Warning lead time | Car and motorbike approaching at 20, 30 and 50 km/h; time from warning to pass | ≥2 s at 50 km/h |
| Pitch error | Log Core Motion pitch against LiDAR-plane pitch every frame while running | establishes σθ, which decides the ground-plane gate |
| False warnings | Ordinary street runs with marker buttons, before and after each step | set after baseline; must fall at every step |
| Sustained performance | 30-minute run logging detector ms and thermal state | ≥20 fps after 30 minutes |
| Mount and light | Chest vs armband or hip; daylight vs dusk, reported separately | report separately |

## Conclusion

The project's instinct was to fix distance with a better depth network. The evidence points the other way. For a warning, metres are secondary: the trigger is time-to-contact, which needs no prior, no camera height and no depth model. What limits it is how stable and how large the vehicle's box is in pixels. That makes input resolution the highest-leverage change in the pipeline, because it extends detection range, which buys warning time, and it shrinks the jitter term in both TTC and range. Retiring Depth Anything pays for it. The licensing question (open-source entry versus closed App Store app) is the real fork in the model choice and should be settled first, since it decides between a measured YOLO26 path and an unproven RF-DETR one.

Two quantities nobody has published will decide the final accuracy. One is how far a running body pitches the camera between frames. The other is how often road clutter fools a modern detector from a sidewalk-height rear view. Both can be measured cheaply with the recording and marker tools already in the app. Until they are, every error band in this report is a well-founded estimate rather than a result. The order of work follows from that: free gates first, then the detector swap, then geometry, with a measurement at every step.
