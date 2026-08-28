# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `667f57`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `034d2da3004fc2c842865efa8554af6bc2fc297b` |
| Kubernetes versions | client `v1.36.1`; server `v1.36.1` |
| HPA identity | `ingestion-service` UID `7e03694f-fac1-4371-a5b3-3859cc590d57`, generation `<not reported by API>`; UID, generation, and spec remained fixed throughout the run |
| SuccessfulRescale baseline | Established at 2026-08-28T01:33:49Z; pre-existing event UIDs/counts were excluded, and collection succeeded in all 70 samples |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `10s`; recommendation evidence collected over intervals shown below (widest `4s`); widest conservative evidence gap `24s`, gap before the scale-in recommendation `12s`; window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; evidence intervals separated by more than `60s` stop counting as continuous observation) |
| Load | 1 pod(s), 6 concurrent POST /api/v1/events loops each |
| Load heartbeat | `autoscaling-load-667f57-1` advanced from `633` to `52079` |
| HPA ScalingActive | `True` in all 69 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 7 of 7 replica transitions mapped one-to-one to post-baseline SuccessfulRescale occurrences from the exact HPA UID with an exact matching `New size`; 0 unmatched occurrence(s) |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 277s`: from completion of the anchor evidence bundle at 01:38:45Z (6 replicas, cpu utilization 10/70 (6 measured) -> 1, clamped to [2, 6] -> 2) through the start of the last recommending bundle at 01:43:22Z; its old desired count was observed at 01:43:23Z, and the decision at 01:43:33Z (anchor-to-observation spacing `288s`, recommendation turnover uncertain by the `12s` conservative evidence gap ending at the anchor). |
| Peak utilization | 306% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
completed | evidence started | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive  newly observed SuccessfulRescale events
01:33:50Z | evidenceStart=01:33:49Z cpu:        2%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=18:33:21Z ready=2 scalingActive=True rescaleEvents=-    <- baseline, before load
01:34:12Z | evidenceStart=01:34:11Z cpu:       93%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:34:08Z ready=2 scalingActive=True rescaleEvents=NewSize=3@b910cc70-8795-46d4-98a6-e95dba7821dd
01:34:24Z | evidenceStart=01:34:23Z cpu:       93%/70%  2  6  3 | desired=4 hpaDesired=3 lastScale=01:34:08Z ready=2 scalingActive=True rescaleEvents=-
01:34:35Z | evidenceStart=01:34:34Z cpu:      306%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:34:23Z ready=3 scalingActive=True rescaleEvents=NewSize=4@cede5fff-b220-4b7c-b260-d051b528abbb
01:34:46Z | evidenceStart=01:34:45Z cpu:      208%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:34:23Z ready=4 scalingActive=True rescaleEvents=-
01:34:57Z | evidenceStart=01:34:56Z cpu:      136%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:34:23Z ready=4 scalingActive=True rescaleEvents=-
01:35:09Z | evidenceStart=01:35:08Z cpu:      136%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:34:23Z ready=4 scalingActive=True rescaleEvents=-
01:35:20Z | evidenceStart=01:35:19Z cpu:      121%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=4 scalingActive=True rescaleEvents=NewSize=6@9ff6b4e3-8317-41fc-a39e-9357b98b2f45
01:35:31Z | evidenceStart=01:35:31Z cpu:      105%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:35:43Z | evidenceStart=01:35:42Z cpu:      148%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:35:54Z | evidenceStart=01:35:53Z cpu:      148%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:36:05Z | evidenceStart=01:36:04Z cpu:       88%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:36:16Z | evidenceStart=01:36:15Z cpu:       97%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:36:28Z | evidenceStart=01:36:27Z cpu:       70%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:36:39Z | evidenceStart=01:36:38Z cpu:       70%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:36:50Z | evidenceStart=01:36:49Z cpu:       71%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:01Z | evidenceStart=01:37:00Z cpu:       58%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:12Z | evidenceStart=01:37:11Z cpu:       61%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:23Z | evidenceStart=01:37:23Z cpu:       61%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:35Z | evidenceStart=01:37:34Z cpu:       68%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:46Z | evidenceStart=01:37:45Z cpu:       63%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:37:57Z | evidenceStart=01:37:56Z cpu:       55%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:38:08Z | evidenceStart=01:38:07Z cpu:       55%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:38:13Z | evidenceStart=01:38:12Z cpu:       68%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-    <- load removed
01:38:24Z | evidenceStart=01:38:23Z cpu:       68%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:38:34Z | evidenceStart=01:38:34Z cpu:       60%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:38:45Z | evidenceStart=01:38:44Z cpu:       10%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:38:56Z | evidenceStart=01:38:55Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:39:06Z | evidenceStart=01:39:06Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:39:17Z | evidenceStart=01:39:17Z cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:39:28Z | evidenceStart=01:39:27Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:39:38Z | evidenceStart=01:39:38Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:39:49Z | evidenceStart=01:39:49Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:00Z | evidenceStart=01:39:59Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:11Z | evidenceStart=01:40:10Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:21Z | evidenceStart=01:40:21Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:32Z | evidenceStart=01:40:31Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:43Z | evidenceStart=01:40:42Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:40:53Z | evidenceStart=01:40:53Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:04Z | evidenceStart=01:41:03Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:15Z | evidenceStart=01:41:14Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:25Z | evidenceStart=01:41:25Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:36Z | evidenceStart=01:41:35Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:47Z | evidenceStart=01:41:46Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:41:57Z | evidenceStart=01:41:57Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:42:08Z | evidenceStart=01:42:08Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:42:19Z | evidenceStart=01:42:18Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:42:29Z | evidenceStart=01:42:29Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:42:40Z | evidenceStart=01:42:39Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:42:51Z | evidenceStart=01:42:50Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:43:01Z | evidenceStart=01:43:01Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:43:12Z | evidenceStart=01:43:12Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:43:23Z | evidenceStart=01:43:22Z cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=01:35:08Z ready=6 scalingActive=True rescaleEvents=-
01:43:34Z | evidenceStart=01:43:33Z cpu:        2%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=01:43:24Z ready=5 scalingActive=True rescaleEvents=NewSize=5@4b12e77d-32d3-4e72-9172-33d83c1ecb57
01:43:44Z | evidenceStart=01:43:44Z cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=01:43:24Z ready=5 scalingActive=True rescaleEvents=-
01:43:55Z | evidenceStart=01:43:54Z cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=01:43:24Z ready=5 scalingActive=True rescaleEvents=-
01:44:06Z | evidenceStart=01:44:05Z cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=01:43:24Z ready=5 scalingActive=True rescaleEvents=-
01:44:17Z | evidenceStart=01:44:16Z cpu:        2%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=01:43:24Z ready=5 scalingActive=True rescaleEvents=-
01:44:27Z | evidenceStart=01:44:27Z cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:44:24Z ready=4 scalingActive=True rescaleEvents=NewSize=4@6bd36e26-02be-425c-be21-95011ec800e0
01:44:40Z | evidenceStart=01:44:38Z cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:44:24Z ready=4 scalingActive=True rescaleEvents=-
01:44:52Z | evidenceStart=01:44:50Z cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:44:24Z ready=4 scalingActive=True rescaleEvents=-
01:45:06Z | evidenceStart=01:45:03Z cpu:        2%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:44:24Z ready=4 scalingActive=True rescaleEvents=-
01:45:18Z | evidenceStart=01:45:17Z cpu:        2%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=01:44:24Z ready=4 scalingActive=True rescaleEvents=-
01:45:31Z | evidenceStart=01:45:29Z cpu:        6%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:45:24Z ready=3 scalingActive=True rescaleEvents=NewSize=3@6a01cf10-2ade-4104-a4c1-c372d55d8f78
01:45:42Z | evidenceStart=01:45:41Z cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:45:24Z ready=3 scalingActive=True rescaleEvents=-
01:45:54Z | evidenceStart=01:45:52Z cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:45:24Z ready=3 scalingActive=True rescaleEvents=-
01:46:05Z | evidenceStart=01:46:04Z cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:45:24Z ready=3 scalingActive=True rescaleEvents=-
01:46:17Z | evidenceStart=01:46:15Z cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=01:45:24Z ready=3 scalingActive=True rescaleEvents=-
01:46:28Z | evidenceStart=01:46:27Z cpu:        2%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=01:46:24Z ready=2 scalingActive=True rescaleEvents=NewSize=2@2f593300-f2db-4632-b263-fa10de7af735
01:46:39Z | evidenceStart=01:46:38Z cpu:        2%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=01:46:24Z ready=2 scalingActive=True rescaleEvents=-
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each transition is credited only when one run-local SuccessfulRescale occurrence from HPA UID `7e03694f-fac1-4371-a5b3-3859cc590d57` names its exact target count. HPA status fields remain diagnostics, not causation evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 01:34:12Z | up | 2 -> 3 | scale subresource | SuccessfulRescale event ingestion-service.18cfd428c7774e3f (event UID b910cc70-8795-46d4-98a6-e95dba7821dd, occurrence +1) names New size 3; observed on the transition sample at 01:34:12Z, controller timestamp 01:34:08Z |
| 01:34:23Z | up | 3 -> 4 | scale subresource | SuccessfulRescale event ingestion-service.18cfd42c482efc9f (event UID cede5fff-b220-4b7c-b260-d051b528abbb, occurrence +1) names New size 4; observed one sample late while desired remained 4 at 01:34:35Z, controller timestamp 01:34:23Z |
| 01:35:20Z | up | 4 -> 6 | scale subresource | SuccessfulRescale event ingestion-service.18cfd436c6a97450 (event UID 9ff6b4e3-8317-41fc-a39e-9357b98b2f45, occurrence +1) names New size 6; observed on the transition sample at 01:35:20Z, controller timestamp 01:35:08Z |
| 01:43:33Z | down | 6 -> 5 | scale subresource | SuccessfulRescale event ingestion-service.18cfd4aa29571465 (event UID 4b12e77d-32d3-4e72-9172-33d83c1ecb57, occurrence +1) names New size 5; observed on the transition sample at 01:43:34Z, controller timestamp 01:43:24Z |
| 01:44:27Z | down | 5 -> 4 | scale subresource | SuccessfulRescale event ingestion-service.18cfd4b8257b0359 (event UID 6bd36e26-02be-425c-be21-95011ec800e0, occurrence +1) names New size 4; observed on the transition sample at 01:44:27Z, controller timestamp 01:44:24Z |
| 01:45:30Z | down | 4 -> 3 | scale subresource | SuccessfulRescale event ingestion-service.18cfd4c623fe3bef (event UID 6a01cf10-2ade-4104-a4c1-c372d55d8f78, occurrence +1) names New size 3; observed on the transition sample at 01:45:31Z, controller timestamp 01:45:24Z |
| 01:46:27Z | down | 3 -> 2 | scale subresource | SuccessfulRescale event ingestion-service.18cfd4d42572fac1 (event UID 2f593300-f2db-4632-b263-fa10de7af735, occurrence +1) names New size 2; observed on the transition sample at 01:46:28Z, controller timestamp 01:46:24Z |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
