# JOIV paper 2826: YOLOv8 + OpenCV distance estimation (Syahrudin, Utami, Hartanto, 2025) — summary and critique

> **How these notes were sourced.** joiv.org sits behind a Cloudflare check. Plain curl and WebFetch got HTTP 403 ("Just a moment..."). The built-in browser got an interactive "Verify you are human" Turnstile box, which I did not attempt to complete. The Wayback Machine, scholar.archive.org/fatcat and DOAJ had no copy of the PDF, and the Semantic Scholar API returned 429. As a result, **I did not read the full text of the JOIV paper.** Everything below about the JOIV paper comes from the Crossref and OpenAlex metadata, including the publisher-deposited abstract.
>
> To fill the gaps, I read the full text of the **authors' immediately preceding paper on the same system** (JURNAL RESTI, 2024), which is openly hosted. Findings from that paper are labelled **[RESTI-2024]** and are *not* findings of the JOIV paper.
>
> To verify the JOIV-specific details, open https://joiv.org/index.php/joiv/article/viewFile/2826/1261 in a normal browser, pass the Cloudflare check by hand, and save the PDF.

## Q1. Identity and setup: title, authors, year, YOLO version, dataset, camera

### Takeaway
The paper is "Object Detection with YOLOv8 and Enhanced Distance Estimation Using OpenCV for Visually Impaired Accessibility" by Erwin Syahrudin, Ema Utami and Anggit Dwi Hartanto (Universitas Amikom Yogyakarta, Indonesia). It appeared in JOIV vol. 9 no. 2, published 31 March 2025, DOI 10.62527/joiv.9.2.2826. It uses **YOLOv8**. The application is navigation help for **visually impaired pedestrians**, not vehicles or runners. The dataset, camera device and mounting height are not stated in the abstract, and I could not verify them.

