# Exercise camera tracking audit

Audit date: 2026-10-04. Catalog: all 280 exercises produced by migrations through 0055.

`ios/TresFort/Station/StationTrackingCatalog.json` is the executable mapping. Match canonical exercise IDs; names and aliases never grant support. The D1 contract test fails on missing, duplicate or unknown IDs. New or custom exercises default to manual tracking.

208 exercises have candidate profiles (193 repetition movements and 15 static holds); 72 have explicit manual fallbacks. 15 catalog entries can select an observation-only experiment. No mapping claims measured camera accuracy or enables workout writes.

## What the mapping means

- **Experiment:** the current app can run a local observation test. Counts and hold time remain estimates pending physical validation.
- **Candidate:** a reusable movement family and camera setup have been identified. A suitable rule and representative iPad trials are still required; the app offers manual logging or timing.
- **Manual:** current pose data or a fixed camera does not provide a sufficiently clear measurement. Keep existing manual reps, workout timers or equipment metrics.

Profiles group development work, not evidence of equivalence. Validate each exercise variant, camera view, unilateral/bilateral convention, slow/partial reps, occlusion and setup/rest false positives. Arm and leg sides must stay distinct; never sum alternating or simultaneous limbs into an invented rep total. Loads, assistance, equipment contact and form quality cannot be inferred by these counters.

## Hold countdown contract

Forearm plank and wall sit have experimental pose-triggered countdowns. The member explicitly enables the camera and arms a test. One second of a clear, stable side-view position starts timing; this setup second is excluded. During acquisition and reacquisition, the dwell restarts if any required joint moves more than 5% of the initial torso length from its position at the start of that dwell. This experimental jitter tolerance uses a fixed reference for the full second, so slow drift cannot accumulate between frames. Only consecutive observed hold frames add time. Leaving the position, unclear joints or a capture gap pauses the countdown and requires another stable second. Previously observed time is retained, so interrupted results are accumulated observed time, not a continuous-hold claim.

A second person, camera/view interruption, backgrounding or account boundary requires an explicit new test. Reaching the target freezes the estimate; it never logs a set, starts rest or advances the workout. The target comes from the selected workout prescription (including the legacy timed target), or starts at 30 seconds for a free experiment. A timed override on a rep exercise never selects an unrelated hold detector.

The plank experiment recognizes a forearm setup only. Side plank, hollow hold, dead hang, L-sit, handstand, lever, planche, ring support and bridge holds are mapped candidates with no enabled detector. A stable skeleton alone cannot prove that a person is supporting their weight or holding the intended position. Hold recording/replay is not introduced in this slice; the existing rep recordings keep their format.

## Existing implementations and datasets

A GitHub/source survey on 2026-10-04 found reusable implementations as well as
training/evaluation data. The catalog mapping is independent of the counting
engine; adding a mapped family does not require inventing a new detector.

