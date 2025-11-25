#!/usr/bin/env perl

use Modern::Perl;

use C4::Context;
use DBI;
use JSON;
use LWP::UserAgent;
use POSIX qw(strftime);
use Getopt::Long::Descriptive;

#
# Extract instance we are working on
#

my $conf = $ENV{KOHA_CONF};
my ($INSTANCE) = $conf =~ m{/sites/([^/]+)/}
    or die "Unable to extract instance name from KOHA_CONF: $conf";

#
# CLI OPTIONS
#

my ($opt, $usage) = describe_options(
    "%c %o",
    ["slack-webhook|s=s", "Slack incoming webhook URL",                ],
    ["max-new-jobs|n=i",  "Threshold: number of 'new' jobs",           { default => 100 }],
    ["max-rate|r=i",      "Threshold: number of new jobs created",     { default => 200 }],
    ["window|w=i",        "Rate window in minutes, set to the cronjob frequency", { default => 1 }],
    ["queue|q=s",        "Queue to work on",                    { default => 'default' }],
    ["max-running-age|a=i","Max allowed age (minutes) for 'running'",  { default => 0 }],
    ["state-file|f=s",    "Path to state file",                        { default => $ENV{XDG_DATA_HOME} ? "$ENV{XDG_DATA_HOME}/koha_job_monitor_state.json" : "$ENV{HOME}/.local/share/koha_job_monitor_state.json" }],
    ["one-shot|o",        "Output current metrics and exit, does not affect state file" ],
    ["verbose|v",         "Enable verbose output" ],
    ["help|h",            "Show this help", { shortcircuit => 1 }],
);

if ($opt->help) {
    print $usage->text;
    exit;
}

#
# Thresholds & config
#

my $MAX_NEW_JOBS         = $opt->max_new_jobs;
my $MAX_NEW_JOBS_RATE    = $opt->max_rate;
my $MAX_RUNNING_AGE      = $opt->max_running_age;
my $ONE_SHOT             = $opt->one_shot;
my $RATE_WINDOW_MINUTES  = $opt->window;
my $SLACK_WEBHOOK        = $opt->slack_webhook;
my $STATE_FILE           = $opt->state_file;
my $VERBOSE              = $opt->verbose;
my $QUEUE                = $opt->queue;

#
# Get DB handle via Koha
#

my $dbh = C4::Context->dbh;

#
# Query for metrics
#

# Count of new jobs
my ($new_count) = $dbh->selectrow_array(
    "SELECT COUNT(*) FROM background_jobs WHERE status='new' AND queue='$QUEUE'"
);

# Rate of new jobs
my ($jobs_rate) = $dbh->selectrow_array(qq{
    SELECT COUNT(*)
      FROM background_jobs
     WHERE status='new'
       AND queue='$QUEUE'
       AND enqueued_on > NOW() - INTERVAL $RATE_WINDOW_MINUTES MINUTE
});

# Jobs stuck in running
my $stuck_jobs = $MAX_RUNNING_AGE ? $dbh->selectall_arrayref(qq{
    SELECT id, type, TIMESTAMPDIFF(MINUTE, started_on, NOW()) AS age
      FROM background_jobs
     WHERE status='running'
       AND queue='$QUEUE'
       AND started_on IS NOT NULL
       AND TIMESTAMPDIFF(MINUTE, started_on, NOW()) > $MAX_RUNNING_AGE
}, { Slice => {} }) : [];

my $stuck_count = scalar(@$stuck_jobs);

# Summary per type
my $summary_rows = $dbh->selectall_arrayref(qq{
    SELECT type, status, COUNT(*) AS c
      FROM background_jobs
     WHERE queue='$QUEUE'
  GROUP BY type, status
}, { Slice => {} });

#
# Handle one shot
#
if ( $ONE_SHOT || $VERBOSE ) {

    say "=== Koha Background Job Status (queue='$QUEUE') For $INSTANCE ===\n";

    # determine width of the right column
    my @nums = ($new_count, $jobs_rate, $stuck_count);
    my $width = 0;
    $width = length($_) > $width ? length($_) : $width for @nums;

    # formatted lines
    printf "%-40s %${width}d\n", "Current new jobs:", $new_count;
    printf "%-40s %${width}d\n", "New jobs in last $RATE_WINDOW_MINUTES minutes:", $jobs_rate;
    printf "%-40s %${width}d\n",
        "Jobs running for more than $MAX_RUNNING_AGE minutes:", $stuck_count;

    say "\n--- Job Summary ---";
    print_summary_table($summary_rows);

    say q{};

    exit 0 if $ONE_SHOT;
}

#
# Load previous state
#

my $previous_state = load_state($STATE_FILE);
$previous_state->{new_count}     //= 0;
$previous_state->{rate}          //= 0;
$previous_state->{stuck_running} //= 0;

my $current_state = {
new_count => $new_count,
rate => $jobs_rate,
stuck_running => $stuck_count,
};

#
# Alert conditions
#

#################################################
# Slack Alerts
#################################################

my $alerted = 0;

