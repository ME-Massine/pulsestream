# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `61eeaf`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `18fe45627b8acc55f06b4fcdd26d181481d0e959` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Load | 3 pod(s), 1 concurrent POST /api/v1/events loops each |
| Peak utilization | 142% |
| Peak replicas | 6 |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready
18:51:55Z | cpu:        3%/70%  2  6  2 | ready=2    <- baseline, before load
18:52:31Z | cpu:       95%/70%  2  6  3 | ready=2
18:52:46Z | cpu:       95%/70%  2  6  3 | ready=2
18:53:01Z | cpu:       97%/70%  2  6  3 | ready=3
18:53:17Z | cpu:       46%/70%  2  6  3 | ready=3
18:53:32Z | cpu:      115%/70%  2  6  5 | ready=3
18:53:48Z | cpu:      125%/70%  2  6  5 | ready=3
18:54:04Z | cpu:       97%/70%  2  6  5 | ready=5
18:54:20Z | cpu:       42%/70%  2  6  5 | ready=5
18:54:37Z | cpu:       97%/70%  2  6  6 | ready=5
18:54:53Z | cpu:      142%/70%  2  6  6 | ready=5
18:55:09Z | cpu:       82%/70%  2  6  6 | ready=5
18:55:28Z | cpu:       66%/70%  2  6  6 | ready=6
18:55:45Z | cpu:       67%/70%  2  6  6 | ready=6
18:56:03Z | cpu:       76%/70%  2  6  6 | ready=6
18:56:19Z | cpu:       63%/70%  2  6  6 | ready=6
18:57:09Z | cpu:       54%/70%  2  6  6 | ready=6    <- load removed
18:57:25Z | cpu:       26%/70%  2  6  6 | ready=6
18:57:41Z | cpu:        3%/70%  2  6  6 | ready=6
18:57:57Z | cpu:        3%/70%  2  6  6 | ready=6
18:58:12Z | cpu:        3%/70%  2  6  6 | ready=6
18:58:28Z | cpu:        2%/70%  2  6  6 | ready=6
18:58:43Z | cpu:        2%/70%  2  6  6 | ready=6
18:58:59Z | cpu:        3%/70%  2  6  6 | ready=6
18:59:15Z | cpu:        2%/70%  2  6  6 | ready=6
18:59:31Z | cpu:        3%/70%  2  6  6 | ready=6
18:59:47Z | cpu:        4%/70%  2  6  6 | ready=6
19:00:03Z | cpu:        4%/70%  2  6  6 | ready=6
19:00:19Z | cpu:        2%/70%  2  6  6 | ready=6
19:00:34Z | cpu:        2%/70%  2  6  6 | ready=6
19:00:50Z | cpu:        2%/70%  2  6  6 | ready=6
19:01:06Z | cpu:        2%/70%  2  6  6 | ready=6
19:01:21Z | cpu:        3%/70%  2  6  6 | ready=6
19:01:37Z | cpu:        3%/70%  2  6  6 | ready=6
19:01:53Z | cpu:        2%/70%  2  6  6 | ready=6
19:02:08Z | cpu:        3%/70%  2  6  5 | ready=5
19:02:24Z | cpu:        3%/70%  2  6  5 | ready=5
19:02:39Z | cpu:        2%/70%  2  6  5 | ready=5
19:02:55Z | cpu:        2%/70%  2  6  5 | ready=5
19:03:10Z | cpu:        2%/70%  2  6  4 | ready=4
19:03:26Z | cpu:        2%/70%  2  6  4 | ready=4
19:03:41Z | cpu:        2%/70%  2  6  4 | ready=4
19:03:57Z | cpu:        1%/70%  2  6  4 | ready=4
19:04:12Z | cpu:        1%/70%  2  6  3 | ready=3
19:04:27Z | cpu:        2%/70%  2  6  3 | ready=3
19:04:42Z | cpu:        2%/70%  2  6  3 | ready=3
19:04:58Z | cpu:        2%/70%  2  6  3 | ready=3
19:05:13Z | cpu:        3%/70%  2  6  2 | ready=2
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 18:52:31Z | up | 2 -> 3 |
| 18:53:32Z | up | 3 -> 5 |
| 18:54:37Z | up | 5 -> 6 |
| 19:02:08Z | down | 6 -> 5 |
| 19:03:10Z | down | 5 -> 4 |
| 19:04:12Z | down | 4 -> 3 |
| 19:05:13Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-ingestion-service-hpa.ps1`.
