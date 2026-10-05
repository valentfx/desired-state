

## Live plots update 2026-10-04

# Live plots and EEG review — 2026-10-04

Live adds Delta and uses a common 0–100% axis for Delta/Theta/Alpha/Beta share of 1–30 Hz power. This is relative band power, not a validated state score. Device diagnostics retains absolute µV² and per-channel/raw data. Signal acquisition, processing and recorded raw/band values are unchanged.

The BPM/HRV overlay now has native numeric axes: first selected metric left, second right, matching their line colors. Additional selected metrics retain the legend/summaries and native detail plots. Line plots replace point markers across history, review and EEG views. Numeric endpoints remain on all plot axes. Short EEG panels show fewer tick labels to prevent overlap.

Live removes earlier/later/zoom buttons and hides the range slider while following live data. Dragging or tapping the plot still freezes inspection and reveals the slider; Back to live restores following. The toolbar and padding shrink, the H10 graph is taller, and the top session line includes Live when Live is selected. Diagnostics allows a five-second cadence gap rather than breaking ordinary O2Ring intervals at two seconds. The recorded timeline relies on explicit continuity/quality breaks instead of a two-second plotting cutoff; historical reduction no longer disconnects valid points. Missing/poor quality remains a gap.

## Uploaded recording: 202610040346375_E9E53B2C

119 H10 measurement rows, 143 RR rows, 59 ring readings, 169 acceleration frames, 212 ECG frames, and 478 Muse batches are present. Muse has 30,592 samples per channel (about 119.5 seconds at 256 Hz). All 100 saved band windows matched independent NumPy Hann-periodogram calculations to maximum relative discrepancy 1.11e-15. Four-channel threshold screening passed 84/100 windows.

Across those 84 windows, Delta was largest in 62 and Beta in 22; Theta was never the largest of all four bands. Median average powers: Delta 25.38, Theta 12.03, Alpha 6.59, Beta 7.26 µV². Live previously omitted Delta, making theta appear more dominant. Channels 1 and 4 show much larger slow power than channels 2 and 3 and raw correlation 0.824. This is compatible with shared artifact, but does not identify its cause or establish that the remaining EEG is artifact-free. Passing amplitude/step checks is a basic screen, not artifact removal.

Muse states that muscle and eye movement can generate stronger electrical signals than brainwaves: https://choosemuse.my.site.com/s/article/Visualizing-My-Brainwaves . Review the signals with still eyes-open, still eyes-closed, and deliberate blink/jaw/head-movement event markers before using the trends as state feedback. Those trials can help separate artifact sensitivity from reproducible changes. Relative percentages improve display readability; they do not eliminate artifact.

## Validation

Source delimiter/import checks, payload hashes and ZIP integrity pass locally. Flutter is unavailable in this execution environment. The installer backs up source, runs analysis, targeted and full tests, builds, then upgrades/launches the Android app. Hardware/overnight validation remains pending. Prior revision 5 and its installed formatted sources are accepted.