warn "PREV STATE: " . Data::Dumper::Dumper( $previous_state );
# Max 'new' jobs ceiling exceeded
$alerted ||= handle_alert(
    state_key   => "new_count",
    is_active   => $current_state->{new_count} > $MAX_NEW_JOBS,
    was_active  => $previous_state->{new_count} > $MAX_NEW_JOBS,
    message_on  => ":warning: [$INSTANCE] *Koha job backlog alert*: $new_count new jobs (threshold $MAX_NEW_JOBS)",
    message_off => ":white_check_mark: [$INSTANCE] Koha job backlog recovered: $new_count new jobs.",
);

# Rate exceeded
$alerted ||= handle_alert(
    state_key   => "rate",
    is_active  => $current_state->{last_jobs_rate} > $MAX_NEW_JOBS_RATE,
    was_active  => $previous_state->{last_jobs_rate} > $MAX_NEW_JOBS_RATE,
    message_on  => ":warning: [$INSTANCE] *Koha job creation rate alert*: $jobs_rate in last $RATE_WINDOW_MINUTES minutes (threshold $MAX_NEW_JOBS_RATE)",
    message_off => ":white_check_mark: [$INSTANCE] Koha job creation rate recovered to $jobs_rate.",
);

# Stuck jobs
$alerted ||= handle_alert(
    state_key   => "stuck_running",
    is_active  => $current_state->{last_stuck_count} > 0,
    was_active  => $previous_state->{last_stuck_count} > 0,
    message_on  => stuck_jobs_message($stuck_jobs, $MAX_RUNNING_AGE),
    message_off => ":white_check_mark: All running jobs are now under $MAX_RUNNING_AGE minutes.",
);

# Send summary if any alert was triggered
send_slack( summary_message($summary_rows) ) if $SLACK_WEBHOOK && $alerted;

# Save state for next run
save_state($STATE_FILE, $current_state);

# Functions

sub summary_message {
    my ($rows) = @_;
    my %data;

    foreach my $r (@$rows) {
        $data{$r->{type}}{$r->{status}} = $r->{c};
    }

    my $text = "*Koha Job Summary (queue='$QUEUE'):*\n";

    foreach my $type (sort keys %data) {
        $text .= "*$type*: ";
        my @parts;
        foreach my $status (sort keys %{$data{$type}}) {
            push @parts, "$status=$data{$type}{$status}";
        }
        $text .= join(", ", @parts) . "\n";
    }

    return $text;
}

sub stuck_jobs_message {
    my ($jobs, $limit) = @_;
    my $msg = ":warning: *Koha jobs stuck in 'running' for more than $limit minutes:*\n";

    foreach my $j (@$jobs) {
        $msg .= "• Job $j->{id} ($j->{type}) – running for $j->{age} minutes\n";
    }

    return $msg;
}

sub handle_alert {
    my %args = @_;
warn Data::Dumper::Dumper( \%args );

    my $key        = $args{state_key};
    my $is_active     = $args{is_active};
    my $was_active = $args{was_active};
    my $msg_on     = $args{message_on};
    my $msg_off    = $args{message_off};

    if ($is_active) { # && !$was_active) {
        say "ALERT: $msg_on" if $VERBOSE || !$SLACK_WEBHOOK;
        send_slack($msg_on) if $SLACK_WEBHOOK;
        $previous_state->{$key} = 1;
	return 1;
    }
    elsif (!$is_active && $was_active) {
        say "ALERT: $msg_off" if $VERBOSE || !$SLACK_WEBHOOK;
        send_slack($msg_off) if $SLACK_WEBHOOK;
        $previous_state->{$key} = 0;
        return 1;
    }

    return 0;
}

sub send_slack {
    my ($text) = @_;
    my $ua = LWP::UserAgent->new;

    my $payload = encode_json({ text => $text });

    my $resp = $ua->post(
        $SLACK_WEBHOOK,
        Content => $payload,
        'Content-Type' => 'application/json'
    );

    warn "Slack POST failed: " . $resp->status_line
        if !$resp->is_success;
}

sub load_state {
    my ($file) = @_;
    return {} unless -f $file;

    open my $fh, "<", $file or return {};
    local $/;
    my $json = <$fh>;
    close $fh;

    return decode_json($json);
}

sub save_state {
    my ($file, $state) = @_;
    open my $fh, ">", $file or die "Cannot write state file '$file': $!";
    print $fh encode_json($state);
    close $fh;
}

sub print_summary_table {
    my ($rows) = @_;

    # Determine column widths
    my $w_type  = length("type");
    my $w_status = length("status");
    my $w_count = length("count");

    foreach my $r (@$rows) {
        $w_type   = length($r->{type}) if length($r->{type}) > $w_type;
        $w_status = length($r->{status})   if length($r->{status}) > $w_status;
        $w_count  = length($r->{c})        if length($r->{c}) > $w_count;
    }

    # Print header
    printf "%-*s  %-*s  %*s\n",
        $w_type, "type",
        $w_status, "status",
        $w_count, "count";

    # Separator
    print "-" x ($w_type + $w_status + $w_count + 4), "\n";

    # Print rows
    foreach my $r (@$rows) {
        printf "%-*s  %-*s  %*d\n",
            $w_type,   $r->{type},
            $w_status, $r->{status},
            $w_count,  $r->{c};
    }
}
