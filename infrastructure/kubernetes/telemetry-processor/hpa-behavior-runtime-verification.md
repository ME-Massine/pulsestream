# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `df2c16`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `af185ce733fdc1781bf365283719458aa8ce5caf` |
| Kubernetes versions | client `v1.36.1`; server `v1.36.1` |
| HPA identity | `telemetry-processor` UID `8c1180ca-dcd6-4fb0-87fe-8b0ed1bae32f`, generation `<not reported by API>`; UID, generation, and spec remained fixed throughout the run |
| SuccessfulRescale baseline | Established at 2026-08-27T13:40:44Z; pre-existing event UIDs/counts were excluded, and collection succeeded in all 38 samples |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `10s`, widest observed gap `22s`, gap before the scale-in recommendation `11s`, window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; consecutive samples more than `60s` apart stop counting as continuous observation) |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 800 events/s for 60s then 50 events/s per pod |
| Load heartbeat | `autoscaling-load-df2c16-1` advanced from `6400` to `57600` |
| HPA ScalingActive | `True` in all 37 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 2 of 2 replica transitions mapped one-to-one to post-baseline SuccessfulRescale occurrences from the exact HPA UID with an exact matching `New size`; 0 unmatched occurrence(s) |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 270s`: recommended continuously from 13:42:22Z (3 replicas, cpu utilization 46/70 (3 measured) -> 2, clamped to [2, 3] -> 2) through the last old-count sample at 13:46:52Z; decision observed at 13:47:03Z (anchor-to-observation spacing `281s`, recommendation turnover uncertain by the `11s` gap ending at the anchor). |
| Peak utilization | 97% |
| Peak replicas | 3, all Ready at the peak (highest Ready count observed: 3) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive  newly observed SuccessfulRescale events
13:40:44Z | cpu:        3%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:25:47Z ready=2 scalingActive=True rescaleEvents=-    <- baseline, before load
13:41:06Z | cpu:       18%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:25:47Z ready=2 scalingActive=True rescaleEvents=-
13:41:17Z | cpu:       18%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:25:47Z ready=2 scalingActive=True rescaleEvents=-
13:41:28Z | cpu:       76%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:25:47Z ready=2 scalingActive=True rescaleEvents=-
13:41:39Z | cpu:       91%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=2 scalingActive=True rescaleEvents=NewSize=3@c04a346b-dc34-48de-b16d-6da715b6c74d
13:41:49Z | cpu:       94%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=2 scalingActive=True rescaleEvents=-
13:42:00Z | cpu:       94%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=2 scalingActive=True rescaleEvents=-
13:42:11Z | cpu:       97%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:42:22Z | cpu:       46%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:42:32Z | cpu:       46%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:42:43Z | cpu:       16%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:42:54Z | cpu:       11%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:04Z | cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:15Z | cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:26Z | cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:37Z | cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:47Z | cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:43:58Z | cpu:       11%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:44:09Z | cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:44:19Z | cpu:       14%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:44:30Z | cpu:       14%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:44:41Z | cpu:        6%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:44:51Z | cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:02Z | cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:06Z | cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-    <- load removed
13:45:17Z | cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:27Z | cpu:        6%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:38Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:49Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:45:59Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:46:10Z | cpu:        2%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:46:20Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:46:31Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:46:42Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:46:52Z | cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:47:03Z | cpu:        1%/70%  2  3  3 | desired=2 hpaDesired=3 lastScale=13:41:32Z ready=3 scalingActive=True rescaleEvents=-
13:47:13Z | cpu:        1%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:47:03Z ready=2 scalingActive=True rescaleEvents=NewSize=2@4e0f4a74-dfeb-41b9-8878-29b9eedf3d79
13:47:24Z | cpu:        1%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:47:03Z ready=2 scalingActive=True rescaleEvents=-
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each transition is credited only when one run-local SuccessfulRescale occurrence from HPA UID `8c1180ca-dcd6-4fb0-87fe-8b0ed1bae32f` names its exact target count. HPA status fields remain diagnostics, not causation evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 13:41:38Z | up | 2 -> 3 | scale subresource | SuccessfulRescale event telemetry-processor.18cf88120f0f9fc6 (event UID c04a346b-dc34-48de-b16d-6da715b6c74d, occurrence +1) names New size 3; observed on the transition sample at 13:41:39Z, controller timestamp 13:41:32Z |
| 13:47:03Z | down | 3 -> 2 | scale subresource | SuccessfulRescale event telemetry-processor.18cf886d140fcc84 (event UID 4e0f4a74-dfeb-41b9-8878-29b9eedf3d79, occurrence +1) names New size 2; observed one sample late while desired remained 2 at 13:47:13Z, controller timestamp 13:47:03Z |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