| Candidate | Verified scope | Fit and remaining work |
|---|---|---|
| [QuickPose iOS SDK](https://github.com/quickpose/quickpose-ios-sdk) | Its [exercise library](https://docs.quickpose.ai/docs/MobileSDK/ExerciseLibrary) lists 24 entries, including squats, lunges, presses, curls, bridges and planks. | Broad native-iOS comparison candidate. `Package.swift` distributes the core as a binary; an SDK key and [device-based commercial terms](https://quickpose.ai/sdk-pricing/) apply. No account, key or subscription was created. |
| [RepCounterSDK](https://github.com/NazarKozak/RepCounterSDK) | MIT-licensed Swift source for squat, push-up, lunge, curl, shoulder press and plank, with custom rep/hold specifications. | Small source-based comparison candidate. At `94aaae7`, the plank rule uses hip angle and the timer has no capture-gap bound; preserve Station's position and lost-observation guards when evaluating reuse. |
| [PoseFit](https://github.com/tefooh/PoseFit) | At `6ca236b`, the classifier catalog has 22 labels and corresponding angle-based handlers. | Broader MediaPipe reference, GPL-3.0. Its `.keras` file is a text pointer marked missing binary; no release supplies the weights. The plank handler exposes hip angle/hold state but no timer. Reported 86.31% accuracy is exercise classification, not rep-count accuracy. |
| [FLAG3D](https://github.com/AndyTang15/FLAG3D) | [Research dataset](https://andytang15.github.io/FLAG3D/) with 60 fitness categories and 180K sequences, combining captured/rendered motion and natural video. | Training/evaluation data and action-recognition baselines. Its [agreement](https://andytang15.github.io/FLAG3D/License_FLAG3D.pdf) limits use to scientific research and excludes commercial use, including testing commercial systems. |
| [TransRAC / RepCount](https://github.com/SvipRepetitionCounting/TransRAC) and [Google RepNet](https://github.com/google-research/google-research/tree/master/repnet) | Research implementations for counting repetitive actions; RepCount provides action-cycle boundaries. | Useful counting baselines. TransRAC code is Apache-2.0, while its [paper](https://arxiv.org/html/2204.01018v1#S6) limits RepCount data to academic research; assess pretrained-weight terms separately. RepCount-B original videos are not released. |

Prioritize PoseFit's broader exercise rules and a TransRAC benchmark for the
catalog coverage question. PoseFit's learned component identifies the exercise;
its separate hand-authored counters still need count-accuracy evaluation. The
workout already identifies the selected exercise, so evaluating those counters
does not depend on recovering the classifier weights. The
TransRAC release samples 64 frames across a completed video and predicts a total
from a density map, so live incremental counting and an on-device port require
additional work. It does not provide hold timing. QuickPose and RepCounterSDK
remain native comparison candidates, and the current counters remain baselines.
Inspect availability, permissions and terms before importing code, models or
datasets; this source survey adds no dependency and is not an accuracy benchmark.

## Reusable profiles

| Profile | Measurement | Camera setup | Rule and limitation |
|---|---|---|---|
| Squat (`squat`) | Repetitions | Side view; hip, knee and ankle visible | Stand, lower, and return to standing. Front-facing depth needs a separate calibrated rule. |
| Single-leg squat (`single_leg_squat`) | Repetitions | Side or diagonal view of working leg | A complete lower-and-rise cycle for each leg. Identify the working leg; never borrow the resting leg. |
| Lunge / split squat (`lunge`) | Repetitions | Diagonal view with both legs visible | Lower and rise on the selected working side. Count sides separately; distinguish steps from repetitions. |
| Lateral lunge (`lateral_lunge`) | Repetitions | Front view with both feet in frame | Shift, bend the working knee, and return. Needs a lateral-motion rule and per-side counts. |
| Step-up (`step_up`) | Repetitions | Side view including platform and both feet | Step up fully, then return to the floor. Platform occlusion and lead-leg identity need validation. |
| Hip hinge / deadlift (`hinge`) | Repetitions | Side view of shoulder, hip, knee and ankle | Hinge down and return upright. Knee angle alone is insufficient; load is entered manually. |
| Single-leg hinge (`single_leg_hinge`) | Repetitions | Side view including supporting and free legs | Hinge and return on one supporting leg. Separate sides and balance corrections from complete reps. |
| Bridge / hip thrust (`bridge`) | Repetitions | Side view of shoulders, hips and knees | Raise the hips and return to the starting position. Bench, bar and floor occlusion require setup-specific validation. |
| Leg extension (`leg_extension`) | Repetitions | Side view with hip, knee and ankle exposed | Extend the working knee and return. Machine pads can hide the knee; count each working side. |
| Leg curl (`leg_curl`) | Repetitions | Side view with hip, knee and ankle exposed | Bend the knee and return. Seated, prone and standing positions need separate calibration. |
| Nordic / glute-ham raise (`nordic`) | Repetitions | Side view including knees and torso | Lower the torso and return to the start. Assistance and eccentric-only reps need explicit treatment. |
| Calf raise (`calf_raise`) | Repetitions | Side view including heels and toes | Lift the heels and lower completely. Requires foot landmarks and small-motion resolution beyond current joint data. |
| Elbow curl (`curl`) | Repetitions | Side or diagonal view of shoulders, elbows and wrists | Lower, curl, and lower each working arm. Keep arm counts separate, including alternating curls. |
| Bench / horizontal press (`horizontal_press`) | Repetitions | Side view of shoulders, elbows and wrists | Extend, lower, and press to extension. Rack and bench occlusion; independent arms need their own rule. |
| Push-up (`pushup`) | Repetitions | Side view including torso and arms | Lower and press back up while maintaining the starting body position. Distinguish setup, knee support and partial reps. |
| Overhead press (`overhead_press`) | Repetitions | Front-diagonal view with hands visible overhead | Press from shoulders overhead and return. Requires shoulder and wrist height as well as elbow angle. |
| Pike / landmine press (`inclined_press`) | Repetitions | Side view including torso and working arm | Press along the intended inclined path and return. Do not reuse horizontal-press thresholds without calibration. |
| Pull-up / pulldown (`pullup`) | Repetitions | Front-diagonal view with full arm path visible | Pull through the prescribed range and return. Hanging body motion and seated machines require different references. |
| Row (`row`) | Repetitions | Side-diagonal view of torso and working arms | Pull toward the torso and return. Torso motion and supported or unilateral variants need validation. |
| Dip (`dip`) | Repetitions | Side view with shoulders and elbows clear | Lower and press back to the starting support. Bars and rings can hide joints; assistance cannot be inferred. |
| Triceps extension (`triceps_extension`) | Repetitions | Side view of the working upper arm | Bend and extend the elbow along the selected exercise path. Overhead, prone and pushdown variants have different start poses. |
| Arm raise (`arm_raise`) | Repetitions | Front or side view aligned with the movement plane | Raise the arm and lower to the start. Front and lateral raises need different camera views and rules. |
| Fly / pull-apart (`fly`) | Repetitions | Front-diagonal view with both hands visible | Open and close the arms through the intended arc. Pressing and elbow flexion must not become fly reps. |
| Straight-arm pull / pullover (`straight_arm_pull`) | Repetitions | Side view of shoulder and wrist path | Move the extended arm through its arc and return. Needs torso-relative wrist motion, not an elbow-cycle counter. |
| Crunch / sit-up (`trunk_flexion`) | Repetitions | Side view including shoulders, hips and knees | Curl the trunk and return. Small crunches and full sit-ups need different range calibration. |
| Leg raise / reverse crunch (`leg_raise`) | Repetitions | Side view including torso and legs | Raise and lower the legs through the prescribed range. Different floor and hanging starts; distinguish swinging. |
| Hip abduction / adduction (`hip_abduction`) | Repetitions | View facing the leg movement plane | Move the working leg out or in and return. Per-side identification and machine-pad visibility are required. |
| Quadruped extension (`quadruped`) | Repetitions | Side-diagonal view of all supporting limbs | Extend the selected limb or diagonal pair and return. Count each side without counting weight shifts. |
| Dead bug (`dead_bug`) | Repetitions | Side-diagonal view of arms, hips and legs | Extend a diagonal arm/leg pair and return. Requires paired-limb tracking and explicit per-side counting. |
| Back extension (`back_extension`) | Repetitions | Side view of shoulder, hip and knee | Lower and raise the trunk or legs as prescribed. Apparatus and floor variants need distinct references. |
| Trunk rotation (`trunk_rotation`) | Repetitions | Front-diagonal view of shoulders and hips | Rotate and return for each side. 2D overlap can hide rotation; requires 3D validation. |
| Rollout / pike (`rollout`) | Repetitions | Side view with hands and feet in frame | Extend or fold the body and return to the start. Needs multiple joint relationships, not a single angle. |
| Jumping jack (`jumping_jack`) | Repetitions | Front view with hands and feet fully in frame | Open arms and legs, then close. Fast motion and frame coverage need validation. |
| Alternating knee drive (`knee_drive`) | Repetitions | Side-diagonal view including both knees | Drive one knee and return, counted per side. Distinguish running or plank starts and alternating steps. |
| Forearm plank (`plank`) | Seconds | Level side view with shoulder, elbow, wrist, hip, knee and ankle visible | Accumulate observed time after a stable forearm-plank position. Experimental posture recognition; cannot assess form, effort or floor contact. |
| Side plank (`side_plank`) | Seconds | View facing the chest with supporting arm and feet visible | Time a stable side-support position for the selected side. Needs support-side and body-orientation validation. |
| Wall sit (`wall_sit`) | Seconds | Level side view with shoulder, hip, knee and ankle visible | Time a stable seated hold with hips and knees bent. Camera cannot verify wall contact; use an actual wall. |
| Hollow hold (`hollow_hold`) | Seconds | Level side view including shoulders, hips and feet | Time the prescribed raised-shoulder and raised-leg position. Floor contact and lower-back position cannot be verified from joints. |
| Dead hang (`hang`) | Seconds | Full body side-diagonal view including bar and wrists | Time a stable overhead hanging position. Joints alone cannot prove grip, foot clearance or load-bearing. |
| L-sit (`l_sit`) | Seconds | Side view including hands, hips, knees and ankles | Time the supported upright torso with legs extended forward. Requires support contact and foot clearance validation. |
| Handstand (`handstand`) | Seconds | Side view with hands and feet fully in frame | Time a stable inverted support position. Inversion, wall support and safe entry need separate validation. |
| Lever hold (`lever`) | Seconds | Side view including support, torso and legs | Time the selected horizontal or tucked lever position. Front, back and tuck variants need distinct posture definitions. |
| Planche / crow support (`planche`) | Seconds | Side-diagonal view including hands and feet | Time the selected supported balance position. Contact, tuck and lean variants cannot share a generic plank detector. |
| Ring support (`ring_support`) | Seconds | Full body side-diagonal view including both rings | Time a stable upright straight-arm support. Cannot infer load-bearing or foot clearance from arm angles alone. |
| Gymnastic bridge hold (`gymnastic_bridge`) | Seconds | Side view including hands, shoulders, hips and feet | Time a stable raised bridge position. Needs its own geometry and support validation; never infer form quality. |

## Full catalog mapping

| Exercise | Canonical ID | Profile or manual reason | Availability |
|---|---|---|---|
| 90/90 Hip Switch | `ex_90_90_hip` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Ab Wheel Rollout | `ex_ab_wheel` | Rollout / pike | Candidate |
| Archer Pull-Up | `ex_archer_pullup` | Pull-up / pulldown | Candidate |
| Archer Push-Up | `ex_archer_pushup` | Push-up | Candidate |
| Arnold Press | `ex_arnold_press` | Overhead press | Candidate |
| Assisted Pull-Up | `ex_assisted_pullup` | Pull-up / pulldown | Candidate |
| Back Extension | `ex_back_extension` | Back extension | Candidate |
| Back Lever | `ex_back_lever` | Lever hold | Candidate |
| Back Squat | `ex_back_squat` | Squat | Experiment |
| Banded Glute Bridge | `ex_banded_glute_bridge` | Bridge / hip thrust | Candidate |
| Banded Pull-Apart | `ex_banded_pull_apart` | Fly / pull-apart | Candidate |
| Bar Muscle-Up | `ex_bar_muscle_up` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Barbell Calf Raise | `ex_bb_calf_raise` | Calf raise | Candidate |
| Barbell Curl | `ex_bb_curl` | Elbow curl | Experiment |
| Barbell Lunge | `ex_bb_lunge` | Lunge / split squat | Candidate |
| Barbell Reverse Wrist Curl | `ex_reverse_wrist_curl` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Barbell Row | `ex_barbell_row` | Row | Candidate |
| Barbell Shrug | `ex_bb_shrug` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Barbell Step-Up | `ex_bb_step_up` | Step-up | Candidate |
| Barbell Walking Lunge | `ex_bb_walking_lunge` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Barbell Wrist Curl | `ex_wrist_curl` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Bear Crawl | `ex_bear_crawl` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Belt Squat | `ex_belt_squat` | Squat | Candidate |
| Bench Dip | `ex_bench_dips` | Dip | Candidate |
| Bench Press | `ex_bench` | Bench / horizontal press | Experiment |
| Bicycle Crunch | `ex_bicycle_crunch` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Bike Erg | `ex_bike_erg` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Bird Dog | `ex_bird_dog` | Quadruped extension | Candidate |
| Bodyweight Calf Raise | `ex_bw_calf_raise` | Calf raise | Candidate |
| Bodyweight Curtsy Lunge | `ex_bw_curtsy_lunge` | Lunge / split squat | Candidate |
| Bodyweight Good Morning | `ex_bw_good_morning` | Hip hinge / deadlift | Candidate |
| Bodyweight Lateral Lunge | `ex_bw_lateral_lunge` | Lateral lunge | Candidate |
| Bodyweight Reverse Lunge | `ex_bw_reverse_lunge` | Lunge / split squat | Candidate |
| Bodyweight Single-Leg Hip Thrust | `ex_bw_single_leg_hip_thrust` | Bridge / hip thrust | Candidate |
| Bodyweight Single-Leg RDL | `ex_bw_single_leg_rdl` | Single-leg hinge | Candidate |
| Bodyweight Squat | `ex_bw_squat` | Squat | Experiment |
| Bodyweight Walking Lunge | `ex_bw_lunge` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Box Jump | `ex_box_jump` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Box Squat | `ex_box_squat` | Squat | Candidate |
| Broad Jump | `ex_broad_jump` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Burpee | `ex_burpee` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Cable Crossover | `ex_cable_crossover` | Fly / pull-apart | Candidate |
| Cable Crunch | `ex_cable_crunch` | Crunch / sit-up | Candidate |
| Cable Curl | `ex_cable_curl` | Elbow curl | Candidate |
| Cable Glute Kickback | `ex_cable_kickback` | Quadruped extension | Candidate |
| Cable Lateral Raise | `ex_cable_lateral_raise` | Arm raise | Candidate |
| Cable Overhead Triceps Extension | `ex_overhead_tricep_ext` | Triceps extension | Candidate |
| Cable Pull-Through | `ex_pull_through` | Hip hinge / deadlift | Candidate |
| Cable Rear Delt Fly | `ex_cable_rear_delt_fly` | Fly / pull-apart | Candidate |
| Cable Shrug | `ex_cable_shrug` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Cable Woodchop | `ex_woodchop` | Trunk rotation | Candidate |
| Calf Press | `ex_calf_press` | Calf raise | Candidate |
| Cat-Cow | `ex_cat_cow` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Chest-Supported Row | `ex_chest_supported_row` | Row | Candidate |
| Child's Pose | `ex_childs_pose` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Chin-Up | `ex_chinup` | Pull-up / pulldown | Candidate |
| Clamshell | `ex_clamshell` | Hip abduction / adduction | Candidate |
| Clean Pull | `ex_clean_pull` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Clean and Jerk | `ex_clean_jerk` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Close-Grip Bench Press | `ex_cgbp` | Bench / horizontal press | Experiment |
| Close-Grip Lat Pulldown | `ex_close_pulldown` | Pull-up / pulldown | Candidate |
| Commando Pull-Up | `ex_commando_pullup` | Pull-up / pulldown | Candidate |
| Concentration Curl | `ex_concentration_curl` | Elbow curl | Candidate |
| Conventional Deadlift | `ex_deadlift` | Hip hinge / deadlift | Candidate |
| Cossack Squat | `ex_cossack_squat` | Lateral lunge | Candidate |
| Couch Stretch | `ex_couch_stretch` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Crab Walk | `ex_crab_walk` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Crow Pose | `ex_crow_pose` | Planche / crow support | Candidate |
| Crunch | `ex_crunch` | Crunch / sit-up | Candidate |
| Dead Bug | `ex_dead_bug` | Dead bug | Candidate |
| Dead Hang | `ex_dead_hang` | Dead hang | Candidate |
| Decline Barbell Bench Press | `ex_decline_bench` | Bench / horizontal press | Candidate |
| Decline Dumbbell Bench Press | `ex_decline_db_press` | Bench / horizontal press | Candidate |
| Decline Push-Up | `ex_decline_pushup` | Push-up | Candidate |
| Deficit Deadlift | `ex_deficit_dl` | Hip hinge / deadlift | Candidate |
| Diamond Push-Up | `ex_diamond_pushup` | Push-up | Candidate |
| Dips | `ex_dips` | Dip | Candidate |
| Dragon Flag | `ex_dragon_flag` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Dumbbell B-Stance RDL | `ex_db_bstance_rdl` | Single-leg hinge | Candidate |
| Dumbbell Bench Press | `ex_db_press` | Bench / horizontal press | Experiment |
| Dumbbell Bulgarian Split Squat | `ex_db_split_squat` | Lunge / split squat | Candidate |
| Dumbbell Calf Raise | `ex_db_calf_raise` | Calf raise | Candidate |
| Dumbbell Curl | `ex_db_curl` | Elbow curl | Experiment |
| Dumbbell Farmer's Walk | `ex_db_farmers_walk` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Dumbbell Fly | `ex_db_fly` | Fly / pull-apart | Candidate |
| Dumbbell Front Raise | `ex_front_raise` | Arm raise | Candidate |
| Dumbbell Lateral Raise | `ex_lateral_raise` | Arm raise | Candidate |
| Dumbbell Lunge | `ex_db_lunge` | Lunge / split squat | Candidate |
| Dumbbell Overhead Triceps Extension | `ex_db_overhead_ext` | Triceps extension | Candidate |
| Dumbbell Pullover | `ex_db_pullover` | Straight-arm pull / pullover | Candidate |
| Dumbbell Push Press | `ex_db_push_press` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Dumbbell Reverse Fly | `ex_reverse_fly` | Fly / pull-apart | Candidate |
| Dumbbell Reverse Lunge | `ex_db_reverse_lunge` | Lunge / split squat | Candidate |
| Dumbbell Romanian Deadlift | `ex_db_rdl` | Hip hinge / deadlift | Candidate |
| Dumbbell Shoulder Press | `ex_db_ohp` | Overhead press | Candidate |
| Dumbbell Shrug | `ex_db_shrug` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Dumbbell Single-Leg RDL | `ex_db_single_leg_rdl` | Single-leg hinge | Candidate |
| Dumbbell Squat | `ex_db_squat` | Squat | Candidate |
| Dumbbell Step-Up | `ex_db_step_up` | Step-up | Candidate |
| Dumbbell Thruster | `ex_db_thruster` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| EZ-Bar Curl | `ex_ez_curl` | Elbow curl | Experiment |
| Eccentric Pull-Up | `ex_eccentric_pullup` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Elliptical | `ex_elliptical` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Face Pull | `ex_face_pull` | Row | Candidate |
| Feet-Elevated Push-Up | `ex_feet_elevated_pushup` | Push-up | Candidate |
| Fire Hydrant | `ex_fire_hydrant` | Hip abduction / adduction | Candidate |
| Flutter Kick | `ex_flutter_kick` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Front Lever | `ex_front_lever` | Lever hold | Candidate |
| Front Squat | `ex_front_squat` | Squat | Experiment |
| Glute Bridge | `ex_glute_bridge` | Bridge / hip thrust | Candidate |
| Glute Bridge March | `ex_glute_bridge_march` | Bridge / hip thrust | Candidate |
| Glute Ham Raise | `ex_ghr` | Nordic / glute-ham raise | Candidate |
| Glute Kickback | `ex_glute_kickback` | Quadruped extension | Candidate |
| Goblet Squat | `ex_goblet_squat` | Squat | Experiment |
| Good Morning | `ex_good_morning` | Hip hinge / deadlift | Candidate |
| Gymnastic Bridge | `ex_gymnastic_bridge` | Gymnastic bridge hold | Candidate |
| Hack Squat | `ex_hack_squat` | Squat | Candidate |
| Hammer Curl | `ex_hammer_curl` | Elbow curl | Experiment |
| Handstand Hold | `ex_handstand_hold` | Handstand | Candidate |
| Handstand Push-Up | `ex_hspu` | Pike / landmine press | Candidate |
| Hang Power Clean | `ex_hang_power_clean` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Hang Snatch | `ex_hang_snatch` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Hanging Leg Raise | `ex_hanging_leg_raise` | Leg raise / reverse crunch | Candidate |
| High Knees | `ex_high_knees` | Alternating knee drive | Candidate |
| High Pull | `ex_high_pull` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Hindu Push-Up | `ex_hindu_pushup` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Hip Abduction Machine | `ex_hip_abduction` | Hip abduction / adduction | Candidate |
| Hip Adduction Machine | `ex_hip_adduction` | Hip abduction / adduction | Candidate |
| Hip Thrust | `ex_hip_thrust` | Bridge / hip thrust | Candidate |
| Hollow Hold | `ex_hollow` | Hollow hold | Candidate |
| Hollow Rocks | `ex_hollow_rocks` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Inchworm | `ex_inchworm` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Incline Bench Press | `ex_incline_bench` | Bench / horizontal press | Candidate |
| Incline Dumbbell Curl | `ex_incline_db_curl` | Elbow curl | Candidate |
| Incline Dumbbell Fly | `ex_incline_db_fly` | Fly / pull-apart | Candidate |
| Incline Dumbbell Press | `ex_incline_db_press` | Bench / horizontal press | Candidate |
| Incline Push-Up | `ex_incline_pushup` | Push-up | Candidate |
| Inverted Row | `ex_inverted_row` | Row | Candidate |
| Jackknife Sit-Up | `ex_jackknife_situp` | Crunch / sit-up | Candidate |
| Jefferson Curl | `ex_jefferson_curl` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Jump Rope | `ex_jump_rope` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Jump Squat | `ex_jump_squat` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Jumping Jack | `ex_jumping_jack` | Jumping jack | Candidate |
| Jumping Lunge | `ex_jumping_lunge` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Kettlebell Clean | `ex_kb_clean` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Kettlebell Deadlift | `ex_kb_deadlift` | Hip hinge / deadlift | Candidate |
| Kettlebell Goblet Squat | `ex_kb_goblet_squat` | Squat | Candidate |
| Kettlebell Snatch | `ex_kb_snatch` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Kettlebell Swing | `ex_kb_swing` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| L-Sit | `ex_l_sit` | L-sit | Candidate |
| Landmine RDL | `ex_landmine_rdl` | Hip hinge / deadlift | Candidate |
| Lat Pulldown | `ex_lat_pulldown` | Pull-up / pulldown | Candidate |
| Leg Extension | `ex_leg_extension` | Leg extension | Candidate |
| Leg Press | `ex_leg_press` | Leg extension | Candidate |
| Low Cable Crossover | `ex_low_cable_crossover` | Fly / pull-apart | Candidate |
| Lying Leg Curl | `ex_lying_leg_curl` | Leg curl | Candidate |
| Machine Chest Press | `ex_machine_chest_press` | Bench / horizontal press | Candidate |
| Machine Dip | `ex_machine_dip` | Dip | Candidate |
| Machine Incline Press | `ex_machine_incline_press` | Bench / horizontal press | Candidate |
| Machine Reverse Fly | `ex_machine_reverse_fly` | Fly / pull-apart | Candidate |
| Machine Shoulder Press | `ex_machine_shoulder_press` | Overhead press | Candidate |
| Machine Triceps Extension | `ex_machine_tricep_ext` | Triceps extension | Candidate |
| Marching Wall Sit | `ex_wall_sit_marching` | Alternating knee drive | Candidate |
| Mixed-Grip Pull-Up | `ex_mixed_grip_pullup` | Pull-up / pulldown | Candidate |
| Mountain Climber | `ex_mountain_climber` | Alternating knee drive | Candidate |
| Muscle Clean | `ex_muscle_clean` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Muscle Snatch | `ex_muscle_snatch` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Neutral-Grip Pull-Up | `ex_neutral_pullup` | Pull-up / pulldown | Candidate |
| Nordic Hamstring Curl | `ex_nordic_curl` | Nordic / glute-ham raise | Candidate |
| One-Arm Dumbbell Row | `ex_one_arm_db_row` | Row | Candidate |
| Overhead Carry | `ex_db_overhead_carry` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Overhead Press | `ex_ohp` | Overhead press | Candidate |
| Overhead Squat | `ex_ohs` | Squat | Candidate |
| Pallof Press | `ex_pallof_press` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Paused Bench Press | `ex_paused_bench` | Bench / horizontal press | Experiment |
| Paused Squat | `ex_paused_squat` | Squat | Candidate |
| Pec Deck | `ex_pec_deck` | Fly / pull-apart | Candidate |
| Pigeon Pose | `ex_pigeon_pose` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Pike Push-Up | `ex_pike_pushup` | Pike / landmine press | Candidate |
| Pin Squat | `ex_pin_squat` | Squat | Candidate |
| Pistol Squat | `ex_pistol_squat` | Single-leg squat | Candidate |
| Planche Lean | `ex_planche_lean` | Planche / crow support | Candidate |
| Plank | `ex_plank` | Forearm plank | Experiment |
| Plank-to-Pike | `ex_plank_to_pike` | Rollout / pike | Candidate |
| Plyo Push-Up | `ex_plyo_pushup` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Power Clean | `ex_power_clean` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Power Snatch | `ex_power_snatch` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Preacher Curl | `ex_preacher_curl` | Elbow curl | Candidate |
| Pseudo-Planche Push-Up | `ex_pseudo_planche_pushup` | Push-up | Candidate |
| Pull-Up | `ex_pullup` | Pull-up / pulldown | Candidate |
| Push Jerk | `ex_push_jerk` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Push Press | `ex_push_press` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Push-Up | `ex_pushup` | Push-up | Candidate |
| Rack Pull | `ex_rack_pull` | Hip hinge / deadlift | Candidate |
| Renegade Row | `ex_renegade_row` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Reverse Crunch | `ex_reverse_crunch` | Leg raise / reverse crunch | Candidate |
| Reverse Curl | `ex_reverse_curl` | Elbow curl | Candidate |
| Reverse Hyperextension | `ex_reverse_hyper` | Back extension | Candidate |
| Reverse-Grip Barbell Row | `ex_reverse_grip_row` | Row | Candidate |
| Ring Dip | `ex_ring_dip` | Dip | Candidate |
| Ring Muscle-Up | `ex_ring_muscle_up` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Ring Push-Up | `ex_ring_pushup` | Push-up | Candidate |
| Ring Row | `ex_ring_row` | Row | Candidate |
| Ring Support Hold | `ex_ring_support_hold` | Ring support | Candidate |
| Romanian Deadlift | `ex_rdl` | Hip hinge / deadlift | Candidate |
| Rope Triceps Pushdown | `ex_rope_pushdown` | Triceps extension | Candidate |
| Rowing Erg | `ex_row_erg` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Russian Twist | `ex_russian_twist` | Trunk rotation | Candidate |
| Scapular Pull-Up | `ex_scapular_pullup` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Scissor Kick | `ex_scissor_kick` | Use manual reps: subtle or overlapping joint motion is not dependable with the current body landmarks. | Manual |
| Seated Barbell Press | `ex_seated_bb_press` | Overhead press | Candidate |
| Seated Cable Row | `ex_seated_cable_row` | Row | Candidate |
| Seated Calf Raise | `ex_seated_calf_raise` | Calf raise | Candidate |
| Seated Dumbbell Press | `ex_seated_db_press` | Overhead press | Candidate |
| Seated Leg Curl | `ex_seated_leg_curl` | Leg curl | Candidate |
| Shoulder Tap Push-Up Plank | `ex_shoulder_tap` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Shrimp Squat | `ex_shrimp_squat` | Single-leg squat | Candidate |
| Side Plank | `ex_side_plank` | Side plank | Candidate |
| Side-Lying Hip Abduction | `ex_side_lying_abduction` | Hip abduction / adduction | Candidate |
| Single-Arm Cable Curl | `ex_sa_cable_curl` | Elbow curl | Experiment |
| Single-Arm Cable Lateral Raise | `ex_sa_cable_lateral` | Arm raise | Candidate |
| Single-Arm Cable Pushdown | `ex_sa_cable_pushdown` | Triceps extension | Candidate |
| Single-Arm Cable Row | `ex_sa_cable_row` | Row | Candidate |
| Single-Arm Dumbbell Bench Press | `ex_sa_db_bench` | Bench / horizontal press | Candidate |
| Single-Arm Dumbbell Shoulder Press | `ex_sa_db_ohp` | Overhead press | Candidate |
| Single-Arm Kettlebell Swing | `ex_sa_kb_swing` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Single-Arm Landmine Press | `ex_landmine_press` | Pike / landmine press | Candidate |
| Single-Arm Landmine Row | `ex_landmine_row` | Row | Candidate |
| Single-Arm Lat Pulldown | `ex_sa_lat_pulldown` | Pull-up / pulldown | Candidate |
| Single-Arm Push-Up | `ex_single_arm_pushup` | Push-up | Candidate |
| Single-Leg Calf Raise | `ex_single_leg_calf_raise` | Calf raise | Candidate |
| Single-Leg Glute Bridge | `ex_sl_glute_bridge` | Bridge / hip thrust | Candidate |
| Single-Leg Leg Curl | `ex_single_leg_curl` | Leg curl | Candidate |
| Single-Leg Leg Extension | `ex_single_leg_extension` | Leg extension | Candidate |
| Single-Leg Leg Press | `ex_single_leg_press` | Leg extension | Candidate |
| Sissy Squat | `ex_sissy_squat` | Squat | Candidate |
| Sit-Up | `ex_situp` | Crunch / sit-up | Candidate |
| Skater Squat | `ex_skater_squat` | Single-leg squat | Candidate |
| Ski Erg | `ex_ski_erg` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Skin the Cat | `ex_skin_the_cat` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Skullcrusher | `ex_skullcrusher` | Triceps extension | Candidate |
| Smith Machine Bench Press | `ex_smith_bench` | Bench / horizontal press | Candidate |
| Smith Machine Row | `ex_smith_row` | Row | Candidate |
| Smith Machine Squat | `ex_smith_squat` | Squat | Candidate |
| Snatch | `ex_full_snatch` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Snatch Pull | `ex_snatch_pull` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Spider Curl | `ex_spider_curl` | Elbow curl | Candidate |
| Split Jerk | `ex_split_jerk` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| StairMaster | `ex_stairmaster` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Standing Calf Raise | `ex_standing_calf_raise` | Calf raise | Candidate |
| Standing Leg Curl | `ex_standing_leg_curl` | Leg curl | Candidate |
| Stationary Bike | `ex_stationary_bike` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Stiff-Legged Deadlift | `ex_stiff_leg_dl` | Hip hinge / deadlift | Candidate |
| Straight-Arm Pulldown | `ex_straight_arm_pulldown` | Straight-arm pull / pullover | Candidate |
| Suitcase Carry | `ex_db_suitcase_carry` | Use manual reps or a manual timer: travel may leave a stationary camera's view. | Manual |
| Suitcase Deadlift | `ex_db_suitcase_dl` | Hip hinge / deadlift | Candidate |
| Sumo Deadlift | `ex_sumo_dl` | Hip hinge / deadlift | Candidate |
| Superman | `ex_superman` | Back extension | Candidate |
| T-Bar Row | `ex_tbar_row` | Row | Candidate |
| Thoracic Rotation | `ex_thoracic_rotation` | Trunk rotation | Candidate |
| Thruster | `ex_thruster` | Use manual reps: ballistic or compound phases need equipment tracking and a dedicated sequence model. | Manual |
| Toe-Touch Crunch | `ex_toe_touch_crunch` | Crunch / sit-up | Candidate |
| Towel Pull-Up | `ex_towel_pullup` | Pull-up / pulldown | Candidate |
| Trap Bar Deadlift | `ex_trap_bar_dl` | Hip hinge / deadlift | Candidate |
| Treadmill | `ex_treadmill` | Use the existing manual timer or equipment metrics; camera cycles do not establish duration, distance or effort. | Manual |
| Triceps Kickback | `ex_tricep_kickback` | Triceps extension | Candidate |
| Triceps Pushdown | `ex_tricep_pushdown` | Triceps extension | Candidate |
| Tuck Front Lever | `ex_tuck_front_lever` | Lever hold | Candidate |
| Tuck Jump | `ex_tuck_jump` | Use manual reps: flight, landings and fast motion need dedicated validation. | Manual |
| Tuck Planche | `ex_tuck_planche` | Planche / crow support | Candidate |
| Two-Arm Dumbbell Row | `ex_db_row_two` | Row | Candidate |
| Typewriter Pull-Up | `ex_typewriter_pullup` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Upright Row | `ex_upright_row` | Row | Candidate |
| V-Up | `ex_v_up` | Crunch / sit-up | Candidate |
| Wall Sit | `ex_wall_sit` | Wall sit | Experiment |
| Wall Walk | `ex_wall_walk` | Use manual reps: multiple phases, partial or one-way cycles, or changing support make a generic counter ambiguous. | Manual |
| Wide Push-Up | `ex_wide_pushup` | Push-up | Candidate |
| Wide-Grip Lat Pulldown | `ex_wide_pulldown` | Pull-up / pulldown | Candidate |
| World's Greatest Stretch | `ex_worlds_greatest_stretch` | Use manual reps or a manual timer: mobility endpoints and intended hold duration vary. | Manual |
| Zercher Squat | `ex_zercher_squat` | Squat | Candidate |
