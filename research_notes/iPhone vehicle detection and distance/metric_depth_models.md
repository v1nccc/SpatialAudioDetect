# Monocular metric depth models for vehicle distance (5–50 m) on iPhone 17 Pro Max

Scope: AI depth models that estimate how far away a vehicle is from a single rear-facing phone camera (optionally helped by the iPhone's LiDAR, which reaches ~5 m) on a runner. Target is Core ML / Neural Engine on iPhone 17 Pro Max, iOS 27. Researched 2026-10-23.

Context from the repo: the project already ships Apple's `DepthAnythingV2SmallF16.mlpackage` (relative depth) and `YOLOv3Int8LUT.mlmodel`. The current approach fits an inverse-depth affine (a/z + b) on LiDAR points at 0.4–5 m and extrapolates it out to 30 m.

---

## 1. Depth Anything V2: relative vs Metric-Outdoor/Indoor fine-tunes, accuracy, sizes, licenses, Core ML

### Takeaway
On real KITTI, Depth Anything V2's metric numbers are good (AbsRel 0.045–0.053, RMSE 1.86–2.24 m), but only after fine-tuning on KITTI itself. The public "Metric-Outdoor" checkpoints were trained only on synthetic Virtual KITTI 2 with an 80 m cap and publish no real-world zero-shot numbers. A third-party zero-shot test (Depth Pro paper) found DA-V2's metric variants very poor out of domain: nuScenes δ1 = 17.7%. Apple's official Core ML build is the relative Small model only. It runs in ~34 ms on the Neural Engine.

### Cited Findings
**Model family and sizes**
- Six metric checkpoints exist: Small (24.8M params), Base (97.5M) and Large (335.3M), each in Indoor (fine-tuned on Hypersim, `max_depth=20`) and Outdoor (fine-tuned on Virtual KITTI 2, `max_depth=80`) versions. `infer_image` returns an HxW depth map in metres. — [DA-V2 metric_depth README](https://github.com/DepthAnything/Depth-Anything-V2/tree/main/metric_depth)
- The README tells users to "first try our larger models (if computational cost is affordable) and the indoor version". It publishes no AbsRel/δ1/RMSE numbers for the released checkpoints. — [DA-V2 metric_depth README](https://github.com/DepthAnything/Depth-Anything-V2/tree/main/metric_depth)
- The HF card for Metric-Outdoor-Small says ~24.8M params, fine-tuned on Virtual KITTI 2, no evaluation numbers, no license field, and nothing about camera intrinsics. — [HF Depth-Anything-V2-Metric-Outdoor-Small-hf](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Outdoor-Small-hf)

**Metric accuracy (paper, in-domain fine-tune on KITTI/NYU, not the released VKITTI checkpoints)**

| Model | KITTI δ1 | KITTI AbsRel | KITTI RMSE (m) | NYU δ1 | NYU AbsRel | NYU RMSE (m) |
|---|---|---|---|---|---|---|
| ZoeDepth | 0.971 | 0.054 | 2.281 | 0.951 | 0.077 | 0.282 |
| DA-V2 Small (ViT-S) | 0.973 | 0.053 | 2.235 | 0.961 | 0.073 | 0.261 |
| DA-V2 Base (ViT-B) | 0.979 | 0.048 | 1.999 | 0.977 | 0.063 | 0.228 |
| DA-V2 Large (ViT-L) | 0.983 | 0.045 | 1.861 | 0.984 | 0.056 | 0.206 |

— [DA-V2 paper, Table 4](https://arxiv.org/html/2406.09414)
- The paper says models trained on NYUv2/KITTI "fail to produce fine-grained depth prediction and are not robust to transparent objects", which is why the released outdoor model was fine-tuned on synthetic Virtual KITTI instead. Appendix D notes that the synthetic sets "are not diverse enough". — [DA-V2 paper](https://arxiv.org/html/2406.09414)

**Zero-shot generalisation of DA-V2 metric (independent evaluation)**
- Depth Pro Table 1, δ1 (%) for "Depth Anything v2*" (its indoor/outdoor metric variants, greyed as not strictly zero-shot): Booster 59.5, ETH3D 36.3, Middlebury 37.2, **NuScenes 17.7**, Sintel 5.9, Sun-RGBD 72.4. On NuScenes, Metric3D v2 scores 82.6, UniDepth 83.6 and Depth Pro 49.1. — [Depth Pro paper](https://arxiv.org/html/2410.02073)

**Core ML availability and speed**
- `apple/coreml-depth-anything-v2-small` ships `DepthAnythingV2SmallF32.mlpackage` (99.2 MB) and `DepthAnythingV2SmallF16.mlpackage` (49.8 MB), both 24.8M params. Abs-rel error vs the PyTorch reference is 0.0072 (F32) and 0.0089 (F16). License: apache-2.0. Evaluation stretched COCO images to 518×396. — [Apple Core ML DA-V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)
- F16 latency on the Neural Engine: iPhone 12 Pro Max (iOS 18.0) 31.10 ms; iPhone 15 Pro Max (iOS 17.4) 33.90 ms; M1 Max 32.80 ms; M3 Max 24.58 ms. — [Apple Core ML DA-V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)
- The card doesn't say whether the output is relative or metric. It is the base (relative) DA-V2 Small. Apple publishes no Core ML conversion of the Metric-Outdoor checkpoints. — [Apple Core ML DA-V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)

### Inferences
- The KITTI AbsRel 0.045–0.053 figures show what DA-V2 can reach after in-domain fine-tuning on KITTI. They do not describe the downloadable Metric-Outdoor checkpoints on a phone camera. The 17.7% nuScenes δ1 is the best warning available: a synthetic-only outdoor fine-tune does not transfer reliably to real cameras and intrinsics.
- DA-V2 metric takes no camera intrinsics, so its scale is tied to Virtual KITTI's camera: a ~1.5 m-high car roof, forward-facing, fixed focal length. An iPhone on a runner (lower and moving, rear-facing, a different FOV on main vs ultra-wide) is a different camera. Expect a systematic scale bias that changes with the lens used.
- Metric-Outdoor-Small has the same ViT-S + DPT architecture as Apple's relative Small. A custom Core ML conversion should run at about the same ~30–35 ms on the Neural Engine. This is not measured.
- License: DA-V2's sibling project Video Depth Anything uses Apache-2.0 for Small and CC-BY-NC-4.0 for Base/Large (see §2). The DA-V2 main README is widely reported to use the same split, but it was not re-verified this session. Apple's Core ML Small card says apache-2.0.

### Gaps
- No published zero-shot KITTI/real-world AbsRel/RMSE exists for the released VKITTI-trained Metric-Outdoor checkpoints.
- The DA-V2 Base/Large license (CC-BY-NC-4.0) was not directly verified in this session.
- No latency figures for iPhone 16/17 or iOS 26/27 were found.

---

## 2. Newer and alternative models: DA3, Video Depth Anything, Prompt Depth Anything, Depth Pro, Metric3D v2, UniDepth v2, ZoeDepth, MoGe-2

### Takeaway
For zero-shot metric accuracy on driving scenes, the leaders are Metric3D v2 (KITTI AbsRel 0.051, BSD-2 code), UniDepth v2 (KITTI AbsRel 0.076 / δ1 0.968–0.989, but CC-BY-NC) and DA3-Metric-Large (KITTI AbsRel 0.086, Apache-2.0, 0.35B). Depth Pro is strong on general photos but weak on KITTI (AbsRel 0.121) and far too heavy for real time on a phone. The only metric models in the ~25–35M class that could plausibly run in real time on the Neural Engine are DA-V2-Metric-Small, Video-Depth-Anything-Metric-Small and MoGe-2 ViT-S. None of the three has an official Core ML build.

### Cited Findings
**Zero-shot metric depth, same protocol (DA3 paper Table 11, δ1 / AbsRel)**

| Method | NYUv2 | KITTI | ETH3D | SUN-RGBD | DIODE |
|---|---|---|---|---|---|
| Depth Pro | 0.932 / 0.093 | 0.843 / 0.121 | 0.386 / 0.349 | 0.950 / 0.126 | 0.734 / 0.173 |
| Metric3D v2 | 0.971 / 0.067 | 0.976 / 0.051 | 0.830 / 0.138 | 0.954 / 0.132 | 0.018(?) / 0.154 |
| UniDepth v1 | 0.980 / 0.061 | 0.978 / 0.051 | 0.234 / 0.464 | 0.971 / 0.113 | 0.570 / 0.266 |
| UniDepth v2 | 0.968 / 0.064 | 0.968 / 0.076 | 0.863 / 0.152 | 0.977 / 0.111 | 0.856 / 0.123 |
| DA3-metric | 0.963 / 0.070 | 0.953 / 0.086 | 0.917 / 0.104 | 0.973 / 0.105 | 0.838 / 0.128 |

— [Depth Anything 3 paper](https://arxiv.org/html/2511.10647). The Metric3D v2 DIODE δ1 of 0.018 looks like a typo in the source. The paper calls DA3-metric "competitive". UniDepth v1/v2 are best on NYU/KITTI.

**Depth Anything 3 (ByteDance-Seed, released 14 Nov 2025, arXiv 2511.10647)**
- Model zoo: DA3-Giant 1.15B (CC BY-NC 4.0), DA3-Large 0.35B (CC BY-NC 4.0), DA3-Base 0.12B (Apache 2.0), DA3-Small 0.08B (Apache 2.0), **DA3Metric-Large 0.35B (Apache 2.0)**, DA3Mono-Large 0.35B (Apache 2.0, relative), DA3Nested-Giant-Large 1.40B (CC BY-NC 4.0, output already in metres). Original Giant/Large/Nested are "deprecated" in favour of the -1.1 checkpoints. — [DA3 GitHub](https://github.com/ByteDance-Seed/Depth-Anything-3)
- Metric conversion: `metric_depth = focal * net_output / 300`, with focal in pixels (mean of fx, fy). — [DA3 GitHub](https://github.com/ByteDance-Seed/Depth-Anything-3)
- The metric model uses canonical focal length fc = 300. It was trained on 14 datasets, including many driving sets (DDAD, Argoverse, Lyft, PandaSet, Waymo, DSEC, Driving Stereo, Cityscapes, DIML Outdoor) plus ScanNet++ and ARKitScenes, at base resolution 504. — [DA3 paper](https://arxiv.org/html/2511.10647)
- Monocular relative KITTI δ1: DA2 94.6 vs DA3 95.3 (teacher 97.2). — [DA3 paper](https://arxiv.org/html/2511.10647)
- The README has no Core ML or mobile notes. — [DA3 GitHub](https://github.com/ByteDance-Seed/Depth-Anything-3)

**Video Depth Anything (temporal consistency)**
- Relative: Small 28.4M (Apache-2.0), Base 113.1M (CC-BY-NC-4.0), Large 381.8M (CC-BY-NC-4.0). Metric versions come in Small, Base and Large at the same sizes. No separate license is listed for the metric models. — [Video Depth Anything GitHub](https://github.com/DepthAnything/Video-Depth-Anything)
- Timeline: paper and code 2025-01-21; Metric Large 2025-04-25; Small/Base metric 2025-08-28; experimental training-free streaming mode 2025-07-03 (metric streaming added 2025-09-12). Streaming mode caches temporal-attention states so each frame is processed alone, at a cost: ScanNet δ1 drops from 0.926 to 0.836. — [Video Depth Anything GitHub](https://github.com/DepthAnything/Video-Depth-Anything)
- README metric δ1 on KITTI (the table is flattened, so column alignment is inferred): VDA-S-Metric 0.877, VDA-B-Metric 0.887, VDA-L-Metric 0.910, UniDepthV2-L 0.982, DepthPro 0.822, MoGe-2-L 0.415 (suspicious). Temporal error (TAE, ScanNet) is better for VDA (1.09–1.48) than DepthPro (2.73). — [Video Depth Anything GitHub](https://github.com/DepthAnything/Video-Depth-Anything)
- A100 latency for a 1×32×518×518 input: Small 9.1 ms FP32 / 7.5 ms FP16; Large 67 / 14 ms. No Core ML, ONNX or TensorRT export is mentioned. — [Video Depth Anything GitHub](https://github.com/DepthAnything/Video-Depth-Anything)

**Prompt Depth Anything (CVPR 2025): iPhone LiDAR as a metric prompt**
- Built on DA-V2 (ViT-L main). The LiDAR depth map (192×256 for ARKit4, 240×320 for ARKit6) is resized at each DPT decoder scale and fused through a shallow conv and a zero-initialised layer. Output resolution goes up to 2160×3840. — [Prompt Depth Anything paper](https://arxiv.org/html/2412.14015)
- ARKitScenes (768×1024): Ours L1 0.0132 m / RMSE 0.0315 m. Zero-shot synthetic-only model: 0.0163 / 0.0371. **DA-V2 + RANSAC alignment to LiDAR: 0.0616 / 0.1368.** Raw ARKit depth: 0.0250 / 0.0423. Depth Prompting: 0.0253 / 0.0422. — [Prompt Depth Anything paper](https://arxiv.org/html/2412.14015)
- ScanNet++ AbsRel: Ours 0.0175. Aligned DA-V2 0.0402, Depth Pro 0.0510, Metric3D v2 0.0419. — [Prompt Depth Anything paper](https://arxiv.org/html/2412.14015)
- Speed on A100: ViT-L 20.4 FPS at 768×1024 and 2.0 FPS at 4K; ViT-S 80.0 FPS and 10.3 FPS. Prompt fusion adds about 5.7% FLOPs. — [Prompt Depth Anything paper](https://arxiv.org/html/2412.14015)
- Limitations: iPhone LiDAR "detects very noisy depth for far objects", so the method can't handle long range. LiDAR flicker causes flickering depth. Training is indoor; outdoor results are only qualitative, and accuracy beyond LiDAR range is not quantified. — [Prompt Depth Anything paper](https://arxiv.org/html/2412.14015)

**Depth Pro (Apple, Oct 2024)**
- 504M params, 4370 GFLOPs at HD, fixed internal 1536×1536 resolution. 341.3 ms per image on a V100 at any input size. It estimates focal length itself (e.g. PPR10K δ25% 64.6 vs runner-up SPEC 34.6). Parameter counts of other models from the same table: ZoeDepth 340M, DA-V2-L 335M, UniDepth 347M, Metric3D v2 (giant) 1.378B taking 1299.6 ms. — [Depth Pro paper](https://arxiv.org/html/2410.02073)
- Zero-shot δ1: NuScenes 49.1%, Sun-RGBD 89.0%. Average rank 2.5 (best in its table). Stated limitations: translucent surfaces and volumetric scattering. — [Depth Pro paper](https://arxiv.org/html/2410.02073)
- Core ML builds exist. `coreml-projects/DepthPro-coreml` is ~1.9 GB (Apple sample-code license), takes 1536×1536 and outputs metres. There's also a pruned/quantised ~1.1 GB variant. — [coreml-projects/DepthPro-coreml](https://huggingface.co/coreml-projects/DepthPro-coreml)
- A community 6-bit palettised build is 682 MB (fp16 1.8 GB), with median error 1.17% vs PyTorch, and takes **3.6 s/frame (6-bit) and 4.8 s (fp16) on a fanless M-series Mac**. First load compiles for the Neural Engine and takes "a couple of minutes". No iPhone numbers are given. — [mickeyvanolst/depthpro-coreml](https://huggingface.co/mickeyvanolst/depthpro-coreml)

**Metric3D v2**
- README benchmark (KITTI δ1 / AbsRel / RMSE): ViT-Large 0.985 / 0.044 / 1.985; ViT-giant2 0.989 / 0.039 / 1.766. ZoeDepth 0.971 / 0.053 / 2.281 and DepthAnything-L 0.982 / 0.046 / 1.985 for comparison. The README doesn't say whether these are zero-shot or fine-tuned. — [Metric3D GitHub](https://github.com/YvanYin/Metric3D)
- ViT-S and ConvNeXt checkpoints exist, but with no benchmark rows. Code is 2-clause BSD. "Improved ONNX checkpoints" for v2-S/L/g with dynamic shapes are available. Config shows crop_size (512, 1088) and canonical img_size (512, 960). — [Metric3D GitHub](https://github.com/YvanYin/Metric3D)

**UniDepth v2**
- Backbones ViT-S/B/L (v2), ConvNeXt-L and ViT-L (v1). Zero-shot KITTI d1: UniDepthV2 98.9, UniDepthV1 98.6, Metric3Dv2 98.5, ZoeDepth 96.5. v2 adds "Faster inference" and "ONNX support". **License: CC BY-NC 4.0.** — [UniDepth GitHub](https://github.com/lpiccinelli-eth/UniDepth)

**MoGe-2 (Microsoft, arXiv 2507.02546)**
- Metric-scale checkpoints: ViT-L 326M, ViT-L-normal 331M, ViT-B-normal 104M, **ViT-S-normal 35M**. Code is MIT (DINOv2 parts Apache 2.0); no separate weights license is stated. 60 ms on A100/RTX3090 FP16 for ViT-L. An ONNX doc exists. The README carries a 2026-08-18 news item about **MoGe-3**, which may supersede MoGe-2 (not examined). — [MoGe GitHub](https://github.com/microsoft/MoGe)

**ZoeDepth (2023)**: KITTI δ1 0.971, AbsRel 0.053–0.054, RMSE 2.281; 340M params. Every newer model above beats it. — [DA-V2 paper](https://arxiv.org/html/2406.09414); [Metric3D GitHub](https://github.com/YvanYin/Metric3D); [Depth Pro paper](https://arxiv.org/html/2410.02073)

### Inferences
- Superseded: ZoeDepth by every newer model; DA-V2 (relative) by DA3 on accuracy, although DA3's metric model ships only in Large; UniDepth v1 by v2; the original DA3 checkpoints by DA3 -1.1; possibly MoGe-2 by MoGe-3 (Aug 2026).
- Canonical-camera models take intrinsics and estimate scale from them: DA3-metric (focal/300), Metric3D v2, UniDepth (which predicts the camera), and Depth Pro (which estimates focal). They suit a phone better than DA-V2/VDA metric, because the real iPhone intrinsics can be passed in (AVFoundation `cameraCalibrationData` or ARKit `ARCamera.intrinsics`).
- Shortlist for a commercially usable, on-device build: Metric3D v2 ViT-S (BSD-2, ONNX available, so Core ML conversion is plausible, but no published ViT-S accuracy), DA3Metric-Large (Apache, but 0.35B is heavy), VDA-Metric-Small (license for the metric weights unconfirmed), and MoGe-2 ViT-S (MIT code, 35M). UniDepth is non-commercial.
- Depth Pro's KITTI AbsRel of 0.121 and nuScenes δ1 of 49% make it a poor fit for street-scale distances even before the cost problem (seconds per frame).

### Gaps
- No published Core ML conversions or iPhone latencies were found for DA3, VDA, Metric3D v2, UniDepth v2, MoGe-2 or Prompt Depth Anything.
- Prompt Depth Anything's license and model sizes were not retrieved.
- No accuracy numbers were found for Metric3D v2 ViT-S, UniDepth v2 ViT-S or MoGe-2 ViT-S on KITTI.
- The MoGe-2 KITTI δ1 of 0.415 in the VDA README is probably a column-misalignment artefact. Unverified.

---

## 3. How error grows with distance (10/20/40 m), and what KITTI AbsRel means in metres

### Takeaway
No source found reports AbsRel per distance bin (e.g. 20–40 m vs 40–80 m) for the foundation models. Benchmarks report averages over 0–80 m of KITTI LiDAR pixels, and most of those pixels are nearby. As a rule of thumb, mean error ≈ AbsRel × distance. For the best zero-shot model (AbsRel ≈ 0.05) that's ~1 m at 20 m and ~2 m at 40 m. For Depth Pro (0.12) it's ~2.4 m and ~4.8 m. And 2–16% of pixels are off by more than 25%. Any error in inverse depth (disparity) turns into a metric error that grows with distance squared.

### Cited Findings
- KITTI evaluation usually caps depth at 50 m or 80 m. The 80 m cap reflects the maximum LiDAR depth, and errors without a threshold are sensitive to small-disparity (far) predictions. — [Geo-Supervised Visual Depth Prediction](https://arxiv.org/pdf/1807.11130)
- A KITTI monocular-3D-detection study reports depth error on car pixels in cumulative ranges (0–10, 0–20, 0–30, 0–40 m). Error rises with range. (The table rows are garbled in the extracted text, so the exact numbers aren't reliable.) — [Learning Geometry-Guided Depth via Projective Modeling](https://arxiv.org/pdf/2107.13931)
- Inverse-depth metrics penalise errors at close range much more heavily. — [Monocular Visual-Inertial Depth Estimation](https://ar5iv.labs.arxiv.org/html/2303.12134)
- KITTI RMSE (m) for in-domain fine-tuned models: DA-V2-L 1.861, DA-V2-S 2.235, ZoeDepth 2.281. — [DA-V2 paper](https://arxiv.org/html/2406.09414); Metric3D v2 g2 1.766 — [Metric3D GitHub](https://github.com/YvanYin/Metric3D)
- Zero-shot KITTI AbsRel: Metric3D v2 0.051, UniDepth v2 0.076, DA3-metric 0.086, Depth Pro 0.121. δ1 0.976 / 0.968 / 0.953 / 0.843. — [DA3 paper](https://arxiv.org/html/2511.10647)

### Inferences
- **AbsRel to metres** (mean absolute error ≈ AbsRel × Z, assuming relative error stays flat with distance, which is optimistic):

| Model (setting) | AbsRel | @10 m | @20 m | @40 m |
|---|---|---|---|---|
| DA-V2-L (KITTI fine-tuned) | 0.045 | 0.45 m | 0.9 m | 1.8 m |
| Metric3D v2 (zero-shot) | 0.051 | 0.5 m | 1.0 m | 2.0 m |
| DA-V2-S (KITTI fine-tuned) | 0.053 | 0.5 m | 1.1 m | 2.1 m |
| UniDepth v2 (zero-shot) | 0.076 | 0.8 m | 1.5 m | 3.0 m |
| DA3-metric (zero-shot) | 0.086 | 0.9 m | 1.7 m | 3.4 m |
| Depth Pro (zero-shot) | 0.121 | 1.2 m | 2.4 m | 4.8 m |

- δ1 is the share of pixels within ×1.25 of the truth. At 40 m, a δ1 of 0.843 (Depth Pro, KITTI) means ~16% of pixels are wrong by more than 8–10 m. Expect bigger errors on vehicles at range than these averages suggest, because KITTI's pixel mix is dominated by road and near objects.
- Domain shift: KITTI is a car-roof camera (~1.65 m, forward-facing, fixed intrinsics, horizon at a constant row). A runner's phone sits lower or at chest height, faces backward, bounces and rolls, and suffers motion blur and different focal lengths. Even zero-shot numbers are measured on car-mounted cameras. A runner's phone is outside every benchmark found, so field validation against ground truth (LiDAR, laser rangefinder or tape) is needed.

### Gaps
- No paper was found reporting per-bin (10–20 / 20–40 / 40–80 m) errors for DA-V2, DA3, Metric3D v2, UniDepth or Depth Pro. The HAL paper on distance-range evaluation ([hal-02978149](https://hal.archives-ouvertes.fr/hal-02978149)) was blocked by bot protection.
- No figures were found on vehicle-only error (as opposed to all pixels) at 20–50 m for any foundation model.

---

## 4. Scaling relative depth with sparse LiDAR (affine fit at 0.4–5 m, extrapolated to 30 m)

### Takeaway
Extrapolating from 5 m to 30 m is not reliable. A least-squares fit in inverse-depth space is anchored where 1/Z runs from 0.2 to 2.5 m⁻¹, but 30 m sits at 0.033 m⁻¹, near zero, where the shift term b dominates. A tiny shift error of ±0.005 m⁻¹ moves a 30 m car to 26–35 m, and ±0.01 m⁻¹ moves it to 23–43 m. Even inside LiDAR range, global affine alignment of DA-V2 to iPhone LiDAR gives RMSE 0.137 m, against 0.032 m for Prompt Depth Anything. No source tests either method beyond LiDAR range.

### Cited Findings
- Standard practice: global scale and shift (z̃ = s·z + t) fitted by least squares in **inverse-depth space** against sparse metric points. Adding a dense scale map cuts inverse RMSE by up to 30% over global alignment alone. On VOID (150 points): iRMSE 106.37 → 74.67 km⁻¹, iAbsRel 0.103 → 0.063. On TartanAir: 35.49 → 29.48, 0.126 → 0.093. — [Monocular Visual-Inertial Depth Estimation (Wofk et al.)](https://ar5iv.labs.arxiv.org/html/2303.12134)
- The same paper evaluates VOID at 0.2–5 m and TartanAir at 0.2–50 m. Dense scaling outside the convex hull of the anchor points "signals no information", and with few points the scale map collapses to identity. It gives no far-range extrapolation analysis. — [Monocular Visual-Inertial Depth Estimation](https://ar5iv.labs.arxiv.org/html/2303.12134)
- Indoors on ARKitScenes, DA-V2 with RANSAC alignment to iPhone LiDAR scores L1 0.0616 m / RMSE 0.1368 m. Prompt Depth Anything scores 0.0132 / 0.0315 and raw ARKit depth 0.0250 / 0.0423. — [Prompt Depth Anything](https://arxiv.org/html/2412.14015)
- iPhone LiDAR is "very noisy" for far objects. Prompt DA is not quantified outdoors or beyond LiDAR range. — [Prompt Depth Anything](https://arxiv.org/html/2412.14015)
- A CVPR 2026 supplement reports (per search snippet, not read in full) that DA-aligned depth maps still show scale inconsistencies after alignment, and that sparse-anchor alignment introduced local distortions. — [SPE-MVS CVPR 2026 supplemental](https://openaccess.thecvf.com/content/CVPR2026/supplemental/Wang_SPE-MVS_Spatial_Position_CVPR_2026_supplemental.pdf)

### Inferences
- **Sensitivity of the current method (derived):** Z_est = 1/(1/Z + δ), so ΔZ ≈ Z²·δ, which grows quadratically, as with stereo.

| True Z | δ = ±0.005 m⁻¹ | δ = ±0.01 m⁻¹ |
|---|---|---|
| 10 m | 9.5–10.5 m | 9.1–11.1 m |
| 20 m | 18.2–22.2 m | 16.7–25 m |
| 30 m | 26.1–35.3 m | 23.1–42.9 m |
| 40 m | 33.3–50 m | 28.6–66.7 m |
| 50 m | 40–66.7 m | 33.3–100 m |

A δ of 0.01 m⁻¹ is only ~0.4% of the 0.2–2.5 m⁻¹ span the fit covers. That is well inside LiDAR noise plus model-fit residuals, and the inverse-depth least-squares fit is dominated by the nearest points.
- The method also assumes DA-V2's relative disparity is exactly affine to true inverse depth from 0.4 m to 50 m. Relative models are trained with scale/shift-invariant losses, and the 13.7 cm in-range RMSE above shows the residual isn't zero. Any compression of far disparities passes straight into the extrapolation.
- Practical consequences:
  1. Treat distances beyond ~10–15 m from this pipeline as coarse bins (near / mid / far) rather than metres.
  2. Constrain b with priors, e.g. b ≈ 0, so disparity → 0 at infinity, and use sky or horizon pixels as a "far" anchor.
  3. Cross-check with geometric cues that hold at long range: the pinhole size prior Z ≈ f·W_real/w_px (car width ~1.8 m), or a ground-plane contact point using the phone's height and pitch from ARKit or Core Motion.
  4. Use a canonical-camera metric model (DA3-metric, Metric3D v2) for scale beyond LiDAR range, keeping LiDAR as a near-range check.

### Gaps
- No literature was found that measures error when extrapolating a sparse-depth affine fit beyond the sensor's range (e.g. 5 m → 30 m).
- No outdoor quantitative results for Prompt Depth Anything with iPhone LiDAR were found.

---

## 5. Real-time feasibility on iPhone (ANE latency, quantisation, input resolution)

### Takeaway
Only ~25–35M-parameter models are proven real-time on the Neural Engine: DA-V2-Small F16 runs in 33.9 ms on iPhone 15 Pro Max at ~518×396. Large-class (0.33–0.38B) metric models are plausible at a few Hz. Depth Pro (504M, 1536² fixed) takes seconds per frame even on M-series Macs and is not viable.

### Cited Findings
- DA-V2-Small F16 (49.8 MB): 33.90 ms on iPhone 15 Pro Max and 31.10 ms on iPhone 12 Pro Max, both on the Neural Engine. F16 error vs F32 reference: 0.0089 vs 0.0072 abs-rel. — [Apple Core ML DA-V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)
- Depth Pro Core ML: fp16 1.8–1.9 GB, 6-bit 682 MB, 3.6–4.8 s/frame on a fanless M-series Mac, minutes-long first Neural Engine compile. — [mickeyvanolst/depthpro-coreml](https://huggingface.co/mickeyvanolst/depthpro-coreml); [coreml-projects/DepthPro-coreml](https://huggingface.co/coreml-projects/DepthPro-coreml)
- Depth Pro: 4370 GFLOPs at HD, 341 ms on a V100. Metric3D v2 (giant, 1.378B): 1299.6 ms on a V100. — [Depth Pro paper](https://arxiv.org/html/2410.02073)
- Desktop GPU speeds: VDA-Small 7.5 ms FP16 and VDA-Large 14 ms FP16 on A100 (1×32×518×518) — [VDA GitHub](https://github.com/DepthAnything/Video-Depth-Anything); MoGe-2 ViT-L 60 ms on A100/3090 — [MoGe GitHub](https://github.com/microsoft/MoGe); Prompt DA ViT-S 80 FPS / ViT-L 20.4 FPS at 768×1024 on A100 — [Prompt DA](https://arxiv.org/html/2412.14015)
- Model sizes: DA3Metric-Large 0.35B, DA3-Small 0.08B — [DA3 GitHub](https://github.com/ByteDance-Seed/Depth-Anything-3); MoGe-2 ViT-S 35M — [MoGe GitHub](https://github.com/microsoft/MoGe); VDA-Small 28.4M — [VDA GitHub](https://github.com/DepthAnything/Video-Depth-Anything)

### Inferences
- Feasibility tiers for the iPhone 17 Pro Max Neural Engine (extrapolated from the 15 Pro Max number and parameter/FLOP ratios, not measured):
  - **Real-time (≥15–30 FPS):** DA-V2-Small relative (current), DA-V2-Metric-Outdoor-Small (same architecture, needs custom conversion), VDA-Small (temporal attention may not map cleanly to the Neural Engine), MoGe-2 ViT-S, Metric3D v2 ViT-S (via ONNX→Core ML, unverified).
  - **Low rate (~1–5 Hz):** ViT-L class (DA3Metric-Large, DA-V2-L, VDA-L). These have ~13× the params of ViT-S. Usable as a periodic metric-scale "keyframe" alongside a fast relative model.
  - **Not viable:** Depth Pro, Metric3D v2 giant, DA3 Giant/Nested.
- Levers: F16 is the default and costs little accuracy. 6-bit palettisation roughly halves to thirds the size with ~1% error (Depth Pro case). Lower input resolution speeds things up, but a car at 40 m is only a few dozen pixels wide, so too small an input destroys far-range accuracy. Cropping the depth input around YOLO boxes, or running at full width only on the road region, keeps resolution where it matters.
- Background or battery limits (the project memory notes that background GPU work is banned on iOS) apply here too. Neural Engine models for a safety app running in the background need separate validation.

### Gaps
- No iPhone 16/17 Pro or iOS 26/27 Neural Engine benchmarks were found for any depth model.
- No measured Core ML latency was found for DA-V2 Metric, VDA, DA3, Metric3D v2, UniDepth v2, MoGe-2 or Prompt DA on any iPhone.
