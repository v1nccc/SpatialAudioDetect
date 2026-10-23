# Geometric (and lightly learned) monocular distance to detected vehicles: methods, accuracy, fusion, and filtering for a backward-facing runner-worn iPhone

Context: the prototype currently uses `Z = f * H_class / h_box` (car 1.5 m, motorbike with rider 1.45 m), LiDAR within 5 m, and time-to-contact (TTC) from box growth. Numbers marked "derived" are my own calculations from the cited equations, using an illustrative f ≈ 1000 px and camera height H ≈ 1.1 m. They are not measured results.

## Q1. Pinhole / triangle-similarity with known object size: height vs width, errors, box jitter, class size statistics

### Takeaway
Range from known size has a roughly constant relative error, set mainly by how much real vehicle sizes vary from the assumed prior. Mobileye's ACC paper puts width-based range at about 30% accuracy across unknown vehicle types. Restricted to one class, the height prior is much tighter: KITTI car heights mostly fall in 1.4–1.6 m, so about ±7%. Box jitter adds an error that grows linearly with distance, about 1–5% at 10–40 m for 2 px of jitter. Seen from front or rear, height is the more stable dimension because it does not change with yaw. Box width grows as soon as a vehicle's side comes into view.

### Cited Findings
- Stein, Mano & Shashua (Mobileye, IV 2003) name two monocular range cues: the size of the vehicle in the image, and the position of its bottom in the image. A vehicle of unknown type (car, van, truck) can be 1.5–3 m wide, so "a range estimate based on width will only be about 30% accurate". They class it as a sanity check and an out-of-calibration check, "not good enough for actuation control". — [Stein et al. 2003, PDF](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf) ([IEEE listing](https://ieeexplore.ieee.org/abstract/document/1212895))
- The same paper writes the scale relation as `w = fW/Z`, where W is the width "(or height)" of the target, so height and width are treated as interchangeable size cues. — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- KITTI car heights "mainly vary from 1.4 to 1.6 meters", per the WeakM3D appendix histograms. The same passage gives a length range of about 3.3–4.5 m, but its text is garbled and lists "width" twice. — [WeakM3D, arXiv 2203.08332](https://arxiv.org/pdf/2203.08332)
- KITTI labels store 3D size as height, width, length in metres. A tutorial's example Car label is about 1.73 m (h) × 1.87 m (w) × 4.60 m (l). — [KITTI tutorial](https://deepdatamininglearning.readthedocs.io/en/latest/KITTI_Tutorial.html)
- A per-category nuScenes size-range table found in an arXiv appendix gives approximate ranges. Motorcycle: 0.4–1.5 m wide, 1.1–2.0 m high, 1.2–2.8 m long. Car: 1.4–2.8 m wide, 1.2–3.1 m high, 3.4–6.6 m long. These are ranges, not means. The search summary did not say which of the returned papers holds the table, and I did not verify it by fetching. — [arXiv 2205.12519 (probable source)](https://arxiv.org/pdf/2205.12519)
- One study comparing depth sources for monocular 3D detection found that a known-vehicle-height assumption beat learned depth at longer ranges. It also found that the offset between the box and the object centre becomes an error source on curves, because the vehicle's heading is unknown. — [arXiv 2005.07424](https://arxiv.org/pdf/2005.07424)
- Mobileye's range-rate method does not rely on detector box edges. It aligns the image patch of the vehicle between frames, and "alignment errors of 0.1 pixels are possible if the image patch has a few hundred pixels". — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)

### Inferences
- Size-based error budget: σZ/Z ≈ sqrt((σH/H)² + (σh/h)²). The class prior term stays constant with range. For cars it is about ±7% if the fleet looks like KITTI (1.4–1.6 m), and ±15% or more once SUVs, vans, or pickups at 1.7–2.0 m appear. The 1.5 m car prior biases distance low for SUVs: a 1.8 m SUV reads about 17% closer than it is. That error is on the safe side for a warning app.
- Derived box-jitter term with f = 1000 px. A 1.5 m car is 150 px tall at 10 m, 75 px at 20 m, and 38 px at 40 m. Two pixels of jitter then gives about 1.3%, 2.7%, and 5.3% error. The prior dominates up to about 30–40 m, and jitter dominates beyond that. An int8 or low-resolution detector input (for example 416 px, upsampled to the frame) multiplies the jitter in frame pixels.
- Height vs width, viewed from front or rear:
  - Cars: height is invariant to yaw. Width inflates when the car is oblique, because the side shows (up to about 4.5 m of length). A car in an adjacent lane or turning therefore looks wider and closer. Use height. Width (about 1.7–1.9 m for cars) is only a cross-check when the box aspect ratio is near frontal.
  - Motorbikes: width is unreliable. The handlebars, mirrors, and the rider's arms set it, and nuScenes widths span 0.4–1.5 m. Height (bike plus rider, about 1.4–1.6 m) is the better cue. Rider posture adds variance: a sport tuck is lower than an upright scooter rider.
- Failure modes:
  - Truncation: a close vehicle overflows the frame, so h_box shrinks and the distance reads too far. This happens at a few metres, exactly where LiDAR takes over.
  - Partial occlusion, for example by a parked car, also inflates distance.
  - Shadows or road texture included in the box shrink distance.
  - Class confusion (truck taken for car) gives a 2x error.
  - Detector jitter of 1–3 px per frame needs temporal smoothing (see Q3).

### Gaps
- I found no official KITTI per-class mean dimensions table from the devkit. Commonly quoted means (car about 1.53 h × 1.63 w × 3.88 l) could not be verified this session.
- I could not verify the official nuScenes motorcycle mean size, or whether nuScenes motorcycle boxes include the rider.
- I found no published study that quantifies YOLO box-edge jitter in pixels on vehicles.

## Q2. Ground-plane / inverse perspective mapping (IPM): bottom-contact point, camera height and pitch, sensitivity, slope, height estimation, horizon

### Takeaway
On a flat road, the bottom-contact method gives `Z = fH / (y_bottom − y_horizon)`. With car-fixed calibration it is excellent: Mobileye quotes 5% error at 44 m and 10% at 90 m for 1 px of error. However, it is very sensitive to pitch, horizon, and camera height. With H about 1.1 m, a 1° pitch error turns 20 m into 15–29 m, and 40 m into 24–110 m. For a bouncing, arm-swinging runner, a ground-plane estimate is only competitive with the size prior within about 5–10 m, unless pitch is known to better than about 0.5°.

### Cited Findings
- Flat-road model: `y = fH/Z`, so `Z = fH/y`, where y is the image offset of the road-contact point below the horizon. After compensating for camera angle and road slope, "the main source of error is in determining the image coordinates of contact point", which "can be found to within 1 pixel". — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Error from n pixels of contact-point error: `Z_err = nZ²/(fH + nZ) ≈ nZ²/(fH)`. The error grows quadratically, so the percentage error grows linearly with range. Example: 640×480 image, 47° horizontal FOV, so f = 740 px, and H = 1.2 m. One pixel of error gives 5% at 44 m and about 10% at 90 m. — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Mobileye estimates the mounting angle and the dynamic pitch change separately, and compensates for road non-planarity "to a first order by analyzing the lane markings". — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- A Mobileye-lineage patent says range error comes from three sources: locating the bottom edge, locating the horizon, and deviation from the planar-road assumption. Another shows that just 2 px of horizon error gives significant distance error, and that "lower cameras are more sensitive". It gives a typical car camera height of 1.2–1.4 m. — [US patent 8378851](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8378851); [US patent 9223013](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9223013)
- A pitch-calibration patent for autonomous vehicles (2D box plus 3D distance) says about 0.5° of pitch error causes about 15% range error at about 20 m, and that the error grows with distance. It attributes per-frame pitch change to suspension, braking, acceleration, load, and uneven roads. — [US patent 10769793](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10769793)
- A JSAE 2021 paper estimates camera pitch per frame from 2D-to-3D box detections to improve monocular vehicle distance. — [JSAE 2021](https://tech.jsae.or.jp/paperinfo/en/content/conf2021-02.04/)
- A patent on adaptive ground-plane estimation fuses several cues (stereo or SfM, 3D points, detection boxes), weighting each per frame by its confidence. — [JP2018091857A](https://patents.google.com/patent/JP2018091857A/en)
- As a learned or IPM baseline on KITTI per-object distance, IPM has 49.7% abs-rel error for cars and 39.0% across all classes. This shows how badly the method does with fixed calibration over varied scenes and curves. — [DistFormer, arXiv 2401.03191](https://arxiv.org/html/2401.03191)

### Inferences
- Derived exact pitch sensitivity, using `Z = H / tan(atan(H/Z_true) ± δ)` with H = 1.1 m:

  | True Z | Angle below horizon | +0.5° | −0.5° | +1° | −1° |
  |---|---|---|---|---|---|
  | 5 m | 12.4° | 4.8 m | 5.2 m | 4.6 m (−8%) | 5.5 m (+10%) |
  | 10 m | 6.3° | 9.3 m | 10.9 m | 8.6 m (−14%) | 11.9 m (+19%) |
  | 20 m | 3.15° | 17.3 m | 23.8 m | 15.2 m (−24%) | 29.3 m (+47%) |
  | 40 m | 1.58° | 30.4 m | 58.6 m | 24.5 m (−39%) | 109.6 m (+174%) |

  The 20 m/0.5° row (−13% to +19%) matches the patent's "~15% at 20 m". The error is asymmetric: an upward pitch error can push the ray to or above the horizon, and the distance becomes infinite.
- Small-angle rule (derived): `σZ/Z ≈ (Z/H)·σθ` for pitch, plus `σH/H` for camera height. Camera-height error is linear and range-independent: a 10% H error gives a 10% Z error. Solving for where pitch alone produces 10% error at H = 1.1 m: about 6 m at σθ = 1°, about 13 m at 0.5°, and about 25 m at 0.25°.
- Contact-point pixel term for an iPhone (derived, Stein's formula, f = 1000 px, H = 1.1 m): 1 px gives about 0.9% at 10 m, 1.8% at 20 m, and 3.6% at 40 m. Pixel error is not the problem; pitch and H are.
- Camera height of a body-worn phone: about 1.0–1.4 m when chest- or armband-mounted, and it oscillates a few centimetres with each stride. A practical estimate: use ARKit/LiDAR ground depth behind the runner (the ground within 5 m is almost always visible) to fit a plane. That gives H and pitch relative to the actual road, not to gravity, which also absorbs slope at the runner's location. The road-slope change between runner and vehicle stays uncorrected. On a hill crest or sag it biases distant estimates strongly, because a 1° slope change acts like a 1° pitch error.
- Horizon from IMU: `y_horizon = c_y − f·tan(pitch)` (sign depends on axis convention), with pitch from Core Motion's gravity vector. Footstrike impacts and arm-swing angular rates make an instantaneous gravity-derived pitch error of ≥1° plausible. Ideally, sample the attitude at the frame timestamp, or low-pass and use the gyro-integrated attitude. This is a robustness concern, not a measured number.
- Vanishing-point or lane-based horizon (Mobileye style) is weak here: a backward view of a footpath or road shoulder may lack consistent lane lines.
- Other failure modes: the box bottom includes the car's shadow or is clipped by the frame edge; the vehicle's wheels are occluded by kerbs or parked cars; a motorbike's contact point is a narrow tyre, so the box bottom is noisier.

### Gaps
- I found no measured study of smartphone attitude (pitch) error during running. The ≥1° figure is an engineering guess that should be measured on-device, for example by logging Core Motion pitch against a LiDAR-fitted ground plane.
- I could not fetch the CarSafe (MobiSys 2013) full text (TLS error), so its phone-camera following-distance method and error numbers are not included. — [CarSafe PDF link](https://www.cs.dartmouth.edu/~campbell/carsafe.pdf)

## Q3. Combining methods: weighted fusion, LiDAR calibration, Kalman/tracking (SORT, ByteTrack, OC-SORT), TTC from scale change

### Takeaway
Fuse the size and ground-plane estimates by inverse variance. Their errors grow differently with range (size about constant percentage; ground-plane percentage proportional to Z·σθ/H), and they fail for different reasons (prior vs pitch). Use LiDAR at ≤5 m to calibrate both online. Then track each vehicle with a Kalman filter, and get closing speed and TTC from scale change over a longer window, not from differencing noisy ranges. Mobileye's analysis shows that range-rate error grows with Z² and falls with the time window, with an optimal window of about 0.3–0.65 s at 24–57 m.

### Cited Findings
- Range rate from scale change: with `s = (w − w′)/w′`, `v = ΔZ/Δt = Z·s/Δt`. Hence TTC = Z/v = Δt/s, which needs no size prior or camera height. Error: `v_err = Z²·s_err/(f·W·Δt) + nZv/(fH) + ½·a·Δt`. Notes from the paper:
  - the error is independent of velocity;
  - it grows with distance squared;
  - it is inversely proportional to Δt;
  - a narrower FOV (larger f) reduces it linearly.
  — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Worked example: following a small car at 30 m (f = 740 px, W = 1.5 m, H = 1.2 m, Δt = 0.1 s, s_err = 0.1 px) gives v_err ≈ 1 m/s. "Subtracting two noisy values for Z at two different time points cannot produce accurate measurements". Instead, compute ΔZ from scale change. — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Optimal window: `Δt = sqrt(2Z²·s_err/(f·W·a))`. With relative acceleration a = −1 m/s², it is 0.65 s at 57 m and 0.27 s at 24 m. At the optimum, the velocity error is linear in Z. The production system limited Δt to 2 s. Measured velocity error versus radar ground truth "lies mostly within the theoretical bounds". — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Mobileye patents estimate TTC from the ratio of the lead vehicle's image widths at two times. A related patent computes TTC from optical flow without object recognition. — [US patent 9251708](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9251708); [US patent 9925939](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9925939)
- On human looming perception: adapting to expansion lengthened perceived TTC by 18–25% with monocular cues, versus 8–16% binocular. This is a perception result, not machine accuracy. — [ASU / McMaster study](https://asu.elsevierpure.com/en/publications/adapting-to-expansion-increases-perceived-time-to-collision/)
- OC-SORT observes that Kalman-filter trackers assume linear motion. During occlusion the filter trusts its own predictions and error accumulates. OC-SORT uses detector observations to build a virtual trajectory over the occluded period ("Observation-Centric Re-Update"), and adds a direction-consistency term to IoU association ("Observation-Centric Momentum"). — [OC-SORT, arXiv 2203.14360](https://arxiv.org/abs/2203.14360); [Roboflow OC-SORT docs](https://docs.roboflow.com/workflows/blocks/blocks/video-processing/ocsort-tracker)
- ByteTrack keeps low-score detection boxes in a second association stage to re-associate unmatched tracklets. On MOT17 validation this improved SORT from 74.6 to 76.6 MOTA and from 76.9 to 79.3 IDF1, and cut ID switches from 291 to 159. ByteTrackV2 extends this to 3D. — [ByteTrackV2, arXiv 2303.15334](https://arxiv.org/pdf/2303.15334)
- CHARM3R (ICCV 2025): when camera height changes, regression-based depth and ground-based depth drift in opposite directions. Averaging the two inside the model improves generalisation to unseen camera heights by more than 45% (CARLA). This is direct evidence that size-type and ground-type estimates have complementary biases. — [CHARM3R, arXiv 2508.11185](https://arxiv.org/html/2508.11185v1)
- SORT's Kalman state is box centre, scale (area), aspect ratio, and their velocities (aspect ratio has none), with a constant-velocity model. From the SORT paper (not re-fetched this session). — [SORT, arXiv 1602.00763](https://arxiv.org/abs/1602.00763)

### Inferences
- Fusion recipe (derived):
  - `Z_fused = (Z_s/σs² + Z_g/σg²)/(1/σs² + 1/σg²)`.
  - Size estimate: `σs ≈ Z·sqrt(0.07–0.15² + (σh/h)²)`.
  - Ground-plane estimate: `σg ≈ Z·sqrt((σH/H)² + (Z·σθ/H)² + (σy·Z/(fH))²)`.
  - With σθ = 1°, the ground-plane estimate loses to the size prior beyond about 5–7 m. With a LiDAR-plane-referenced pitch at about 0.25°, it wins out to about 20 m.
  - Gate out the ground-plane estimate whenever the box bottom touches the frame edge, or the angle below the horizon is under about 2× σθ.
- LiDAR online calibration (≤5 m):
  - Fit the ground plane from the LiDAR depth map every frame to get H and pitch relative to the road.
  - When a tracked vehicle is in LiDAR range, solve `H_obj = Z_LiDAR·h_box/f` and store it as that track's size, replacing the class prior. As the vehicle moves away, Z from size then rests on a measured height, removing the 7–15% prior error for that track. This mainly helps vehicles that pass close and then recede, not approaching ones, so its value for an approach-warning app is limited.
  - A one-off calibration of the class prior is possible from any LiDAR-range sighting.
- Tracking state for distance: track in metric space with a constant-velocity Kalman filter. State `[Z, Ż]`, or `[log Z, d(log Z)/dt]`, where `−d(log Z)/dt = 1/TTC`. Feed in the fused Z measurement with its σ, and optionally the measured scale rate as a direct measurement of 1/TTC. Gating on the Mahalanobis distance rejects box glitches.
  - ByteTrack-style low-score re-association keeps tracks alive through blur and bounce frames.
  - OC-SORT re-update helps after short occlusions, for example a vehicle hidden behind a parked car.
  - Apple's Vision `VNTrackObjectRequest` could bridge detector frames, but it has no metric state.
- TTC from box scale (derived):
  - `σ_TTC/TTC ≈ σs/s`, with `σs ≈ √2·σh/h` for box-height jitter σh.
  - Example: car at 20 m (h = 75 px at f = 1000) closing at 10 m/s, so TTC = 2 s, with σh = 1.5 px. Over Δt = 0.2 s: s ≈ 0.11 and σs ≈ 0.028, about 25% TTC error. Over Δt = 0.5 s: s ≈ 0.33, about 8%.
  - So use a 0.3–1 s window, or a Kalman filter on log h, rather than frame-to-frame growth.
  - Detector box jitter (≥1 px) is 10x or more worse than Mobileye's 0.1 px patch alignment. Patch alignment or optical flow inside the box would sharply improve scale-rate precision.
- TTC robustness: TTC is the quantity most robust to the runner's motion, because it needs neither H, pitch, nor a size prior. Body bounce shifts and rotates the box, but scales it little. Forward and back motion of the runner's arm or torso (a few cm) is negligible against Z ≥ 5 m. The runner's own forward speed (3–5 m/s) away from a following vehicle subtracts from the closing speed, which is correct for TTC.

### Gaps
- I found no published accuracy evaluation of TTC from detector bounding boxes (as opposed to patch alignment) for vehicles. The numbers above are derived.
- I found no paper on monocular distance or TTC from a body-worn, backward-facing camera on a runner or cyclist with quantitative error. The closest domains are rear-facing bicycle cameras and smartphone ADAS (CarSafe), whose full texts I could not retrieve.

## Q4. Learned box-to-distance regressors (DisNet, Dist-YOLO, 2023–2025): reported errors and generalisation to camera height

### Takeaway
On KITTI, learned per-object regressors reach about 7–11% mean relative error over 0–150 m. Dist-YOLO reports 11%; DECADE about 7.3–8%; DistFormer about 10.4% abs-rel across all classes. DisNet sits around 10–25% depending on the benchmark. Their relative error is worst at 0–10 m (17–33%). Zero-shot transfer to a new camera roughly doubles the error. All of them are trained on car-roof cameras (KITTI is about 1.65 m high), and CHARM3R shows that depth regression degrades at unseen camera heights. They are not a drop-in replacement for geometry on a 1.1 m body-worn phone without fine-tuning.

### Cited Findings
- Dist-YOLO (Vajgl et al., Applied Sciences 2022): extends YOLO with a distance output. Mean relative error is 11% over all 8 KITTI classes within 0–150 m, at the same 45 FPS as unmodified YOLO. Code: gitlab.com/EnginCZ/yolo-with-distance. — [Dist-YOLO, DOI 10.3390/app12031354](https://doi.org/10.3390/app12031354); [DOAJ record](https://doaj.org/article/fa9b617ab74e4c86b6e78932790cf9e3)
- DECADE (2024), on KITTI with the Dist-YOLO split, 0–150 m:
  - Ground-truth boxes: DECADE 1.36 m MAE / 6.35% MRE vs DisNet 1.76 m / 9.89%.
  - End-to-end with YOLOv8n: DECADE 1.62 m / 7.98% vs DisNet 1.77 m / 11.12%. The abstract reports 1.38 m / 7.3%; the paper has an MRE inconsistency of 7.38 vs 7.98.
  - At 0–10 m with ground-truth boxes: DECADE 0.75 m MAE (16.71% MRE) vs DisNet 1.30 m (33.1% MRE).
  - Dataset: 6,699 training and 782 test images, distances clipped to 150 m.
  — [DECADE, arXiv 2410.19336](https://arxiv.org/html/2410.19336v1)
- DisNet (Haseeb et al., PPNIV 2018): a multi-hidden-layer network whose inputs are hand-computed YOLO bounding-box features, trained on 3D laser-scanner ground truth. It was tested mostly on railway scenes, and the authors claim it generalises across cameras. — [DisNet, Papers with Code](https://paperswithcode.com/paper/disnet-a-novel-method-for-distance-estimation)
- DistFormer (2024), Table 3, KITTI "All" abs-rel / RMSE: SVR 147.2% / 24.25; IPM 39.0% / 78.87; DisNet 25.3% / 6.92; Zhu et al. 54.1% / 8.74 (anomalous); DepthAnythingV2-B 27.37% / 6.11; DepthAnythingV2-L 27.22% / 5.65; DistFormer 10.39% / 2.95.
  - Car-class abs-rel (as reprinted): IPM 49.7%, DisNet 26.49%, Zhu et al. 16.1%.
  - nuScenes: DisNet 18.47%, Zhu et al. 14.95%, DistFormer 8.13%.
  — [DistFormer, arXiv 2401.03191](https://arxiv.org/html/2401.03191)
- DistFormer generalisation (pedestrians, trained on synthetic MOTSynth): zero-shot abs-rel 17.6–18.5% on KITTI and 19.9–20.7% on nuScenes. Fine-tuned: 5.4–6.1% (KITTI) and 10.3–15.6% (nuScenes). The authors note the datasets' intrinsics "are very different". — [DistFormer, arXiv 2401.03191](https://arxiv.org/html/2401.03191)
- Zhu & Fang (ICCV 2019) built distance-annotated KITTI and nuScenes object sets and showed that an end-to-end model beats IPM and SVR, "especially on curved roads". — [Zhu & Fang, ICCV 2019](https://openaccess.thecvf.com/content_ICCV_2019/html/Zhu_Learning_Object-Specific_Distance_From_a_Monocular_Image_ICCV_2019_paper.html)
- CHARM3R: monocular 3D detectors "work well at the camera height they were trained on but degrade at unseen heights". Depth estimation is the main cause. — [CHARM3R, arXiv 2508.11185](https://arxiv.org/html/2508.11185v1)
- KITTI's recording cameras are mounted at about 1.65 m above ground on the car roof. — [KITTI sensor setup](https://www.cvlibs.net/datasets/kitti/setup.php)

### Inferences
- Learned regressors partly memorise the camera height, pitch, and focal length of their training data. Box-bottom position is a strong input feature, effectively an implicit IPM. On a 1.1 m, constantly pitching phone, expect errors at least at zero-shot levels (about 20% or worse), and likely worse for the pitch-driven component.
- If a learned head is wanted, feed it pitch- and intrinsics-normalised inputs (box height × f, box bottom angle relative to the IMU horizon) and fine-tune on LiDAR-labelled self-collected data. Or keep geometry and learn only per-class size priors.
- Monocular DepthAnythingV2 (in this repo as `DepthAnythingV2SmallF16.mlpackage`) scored about 27% per-object abs-rel on KITTI even at B/L size, and Small will likely be worse. It also outputs relative depth, so it would need per-frame scale from LiDAR or the geometric estimate. It is not a better ranging source than the size prior at 10–40 m.
- At 0–10 m, learned regressors show their highest relative error (17–33%). That band is covered better by LiDAR (≤5 m) and by geometry with a large, well-resolved box (5–10 m).

### Gaps
- I could not retrieve Dist-YOLO's per-class or per-distance-range tables (MDPI returned 403), nor DisNet's original error figures.
- I found no learned-distance paper that evaluates on a body-worn or handheld camera, or on cameras below about 1.2 m.

## Q5. Realistic achievable accuracy bands at 10, 20, 40 m

### Takeaway
For this phone setup: about ±10–20% at 10–20 m from the size prior, about ±15–25% at 40 m, and better per-track once a LiDAR-calibrated size is known. Ground-plane estimates are good only near range unless pitch is referenced to the LiDAR ground plane. TTC from a 0.5–1 s scale window is the most robust warning signal, at about 10–25% error at 2 s TTC. All bands below except the citations are derived estimates, not measurements.

### Cited Findings
- Car-fixed, calibrated ground-plane (Mobileye): about 5% at 44 m and 10% at 90 m (1 px; f = 740, H = 1.2). — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Width-based range for an unknown vehicle type: about 30%. — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)
- Pitch error of 0.5° gives about 15% at 20 m. — [US patent 10769793](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10769793)
- Learned per-object regressors (KITTI, 0–150 m): 6.4–11% MRE overall; 17–33% at 0–10 m. — [DECADE](https://arxiv.org/html/2410.19336v1); [Dist-YOLO](https://doi.org/10.3390/app12031354)
- Range rate from scale change: about 1 m/s error at 30 m with a 0.1 s window and 0.1 px alignment, improving with longer windows. — [Stein et al. 2003](https://www.cs.huji.ac.il/~shashua/papers/IV2003.pdf)

### Inferences
Derived bands for the runner phone: f ≈ 1000 px, H ≈ 1.1 m, box jitter about 2 px, car height prior ±7–15%.

| Method | 10 m | 20 m | 40 m | Dominant error / failure |
|---|---|---|---|---|
| Size prior, height (current approach) | ±8–15% | ±8–16% | ±9–17% | Class height variance (SUV, van); jitter grows at 40 m; truncation <3–5 m; occlusion |
| Size prior with per-track LiDAR-calibrated height | ±2–4% | ±3–5% | ±5–8% | Only for tracks seen within 5 m; jitter only |
| Ground plane, IMU pitch σθ ≈ 1° | −14 / +19% | −24 / +47% | −39 / +174% | Pitch, bounce, slope; unusable beyond about 10 m |
| Ground plane, LiDAR-referenced pitch σθ ≈ 0.25°, σH 3% | ±5% | ±8–10% | ±15–20% | Road-slope change between runner and vehicle; bottom-edge/shadow |
| Inverse-variance fusion (size + LiDAR-referenced ground) | ±5% | ±7–9% | ±10–15% | Correlated failures (occlusion affects both) |
| Learned regressor, KITTI-trained, zero-shot on phone | ≥20–35% | ≥15–25% | ≥15–25% | Camera height and intrinsics domain shift; pitch |
| LiDAR (≤5 m) | cm-level, but no data beyond 5 m | n/a | n/a | Range limit; sunlight; small or dark targets |
| TTC from box scale, 0.5 s window, σh 1.5 px, TTC = 2 s | about 3–5% | about 8% | about 30%+ | Box jitter; needs a ≥0.3–1 s window; independent of H, pitch, and prior |

- Practical recommendation:
  - Keep height-based size ranging as the primary distance. Add LiDAR ground-plane estimation of H and pitch, and gate the ground-plane estimate to under about 15 m with an inverse-variance weight.
  - Run a per-track constant-velocity Kalman filter in log Z (ByteTrack-style association) for smoothed distance, closing speed, and TTC.
  - Base warnings mainly on TTC plus closing speed, which avoids the size and pitch priors entirely.

### Gaps
- No field measurements exist for this exact configuration (runner-worn iPhone, backward view). Every band above should be validated by logging detector boxes, Core Motion attitude, and LiDAR/ARKit depth against ground truth, for example laser-rangefinder or GPS-tagged test vehicles at 10/20/40 m.
