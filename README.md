# Koha Background Job Monitor

A Perl script to monitor Koha background jobs, alerting via Slack when thresholds are exceeded, and providing job summary metrics.

## Features

* Detects:
  * High number of new jobs.
  * High job creation rate.
  * Jobs stuck in `running` status beyond a configurable age.
* Sends alerts to Slack using an incoming webhook.
* Maintains a persistent state to track ongoing alerts and avoid duplicate notifications.
* Supports one-shot mode for reporting metrics without affecting the state file.
* Provides a formatted summary table of jobs by type and status.

## Requirements

* A Koha install ( this script should be run as the Koha user for an instance )
* Perl 5.20+ with the following modules not included with Koha:
  * `Getopt::Long::Descriptive`
* (Optional) Slack incoming webhook URL for notifications.

### Options

| Option                    | Description                                                    | Default                                                                                          |
| ------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `--slack-webhook`, `-s`   | Slack incoming webhook URL for alerts                          | -                                                                                                |
| `--max-new-jobs`, `-n`    | Threshold for number of new jobs                               | 100                                                                                              |
| `--max-rate`, `-r`        | Threshold for number of new jobs created within the window     | 200                                                                                              |
| `--window`, `-w`          | Rate calculation window in minutes                             | 1                                                                                                |
| `--queue`, `-q`           | Queue to monitor                                               | `default`                                                                                        |
| `--max-running-age`, `-a` | Maximum allowed age (minutes) for running jobs before alerting | 0 (disabled)                                                                                     |
| `--state-file`, `-f`      | Path to state file                                             | `$XDG_DATA_HOME/koha_job_monitor_state.json` or `$HOME/.local/share/koha_job_monitor_state.json` |
| `--one-shot`, `-o`        | Output current metrics and exit (does not affect state)        | -                                                                                                |
| `--verbose`, `-v`         | Enable verbose output                                          | -                                                                                                |
| `--help`, `-h`            | Show usage help                                                | -                                                                                                |

### Examples

* **One-shot summary for the default queue:**

```bash
./koha_job_monitor.pl --one-shot --verbose
```

* **Monitor a specific queue with Slack alerts:**

```bash
./koha_job_monitor.pl --queue=elastic_index --slack-webhook=https://hooks.slack.com/services/XXXXX/XXXXX/XXXXX
```

* **Override default thresholds and rate window:**

```bash
./koha_job_monitor.pl --max-new-jobs=50 --max-rate=100 --window=5
```

### Alert Conditions

The script triggers alerts under these conditions:

* **New jobs exceed threshold:** If the number of jobs with status `new` exceeds `--max-new-jobs`.
* **High job creation rate:** If the number of new jobs in the last `--window` minutes exceeds `--max-rate`.
* **Stuck running jobs:** If jobs in `running` state exceed `--max-running-age` minutes.

Alerts are sent to Slack if a webhook is configured, and only when the state changes to prevent duplicate notifications.

### State File

* By default, the script saves its state in a JSON file at:

```
$XDG_DATA_HOME/koha_job_monitor_state.json
```

or

```
$HOME/.local/share/koha_job_monitor_state.json
```

* The state file stores counts of previous alerts to track ongoing conditions and suppress repeated messages.

### Job Summary

The script produces a summary table grouped by job type and status, for example:

```
type        status   count
--------------------------
EmailJob    new      12
EmailJob    running  3
IndexerJob  new      5
```

This summary is included in Slack notifications and one-shot output.

## Cron Example

To run the script every minute for the default queue and send Slack alerts:

```cron
* * * * * /path/to/koha_job_monitor.pl --slack-webhook=https://hooks.slack.com/services/XXXXX/XXXXX/XXXXX --queue=default -w 1
```

Adjust the frequency to match the `--window` parameter.

## License

AGPLv3
