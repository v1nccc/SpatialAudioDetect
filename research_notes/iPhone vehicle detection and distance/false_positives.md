# Reducing False-Positive Vehicle Detections in a Real-Time iPhone Collision Warner (COCO YOLO, rear camera, runner)

Context taken from the app's own code (this repo, read 2026-10-23):
- Detector: Apple's `YOLOv3Int8LUT.mlmodel` run through Vision. The **only** confidence gate is `top.confidence >= 0.3` on the top label, the same for every class. — [CameraRadar.swift](../../SpatialAudioDetect/CameraRadar.swift) (line ~126)
- Tracker: greedy IoU match at `>= 0.25`. Any unmatched detection **starts a track straight away**, and a track is dropped after 0.7 s unseen. The label can switch whenever a new detection's confidence is at least the track's confidence minus 0.1. — [VehicleTracker.swift](../../SpatialAudioDetect/VehicleTracker.swift)
- Tracked labels are `car, motorbike, bicycle, bus, truck, person` (the `vehicleHeights` dictionary). So **"person" detections become tracks and can raise warnings**. — [VehicleTracker.swift](../../SpatialAudioDetect/VehicleTracker.swift) (line 22)
- Warning: `timeToReach <= 3 s` and lateral offset `<= 2 m`, or LiDAR `<= 3 m` while closing at more than 1 m/s. `timeToReach` needs `>= 5` samples inside a 0.6 s window. That acts as an implicit "min hits" gate, but only on the time-to-contact path. LiDAR readings `<= 0.2 m` are discarded, and distance then **falls back to box size**. — [VehicleTracker.swift](../../SpatialAudioDetect/VehicleTracker.swift)
- The app already has "Vehicle passed now / Missed one / False warning" marker buttons and records video, tracks.csv and events.txt. This is a ready-made hard-negative collection tool. — [CameraRadar.swift](../../SpatialAudioDetect/CameraRadar.swift) (line ~461)

## 1. Confidence thresholds per class, NMS, precision/recall, calibration (YOLOv3 vs newer)

### Takeaway
A single global threshold of 0.3 is a weak gate. The evidence-backed pattern (ByteTrack) uses two thresholds: a **high threshold to start a track**, and a **low threshold only to keep an existing track alive**. Detector confidences are known to be miscalibrated, and the miscalibration varies by box size and position, so per-class thresholds have to be tuned on your own recordings rather than copied from the literature.

