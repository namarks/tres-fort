# Exercise visual options

Inspected October 6, 2026. This is a source comparison supporting the workout
library plan, not a purchase or license acceptance. The final section records the
October 11 adoption.

## Current assets

The app uses photographs from
[free-exercise-db](https://github.com/yuhonas/free-exercise-db), whose repository
declares the Unlicense. They are not original Très Fort illustrations. The
bundling script produces 256-pixel PNGs; the R2 upload script produces WebP at a
maximum 384 pixels. `DemoImageLoader` uses bundled images first, then the
authenticated Worker route. The technique sheet crossfades two stills.

Applying the repository migrations to an in-memory SQLite database at source
`23cad507e17aed3bc83e7279d0618c02d8757d12` gives 280 catalog exercises, 164 with
demo mappings. The 32 bundled image pairs match 33 catalog exercises. These are
source coverage counts, not a claim that all remote objects exist in production.

Visual inspection of the bundled squat and face-pull frames shows busy gym
backgrounds, inconsistent camera framing, and little resolution for enlargement.
At thumbnail size the equipment and body can be hard to separate. They remain
usable as recognition aids when shown without cropping; technique still needs
the larger sheet and exercise-specific text.

## Ranked replacement options

| Rank | Option | Fit and tradeoff | Remaining evidence |
|---|---|---|---|
| 1 | [Workout Guide](https://bryllim.github.io/workout-guide/), derived partly from Everkinetic | Best no-fee candidate to trial. The inspected squat/deadlift examples have transparent backgrounds and high-contrast line work that fits the dark app. The author lists 302 exercises and three SVG frames each. Assets are CC BY-SA 4.0; code is MIT. | Exact mapping to our catalog, per-frame technique review, asset attribution and share-alike handling, and legibility at 64 points. A matching title alone cannot establish the same variation/equipment. |
| 2 | [WorkoutLabs](https://workoutlabs.com/exercise-illustrations-licensing/) | Best commercial candidate. Consistent illustrated people and equipment; PNG/SVG and animated formats are offered. The provider lists 679 gym/mobility exercises. Published starting prices are $1,200/year or $3,500+ perpetual for the full content library; API pricing is separate. | Obtain an app-specific quote covering bundled/offline use and review exact catalog coverage. Professional/anatomical accuracy is the provider's claim, not independently established by this inspection. |
| 3 | [MuscleWiki](https://api.musclewiki.com/) | Consider for future on-demand technique video, not this offline thumbnail path. Broader video demonstrations may explain movement better than two crossfading stills. | Its [terms](https://api.musclewiki.com/api-terms) prohibit permanent media storage/rehosting, limit thumbnail caching, and require API-streamed video. It cannot be dropped into our bundled-assets/R2 design under those published terms. |

The open candidate's [guide](https://bryllim.github.io/workout-guide/guide/) and
[attribution record](https://github.com/bryllim/workout-guide/blob/main/ATTRIBUTION.md)
distinguish the code license from the artwork license and identify Everkinetic
source poses. These are upstream declarations; this comparison does not certify
the entire collection's provenance or exercise accuracy. Prefer pinned,
reviewed files and explicit mappings over a runtime dependency or fuzzy match.

## Recommendation

The owner selected "Finish previews now; recommend replacements separately" on
October 6. Complete the lightweight preview using the existing asset path.
For a future replacement, evaluate a small
matched set of open illustrations next: squat, hinge, horizontal press, cable
pull, unilateral dumbbell work, and a timed hold. Compare at thumbnail size and
in the technique sheet, keeping equipment, laterality and execution mode exact.
Only replace assets whose movement is verified; retain the stable fallback for
unmapped exercises. WorkoutLabs is the next option if the open samples or
coverage do not meet that bar and the owner chooses paid licensing.

Keep previews static even with motion enabled. Their role is recognition; the
name, prescription, group membership and accessible information action remain
the primary content. A larger media/provider replacement does not change a
member's saved workout or require a second exercise catalog.

## October 11 trial and decision

The owner asked why the app still showed photos, then chose a trial of the
first-ranked option. A side-by-side page compared squat, Romanian deadlift,
bench press, face pull, one-arm dumbbell row and plank at the 64 × 52 point
thumbnail and in the technique sheet. Every first frame read clearly once the
empty canvas margin was trimmed. Several later frames needed swapping: the
Romanian deadlift lowers the bar to the floor, the bench drawing can read as an
incline at small size, and the plank's later frames let the knees drop. The
owner approved the drawings, and P0.5(d) implements them.

The full review then checked every candidate frame for 172 name or alias
matches. 169 ship with chosen frames; the Romanian deadlift, skater squat
(drawn as a lateral lunge) and toe-touch crunch (drawn standing) keep their
photos. Matches whose equipment differs from the catalog, such as the barbell
curl against a dumbbell drawing, were left unmapped. The mapping and source
commit live in `scripts/exercise_drawings.json`.

Attribution: the drawings are © Bryl Lim, partly adapted from Everkinetic, under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The app crops
them and re-encodes them losslessly apart from rounding opacity to 32 levels.
Those adapted files remain under CC BY-SA 4.0. The technique sheet shows the
credit and license link wherever a drawing appears.