### Cited Findings
- Title "Object Detection with YOLOv8 and Enhanced Distance Estimation Using OpenCV for Visually Impaired Accessibility"; authors Erwin Syahrudin, Ema Utami, Anggit Dwi Hartanto; JOIV: International Journal on Informatics Visualization, vol. 9, issue 2, first page 575; published 2025-03-31; licence CC BY-SA 4.0 — [Crossref record](https://api.crossref.org/works/10.62527/joiv.9.2.2826)
- DOI 10.62527/joiv.9.2.2826. Landing page joiv.org/index.php/joiv/article/view/2826. The PDF link registered with Crossref is the viewFile/2826/1261 URL from the task — [Crossref record](https://api.crossref.org/works/10.62527/joiv.9.2.2826); [DOI](https://doi.org/10.62527/joiv.9.2.2826)
- All three authors are affiliated with Universitas Amikom Yogyakarta. The paper is listed as diamond open access, and OpenAlex counted 6 citations on the retrieval date (2026-10-23) — [OpenAlex](https://api.openalex.org/works/doi:10.62527/joiv.9.2.2826)
- Abstract: the paper "presents an advanced object detection system that utilizes YOLOv8, enhanced with OpenCV for distance estimation". The test scenarios include "busy streets and indoor settings". Performance is evaluated under varying lighting. There is a panic-button trigger, and output is translated into Indonesian and spoken — [Crossref abstract](https://api.crossref.org/works/10.62527/joiv.9.2.2826)
- [RESTI-2024] The same three authors had earlier published "Enhanced Yolov8 with OpenCV for Blind-Friendly Object Detection and Distance Estimation", JURNAL RESTI vol. 8 no. 2 (2024), pp. 199–207, published 29 March 2024. It describes the same pipeline: YOLOv8, OpenCV distance, a panic button and an Indonesian voice translator — [RESTI-2024 PDF (Horizon repository copy)](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf); [repository record](https://repository.horizon.ac.id/items/show/10400)
- [RESTI-2024] Data is described only in general terms: "images and distance measurements through field testing", with YOLOv8 "trained using an image dataset that included a variety of objects commonly encountered in urban environments". No image count, class list, camera model or mounting height is given. In its conclusion, the paper names COCO, Pascal VOC, Open Images and the Middlebury Stereo dataset as "important resources" — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- The authors followed up in 2025 with a paper comparing YOLOv8+OpenCV against a Coordinate Attention variant, which reports MSE over **0–5 m** distance intervals. It exists as a CommIT journal paper (vol. 19(1), pp. 45–57, 2025) and an INTENSIF vol. 9 no. 2 version with a fourth author, Suwanto Raharjo. I saw this only in search-result snippets: the CommIT site was down for maintenance and the INTENSIF PDF did not download — [CommIT landing](https://journal.binus.ac.id/index.php/commit/article/view/11820); [INTENSIF landing](https://ojs.unpkediri.ac.id/index.php/intensif/article/view/24395)

### Inferences
- The JOIV paper is the second publication in a three-paper series on one blind-navigation prototype from Amikom Yogyakarta, Indonesia. The country is inferred from the affiliation and the Indonesian-language output.
- The test scenes are pedestrian-scale: streets, indoor rooms, doors, chairs. Based on RESTI-2024 and the 0–5 m range of the follow-up, the camera is probably a handheld or worn device or webcam looking forward. This is unverified for the JOIV paper.

### Gaps
- Not verified for the JOIV paper: the YOLOv8 model size (n/s/m/l/x), whether the model was COCO-pretrained or custom-trained, the class list, dataset size, camera or phone model, resolution, mounting height and orientation.

## Q2. Distance method: formula, calibration and reference sizes

### Takeaway
The JOIV abstract says only "OpenCV for distance estimation", so the exact formula in the JOIV paper is **unverified**. The predecessor paper (RESTI-2024) states that it uses **stereo vision**, D = F × T / disparity with OpenCV StereoBM/StereoSGBM. It also mentions monocular size cues, but never describes a stereo rig, a baseline value, the calibration procedure or reference object sizes. The method description therefore does not match a reproducible pipeline.

### Cited Findings
- JOIV abstract: "YOLOv8, enhanced with OpenCV for distance estimation". No formula is named in the abstract — [Crossref abstract](https://api.crossref.org/works/10.62527/joiv.9.2.2826)
- [RESTI-2024] "This method uses stereo vision techniques to calculate depth based on the difference in the position of objects in two stereo images. With the help of the StereoBM or StereoSGBM algorithm contained in OpenCV, the distance of the object from the camera can be calculated" — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] Formula (1): DISTANCE = F × T / DISPARITY, where F is the focal length, T is the baseline between the two cameras, and disparity is the horizontal position difference between the left and right images — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] The same paper also says OpenCV "facilitates distance measurements by utilizing the principles of stereo vision or monocular signals". It describes monocular cues as using "the size or perspective of an object" from a single camera. It never says which of the two it actually ran — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] Error metric, formula (2): Percentage Error = |Actual − Recorded| / Actual × 100. Ground truth was obtained by "manual measurement" — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- The 2025 follow-up describes "camera calibration and depth estimation, utilizing techniques such as triangulation and reprojection" (search snippet only) — [CommIT landing](https://journal.binus.ac.id/index.php/commit/article/view/11820)

### Inferences
- RESTI-2024 does not describe a second camera, a baseline T, a value for F or a calibration board. That makes the stereo claim unverifiable and possibly boilerplate. The JOIV title's "Enhanced Distance Estimation" may refer to a changed method, but I could not confirm this.
- There is no evidence that this group uses the monocular pinhole relation D = f × H_real / h_box (or the width version) with per-class reference sizes. If the JOIV PDF turns out to use triangle similarity, record the per-class reference sizes it uses.

### Gaps
- The exact JOIV formula(s), the calibration procedure, the focal length value, the per-class reference widths or heights, and whether any stereo hardware was used. All of these need the full text.

## Q3. Reported results: detection metrics, distance error, FPS and hardware

### Takeaway
The JOIV abstract reports "average object detection accuracy of 91%" and "a low error rate of about 3.6%". It does not say whether 3.6% is a distance error or a detection error. The abstract also notes that performance drops in low light. RESTI-2024 reported an average distance error of 3.15%, measured only at **0.5–3.8 m**. Its YOLOv5-vs-YOLOv8 speed and accuracy numbers are quoted from another paper, not measured by the authors.

### Cited Findings
- JOIV abstract: precision, recall and F1 were evaluated under varying lighting. "Results show a decrease in performance during low-light conditions". "average object detection accuracy of 91% with a low error rate of about 3.6%" — [Crossref abstract](https://api.crossref.org/works/10.62527/joiv.9.2.2826)
- [RESTI-2024] Table 1 compares YOLOv5 and YOLOv8: accuracy 92.5% vs 94.2%, 25 vs 28 ms/frame, GPU use 70% vs 75%. The text introduces these numbers with "According to the findings [9]", so they are **cited from another work, not measured**, and the GPU model is not given — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] Table 3, car distance: six samples at actual distances of 200, 220, 240, 260, 280 and 300 cm. Errors were 5.4, 2.6, 1.1, 3.4, 0.5 and 1.6%, averaging 2.5%. Single-shot examples in Table 2 include a car at 5.2 m and a motorcycle at 4.1 m, with no ground truth shown — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] Other classes: door at 80–120 cm, 4.7% average error; chair at 50–130 cm, 5.2% (worst 13.8% at 50 cm); tree at 300–380 cm, 1.6%. The conclusion also lists person at 1.08% and motorcycle at 0.42%, and gives an overall average of 3.15% — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- The 2025 follow-up reports MSE "across distance intervals from 0 to 5 m" (search snippet only) — [CommIT landing](https://journal.binus.ac.id/index.php/commit/article/view/11820)

### Inferences
- [RESTI-2024] The numbers are internally inconsistent. The mean of the six per-class averages it lists (2.5, 4.7, 5.2, 1.6, 1.08, 0.42) is 2.58%, not the stated 3.15%. Table 2 marks the tree as not measured ("-"), yet Table 6 gives five tree measurements. This lowers confidence in the series' reporting. The arithmetic is mine, from the paper's own numbers.
- The JOIV "91% accuracy / 3.6% error" pair is a headline figure from the abstract. Without the full text, it cannot be tied to a specific test set, distance range or sample count.

### Gaps
- For the JOIV paper: the per-condition precision, recall and F1 tables, whether mAP is reported, the distance error per range, the number of test samples, FPS, and the inference hardware (GPU, laptop or phone). None of these are in the metadata.

## Q4. Limitations and validity, and fit for the iPhone rear-camera runner app (vehicles at 5–50 m)

### Takeaway
On the evidence available, the series validates distance only at **room or sidewalk scale (≤ about 5 m)**, with a handful of hand-measured samples per class (5–6 for cars). It is aimed at visually impaired pedestrians. Nothing supports accuracy at 5–50 m, for moving vehicles, or for a rear-facing phone at running height. YOLOv8 is a much newer YOLO than YOLOv3. However, the paper's distance method is not shown to beat the standard monocular pinhole estimate f × H_known / h_box, and the stereo formula it cites is impractical at these ranges on a phone.

### Cited Findings
- JOIV abstract: identified limitations are low-light degradation and planned future work on "infrared cameras" and "continuous training with diverse datasets" — [Crossref abstract](https://api.crossref.org/works/10.62527/joiv.9.2.2826)
- [RESTI-2024] The largest ground-truthed distance is 380 cm (tree). Cars were tested at 200–300 cm, with 6 samples. Ground truth was measured by hand — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- [RESTI-2024] The paper calls YOLOv8 "the latest version of YOLO" (at its 2024 publication) — [RESTI-2024 PDF](https://repository.horizon.ac.id/files/original/91141e3ef6b6030260a30066d631fd72.pdf)
- Background: YOLOv3 is Redmon & Farhadi, 2018 (arXiv 1804.02767). YOLOv8 is Ultralytics' 2023 release, which supports Core ML export. Both are general knowledge; I did not re-fetch these pages this session — [YOLOv3 arXiv](https://arxiv.org/abs/1804.02767); [Ultralytics YOLOv8 docs](https://docs.ultralytics.com/models/yolov8/)

### Inferences
- **Is YOLOv8 "newer than YOLOv3"?** Yes. YOLOv8 (2023) is anchor-free, has a decoupled head, and comes in n/s/m/l/x sizes. It is several generations after YOLOv3 (2018), and its small variants are usually both more accurate and lighter than YOLOv3. That comes from the YOLOv8 release itself, not from this paper: the paper benchmarks YOLOv8 only against YOLOv5, and with numbers borrowed from another paper. It offers no evidence for YOLOv8 vs YOLOv3 on vehicles.
- **Is its distance method better than f × H_known / h_box?** There is no evidence for that.
  - If the method really is stereo (D = F·T/disparity), it needs two calibrated cameras. iPhone rear lenses are only about 1–2 cm apart (an assumption, not measured here). The stereo depth error grows as ΔZ ≈ Z²·Δd / (f·B). With B ≈ 0.012 m, f ≈ 1500 px and a 1 px disparity error, ΔZ at 20 m is already larger than Z itself. These are illustrative assumed numbers, but stereo is clearly useless at 5–50 m on a phone.
  - If the method is a monocular size cue, it reduces to the same pinhole relation the app already uses.
  - The paper gives no evaluation beyond about 5 m, so it cannot show superiority in the 5–50 m band.
- **Ranking the error sources for the app's pinhole approach at 5–50 m** (my engineering reasoning, not from the paper):
  1. Variance of real vehicle heights within a class (car about 1.4–1.9 m, so roughly ±15% distance bias).
  2. Box tightness and jitter at small pixel heights. A 1.5 m car at 50 m with f ≈ 1500 px is about 45 px tall, so ±2 px is about ±4–5%.
  3. Partial occlusion, truncation and viewing angle.
  - Calibrating f per device (or reading the intrinsics from AVFoundation), using per-class reference heights, and temporal smoothing or Kalman filtering will matter more than switching YOLO generations.
- **Applicability:**
  - **Low as a distance-method reference.** The test range is wrong (≤ 5 m vs 5–50 m), the targets are wrong (static indoor and sidewalk objects vs approaching vehicles), the camera geometry is unspecified, and the samples are tiny and hand-measured, with internal inconsistencies.
  - **Moderate only as a weak signal on two points.** It shows that YOLOv8 runs in real time for assistive navigation, and that low light degrades detection, which also applies to evening runs.

### Gaps
- Whether the JOIV paper (as opposed to RESTI-2024) changed to a monocular triangle-similarity method, what its test distances were, and whether it reports FPS on a mobile device. All need the full text from joiv.org, which requires passing Cloudflare by hand.
- No independent replication or critical citing paper was found. OpenAlex shows 6 citations, which were not inspected.