### Cited Findings
- ByteTrack sorts detections into high-score, low-score and background groups. High-score boxes are matched to tracks first. Low-score boxes are matched only to tracks still unmatched, and are never used to create new tracks. This recovers occluded true objects and throws away background low-score boxes. — [ByteTrack arXiv abstract](https://arxiv.org/abs/2110.06864); [Qure.ai ByteTrack explainer](https://blog.qure.ai/notes/byte-track-multi-object-tracking)
- ByteTrack paper default: "the default detection score threshold τ is 0.6". New tracks are initialised only from unmatched **high-score** detections (Algorithm 1). — [ByteTrack paper (HTML v3)](https://arxiv.org/html/2110.06864v3)
- ByteTrack reports being "more robust to the detection score threshold than SORT" when τ is swept from 0.2 to 0.8 (Fig. 3; the text gives no exact numbers). — [ByteTrack paper (HTML v3)](https://arxiv.org/html/2110.06864v3)
- Ultralytics ByteTrack defaults: `track_high_thresh: 0.25`, `track_low_thresh: 0.1`, `new_track_thresh: 0.25` (comment: "higher reduces false tracks"), `track_buffer: 30`, `match_thresh: 0.8`, `fuse_score: True`. — [Ultralytics bytetrack.yaml](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/trackers/bytetrack.yaml)
- Example custom Ultralytics configs raise these to `track_high_thresh 0.45`, `track_low_thresh 0.05`, `new_track_thresh 0.45`. That is, a stricter start gate with a looser keep gate. — [search-result summary of custom bytetrack yaml](https://git.factory.uga.edu/MODEL/USDA-throughput-control/src/commit/f7eb63473f879ebd6ce1fff9211aa49482311b17/Final/bytetrack_custom.yaml)
- Roboflow Supervision ByteTrack defaults: `track_thresh` (activation) 0.25, `match_thresh` 0.8, `track_buffer` 30 frames. — [Roboflow Supervision trackers](https://supervision.roboflow.com/trackers/)
- Calibration: recent state-of-the-art detectors are "rather miscalibrated compared to their predictive accuracy" on both in-domain and out-of-domain data. The authors propose a train-time loss that ties class confidence to precision. — [Bridging Precision and Confidence (arXiv 2303.14404)](https://ar5iv.labs.arxiv.org/html/2303.14404)
- Detector miscalibration depends on **box position and scale**, not only on class score. Küppers et al. calibrate confidence using box location and size, and release their code. — [Küppers et al., CVPRW 2020](https://openaccess.thecvf.com/content_CVPRW_2020/papers/w20/Kuppers_Multivariate_Confidence_Calibration_for_Object_Detection_CVPRW_2020_paper.pdf)
- "Box size confidence bias": confidence is conditionally miscalibrated across box sizes. Calibrating per size subgroup improves the precision-recall curve. — [The Box Size Confidence Bias Harms Your Object Detector (arXiv 2112.01901)](https://arxiv.org/pdf/2112.01901)
- A newer YOLO family (YOLO-World) also over- or under-estimates its confidences, and temperature scaling is studied as a fix. — [Uni Halle thesis/paper on YOLO-World calibration](https://www.opendata.uni-halle.de/handle/1981185920/121186)
- Stock YOLOv3 on COCO val in one unofficial run: **motorcycle mAP@0.5 = 0.704, car = 0.646** (IoU 0.5 only, checkpoint not stated). — [Mersive-Technologies/yolov3 log](https://github.com/Mersive-Technologies/yolov3)

### Inferences
- Copy ByteTrack's split in the app's tracker. Start a track only at a **high score** (about 0.5 for car/bus/truck to begin with, perhaps about 0.4 for motorbike if recall drops). Keep or extend a track at a **low score** (about 0.15–0.2). Never start a track from a low-score box. The current single 0.3 gate both starts and keeps tracks.
- Pick per-class thresholds by sweeping them offline on the app's own recordings (tracks.csv, plus the "False warning" and "Missed one" marks). Choose the operating point by **false warnings per hour vs missed approaches**, not by mAP. Published calibration papers show raw scores are unreliable across classes and box sizes, so numbers from other domains won't transfer.
- NMS: Vision already applies NMS inside Apple's YOLOv3 pipeline model, so it can't easily be tuned there. Car↔truck label flicker on one object can be handled by class-agnostic matching in the tracker, which the app already does through label switching. (Not verified: whether Apple's model applies per-class or class-agnostic NMS.)
- Summing the confidences of vehicle classes (car + truck + bus) for a box before thresholding would cut misses caused by car/truck confusion without lowering the threshold. This needs testing.

### Gaps
- No published per-class threshold table was found for COCO YOLO on vehicle classes in a collision-warning setting.
- I found no direct head-to-head calibration study comparing YOLOv3 with YOLOv8/YOLO11. The claim that newer models are better calibrated is unverified.
- I did not find Apple's YOLOv3 Core ML NMS settings (IoU threshold, class-agnostic or not) documented.

## 2. Temporal consistency: N-of-M confirmation, track age, IoU continuity

### Takeaway
Classic trackers require several consecutive hits before reporting a track (SORT: `min_hits = 3`). ByteTrack keeps lost tracks for 30 frames and only starts new tracks from high-score boxes. The ByteTrack paper's evidence is about identity and MOTA improvements; I found no direct quantitative study of how much N-of-M confirmation cuts flicker false positives.

### Cited Findings
- SORT defaults: `max_age = 1`, `min_hits = 3`, `iou_threshold = 0.3`. A track is output only if `trk.time_since_update < 1 and (trk.hit_streak >= self.min_hits or self.frame_count <= self.min_hits)`, which means at least 3 consecutive matched frames. SORT is GPL-3.0 licensed. — [abewley/sort sort.py](https://github.com/abewley/sort/blob/master/sort.py)
- ByteTrack keeps lost tracklets "for 30 frames in case it appears again". — [ByteTrack paper (HTML v3)](https://arxiv.org/html/2110.06864v3)
- MOT17 validation (Table 2): SORT 74.6 MOTA / 76.9 IDF1 / 291 ID switches. DeepSORT 75.4 / 77.2 / 239. MOTDT 75.8 / 77.6 / 273. **BYTE 76.6 / 79.3 / 159**. — [ByteTrack paper (HTML v3)](https://arxiv.org/html/2110.06864v3)
- BYTE (no interpolation) on MOT17 val: FP 3358, FN 9081 (Table 11). The comparison tables do not break out FP per tracker. — [ByteTrack paper (HTML v3)](https://arxiv.org/html/2110.06864v3)
- Adding BYTE to 9 different trackers improved IDF1 by 1–10 points. MOT17 test: 80.3 MOTA, 77.3 IDF1, 63.1 HOTA at 30 FPS on a V100. — [ByteTrack arXiv abstract](https://arxiv.org/abs/2110.06864)
- Ultralytics notes that a higher `track_buffer` "handles occlusion, increases ID switches risk". — [Ultralytics bytetrack.yaml](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/trackers/bytetrack.yaml)

### Inferences
- Add an explicit **confirmation state** in VehicleTracker. For example, a track counts as "confirmed" after at least 3 hits in its first 5 frames (SORT-style `min_hits = 3`). Unconfirmed tracks are drawn faintly and can never warn. At 15–30 fps, 3 hits costs 0.1–0.2 s of latency, which is small next to the 3 s warning horizon.
- Also require **label consistency**: most of a track's hits should be vehicle classes. A track that flips between person/car or chair/car should not warn. This targets the "hand or person labelled car for 2 frames" failure mode.
- Current behaviour: one unmatched 0.3-confidence box makes a new track, and the LiDAR "closingNear" path can warn without the 5-sample requirement. Gate both warning paths on the confirmation state.
- The ByteTrack "keep alive on low score" idea also helps recall. A real car that dips to 0.2 confidence for a few frames, for example under motion blur from running, keeps its track and its time-to-contact history.
- Running bounces the camera, so IoU between frames drops for small, far boxes. A matching threshold of 0.25 on IoU may break tracks for distant motorbikes. Consider centre-distance matching normalised by box size, as a fallback for small boxes. Untested.

### Gaps
- No paper or engineering blog was found that quantifies false-positive reduction from N-of-M confirmation specifically for vehicle detection or ADAS warnings.
- OC-SORT was not reviewed (out of tool budget). Its handling of non-linear motion under camera shake is unverified for this use.

## 3. Plausibility filters (size vs distance, aspect ratio, ROI/horizon, motion, edges, near-lens occlusion)

### Takeaway
I found no published sources with numeric thresholds for these filters in a phone-on-runner setting. They are standard engineering heuristics, and the app's own data (LiDAR, box growth, Vision boxes) makes them cheap to add. The highest-value one is a direct code observation: a hand or clothing near the lens gives a huge box and a sub-0.2 m LiDAR reading. The app then discards the LiDAR reading and estimates distance from box size, which yields a tiny distance and a possible warning.

### Cited Findings
- Box-size-dependent miscalibration is documented. Confidence on very large or very small boxes is less trustworthy, which supports adding size-aware gating. — [Box Size Confidence Bias (arXiv 2112.01901)](https://arxiv.org/pdf/2112.01901); [Küppers et al., CVPRW 2020](https://openaccess.thecvf.com/content_CVPRW_2020/papers/w20/Kuppers_Multivariate_Confidence_Calibration_for_Object_Detection_CVPRW_2020_paper.pdf)
- In the app, LiDAR depth `<= 0.2 m` is discarded (`$0 > 0.2 && $0 <= lidarRange`). Distance then falls back to `focalX * height / boxSize`. A full-frame box therefore reads as about 1 m away. — [VehicleTracker.swift](../../SpatialAudioDetect/VehicleTracker.swift)
- The app already estimates time to contact from the growth rate of `ln(size)`. Approaching objects grow, and growth slower than 1/10 s⁻¹ is treated as "not approaching". — [VehicleTracker.swift](../../SpatialAudioDetect/VehicleTracker.swift)

### Inferences (heuristics to tune on recordings; none are from sources)
- **Near-lens rejection**: drop a detection if the median LiDAR depth in the box is below about 0.3 m, or if the box covers more than about 60–70% of the frame height, or if it touches 3 or more frame edges. A real car that close is already past the point where a warning helps.
- **Size vs LiDAR consistency** (within 5 m): compute size-distance and LiDAR distance. If they disagree by more than about 2×, the box is wrong (a toy, a poster, a wheel bin), or the class height prior is wrong. Mark it as low trust and don't warn. The app already logs both values (`sizeDistance`, `lidarDistance`), so the ratio's distribution on true cars can be checked in tracks.csv.
- **Edge boxes**: a box clipped by the frame edge has a wrong size, and so a wrong distance and growth estimate. Exclude edge-touching boxes from time-to-contact, or require that the box was un-clipped at some point in the track.
- **Aspect-ratio priors** (from the rear, upright phone): cars and buses are roughly as wide as tall or wider; motorbike plus rider seen from front or rear is clearly taller than wide; a person is taller than wide. A "car" box that is much taller than wide is more likely a person or a door. Learn the per-class ranges from the app's recordings rather than hard-coding guesses.
- **ROI / horizon**: approaching road users sit with their box bottom near or below the horizon. The horizon line can come from CoreMotion gravity plus the camera intrinsics. Boxes that float entirely in the upper sky or tree region, or sit on the runner's own body at the very bottom, can be down-weighted. This needs field validation, because a phone swinging on a runner moves the horizon quickly.
- **Motion cue**: keep warnings tied to box growth (already done). Parked cars don't grow. Also require the growth to be consistent across the window: the slope's R² or sign agreement, not just its value, to stop jitter-driven warnings.
- **Drop `person` from warning-eligible labels** (keep it tracked for display if wanted). The objective is road vehicles, and person→warning is a direct false-positive source in the current code.

### Gaps
- No published numeric thresholds for edge, ROI or aspect ratio in a body-worn rear camera setting were found.
- No sources were found on hand or body occlusion near a body-worn camera lens for detection; this is inferred from the code.

## 4. Fine-tuning: datasets (viewpoint, motorcycles), licences, expected gains, hard-negative mining, own data

### Takeaway
Nearly every large driving dataset (BDD100K, nuScenes, Waymo, likely KITTI, Cityscapes and Mapillary Vistas) is **non-commercial**. That is fine for a student or research prototype, but any App Store or commercial release needs care. Waymo's licence explicitly covers models trained on its data. The most licence-safe and domain-matched path is **fine-tuning on the app's own recordings**: label true vehicles, add 0–10% background or false-positive frames, and use any SEA motorcycle data only after checking its licence. Model licence matters too. Apple's YOLOv3 comes from Darknet, which is public domain. Ultralytics models and code are AGPL-3.0.

### Cited Findings
- **BDD100K**: the Regents of the University of California notice grants use for "educational, research, and not-for-profit purposes". Commercial rights are limited to BDD/BAIR Commons members and affiliates. Other commercial licensing goes through UC Berkeley's Office of Technology Licensing. — [HF mirror of BDD100K card with licence](https://huggingface.co/datasets/dgural/bdd100k/commit/8e52994dbb62a377f075b6a345e913cc11b3a72e). This conflicts with a Roboflow re-upload labelled "Public Domain" — [Roboflow bdd-100k](https://universe.roboflow.com/1-ldnsb/bdd-100k-d4uwu). The re-upload label is probably wrong; the official doc.bdd100k.com page could not be reached (DNS failure).
- **Waymo Open**: "Waymo Dataset License Agreement for Non-Commercial Use" (March 2025). Non-commercial covers research, teaching, publication and personal experimentation. Trained models count as "Derivative IP" under the agreement. — [Waymo Open licensing](https://waymo.com/open/licensing)
- **nuScenes**: mostly CC BY-NC-SA 4.0, with modifications in its terms of use. — [nuscenes-devkit package page](https://pypi.tcis.de/data/web/json/nuscenes-devkit)
- **Mapillary**: images contributed to the Mapillary platform are CC BY-SA. The Vistas research dataset may differ (reported as CC BY-NC-SA in a secondary table). — [Map It Anywhere paper (arXiv 2407.08726)](https://arxiv.org/pdf/2407.08726)
- **IDD (India Driving Dataset)**: 10,000 images, finely annotated, 34 classes, from 182 drive sequences on Indian roads. — [IDD site](https://idd.insaan.iiit.ac.in/); [IIIT blog](https://blogs.iiit.ac.in/?p=28522). The content includes two-wheelers, motorised and non-motorised 3-wheelers, trucks, cars, pedestrians and animals. — [IIIT blog](https://blogs.iiit.ac.in/?p=28522). The licence is **not stated** on the homepage, and third-party catalogues list it as "other". — [IDD site](https://idd.insaan.iiit.ac.in/); [hyper.ai IDD entry](https://hyper.ai/en/datasets/17547). IDD-3D is a separate LiDAR release (12k frames). — [IDD-3D (arXiv 2210.12878)](https://arxiv.org/pdf/2210.12878)
- **Indonesian traffic obstacle dataset** (Mulyanto et al., 2021, for ADAS): 11 classes including motorcycles, 26,016 labelled instances in 7,789 images, evaluated with YOLOv4. It was built because local hazards such as pedicabs and street vendors are "not included in existing datasets". — [Universitas Indonesia research output](https://dara.ui.ac.id/research-output/23a432fd-ba87-4770-ba83-5b7575dee81f)
- **UGM thesis (2025)**: Indonesian vehicle-type dataset, 6,384 images / 9,475 annotations, 6 classes including sepeda motor. YOLOv7 + DeepSORT reached mAP@0.5 = 0.932. — [UGM ETD](https://etd.repository.ugm.ac.id/penelitian/detail/258333)
- **Ultralytics training guidance**: "≥ 1500 images per class" and "≥ 10000 instances per class" recommended. Add "about 0-10% background images to help reduce FPs" (COCO has 1,000 background images, about 1%). Background images need no labels. Every object must be labelled, because "Partial labeling will not work". — [Ultralytics tips for best training results](https://docs.ultralytics.com/yolov5/tutorials/tips_for_best_training_results/)
- **Model licences**: Apple's Core ML gallery lists YOLOv3 (248.4 MB), YOLOv3FP16 (124.2 MB), YOLOv3Int8LUT (62.2 MB), YOLOv3Tiny (35.4 MB), YOLOv3TinyFP16 (17.7 MB) and YOLOv3TinyInt8LUT (8.9 MB), with source pjreddie/darknet. The page states no licence. — [Apple ML models](https://developer.apple.com/machine-learning/models/). Darknet's LICENSE: public domain, "Do whatever you want with it." — [pjreddie/darknet LICENSE](https://github.com/pjreddie/darknet/blob/master/LICENSE). Ultralytics code and configs carry "Ultralytics AGPL-3.0 License". — [Ultralytics bytetrack.yaml header](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/cfg/trackers/bytetrack.yaml); [ultralytics.com/license](https://ultralytics.com/license)
- Ultralytics models export to Core ML with FP16, INT8 weight-only, or mixed INT8/FP16 options. — [Ultralytics Core ML export docs](https://docs.ultralytics.com/integrations/coreml)

### Inferences
- **Viewpoint mismatch**: BDD100K, KITTI, nuScenes, Waymo and Cityscapes are filmed from a car roof or dashboard at about 1.5 m, looking along the lane. A runner's rear camera is at chest or hip height, on the sidewalk, bouncing, often looking slightly up or down. Mapillary (crowd-sourced, including pedestrian phones) and the app's **own recordings** match the viewpoint best. The domain gap is an inference; no paper on sidewalk-height rear views was found.
- **Hard-negative mining loop with existing app features**: (1) record runs; (2) every "False warning" mark → export the frames around it and add them as background images with no labels, or with correct labels if real vehicles are present; (3) every "Missed one" → label the vehicle; (4) keep background frames at no more than 10% of the set, per Ultralytics guidance; (5) fine-tune and re-measure false warnings per hour on held-out runs. Hands, the runner's own arm and shirt, poles, bins, parked cars and dogs are likely false-positive sources and should be in the negatives.
- **Licence-safe path for a student/competition app**: NC datasets (BDD100K, nuScenes, Waymo, KITTI, Cityscapes) are OK for a non-commercial student prototype, subject to each licence's share-alike and attribution terms. They are risky for App Store monetisation, and Waymo carries over to trained weights. Own data plus Darknet-licensed YOLOv3 weights is the cleanest. Fine-tuning a newer Ultralytics model (YOLOv8/11/26) brings AGPL-3.0 obligations (open-sourcing the app or buying an Ultralytics enterprise licence).
- **Expected gains**: the only quantitative domain-specific evidence found is for Indonesian datasets with custom models (for example mAP@0.5 0.932 on a local 6-class set). These numbers are not comparable to COCO numbers, and none measure false warnings. Expect the largest gains for motorcycles and SEA-specific vehicles (angkot, bajaj, becak), which COCO doesn't have as classes.
- **Scale target**: Ultralytics' guidance of at least 1,500 images per class is a large labelling job. For a student team, a few hundred labelled frames per class from their own route, plus background frames, fine-tuned from COCO weights, is a realistic first step. Untested; tune by measured false warnings.

### Gaps
- KITTI (reportedly CC BY-NC-SA 3.0) and Cityscapes (reportedly academic/non-commercial only) licences were seen only in secondary search summaries. Verify at cvlibs.net/datasets/kitti and cityscapes-dataset.com.
- The IDD licence terms were not found (the homepage states none; the download page was not reachable without login). Verify before use.
- The Mapillary Vistas licence was not verified at the source.
- The COCO dataset licence (annotations and images) was not fetched in this pass.
- I did not establish whether the Mulyanto Indonesian dataset and the UGM dataset are publicly downloadable, or under what licence.
- No permissively licensed (Apache/MIT) modern detector alternative was researched in this pass (for example YOLOX or RT-DETR licences unverified).

## 5. Two-stage verification (classifier on crops) and phone cost

### Takeaway
I found no measured iPhone latency for a crop-verification classifier in this pass. Structurally, it only needs to run on newly confirmed tracks, about once per track rather than per box per frame, which keeps it cheap. Apple's own gallery offers MobileNetV2 and FastViT classifiers in Core ML.

### Cited Findings
- Apple's Core ML gallery offers image classifiers (MobileNetV2, ResNet-50, FastViT) that list object detection among their use cases. It states no licence for them. — [Apple ML models](https://developer.apple.com/machine-learning/models/)
- Apple's gallery also lists YOLOv3TinyInt8LUT at 8.9 MB, versus 62.2 MB for the full YOLOv3Int8LUT. — [Apple ML models](https://developer.apple.com/machine-learning/models/)
- The app already measures per-frame detector time (`detectMs`, shown as "model X ms") and runs a depth model every 3rd frame. This shows that per-N-frame scheduling of a second model is already a pattern in the code. — [CameraRadar.swift](../../SpatialAudioDetect/CameraRadar.swift)

### Inferences
- **Design**: when a track first becomes "confirmed" (section 2), crop the box with some padding, run a small binary classifier (vehicle vs not-vehicle, or car/motorbike/other), and re-check every about 0.5 s or when the label flips. Only verified tracks warn. The cost is bounded by the number of new tracks, not by frame rate.
- The classifier should be trained on the **app's own false-positive crops** (hands, arms, people, poles) against true vehicle crops from recordings. A COCO-pretrained ImageNet classifier alone may share the detector's confusions.
- Cheaper alternative with no new model: use the detector's own second-best labels. `VNRecognizedObjectObservation.labels` gives the full label distribution, so a box where "person" is close to "car" can be rejected. Untested.
- Measure before adopting: log classifier ms alongside the existing `detectMs`, and keep the total under 66 ms per frame for at least 15 fps.

### Gaps
- No sourced iPhone latency numbers for MobileNetV2/FastViT on 224×224 crops were obtained, and no study measured how much crop re-classification reduces false positives for vehicle detection.

## 6. Domain notes: motorcycles (Indonesia / Southeast Asia) and COCO models

### Takeaway
COCO YOLOv3 detects "motorcycle" as a class with mAP@0.5 around 0.70 in one unofficial run. However, COCO lacks SEA-specific vehicles, and dense motorcycle traffic needs local data. Several Indonesian datasets and theses exist, built for exactly this reason. Their public availability and licences are unconfirmed.

### Cited Findings
- Stock YOLOv3 COCO val (unofficial): motorcycle mAP@0.5 0.704, car 0.646. — [Mersive-Technologies/yolov3](https://github.com/Mersive-Technologies/yolov3)
- OpenVINO's YOLOv3 model, fine-tuned from COCO for person/vehicle/bike at crossroads: **AP vehicles 62.05%, AP bikes/motorcycles 25.66%**. Two-wheelers scored far lower than vehicles in this fine-tuned, merged-class model. — [OpenVINO person-vehicle-bike-detection-crossroad-yolov3-1020](https://docs.openvino.ai/2024/omz_models_model_person_vehicle_bike_detection_crossroad_yolov3_1020.html)
- The Indonesian traffic obstacle dataset (11 classes including motorcycles; 7,789 images) was created because local obstacles such as pedicabs and street vendors are missing from existing datasets. It was evaluated with YOLOv4 for ADAS. — [UI research output](https://dara.ui.ac.id/research-output/23a432fd-ba87-4770-ba83-5b7575dee81f)
- A YOLOv3 study detecting motorbikes on Indonesian sidewalks reported an average of 4 fps (hardware not stated in the snippet). — [Kalbis journal](https://ojs.kalbis.ac.id/ojs/index.php/kalbisiana/article/download/276/218/726)
- IDD includes motorised two-wheelers and three-wheelers, which matches the SEA traffic mix. — [IIIT blog](https://blogs.iiit.ac.in/?p=28522)

### Inferences
- In dense motorbike traffic, several motorbikes overlap. NMS may merge them, and greedy IoU tracking may swap them. Confirmation plus low-score keep-alive (ByteTrack style) matters more here than for sparse car traffic.
- Riders are also "person" detections overlapping the motorbike box. With `person` in the tracked labels, one motorbike can yield two tracks, and two warnings or doubled false positives. Suppress person boxes that mostly overlap a motorbike or bicycle box. This is another reason to remove `person` from warning-eligible labels.
- Motorbike recall is the safety-critical side, so give motorbike a lower start threshold than car if recordings show misses, and compensate with stricter temporal and plausibility checks.

### Gaps
- No official COCO per-class AP@[.5:.95] for car and motorcycle across YOLO versions was found.
- No public SEA motorcycle dataset with confirmed open licence was verified. Vietnam- and Thailand-specific datasets were not covered in this pass.
- No study of motorcycle detection from a pedestrian or rear-facing body-worn viewpoint was found.
