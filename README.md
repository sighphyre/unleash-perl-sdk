# Perl SDK

The `Srv::SDK` client evaluates Unleash feature flags locally using the Yggdrasil engine.

You can use this SDK against Unleash Enterprise, Unleash Open Source, or Unleash Edge via the Client API.

## Requirements

- Perl 5.20+
- `Yggdrasil::Engine` (from the yggdrasil Perl bindings package)
- `Mojolicious` (for `Mojo::IOLoop`, `Mojo::UserAgent`, `Mojo::Promise`, `Mojo::EventEmitter`)

## Installation

Install project dependencies locally:

```sh
cpanm --local-lib-contained "$PWD/.local" Mojolicious
```

If you are using a locally packaged Yggdrasil engine:

```sh
cpanm -L /tmp/yggdrasil-perl-local Yggdrasil-Engine-0.1.0.tar.gz
```

Use both local lib paths when running examples/tests:

```sh
export PERL5LIB="/tmp/yggdrasil-perl-local/lib/perl5:$PWD/.local/lib/perl5:$PERL5LIB"
```

## Configuration

Create the SDK with `Srv::SDK->new(%args)`.

| Argument | Required | Default | Description |
|---|---|---|---|
| `unleash_url` | yes | - | Base URL to Unleash API, for example `http://localhost:4242/api`. |
| `api_key` | yes | - | Backend token sent as `Authorization` header. |
| `app_name` | no | `unleash-perl-app` | Included in register/metrics payloads and backup filename. |
| `instance_id` | no | generated UUID | Stable ID for this SDK process instance. |
| `polling_interval` | no | `15` | Legacy shared poll interval used when specific intervals are omitted. Must be `> 0`. |
| `fetch_features_interval` | no | `polling_interval` | Feature fetch interval in seconds. `0` disables feature polling scheduler. |
| `send_metrics_interval` | no | `polling_interval` | Metrics send interval in seconds. `0` disables metrics scheduler. |
| `state_backup_dir` | no | `/tmp` | Directory for local state backup file `{app_name}-perl-sdk.json`. |
| `bootstrap_function` | no | `undef` | Coderef returning JSON string in `/client/features` format. |
| `custom_strategies` | no | `{}` | Hashref of strategy name => coderef. |
| `supported_strategies` | no | `[]` | Optional strategy names sent during registration (arrayref or hashref keys). |

Notes:
- Custom headers are not currently supported (other than SDK-managed headers like `Authorization` and `Unleash-Client-Spec`).

## Initialization

Initialize early in your application lifecycle:

```perl
use Srv::SDK;

my $sdk = Srv::SDK->new(
    unleash_url => $ENV{UNLEASH_URL},
    api_key     => $ENV{UNLEASH_API_KEY},
    app_name    => 'my-perl-service',
);

$sdk->initialize();
```

## Wait Until Ready

The SDK emits `ready` after the first successful HTTP fetch from Unleash.
Bootstrap and local backup hydration do not emit `ready`.

```perl
$sdk->on(ready => sub {
    print "SDK is ready\n";
});

$sdk->initialize();
```

## Check Flags

### Check if a flag is enabled

```perl
my $enabled = $sdk->is_enabled(
    'my-feature',
    { userId => 'user-123' },
    sub { 0 },
);
```

`is_enabled($toggle_name, $context, $fallback)` behavior:
- `toggle_name` is required.
- `context` should be a hashref (use `{}` if omitted).
- `fallback` is optional coderef returning a boolean-like value.

### Check a flag variant

```perl
my $variant = $sdk->get_variant(
    'checkout-experiment',
    { userId => 'user-123' },
    sub {
        return {
            name           => 'fallback',
            enabled        => 1,
            featureEnabled => 1,
            payload        => { type => 'string', value => 'default' },
        };
    },
);
```

`get_variant($toggle_name, $context, $fallback)` behavior:
- Returns engine variant when available.
- Then uses fallback variant if provided.
- Without fallback, returns default:

```perl
{
    name           => 'disabled',
    payload        => undef,
    enabled        => 0,
    featureEnabled => <resolved toggle enabled state or 0>,
}
```

## Unleash Context

Pass a hashref context to both `is_enabled` and `get_variant`.

