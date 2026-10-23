# Real-time object detectors for iPhone (Core ML / ANE) to replace Apple's YOLOv3 Int8 — fact sheet (as of Oct 2026)

Context from the app (local code, not web): `SpatialAudioDetect/CameraRadar.swift` loads `YOLOv3Int8LUT.mlmodelc` (line 280), uses the back LiDAR or wide-angle camera (line 274-275), feeds the whole frame with `imageCropAndScaleOption = .scaleFill` (line 80, so the frame is stretched into the square input), and keeps detections with `confidence >= 0.3` (line 126). The app's tests use the label `"motorbike"` (`VehicleTracker.swift` line 140).

## 1. Latest YOLO versions: COCO mAP50-95, AP_small, params, FLOPs. What is state of the art in 2026?

### Takeaway
Ultralytics **YOLO26** (released January 2026) is the newest YOLO release. It has the highest mAP of any YOLO at each size: n 40.9, s 48.6, m 53.1, l 55.0, x 57.5. It drops DFL, can run without NMS (one-to-one head), and adds small-target-aware label assignment (STAL). YOLO12 is only slightly behind on AP, but Ultralytics itself says not to use it in production. YOLOv8, YOLOv9, YOLOv10 and YOLO-NAS have been overtaken.

### Cited Findings
**YOLO26 (Ultralytics), COCO val2017 at 640 px.** Speeds use the NMS-free head. AP_S comes from the YOLO26 paper's Table S8 (no AP_S was published for YOLO26n).

| Model | mAP50-95 (NMS) | mAP50-95 (end-to-end, no NMS) | AP_S | Params (M) | FLOPs (B) | CPU ONNX ms | T4 TRT10 ms |
|---|---|---|---|---|---|---|---|
| YOLO26n | 40.9 | 40.1 | n/a | 2.4 | 5.4–5.5 | 38.9 | 1.7 |
| YOLO26s | 48.6 | 47.8 | 29.5 | 9.5 | 20.7–20.9 | 87.2 | 2.5 |
| YOLO26m | 53.1 | 52.5 | 36.7 | 20.4 | 68.2–68.4 | 220.0 | 4.7 |
| YOLO26l | 55.0 | 54.4 | 38.4 | 24.8 | 86.4–86.8 | 286.2 | 6.2 |
| YOLO26x | 57.5 | 56.9 | 41.8 | 55.7 | 193.9–194.4 | 525.8 | 11.8 |

