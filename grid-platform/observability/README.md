# `observability/` — the signals, the alerts and the cost join

What the platform knows about itself: the metrics it records, the alerts that read them, the
dashboards an operator opens, and the query that turns device time into a number a finance team
accepts.

| What lands here | Owning module |
|---|---|
| metric scrape and recording-rule configuration | M12 |
| alerting rules, with the signal each one reads named | M12 |
| dashboard definitions, generated against the pinned dashboard release | M12 |
| the chargeback queries that join device attribution, utilisation and cost | M12 |
| the cost-model input values, with their source and date stated | M12 |
| the collector configuration for traces, where a lab reaches them | M12 |

Dashboard definitions are generated against the exact dashboard release this course pins, because
the definition schema changed across its last two major versions. A dashboard authored against a
different release imports silently and renders wrong.

## What does not land here

- The exporter and the device-health signal source. Publishing the signal is `nodes/` and belongs
  to M4; this directory consumes it.
- The written procedure an alert fires into. The alert rule is here; the procedure it pages is a
  runbook in `runbooks/`.
- The metrics endpoint on a model server. That is part of the server, in `serving/`.
- Cluster creation for the monitoring stack. That is `clusters/`.

## Why the owner is named at all

M12 is authored before M9 in the same phase, out of module order, because the failure mode of
leaving it last is not a short module — it is a course that tails off. The address being fixed in
advance is part of what makes moving it forward cheap.