```perl
my $ctx = {
    userId     => 'user-123',
    sessionId  => 'session-abc',
    properties => {
        plan => 'enterprise',
    },
};

my $enabled = $sdk->is_enabled('my-feature', $ctx, sub { 0 });
my $variant = $sdk->get_variant('checkout-experiment', $ctx);
```

For gradual rollout stickiness, include at least `userId` or `sessionId`.

## Bootstrap Flag Data

Provide a bootstrap function that returns a JSON string in `/client/features` response format:

```perl
my $sdk = Srv::SDK->new(
    unleash_url => $ENV{UNLEASH_URL},
    api_key     => $ENV{UNLEASH_API_KEY},
    bootstrap_function => sub {
        open my $fh, '<', 'bootstrap.json' or return undef;
        local $/;
        return <$fh>;
    },
);
```

Startup hydration order/race:
- Network fetch starts immediately (async).
- Bootstrap and backup are read in parallel.
- If bootstrap wins first, it hydrates state (backup is ignored); network still continues.
- If backup wins first, it hydrates state; bootstrap/network may still supersede it.
- If network succeeds, it always hydrates and becomes authoritative.

## Local Caching And Offline Behavior

The SDK persists fetched feature state to:
- `{state_backup_dir}/{app_name}-perl-sdk.json`

Defaults:
- `state_backup_dir`: `/tmp`

On startup, cached and bootstrap data can hydrate state before the first successful network fetch.

If Unleash is temporarily unavailable:
- last known in-memory state continues to be used
- polling continues on configured intervals
- unresolved flags fall back to provided fallback or default `false`

## Events

The SDK is a `Mojo::EventEmitter`.

```perl
$sdk->on(ready => sub {
    print "ready\n";
});

$sdk->on(error => sub {
    my ($sdk, $message) = @_;
    warn "error: $message\n";
});

$sdk->on(impression => sub {
    my ($sdk, $event) = @_;
    # $event: { featureName, context, enabled, variant? }
});
```

Event semantics:
- `ready`: first successful HTTP feature fetch only.
- `error`: emitted when fetch requests fail/resolve with errors.
- `impression`: emitted on `is_enabled`/`get_variant` when engine indicates impression data should be emitted for that feature.

## Custom Strategies

Register custom strategies with `custom_strategies`.

```perl
my $example_strategy = sub {
    my ($parameters, $context) = @_;
    return 0 if ref($parameters) ne 'HASH' || ref($context) ne 'HASH';
    return 0 if !exists $parameters->{sound} || !exists $context->{sound};
    return $context->{sound} eq $parameters->{sound} ? 1 : 0;
};

my $sdk = Srv::SDK->new(
    unleash_url       => $ENV{UNLEASH_URL},
    api_key           => $ENV{UNLEASH_API_KEY},
    custom_strategies => {
        exampleStrategy => $example_strategy,
    },
);
```

## Impact Metrics

The SDK exposes impact metric methods directly:
- `define_counter($name, $help_text)`
- `inc_counter($name, $value, $labels)`
- `define_gauge($name, $help_text)`
- `set_gauge($name, $value, $labels)`
- `define_histogram($name, $help_text, $buckets)`
- `observe_histogram($name, $value, $labels)`

## Shutdown

Stop schedulers and clear in-flight guards:

```perl
$sdk->shutdown();
```

## Examples

Run examples:

```sh
./bin/basic_usage.pl
./bin/variant_usage.pl
./bin/custom_strategy_usage.pl
./bin/ready_usage.pl
./bin/impression_usage.pl
```

Environment variables used by examples:
- `UNLEASH_URL` (default `http://localhost:4242/api`)
- `UNLEASH_API_KEY` (default `default:development.unleash-insecure-api-token`)
- `UNLEASH_TOGGLE_NAME` (default depends on script)
- `UNLEASH_EVAL_INTERVAL` (default `1`)

## Testing

Run tests:

```sh
prove -I lib t
```

With local libs:

```sh
PERL5LIB="/tmp/yggdrasil-perl-local/lib/perl5:$PWD/.local/lib/perl5:$PERL5LIB" prove -I lib t
```

For client specification tests, clone the specs repo into project root:

```sh
git clone git@github.com:Unleash/client-specification.git
```