Sources: [Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/); [YOLO26 paper, arXiv 2606.03748, Table 7 and S8](https://arxiv.org/html/2606.03748v1). The docs and the paper give slightly different FLOPs; both values are shown above.

- YOLO26 changes from YOLO11:
  - DFL removed and the detection head made lighter.
  - Optional NMS-free one-to-one head, selected with `nms=False`.
  - ProgLoss.
  - STAL (small-target-aware label assignment), which gives small objects more positive labels during training.
  - MuSGD optimizer (SGD combined with Muon).
  - Up to 43% faster CPU ONNX inference than YOLO11n.
  - Source: [Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/).
- The docs page says "released January 2026" but also carries an unexplained "Aug 21, 2026" date stamp — [Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/).
- There is a `yolo26-p2.yaml` variant with an extra P2 head for small objects. It is released as an architecture file only, with no pretrained weights — [Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/).

**Other YOLOs, COCO val2017 (from the YOLO26 paper's Table S8).** Columns: Params (M), GFLOPs, T4 latency (ms), AP, AP_S. Source: [arXiv 2606.03748, Table S8](https://arxiv.org/html/2606.03748v1).
- YOLO12-S: 9 / 21 / 2.6 / **48.0** / 29.8
- YOLO12-M: 20 / 68 / 4.9 / 52.5 / 35.7
- YOLO12-L: 26 / 89 / 6.8 / 53.7 / 36.9
- YOLO12-X: 59 / 199 / 11.8 / 55.2 / 39.6
- YOLO11-S: 9 / 22 / 2.5 / 47.0 / 29.0
- YOLO11-M: 20 / 68 / 4.7 / 51.5 / 33.4
- YOLO11-L: 25 / 87 / 6.2 / 53.4 / 35.6
- YOLO11-X: 57 / 195 / 11.3 / 54.7 / 37.7
- YOLOv10-S: 7 / 22 / 2.5 / 46.3 / 26.8
- YOLOv10-M: 15 / 59 / 4.7 / 51.1 / 33.8
- YOLOv10-L: 24 / 120 / 7.3 / 53.2 / 35.8
- YOLOv10-X: 30 / 160 / 10.7 / 54.4 / 37.0
- YOLOv9-S: 7 / 27 / 3.5 / 46.8 / 25.7
- YOLOv9-M: 20 / 77 / 6.4 / 51.4 / 32.0
- YOLOv9-C: 26 / 103 / 7.2 / 53.0 / 36.2
- YOLOv9-E: 58 / 193 / 16.8 / 55.6 / 40.2

**YOLO12, nano size.** YOLO12n: 40.6 mAP, 2.6M params, 7.5 GFLOPs, 1.64 ms on T4.
- Ultralytics calls YOLO12 a community release that "may exhibit training instability, elevated memory consumption, and slower CPU throughput due to its heavy attention blocks". It says the model is maintained "for benchmarking and research" and recommends YOLO11 or YOLO26 for production.
- Source: [Ultralytics YOLO12 docs](https://docs.ultralytics.com/models/yolo12/).

**Nano-size numbers re-measured by the RF-DETR authors.** Their protocol gives lower numbers than Ultralytics publishes. Format: AP / AP_S / AP_M / AP_L. Source: [RF-DETR paper, arXiv 2511.09554, Tables 2 and 12](https://arxiv.org/html/2511.09554).
- YOLOv8n: 35.2 / 15.8 / 38.8 / 51.3
- YOLO11n: 37.1 / 17.3 / 40.7 / 55.6
- YOLOv8s: 42.4 / 22.2 / 47.1 / 59.6
- YOLO11s: 44.1 / 26.1 / 48.5 / 62.6
- YOLOv8m: 47.3 / 27.5 / 52.9 / 65.1
- YOLO11m: 48.3 / 29.1 / 53.8 / 66.3

These conflict with the YOLO26 paper, which lists YOLO11-S at 47.0 AP and 29.0 AP_S — [arXiv 2606.03748](https://arxiv.org/html/2606.03748v1).
- The RF-DETR paper explains the gap: "prior work often reports latency using FP16 quantized models, but evaluates accuracy with FP32 models", and "YOLO-based models often omit non-maximal suppression (NMS) when computing latency" — [arXiv 2511.09554](https://arxiv.org/html/2511.09554).

**YOLO-NAS.** Deci was acquired by NVIDIA in April 2024, and the original team no longer actively maintains the super-gradients repo — [Roboflow YOLO-NAS license page / search summary](https://roboflow.com/model-licenses/yolo-nas).

### Inferences
- For 2026, the state of the art within the YOLO family is YOLO26. Across all real-time detectors, the AP–latency front at s/m size is shared by YOLO26, DEIM/DEIMv2 and RF-DETR (see section 2). Only YOLO26 has a first-party Core ML/ANE export with published iPhone numbers.
- At s size, YOLO26s beats YOLO11s by +1.6 AP but only +0.5 AP_S. At m size the gain is larger: +3.3 AP_S (33.4 → 36.7).

### Gaps
- No AP_S was published for YOLO26n, and no AP_S for YOLO11n or YOLOv8n under Ultralytics' own protocol. Only the RF-DETR re-measurement (17.3 / 15.8) is available.
- The Ultralytics-reported values for YOLO11n (~39.5) and YOLOv8n/s/m (~37.3/44.9/50.2) are from memory and were not re-checked this session.
- I found no per-class COCO AP for motorcycle, bicycle or person for any of these models.

## 2. Alternatives: RT-DETR/RT-DETRv2, RF-DETR, D-FINE, DEIM/DEIMv2, YOLOX, NanoDet, PP-YOLOE, EfficientDet, Apple's own options

### Takeaway
The DETR-family models (RF-DETR, DEIM/DEIMv2, D-FINE) match or beat YOLO26 on COCO AP and often on AP_S at the same T4 latency. RF-DETR's AP_S lead is especially large on the Apache-licensed N/S/M sizes. The catches are on iPhone: these models are larger in parameters, run less cleanly on the ANE, and some lose a lot of accuracy in FP16. Apple ships no modern detector. Its model gallery still offers only YOLOv3 / YOLOv3-Tiny for detection.

### Cited Findings
**RF-DETR (Roboflow).** Columns: AP50 / AP50:95, T4 TensorRT FP16 latency, params, native input resolution. Source: [RF-DETR GitHub README](https://github.com/roboflow/rf-detr).
- Atto: 49.4 / 30.5, 1.0 ms, 7.4M, 380 px, PML 1.0 license
- Femto: 55.9 / 37.8, 1.4 ms, 7.9M, 384 px, PML 1.0
- Pico: 60.2 / 41.6, 1.7 ms, 8.4M, 560 px, PML 1.0
- **Nano: 67.6 / 48.4, 2.3 ms, 30.5M, 384 px, Apache 2.0**
- **Small: 72.1 / 53.0, 3.5 ms, 32.1M, 512 px, Apache 2.0**
- **Medium: 73.6 / 54.7, 4.4 ms, 33.7M, 576 px, Apache 2.0**
- **Large: 75.1 / 56.5, 6.8 ms, 33.9M, 704 px, Apache 2.0**
- XL: 77.4 / 58.6, 11.5 ms, 126.4M, 700 px, PML 1.0
- 2XL: 78.5 / 60.1, 17.2 ms, 126.9M, 880 px, PML 1.0

The paper is arXiv 2511.09554 (ICLR 2026) — [RF-DETR README](https://github.com/roboflow/rf-detr).

**RF-DETR AP_S, from the paper.** Format: AP / AP_S / AP_M / AP_L. Source: [arXiv 2511.09554](https://arxiv.org/html/2511.09554).
- N: 48.0 / 25.2 / 53.5 / 70.0
- S: 52.9 / 32.0 / 58.3 / 73.0
- M: 54.7 / 36.1 / 59.7 / 73.8
- L: 56.5 / 39.0 / 61.0 / 73.9
- 2XL: 60.1 / 43.2
- Max: 61.8 / 47.5

**LW-DETR, from the same paper.** Format: AP / AP_S. Source: [arXiv 2511.09554](https://arxiv.org/html/2511.09554).
- T: 42.9 / 22.7
- S: 48.0 / 26.7
- M: 52.6 / 32.5
- L: 56.1 / 37.1

**D-FINE (ICLR 2025 Spotlight), COCO-only training.** Columns: AP, params, GFLOPs, T4 latency (TensorRT 10.4, FP16). Source: [D-FINE GitHub](https://github.com/Peterande/D-FINE).
- N: 42.8, 4M, 7 GFLOPs, 2.12 ms
- S: 48.5, 10M, 25, 3.49 ms
- M: 52.3, 19M, 57, 5.62 ms
- L: 54.0, 31M, 91, 8.07 ms
- X: 55.8, 62M, 202, 12.89 ms

**D-FINE pretrained on Objects365 then fine-tuned on COCO.** S 50.7, M 55.1, L 57.3, X 59.3 AP — [D-FINE GitHub](https://github.com/Peterande/D-FINE).
- AP_S for these Objects365 variants, from the RF-DETR paper: N 22.9, S 32.6, M 37.6, L 40.6 — [arXiv 2511.09554](https://arxiv.org/html/2511.09554).
- AP_S for COCO-only D-FINE: S 29.1, M 33.2 — [arXiv 2606.03748, Table S8](https://arxiv.org/html/2606.03748v1).

**DEIM (v1, built on D-FINE).** Format: AP / AP_S, at the same params and latency as D-FINE. Source: [arXiv 2606.03748, Table S8](https://arxiv.org/html/2606.03748v1).
- S: 49.0 / 30.4
- M: 52.7 / 35.3
- L: 54.7 / 36.9
- X: 56.5 / 38.8

**DEIMv2 (released 2025-09-26, arXiv 2509.20787).** Columns: AP, params, GFLOPs, latency (the repo does not say on which hardware). Source: [DEIMv2 GitHub](https://github.com/Intellindust-AI-Lab/DEIMv2).
- Atto: 23.8, 0.5M, 0.8 GFLOPs, 1.10 ms
- Femto: 31.0, 1.0M, 1.7, 1.45 ms
- Pico: 38.5, 1.5M, 5.2, 2.13 ms
- **N: 43.0, 3.6M, 6.8, 2.32 ms**
- S: 50.9, 9.7M, 49.5, 5.78 ms
- M: 53.0, 18.1M, 84.1, 8.80 ms
- L: 56.0, 32.2M, 144.5, 10.47 ms
- X: 57.8, 50.3M, 200.0, 13.75 ms

Backbones: Atto to N use HGNetv2. S and M use a ViT-Tiny distilled from DINOv3-S. L and X use DINOv3-S / S+. The changelog says FLOPs were "corrected on 2026.10.22" because attention FLOPs had been left out, so treat the S–X FLOPs as provisional. Source: [DEIMv2 GitHub](https://github.com/Intellindust-AI-Lab/DEIMv2).

**RT-DETRv2.** Format: AP / AP_S, params, GFLOPs, latency. Source: [arXiv 2606.03748, Table S8](https://arxiv.org/html/2606.03748v1).
- S: 48.1 / 36.1, 20M, 60 GFLOPs, 4.6 ms
- M: 49.9 / 35.8, 31M, 92, 6.9 ms
- X: 54.3 / 35.8, 76M, 259, 13.9 ms

An AP_S of 36.1 at only 48.1 AP is unusually high for the S size. It may be a transcription error in the table.

**On RF100-VL, a benchmark of transfer to new domains** (format: AP / AP50). RF-DETR-S scores 60.9 / 87.5 against D-FINE-S at 60.3 / 85.3. RF-DETR-M scores 61.7 / 88.0 against D-FINE-M at 60.6 and RT-DETR-M at 59.6 AP — [arXiv 2511.09554](https://arxiv.org/html/2511.09554).

**YOLOX** was released in July 2021 under Apache 2.0 — [Roboflow YOLOX page](https://playground.roboflow.com/models/megvii/yolox).

**Roboflow's iOS guide (Nov 10, 2025)** recommends:
- RF-DETR Small to start most new iOS projects
- YOLO11 for the balance of speed and accuracy
- EfficientDet for multi-scale detection
- MobileNetV2-SSDLite for old devices, quoted at "63 FPS on iPhone 7 without GPU acceleration"

Source: [Roboflow blog](https://roboflow.com/blog/best-ios-object-detection-models).

**Apple's Core ML model gallery** lists only YOLOv3 for detection. Variants and sizes:
- YOLOv3: 248.4 MB
- YOLOv3 FP16: 124.2 MB
- YOLOv3 Int8LUT: 62.2 MB
- YOLOv3-Tiny: 35.4 MB, 17.7 MB and 8.9 MB variants

The page gives no mAP, input size or latency for them. It also lists DETR ResNet-50 (semantic/panoptic segmentation, COCO 2017, 43M params). The F16 version runs in 34.32 ms on an iPhone 16 Pro and 39 ms on an iPhone 15 Pro Max. Source: [Apple ML models](https://developer.apple.com/machine-learning/models/).

**Apple "Core AI".** Secondary reporting says Apple announced Core AI at WWDC 2026 as Core ML's successor, focused on on-device and Private Cloud Compute LLM and generative workloads. Whether Core ML is being deprecated or will coexist is unclear. Sources: [AppleInsider (pre-WWDC, citing Gurman)](https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml); [LetsDataScience](https://letsdatascience.com/news/apple-unveils-core-ai-for-on-device-generative-models-1142390f).
- Community Hugging Face repos already publish RF-DETR in a Core AI (`.aimodel`) format — [coreai-community/RF-DETR-CoreAI](https://huggingface.co/coreai-community/RF-DETR-CoreAI); [iosafat/RF-DETR-CoreAI-md](https://huggingface.co/iosafat/RF-DETR-CoreAI-md).

### Inferences
- At "small" size, AP_S ranks roughly as follows: D-FINE-S (O365) 32.6 ≈ RF-DETR-S 32.0 > DEIM-S 30.4 > YOLO12-S 29.8 ≈ YOLO26s 29.5 ≈ YOLO11-S 29.0. At "medium" size: D-FINE-M (O365) 37.6 > YOLO26m 36.7 ≈ RF-DETR-M 36.1 > YOLO12-M 35.7 > DEIM-M 35.3.
  - Each model was evaluated at its own native resolution: RF-DETR-S at 512 px, YOLO at 640 px.
  - So the DETR advantage on small objects is real but modest, about 2–3 AP_S at S size and roughly zero at M size.
- RF-DETR's "nano" has 30.5M params because of its DINOv2 ViT backbone. YOLO26n has 2.4M and DEIMv2-N has 3.6M. On a phone, RF-DETR-N is closer in memory and compute to a YOLO "m" than to a nano.
- Old or superseded for this purpose: YOLOX (2021), EfficientDet (2019/2020), MobileNet-SSD, NanoDet, YOLOv3/v3-Tiny. I fetched no current benchmark that puts them near the 2025–26 models.

### Gaps
- No COCO AP, AP_S or iPhone numbers were fetched for YOLOX, NanoDet/NanoDet-Plus, PP-YOLOE+ or EfficientDet-Lite. From memory, YOLOX-S is about 40.5 AP; this was not verified.
- No primary Apple developer documentation for "Core AI" was retrieved. Whether it changes how vision detectors are deployed on iOS 27 is unverified.
- I did not verify whether Apple's Vision framework offers any built-in vehicle detector. From memory it does not; only human, animal and face requests exist. Unverified this session.

## 3. Core ML export and measured iPhone / Neural Engine latency

### Takeaway
Ultralytics YOLO26 and YOLO11 have the most mature path. There is a first-party `format=coreml` export with FP16/INT8/W8A16 quantization and embedded NMS, plus a Swift iOS SDK. On an iPhone 17 Pro, YOLO26n INT8 runs detection at 640 px in **3.2 ms on CPU+ANE in single-image bursts, or about 11.3 ms per frame when sustained on live camera**.
- RF-DETR has a native Core ML export since `rfdetr[coreml]>=1.9.0`, but there are no official iPhone benchmarks, and community reports show the backbone ending up on GPU or CPU rather than the ANE.
- D-FINE and DEIMv2 have no Core ML exporter. D-FINE is known to collapse in naive FP16, which matters because the ANE computes in FP16.

### Cited Findings
**Ultralytics Core ML export arguments.** Source: [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/).
- `imgsz`: default 640. It can be an int, or a tuple `(height, width)` for rectangular input.
- `quantize`: one of `16` (FP16), `8` (INT8), `"w8a16"` or `32`. This replaces the deprecated `half` and `int8` flags.
- `nms`: `None` (default) leaves NMS to the app, `True` embeds NMS, `False` selects the NMS-free head.
- `dynamic=True` is "Not supported for classification or RT-DETR models, and cannot be combined with `nms=True`"; `batch` above 1 requires `dynamic=True`.
- Embedded NMS "supports detect, segment and pose with `dynamic=False`."

**Ultralytics iOS SDK.**
- It defaults to `.cpuAndNeuralEngine` on iOS 16+. Leaving out the GPU "avoids contention and frame-time jitter" in camera apps.
- Nano models come bundled. Larger models are downloaded on demand.
- Plain `.mlpackage` integration works with `VNCoreMLRequest`.

Source: [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/).

**Ultralytics known limitations.**
- CoreML inference and validation run on macOS only.
- Export runs on macOS or x86 Linux.
- On coremltools 9.x, `ComputeUnit.ALL` / `CPU_AND_GPU` can abort with "MLIR pass manager failed" on macOS hosts.

Source: [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/).

**Measured on iPhone 17 Pro, YOLO26n INT8.** Mean of 15 runs after 3 warm-up runs, single image, total ms. Source: [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/).

| Task | Input (px) | CPU only (ms) | CPU + ANE (ms) |
|---|---|---|---|
| Detect | 640 | 9.2 | 3.2 |
| Segment | 640 | 12.6 | 4.8 |
| Pose | 640 | 11.9 | 3.9 |
| OBB | 640 | 10.6 | 3.4 |
| Depth | 640 | 25.0 | 5.3 |

On the same device, an earlier sustained camera sweep measured 11.3 ms per frame for YOLO26n detect and 16.5 ms per frame for YOLO26n Depth.

**Roboflow's iOS blog** reports a YOLO11 case study that went from "21 FPS (PyTorch on-device) to 85 FPS" after Core ML export (device not named). It says ANE-optimized models see "3-5x speedups over CPU-only", and it lists "Some transformer attention mechanisms" as problematic on the ANE — [Roboflow blog](https://roboflow.com/blog/best-ios-object-detection-models).

**RF-DETR Core ML export.** Source: [RF-DETR Core ML cookbook](https://rfdetr.roboflow.com/latest/cookbooks/export-coreml/) (summarized via search).
- The call is `model.export(format="coreml")`, which produces a `.mlpackage` with no ONNX step.
- It needs macOS and `rfdetr[coreml]>=1.9.0`.
- Shapes are fixed (no dynamic batch) "for reliable ANE/GPU scheduling".
- The default precision is FP32. `coreml_precision="float16"` produces an ANE-oriented bundle "with more numeric drift".

There is also an ExecuTorch path, `model.export(format="executorch", backend="coreml")`, which produces a `.pte` file that runs FP16 on the ANE — [RF-DETR ExecuTorch cookbook](https://rfdetr.roboflow.com/latest/cookbooks/export-executorch/).

**RF-DETR community reports on iPhone (anecdotal).**
- RF-DETR Nano in FP32 ran at about 15 fps on an iPhone 14 Pro, apparently without the ANE. Other figures in the same thread range from about 10 fps at 512×512 up to a claimed 120 fps — [Reddit snapshot](https://reddit.sentinel-team.org/posts/1uc3qdf/snapshots/2026-06-26T22%3A16%3A49.53411Z).
- On the iOS 27 beta, the Core AI runtime still put the RF-DETR backbone on the GPU even when asked to prefer the Neural Engine. Running the whole model on the GPU was fastest — [HF coreai-community/RF-DETR-CoreAI](https://huggingface.co/coreai-community/RF-DETR-CoreAI).

**D-FINE and DEIMv2 export paths.**
- D-FINE officially exports to ONNX and TensorRT only; Core ML is not mentioned — [D-FINE GitHub](https://github.com/Peterande/D-FINE).
- "naively quantizing D-FINE to FP16 reduces performance to 0.5 AP" — [RF-DETR paper](https://arxiv.org/html/2511.09554).
- DEIMv2 exports to ONNX and TensorRT; Core ML is not mentioned. The repo warns: "With TensorRT 10.4, FP16 inference may produce incorrect outputs" — [DEIMv2 GitHub](https://github.com/Intellindust-AI-Lab/DEIMv2).

**Apple's own reference timings for transformer and ViT models.**
- DETR ResNet-50 F16: 34.32 ms on iPhone 16 Pro. The F16P8 version: 32.23 ms.
- Depth Anything V2 Small F16 (24.8M params, the depth model this app already ships): 26.21 ms on iPhone 16 Pro and 33.90 ms on iPhone 15 Pro Max.

Source: [Apple ML models](https://developer.apple.com/machine-learning/models/).

### Inferences
- **Estimated cost of larger YOLO26 sizes.** YOLO26s has about 3.8× the FLOPs of n (20.7 vs 5.4), and YOLO26m about 12.6×. If ANE time scales roughly with FLOPs, YOLO26s at 640 would take about 8–15 ms per frame sustained on an iPhone 17 Pro Max, and YOLO26m about 20–40 ms. These are estimates, not measurements. YOLO26s should fit comfortably at 30 fps alongside Depth Anything V2 Small (~26 ms on A18 Pro). YOLO26m would probably force the frame rate down to 15–20 fps when both run every frame.
- **Drop-in path.** Export with `nms=True` so Vision returns `VNRecognizedObjectObservation` with labels, as YOLOv3 does today. Exporting with `nms=False` gives raw NMS-free tensors, which the app would have to decode itself.
- **Label names will change.** The app expects Apple's "motorbike" naming. Ultralytics' COCO names use "motorcycle" (from memory, verify in the exported model's metadata).
- **Input aspect ratio.** The app currently stretches the full frame (`.scaleFill`). Ultralytics models are trained with letterboxing. A rectangular `imgsz=(480, 640)` or `(720, 1280)` export (tuples are supported) would avoid distortion, and would also avoid wasting pixels on padding.
- **DETR models on the ANE.** Models with FP16-sensitive decoders (D-FINE, and likely DEIM/DEIMv2, which share its regression head) are risky on the ANE. They need FP32 on GPU or a careful mixed-precision conversion. RF-DETR has an official exporter, but its ANE placement on iOS 27 is unproven.

### Gaps
- No published iPhone benchmarks were found for YOLO26s/m, for any model at 1280 px, or for RF-DETR, D-FINE or DEIM on the ANE.
- No iPhone 17 Pro Max specific numbers were found. The Ultralytics figures are for the iPhone 17 Pro, which uses the same A19 Pro chip class (assumption, not verified).
- The INT8 vs FP16 accuracy drop for YOLO26 under Core ML was not found. The YOLO26 paper reports no quantization accuracy results.

## 4. Licensing for shipping inside an iOS app

### Takeaway
Every Ultralytics model is AGPL-3.0 by default, including models you train yourself. That covers YOLOv8, YOLO11, YOLO12, YOLO26 and Ultralytics' RT-DETR implementation. A closed-source App Store app needs an Ultralytics Enterprise License (custom pricing), or the whole app must be released under AGPL-3.0.
- Clean permissive options: RF-DETR N/S/M/L (Apache-2.0), D-FINE (Apache-2.0, with a caveat on its Objects365 checkpoints) and YOLOX (Apache-2.0).
- Not cleanly permissive: DEIMv2 has moved to a custom license; YOLOv9 is GPL-3.0; YOLOv10 is AGPL-3.0; YOLO-NAS's pretrained weights are non-commercial.

### Cited Findings
**Ultralytics license terms.** Source: [Ultralytics license page](https://www.ultralytics.com/license).
- "All Ultralytics YOLO trained models fall under the AGPL-3.0 License by default." AGPL "covers the training code and the models produced by that training code".
- Complying means "publicly releasing the complete corresponding source code for the entire derivative work".
- "Proprietary / closed-source software" and "Any commercial product or service" require an Enterprise License.
- The Enterprise License covers YOLO26 and earlier versions, per project or organization-wide. Pricing is custom, via a quote form.
- Free AGPL use covers academic research, university coursework, personal and non-profit projects, provided the project is fully disclosed.

**RF-DETR.** The `rfdetr` package and the N/S/M/L weights are Apache-2.0. Atto, Femto, Pico, XL and 2XL are under "PML 1.0" and need the `rfdetr_plus` extension — [RF-DETR README](https://github.com/roboflow/rf-detr).

**D-FINE** is Apache-2.0. The repo itself warns that Objects365-trained checkpoints "should not be assumed to be commercially cleared under the D-FINE license" — [D-FINE GitHub](https://github.com/Peterande/D-FINE).

**DEIMv2** "is released under the DEIMv2 License" (LICENSE.md); commercial licensing requires contacting the authors — [DEIMv2 GitHub](https://github.com/Intellindust-AI-Lab/DEIMv2).

**YOLOv9, YOLOv10 and YOLOX.**
- YOLOv9 is labeled GPL-3.0, though Roboflow's own commercial guidance on that page points to AGPL terms or a paid license, so the page is inconsistent — [Roboflow YOLOv9 license page](https://roboflow.com/model-licenses/yolov9).
- YOLOv10 is AGPL-3.0 — [Roboflow YOLOv10 license page](https://roboflow.com/model-licenses/yolov10).
- YOLOX is Apache-2.0 — [Roboflow YOLOX page](https://playground.roboflow.com/models/megvii/yolox).

**YOLO-NAS.** The code is Apache-2.0. The pretrained weights are under LICENSE.YOLONAS.md, which is limited to research and non-commercial use.
- NVIDIA forum staff said commercial use is not permitted and licenses are no longer issued. One NVIDIA reply said the architecture (Apache) can be trained from scratch commercially. The forum is inconsistent.
- Sources: [Roboflow YOLO-NAS](https://roboflow.com/model-licenses/yolo-nas); [NVIDIA forum 326342](https://forums.developer.nvidia.com/t/licensing-and-usage-terms-for-yolo-nas-model/326342); [NVIDIA forum 352885](https://forums.developer.nvidia.com/t/yolo-nas-commercial-use/352885).

**Roboflow-hosted YOLO11.** On Roboflow's cloud, "a commercial license is included for every user, including the free plan". Self-hosting needs an Enterprise add-on or AGPL — [Roboflow blog](https://roboflow.com/blog/best-ios-object-detection-models).

### Inferences
- **If this is a hackathon or academic project (ADA'26 SunRise Challenge) published openly,** YOLO26 under AGPL is acceptable as long as the full app source is published under AGPL-3.0.
- **For an App Store release with closed source,** either budget for an Ultralytics Enterprise License or pick RF-DETR N/S (Apache), D-FINE N/S (Apache, COCO-only weights) or YOLOX (Apache).
- **Avoid for commercial use:** the smaller RF-DETR models (Atto, Femto, Pico) under PML, DEIMv2 under its custom license, and YOLO-NAS weights.

### Gaps
- The text of Roboflow's PML 1.0 was not retrieved, so the terms for the small RF-DETR models are unknown.
- The DEIM v1 and RT-DETR/RT-DETRv2 (lyuwenyu) repositories are believed to be Apache-2.0. Not verified this session.
- Apple's own license for its YOLOv3 Core ML conversion was not checked.
- Whether AGPL/GPL code is compatible with App Store distribution terms (the historical FSF objection) was not researched. Get legal review.

## 5. Small and distant objects: detecting a motorcycle at 30–50 m

### Takeaway
At 30–50 m, a motorcycle from a wide-angle phone camera falls well inside COCO's "small" range (<32×32 px) at 416–640 px input. Modern models roughly double YOLOv3-era small-object AP (AP_S about 29–37 for s/m models vs about 15–18 for YOLOv8n/YOLO11n-class nanos). Even so, resolution is the main lever: a larger rectangular input, or a second pass on a crop around the horizon/road band, does more than the choice of architecture.
- YOLO26's STAL adds only +0.6 AP_S.
- A P2-head variant exists, but only untrained.

### Cited Findings
- **STAL ablation**, using YOLO11s as the baseline:
  - Reference size s_ref=16 gives 46.8 AP (+0.2) and lifts AP_S from 29.0 to 29.6.
  - s_ref=8 hurts AP_S, and s_ref=32 also degrades results.
  - Source: [YOLO26 paper, arXiv 2606.03748](https://arxiv.org/pdf/2606.03748).
- **DFL removal ablation.** YOLO26s without DFL scores 46.3 AP / 27.9 AP_S — [arXiv 2606.03748](https://arxiv.org/html/2606.03748v1).
- **P2 head.** `yolo26-p2.yaml` adds a small-object head, with no pretrained weights — [Ultralytics YOLO26 docs](https://docs.ultralytics.com/models/yolo26/).
- **AP_S at nano and small size**, from the RF-DETR paper's protocol. Source: [arXiv 2511.09554](https://arxiv.org/html/2511.09554).
  - YOLOv8n: 15.8
  - YOLO11n: 17.3
  - LW-DETR-T: 22.7
  - D-FINE-N (O365): 22.9
  - RF-DETR-N: 25.2
  - YOLO11s: 26.1
  - RF-DETR-S: 32.0
  - D-FINE-S (O365): 32.6
- **AP_S at medium size**: YOLO26m 36.7, D-FINE-M (O365) 37.6, RF-DETR-M 36.1, DEIM-M 35.3 — [arXiv 2606.03748](https://arxiv.org/html/2606.03748v1); [arXiv 2511.09554](https://arxiv.org/html/2511.09554).
- **Effect of a fixed IoU threshold.** A third-party YOLO26 analysis notes that fixed-IoU assignment hurts targets covering under 1% of the image, the "small object vanishing" problem — [arXiv 2601.12882](https://arxiv.org/pdf/2601.12882).
- **Rectangular input.** Ultralytics Core ML export accepts `imgsz=(h, w)` — [Ultralytics Core ML docs](https://docs.ultralytics.com/integrations/coreml/).

### Inferences
**Pixel geometry (my own calculation).**
- Assumptions:
  - A main camera with about 24 mm-equivalent focal length, so about 74° horizontal field of view across the long side.
  - A motorcycle seen head-on is about 0.8 m wide and about 1.5 m tall with its rider.
  - The full frame width is mapped to the model input.
- At 40 m, the motorcycle spans about 1.15° × 2.15°. The resulting box size by input width:

| Input width | 30 m | 40 m | 50 m |
|---|---|---|---|
| 416 px (current YOLOv3) | ~8×15 px | ~6×12 px | ~5×9 px |
| 640 px | ~13×25 px | ~10×19 px | ~8×15 px |
| 1280 px | ~26×50 px | ~20×37 px | ~16×30 px |

- Everything below 1280 px is COCO-"small". A 2× crop of the road band, or the telephoto lens, roughly doubles these sizes again.
- **Cost of more resolution.** Compute scales with input pixels. 1280×720 is about 2.25× the pixels of 640×640, so a YOLO26s at 1280×720 costs about the same as a YOLO26m at 640 (~47 vs 68 GFLOPs). A two-pass scheme (full frame at 640 plus one 640 crop of the horizon band) costs about 2× a single pass. SAHI-style N-tile slicing costs about N+1 passes plus merging; with ~3 ms bursts for YOLO26n, a 2×2 tiling of YOLO26n is plausible within 33 ms.
- **Warning time.** A motorcycle at 50 km/h (13.9 m/s) covers 50 → 10 m in about 2.9 s. Each 10 m of extra detection range buys about 0.7 s of warning, which arguably matters more than a few points of COCO AP.
- **Training on the runner's own footage.** Fine-tuning on real rear-camera footage at the deployment resolution should help far-object recall more than switching architectures. The P2 variant needs this training anyway, because it ships without weights.

### Gaps
- No per-distance or per-pixel-size recall data was found for any model.
- No measured iPhone cost was found for SAHI or tiling, or for any model at 960/1280 px.
- The iPhone 17 Pro Max's camera field of view and sensor crop modes were not verified this session. The geometry above uses assumed values.

## 6. Do newer models reduce false positives vs YOLOv3 (calibration, precision at a given confidence)?

### Takeaway
Overall error is much lower: at s/m size, COCO mAP50-95 is about 47–53 vs YOLOv3's ~28–33. NMS-free and DETR heads also remove duplicate boxes. However, I found no published study comparing false-positive rates or calibration of YOLOv3 vs YOLO26 or DETRs at a fixed confidence. Confidence scores are not comparable across models, so the app's 0.3 threshold must be re-tuned on recorded footage.

### Cited Findings
- **YOLOv3 baseline.** From the YOLOv3 abstract: "At 320 × 320 YOLOv3 runs in 22 ms at 28.2 mAP", and it reaches 57.9 AP50 at 608 px in 51 ms on a Titan X (from memory of the abstract, not re-fetched this session) — [YOLOv3 paper, arXiv 1804.02767](https://arxiv.org/abs/1804.02767).
- **Confidence-threshold trade-off.** The RT-DETR paper notes that in NMS pipelines, a higher confidence threshold raises false negatives, while a low threshold (e.g. 0.001) floods the output with redundant boxes. The NMS IoU threshold is harder to tune than the confidence threshold — [RT-DETR paper, arXiv 2304.08069](https://arxiv.org/pdf/2304.08069).
- **YOLO26's NMS-free head.** It gives "a unique end-to-end assignment per ground-truth instance" and outputs "at most 300 detections per image". The end-to-end (no-NMS) mAP is 0.6–0.8 below the NMS branch (e.g. 48.6 vs 47.8 for s). The paper does not discuss false positives or detection-confidence calibration — [arXiv 2606.03748](https://arxiv.org/html/2606.03748v1).
- **DETR calibration.** In DETRs, usually one prediction per object is well calibrated and the rest are poorly calibrated — [Park et al., arXiv 2412.01782](https://arxiv.org/html/2412.01782v2). Cal-DETR is a training-time fix for DETR overconfidence — [NeurIPS 2023](https://neurips.cc/virtual/2023/poster/72856).
- **Post-hoc calibration.** Platt scaling of detector scores "does not affect AP values" but makes scores track the true likelihood of a correct detection — [MathWorks](https://www.mathworks.com/help/vision/ug/calibrate-object-detection-confidence-scores.html).

### Inferences
- **Fewer false positives at the same recall.** A model with about 20 more mAP50-95 points has a much larger precision-recall area, so at equal recall it should produce substantially fewer false positives than YOLOv3-416. The exact reduction must be measured on this app's own footage.
- **Fewer duplicate tracks.** An NMS-free head (YOLO26 `nms=False`, or any DETR) removes duplicate or overlapping boxes, which can otherwise spawn duplicate tracks in `VehicleTracker`. With `nms=True`, the IoU threshold still needs tuning.
- **Re-tuning the threshold.**
  - Record sessions with the existing `CameraRecorder` CSV log.
  - Label a small set of clips.
  - Pick a per-class confidence threshold from the precision-recall curve.
  - Optionally fit Platt or temperature scaling, so a threshold like 0.3 or 0.5 has a stable meaning.
- **Requiring persistence across frames.** Temporal confirmation (e.g. a track must persist for N frames, which the tracker already partly does) is the cheapest further reduction in false positives, regardless of model.

### Gaps
- No published comparison was found of false positives per image, precision at a fixed confidence, or expected calibration error between YOLOv3 and YOLO11/YOLO26/RF-DETR/D-FINE.
- No data was found on false positives from road-scene clutter (signs, bins, parked vehicles) for any of these models.
- YOLOv3-416's exact COCO AP (believed ~31.0 AP / 55.3 AP50) and AP_S (believed ~18.3 at 608 px) are from memory of the paper and were not verified this session.
