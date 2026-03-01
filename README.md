# Perl SDK Shell

Library-first Perl scaffold.

## Layout

- `lib/Srv/SDK.pm`: library module
- `bin/basic_usage.pl`: minimal `is_enabled` example
- `bin/variant_usage.pl`: minimal `get_variant` example
- `bin/custom_strategy_usage.pl`: custom strategy registration example
- `t/basic.t`: basic module test

## Run Examples

```sh
./bin/basic_usage.pl
```

```sh
./bin/variant_usage.pl
```

```sh
./bin/custom_strategy_usage.pl
```

## Run Tests

```sh
prove -I lib t
```

If dependencies are installed into local `.local`, run tests with:

```sh
PERL5LIB="$PWD/.local/lib/perl5:$PERL5LIB" prove -I lib t
```

If you installed a local Yggdrasil package (for example via `cpanm -L /tmp/yggdrasil-perl-local ...`),
prepend that path too:

```sh
PERL5LIB="/tmp/yggdrasil-perl-local/lib/perl5:$PWD/.local/lib/perl5:$PERL5LIB" prove -I lib t
```

For spec testing, clone the Unleash client specification repo into this project root:

```sh
git clone git@github.com:Unleash/client-specification.git
```

## Install The Library

### Option 1: ExtUtils::MakeMaker (classic)

```sh
perl Makefile.PL
make
make test
```

Install for your current user/project path (no sudo):

```sh
make install INSTALL_BASE=$PWD/.local
```

Then use it in this shell:

```sh
export PERL5LIB="$PWD/.local/lib/perl5:$PERL5LIB"
```

### Option 2: cpanm from local directory

```sh
cpanm --installdeps .
cpanm --local-lib-contained "$PWD/.local" .
```

Then use it in this shell:

```sh
export PERL5LIB="$PWD/.local/lib/perl5:$PERL5LIB"
export PATH="$PWD/.local/bin:$PATH"
```
