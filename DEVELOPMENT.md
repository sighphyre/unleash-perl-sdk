# Development Guide

This guide covers local development setup, testing, and contribution workflow for the Perl SDK.

## Prerequisites

- Perl 5.20+
- `Mojolicious` installed (recommended into local `.local`)
- Local checkout of Yggdrasil bindings on branch `feat/perl-engine`

Clone Yggdrasil bindings:

```sh
git clone git@github.com:Unleash/yggdrasil-bindings.git
cd yggdrasil-bindings
git checkout feat/perl-engine
```

## Yggdrasil Local Publish

The Perl SDK depends on the locally packaged Yggdrasil engine while development is ongoing.

From the Yggdrasil bindings repo (`yggdrasil-bindings/perl-engine`), build and package:

```sh
./build.sh
perl Makefile.PL
make
make test
rm -f Yggdrasil-Engine-0.1.0.tar.gz
make dist
```

Install the tarball into a local Perl library path:

```sh
cpanm -L /tmp/yggdrasil-perl-local Yggdrasil-Engine-0.1.0.tar.gz
```

In this SDK repo, use local libs for commands in your shell:

```sh
export PERL5LIB="/tmp/yggdrasil-perl-local/lib/perl5:$PWD/.local/lib/perl5:$PERL5LIB"
```

## Running Tests

Run all tests:

```sh
prove -I lib t
```

Run with local libs explicitly:

```sh
PERL5LIB="/tmp/yggdrasil-perl-local/lib/perl5:$PWD/.local/lib/perl5:$PERL5LIB" prove -I lib t
```

## Client Specification Tests

Clone the spec repository into this project root:

```sh
git clone git@github.com:Unleash/client-specification.git
```

The test suite reads spec files from `client-specification/specifications`.

## Contribution Notes

Contributions are welcome.

If you add or remove files that are distributed, update `MANIFEST` before creating a release tarball.
